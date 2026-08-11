import Foundation
import AVFoundation
import Combine
import Kingfisher
import OSLog
import QuartzCore
import SwiftData
import UIKit

/// CLAUDE.md §8: single source of truth for playback. Injected via SwiftUI environment.
/// Mini player and full-screen player both observe this object — neither owns its own `AVPlayer`.
///
/// Combine is used **only** here for `AVPlayer` time-observer bridging, per CLAUDE.md §2.9.
@available(iOS 17.0, *)
@MainActor
@Observable
final class PlayerStateManager {
    enum LoadState: Equatable {
        case idle
        case resolving
        /// File is being fetched. `progress` is 0…1 when known, nil during yt-dlp's mux/merge phase.
        /// `phase` labels which stream is in flight ("video", "audio", "stream") so the UI can show
        /// "Downloading video 42%" instead of two confusing identical bars in a row.
        case downloading(progress: Double?, phase: String?)
        case readyToPlay
        case failed(String)
    }

    // MARK: - Published state

    private(set) var currentVideo: Video?
    /// Cached artwork for the current video. Used both to populate `MPNowPlayingInfoCenter`
    /// (lock-screen + Control Center) and (in the future) any in-app UI that wants a UIImage rather
    /// than the SwiftUI `Image`. Refreshed when the current video changes.
    private(set) var currentArtwork: UIImage?
    private(set) var loadState: LoadState = .idle
    private(set) var isPlaying: Bool = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// Human-readable source/quality shown by the full player. This reports the actual selected
    /// native path, not merely the user's preferred ceiling.
    private(set) var playbackQualityLabel: String = "Resolving…"
    private(set) var hdDiagnosticMessage: String = "等待高清诊断"
    var miniPlayerVisible: Bool = false
    var fullScreenPresented: Bool = false

    // MARK: - AVPlayer

    /// `AVQueuePlayer` to unlock `advanceToNextItem()` and queue introspection for future preload.
    /// IMPORTANT: don't use `replaceCurrentItem(with:)` to load tracks — it's a no-op on
    /// `AVQueuePlayer` when the internal queue is empty (which is our usual state). Use the
    /// `removeAllItems()` + `insert(_:after:)` pattern via `swap(to:)` below.
    let player = AVQueuePlayer()

    /// YouTube's 720p/1080p DASH formats are split into a silent video stream and a separate AAC
    /// stream. `AVMutableComposition` cannot insert those remote fragmented-MP4 tracks reliably,
    /// so HD playback uses this second native player for audio and keeps it locked to `player`.
    private var adaptiveAudioPlayer: AVPlayer?
    private var adaptiveAudioStatusObservation: NSKeyValueObservation?
    private var adaptiveAudioErrorLogObservation: NSObjectProtocol?
    private var isCorrectingAdaptiveSync = false
    /// Watches for actual decoded video dimensions. `readyToPlay` alone can still mean a black
    /// remote DASH timeline with no pixel output.
    private var hdVideoOutputWatchTask: Task<Void, Never>?
    private var hdVideoOutput: AVPlayerItemVideoOutput?

    // MARK: - Collaborators

    let queue: QueueManager
    private let resolver: any PlaybackResolving
    private let preferences: UserPreferences
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "PlayerStateManager")

    /// Sticky "this queue is endless" intent. Set to `true` whenever the user loads a video
    /// without explicitly skipping recommendations (Home / Search / Mini-player / row taps),
    /// and `false` for curated batch actions like playlist's Play all / Shuffle all. Drives:
    ///   1. The per-load `fillQueueWithRecommendations` call in `resolveAndPlay`.
    ///   2. The auto-advance dead-end recovery in `playNext()` — when the queue runs out and
    ///      repeat is off, we fire a fresh recs fetch using the queue's last item as a seed,
    ///      then advance once new items land. That gives the requested "endless queue" feel:
    ///      whenever you reach the latest item, recommendations refill behind it.
    private var queueAcceptsRecommendations = true

    private var timeObserver: Any?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var statusCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemErrorLogObservation: NSObjectProtocol?
    private var playerErrorObservation: NSKeyValueObservation?
    private var defaultRateObservation: NSKeyValueObservation?
    init(
        queue: QueueManager = QueueManager(),
        resolver: any PlaybackResolving = PlaybackResolver(),
        preferences: UserPreferences = UserPreferences()
    ) {
        self.queue = queue
        self.resolver = resolver
        self.preferences = preferences
        // Keep the audio track running when the player view goes off-screen (popup minimize, app
        // backgrounded). Without this, AVPlayer pauses video tracks as soon as their pixel buffer
        // pipeline is no longer visible, which manifests as "audio cuts out the moment you collapse
        // the mini-player." Pairs with the `.playback` AVAudioSession configured at launch.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        // Restore the last-used playback speed. `defaultRate` is what `AVPlayerViewController`'s
        // speed menu writes, and `AVPlayer.play()` resumes at this rate (not the transient `rate`).
        // Setting it *before* installObservers keeps the KVO from firing back and re-saving the
        // same value during launch.
        player.defaultRate = Float(preferences.playbackRate)
        installObservers()
    }

    /// Tear-down hook for tests / app lifecycle. Call before releasing the manager. We avoid `deinit`
    /// here so we don't have to reach into main-actor-isolated state from a nonisolated context.
    func tearDownObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
    }

    // MARK: - Public commands

    /// Loads a video for playback.
    ///
    /// - Parameter skipRecommendations: when `true`, suppresses the post-play "fill queue with
    ///   YouTube recommendations" call. Pass this from explicit batch actions that already
    ///   populated a curated queue — playlist's Play all / Shuffle all — so the user's queue
    ///   stays exactly what they chose. Default is `false` so single-video taps from Home /
    ///   Search / Mini-player still get the YouTube-app-style autoplay chain.
    /// Play a local file already on disk — used by the **Link** tab's completed downloads.
    ///
    /// **Why a separate entry point and not `load(video:)`:** the YouTube-shaped resolver in
    /// `resolveAndPlay` calls `DownloadManager.ensureDownloaded` which keys off `videoID` and
    /// looks for `Documents/<id>.mp4`. URL-fetched files live under `Documents/<title>.mp4`
    /// and don't have a YouTube `videoID`, so threading them
    /// through the normal path would either crash or silently re-trigger a yt-dlp download.
    /// This method skips resolution entirely — the file is already there, just play it.
    ///
    /// **What we skip vs the normal load path:** watch-history upsert (URL files aren't in
    /// the YouTube `WatchHistoryEntry` schema), queue recommendation fill (no related-video
    /// surface for arbitrary URLs), and `ensureDownloaded` (file is on disk).
    /// **What we keep:** `currentVideo` (synthetic so the mini-player title/subtitle still
    /// render), `miniPlayerVisible` flipped true so LNPopupUI shows the bar, NowPlayingCenter
    /// update for lock-screen artwork, and the standard observe/loadItem flow so errors and
    /// playback state still surface through the existing UI.
    func loadLocalFile(at fileURL: URL, title: String, source: String?, thumbnailURL: URL?) {
        log.info("loadLocalFile path=\(fileURL.path, privacy: .public) title=\"\(title, privacy: .public)\"")
        if isPlaying { pause() }
        if !player.items().isEmpty { player.removeAllItems() }

        // Synthetic Video so the existing mini-player + FullScreenPlayer chrome (which read
        // `currentVideo` everywhere) work without conditional branches. Channel name reuses
        // the extractor ("YouTube", "Vimeo", …) — closest analogue for arbitrary URLs.
        let synthetic = Video(
            id: "fetch-" + UUID().uuidString,
            title: title,
            channelID: "",
            channelName: source ?? "Link",
            channelThumbnailURL: nil,
            thumbnailURL: thumbnailURL,
            duration: nil,
            viewCount: nil,
            publishedAt: nil,
            descriptionSnippet: nil,
            isLive: false,
            isShort: false
        )
        currentVideo = synthetic
        // Bypass the queue's YouTube-related tracking — URL files don't participate in the
        // recommendation chain. setCurrent appends to the queue dataset for upcoming-up UI;
        // we just zero it for arbitrary files.
        queueAcceptsRecommendations = false
        miniPlayerVisible = true
        elapsed = 0
        duration = 0
        refreshArtwork(for: synthetic)

        let item = AVPlayerItem(url: fileURL)
        loadItem(item)
        loadState = .readyToPlay
        updateNowPlaying()
        play()
    }

    func load(_ video: Video, autoplay: Bool = true, skipRecommendations: Bool = false) {
        log.info("load(\(video.id, privacy: .public)) autoplay=\(autoplay, privacy: .public) skipRecs=\(skipRecommendations, privacy: .public)")
        queueAcceptsRecommendations = !skipRecommendations
        // Pause and tear down anything currently playing. Otherwise we'd keep streaming audio from
        // the previous video while the new one's file is downloading — which is what the user kept
        // hearing when they tapped "next" mid-download.
        if isPlaying {
            log.info("load: pausing current playback before resolving new video")
            pause()
        }
        if !player.items().isEmpty {
            log.debug("load: clearing AVQueuePlayer items (\(self.player.items().count, privacy: .public) entries)")
            player.removeAllItems()
        }
        clearAdaptiveAudio()
        currentVideo = video
        playbackQualityLabel = "Resolving…"
        hdDiagnosticMessage = "正在请求 1080p 视频与 AAC 音频轨道…"
        // Keep the queue coherent. Fresh taps from search/home append the video; subsequent calls
        // from `playNext()` / `playPrevious()` find it already there and just update `currentIndex`.
        queue.setCurrent(video)
        miniPlayerVisible = true
        loadState = .resolving
        // Wipe transport state from the previous video so a stray time-observer tick during the
        // transition (the periodic callback can fire AFTER currentVideo flips but BEFORE the new
        // AVPlayerItem is installed) doesn't carry the old item's elapsed/duration into a save —
        // that's what showed phantom progress bars on cells the user never played.
        elapsed = 0
        duration = 0
        recordWatchHistory(video: video)
        refreshArtwork(for: video)
        Task { await resolveAndPlay(video: video, autoplay: autoplay, skipRecommendations: skipRecommendations) }
    }

    private var progressObservationTask: Task<Void, Never>?

    /// Polls `DownloadManager.shared.progressByVideoID` and updates `loadState` so the UI sees a
    /// live progress bar while the file is downloading. The dictionary updates synchronously via
    /// `@Observable`, but we still need an explicit poll loop because `loadState` lives on the
    /// player and SwiftUI views don't observe `DownloadManager` from this file's call site.
    private func startProgressObservation(for videoID: String) {
        progressObservationTask?.cancel()
        progressObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let progress = DownloadManager.shared.progressByVideoID[videoID]
                let phase = DownloadManager.shared.phaseByVideoID[videoID]
                if case .downloading = self.loadState {
                    self.loadState = .downloading(progress: progress, phase: phase)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func stopProgressObservation() {
        progressObservationTask?.cancel()
        progressObservationTask = nil
    }

    /// Upserts a `WatchHistoryEntry` so the Library's "Recents" section reflects what the user
    /// played. Same-id taps just bump `watchedAt` so the row floats to the top. The actor hop keeps
    /// the SQL write off the main thread; @Query observers see the change automatically once the
    /// background context saves.
    private func recordWatchHistory(video: Video) {
        let videoID = video.id
        let title = video.title
        let channelName = video.channelName
        let thumbnailURL = video.thumbnailURL
        Task {
            await PersistenceWriter.shared.upsertWatchHistory(
                videoID: videoID,
                title: title,
                channelName: channelName,
                thumbnailURL: thumbnailURL
            )
        }
    }

    func selectQuality(_ quality: VideoQuality) {
        preferences.preferredQuality = quality
        guard let video = currentVideo else { return }
        let resumeTime = elapsed
        load(video, autoplay: true, skipRecommendations: true)
        if resumeTime > 1 {
            Task { @MainActor [weak self] in
                // Give the replacement AVPlayerItem time to install before restoring position.
                try? await Task.sleep(for: .seconds(1))
                self?.seek(to: resumeTime)
            }
        }
    }

    var preferredQuality: VideoQuality { preferences.preferredQuality }

    func play() {
        log.info("play()")
        isPlaying = true
        // Let AVPlayer manage remote-DASH readiness and buffering. Scheduling an `.unknown`
        // AVPlayerItem with `setRate(_:time:atHostTime:)` can raise an Objective-C exception inside
        // AVFoundation, which Swift cannot catch. AAC joins only after its item reports ready.
        player.play()
        startAdaptiveAudioIfReady(forceAlign: true)
    }

    func pause() {
        log.info("pause()")
        player.pause()
        adaptiveAudioPlayer?.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        log.info("togglePlayPause() (isPlaying=\(self.isPlaying, privacy: .public))")
        isPlaying ? pause() : play()
    }

    func seek(to seconds: TimeInterval) {
        log.info("seek(to: \(seconds, privacy: .public)s)")
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let shouldResume = isPlaying
        player.pause()
        adaptiveAudioPlayer?.pause()
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Seeking an `.unknown` remote AAC item can trigger an internal AVFoundation
                // exception. If it is not ready yet, the ready callback aligns it later.
                guard let audio = self.adaptiveAudioPlayer,
                      audio.currentItem?.status == .readyToPlay else {
                    if shouldResume { self.play() }
                    return
                }
                audio.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak audio] _ in
                    guard let self, let audio else { return }
                    Task { @MainActor in
                        guard self.adaptiveAudioPlayer === audio else { return }
                        if shouldResume { self.play() }
                    }
                }
            }
        }
    }

    func seekRelative(by delta: TimeInterval) {
        log.info("seekRelative(by: \(delta, privacy: .public)s)")
        seek(to: max(0, min(elapsed + delta, duration)))
    }

    func playNext() {
        log.info("playNext() — queue size=\(self.queue.items.count, privacy: .public) currentIndex=\(self.queue.currentIndex, privacy: .public)")
        if let next = queue.advance() {
            load(next)
            return
        }
        // Queue at end. If this queue accepts recommendations and the user hasn't asked for
        // repeat-all/repeat-one, refill from the last item's recommendations and try advancing
        // again — that's the "endless queue" behavior: every time we hit the bottom, more recs
        // refill behind us.
        guard queueAcceptsRecommendations,
              queue.repeatMode == .off,
              let seed = queue.items.last else {
            log.notice("playNext: queue at end, no recs refill (acceptsRecs=\(self.queueAcceptsRecommendations, privacy: .public), repeat=\(String(describing: self.queue.repeatMode), privacy: .public))")
            return
        }
        log.info("playNext: queue at end, refilling recs from seed=\(seed.id, privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            let countBefore = self.queue.items.count
            await self.fillQueueWithRecommendations(for: seed)
            guard self.queue.items.count > countBefore else {
                self.log.notice("playNext: refill produced no new items, giving up")
                return
            }
            if let next = self.queue.advance() {
                self.load(next)
            }
        }
    }

    func playPrevious() {
        log.info("playPrevious() — queue size=\(self.queue.items.count, privacy: .public) currentIndex=\(self.queue.currentIndex, privacy: .public)")
        guard let previous = queue.previous() else {
            log.notice("playPrevious: at start of queue, nothing to go back to")
            return
        }
        load(previous)
    }

    func dismiss() {
        log.info("dismiss()")
        pause()
        miniPlayerVisible = false
        fullScreenPresented = false
        currentVideo = nil
        loadState = .idle
        player.removeAllItems()
        clearAdaptiveAudio()
        NowPlayingCenter.clear()
    }

    // MARK: - Internals

    /// Swap the player to a new item using the `AVQueuePlayer`-correct pattern. `replaceCurrentItem`
    /// is documented to be a no-op when the player's internal queue is empty (which is our usual
    /// state since the playable URL is short-lived and we never preload), so we always tear the
    /// queue down to nothing first and then insert. Also wires KVO so we hear about decode/auth
    /// failures the moment they happen (CoreMedia's `CFByteFlume err=-12939` style messages don't
    /// surface a structured `NSError` otherwise).
    private func loadItem(_ item: AVPlayerItem) {
        clearAdaptiveAudio()
        let url = (item.asset as? AVURLAsset)?.url.path ?? "(non-URL asset)"
        log.info("loadItem: removeAllItems + insert (asset=\(url, privacy: .public))")
        player.removeAllItems()
        player.insert(item, after: nil)
        log.debug("loadItem: queue size after insert=\(self.player.items().count, privacy: .public)")
        observe(item: item)
    }

    private func installAdaptiveAudioItem(_ item: AVPlayerItem) {
        clearAdaptiveAudio()
        let audio = AVPlayer(playerItem: item)
        audio.defaultRate = player.defaultRate
        audio.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        adaptiveAudioPlayer = audio

        adaptiveAudioStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                switch item.status {
                case .readyToPlay:
                    let size = self.player.currentItem?.presentationSize ?? .zero
                    if size.width > 0, size.height > 0 {
                        self.hdDiagnosticMessage = "1080p H.264 画面与兼容音源均已就绪（\(Int(size.width))×\(Int(size.height))）"
                    } else {
                        self.hdDiagnosticMessage = "兼容音源已就绪，正在等待 1080p 视频像素输出"
                    }
                    self.log.info("Adaptive AAC item ready")
                    self.startAdaptiveAudioIfReady(forceAlign: true)
                case .failed:
                    let error = item.error as NSError?
                    let event = item.errorLog()?.events.last
                    let detail = error.map { "\($0.domain) \($0.code)：\($0.localizedDescription)" }
                        ?? event.map { "\($0.errorDomain) \($0.errorStatusCode)：\($0.errorComment ?? "无说明")" }
                        ?? "AVFoundation 未提供错误码"
                    self.hdDiagnosticMessage = "1080p 视频已加载，但兼容音源播放失败：\(detail)"
                    self.log.error("Adaptive audio item failed: \(detail, privacy: .public)")
                default:
                    break
                }
            }
        }
        adaptiveAudioErrorLogObservation = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let entry = item?.errorLog()?.events.last else { return }
            self?.log.error("Adaptive audio error: domain=\(entry.errorDomain, privacy: .public) code=\(entry.errorStatusCode, privacy: .public) comment=\(entry.errorComment ?? "", privacy: .public)")
            Task { @MainActor [weak self] in
                self?.hdDiagnosticMessage = "兼容音源错误：\(entry.errorDomain) \(entry.errorStatusCode)：\(entry.errorComment ?? "无说明")"
            }
        }
    }

    private func startAdaptiveAudioIfReady(forceAlign: Bool) {
        guard isPlaying,
              let audio = adaptiveAudioPlayer,
              let item = audio.currentItem,
              item.status == .readyToPlay else { return }
        if forceAlign {
            let videoTime = player.currentTime()
            guard videoTime.isNumeric else { return }
            audio.seek(to: videoTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak audio] _ in
                guard let self, let audio else { return }
                Task { @MainActor in
                    guard self.isPlaying, self.adaptiveAudioPlayer === audio else { return }
                    audio.play()
                }
            }
        } else {
            audio.play()
        }
    }

    private func clearAdaptiveAudio() {
        adaptiveAudioPlayer?.pause()
        adaptiveAudioPlayer?.replaceCurrentItem(with: nil)
        adaptiveAudioPlayer = nil
        adaptiveAudioStatusObservation?.invalidate()
        adaptiveAudioStatusObservation = nil
        if let token = adaptiveAudioErrorLogObservation {
            NotificationCenter.default.removeObserver(token)
        }
        adaptiveAudioErrorLogObservation = nil
        hdVideoOutputWatchTask?.cancel()
        hdVideoOutputWatchTask = nil
        if let output = hdVideoOutput, let item = player.currentItem {
            item.remove(output)
        }
        hdVideoOutput = nil
        isCorrectingAdaptiveSync = false
    }

    private func startHDVideoOutputWatch(item: AVPlayerItem, videoID: String) {
        hdVideoOutputWatchTask?.cancel()
        if let oldOutput = hdVideoOutput, let oldItem = player.currentItem {
            oldItem.remove(oldOutput)
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        hdVideoOutput = output

        hdVideoOutputWatchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Keep the output strongly retained while polling. `readyToPlay` and
            // `presentationSize` can both be nonzero before a CDN segment has decoded, so require
            // an actual pixel buffer from the output pipeline.
            for _ in 0..<24 {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.currentVideo?.id == videoID,
                      let currentItem = self.player.currentItem,
                      currentItem === item,
                      let output = self.hdVideoOutput else { return }
                let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
                var displayTime = CMTime.invalid
                if output.hasNewPixelBuffer(forItemTime: itemTime),
                   output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) != nil {
                    let size = item.presentationSize
                    self.hdDiagnosticMessage = "1080p H.264 已输出真实画面（\(Int(size.width))×\(Int(size.height))），音画同步中"
                    self.log.info("HD video produced decoded pixels size=\(size.width, privacy: .public)x\(size.height, privacy: .public)")
                    return
                }
            }

            guard self.currentVideo?.id == videoID,
                  self.player.currentItem === item else { return }
            self.hdDiagnosticMessage = "1080p 轨道已就绪但 12 秒内没有像素输出，正在自动切换兼容画面"
            self.log.error("HD item ready but produced no decoded video pixels; falling back")
            self.pause()
            if let fallbackURL = await self.resolveStreamingURL(
                videoID: videoID,
                quality: self.preferences.preferredQuality
            ) {
                let fallbackItem = AVPlayerItem(url: fallbackURL)
                self.loadItem(fallbackItem)
                self.loadState = .readyToPlay
                self.hdDiagnosticMessage = "1080p 双轨无像素输出，已自动切换至 \(self.playbackQualityLabel)"
                self.play()
            } else {
                self.clearAdaptiveAudio()
                self.loadState = .failed("1080p 轨道没有画面，兼容播放源也不可用。请复制高清诊断。")
            }
        }
    }

    /// The two AVPlayers share a scheduled host-time when started, but HTTP buffering and native
    /// scrubber gestures can still move only the video clock. Correct meaningful drift here;
    /// ignoring sub-120 ms differences avoids a seek storm and remains below lip-sync perception.
    private func correctAdaptiveAudioSync(force: Bool = false) {
        guard let audio = adaptiveAudioPlayer,
              audio.currentItem?.status == .readyToPlay,
              !isCorrectingAdaptiveSync else { return }
        let videoSeconds = player.currentTime().seconds
        let audioSeconds = audio.currentTime().seconds
        guard videoSeconds.isFinite, audioSeconds.isFinite else { return }
        let drift = abs(videoSeconds - audioSeconds)
        guard force || drift > 0.12 else { return }
        isCorrectingAdaptiveSync = true
        let target = CMTime(seconds: videoSeconds, preferredTimescale: 600)
        audio.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak audio] _ in
            guard let self, let audio else { return }
            Task { @MainActor in
                guard self.adaptiveAudioPlayer === audio else { return }
                self.isCorrectingAdaptiveSync = false
                if self.player.timeControlStatus == .playing {
                    audio.play()
                }
            }
        }
    }

    private func observe(item: AVPlayerItem) {
        itemStatusObservation?.invalidate()
        if let token = itemErrorLogObservation { NotificationCenter.default.removeObserver(token) }

        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                switch item.status {
                case .unknown:
                    self.log.info("AVPlayerItem status: unknown")
                case .readyToPlay:
                    self.log.info("AVPlayerItem status: readyToPlay (duration=\(item.duration.seconds, privacy: .public)s, size=\(item.presentationSize.width, privacy: .public)x\(item.presentationSize.height, privacy: .public))")
                    if self.playbackQualityLabel.contains("原生双轨") {
                        self.hdDiagnosticMessage = "H.264 高清视频轨已就绪（\(Int(item.presentationSize.width))×\(Int(item.presentationSize.height))），等待兼容音源"
                    }
                case .failed:
                    let err = item.error as NSError?
                    let event = item.errorLog()?.events.last
                    let detail = err.map { "\($0.domain) \($0.code)：\($0.localizedDescription)" }
                        ?? event.map { "\($0.errorDomain) \($0.errorStatusCode)：\($0.errorComment ?? "无说明")" }
                        ?? "AVFoundation 未提供错误码"
                    if self.playbackQualityLabel.contains("原生双轨") {
                        self.hdDiagnosticMessage = "1080p H.264 视频轨播放失败：\(detail)"
                    }
                    self.log.error("AVPlayerItem status: FAILED \(detail, privacy: .public)")
                @unknown default:
                    break
                }
            }
        }

        itemErrorLogObservation = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let entry = item?.errorLog()?.events.last else { return }
            self?.log.error("AVPlayerItem error-log: domain=\(entry.errorDomain, privacy: .public) code=\(entry.errorStatusCode, privacy: .public) comment=\(entry.errorComment ?? "", privacy: .public) URI=\(entry.uri ?? "", privacy: .public)")
            Task { @MainActor [weak self] in
                guard let self, self.playbackQualityLabel.contains("原生双轨") else { return }
                self.hdDiagnosticMessage = "1080p 视频轨错误：\(entry.errorDomain) \(entry.errorStatusCode)：\(entry.errorComment ?? "无说明")"
            }
        }
    }

    private func resolveAndPlay(video: Video, autoplay: Bool, skipRecommendations: Bool = false) async {
        log.info("resolveAndPlay: start for \(video.id, privacy: .public)")
        // Watch the manager's progress dictionary so the player UI can render a real-time progress
        // bar. Cancelled in `dismiss()` and replaced on each `load`.
        startProgressObservation(for: video.id)

        // Sideload-stable playback path. Embedded CPython/YoutubeDL currently SIGSEGVs when
        // initialized from Swift's cooperative pool, so never invoke it from a play tap.
        // Reuse an existing local download when available; otherwise resolve a native HLS or
        // progressive MP4 URL through YouTubeKit and hand it directly to AVPlayer.
        let item: AVPlayerItem
        var adaptiveAudioItem: AVPlayerItem?
        if let local = DownloadManager.shared.localFile(for: video.id) {
            item = AVPlayerItem(url: local)
            playbackQualityLabel = "本地文件"
            log.info("resolveAndPlay: cache hit \(local.path, privacy: .public)")
        } else if let hlsURL = await resolvePreferredHLSURL(videoID: video.id) {
            item = AVPlayerItem(url: hlsURL)
            log.info("resolveAndPlay: preferred HLS \(hlsURL.absoluteString, privacy: .public)")
        } else if let adaptiveItems = await resolveAdaptiveHDItems(
            videoID: video.id,
            maxHeight: preferences.preferredQuality.heightCap ?? 1080
        ) {
            item = adaptiveItems.videoItem
            adaptiveAudioItem = adaptiveItems.audioItem
            playbackQualityLabel = "\(adaptiveItems.height)p · 原生双轨"
            hdDiagnosticMessage = "已加载 \(adaptiveItems.height)p H.264 与 AAC 双原生播放器"
            log.info("resolveAndPlay: legacy Android adaptive dual-player \(adaptiveItems.height, privacy: .public)p")
        } else if let streamURL = await resolveStreamingURL(
            videoID: video.id,
            quality: preferences.preferredQuality
        ) {
            item = AVPlayerItem(url: streamURL)
            log.info("resolveAndPlay: native streaming fallback \(streamURL.absoluteString, privacy: .public)")
        } else {
            log.error("resolveAndPlay: native streaming unavailable for \(video.id, privacy: .public)")
            let hasLogin = !(CookieStore.shared.loadHeader() ?? "").isEmpty
            let diagnostic = hdDiagnosticMessage
            loadState = .failed(hasLogin
                ? "高清与兼容播放均失败：\(diagnostic)\n\n这不一定表示登录已过期，请打开右上角菜单复制高清诊断。"
                : "YouTube 要求验证此视频。请先在资料库登录，然后重新播放。\n\n高清诊断：\(diagnostic)")
            stopProgressObservation()
            return
        }
        loadItem(item)
        if let adaptiveAudioItem {
            installAdaptiveAudioItem(adaptiveAudioItem)
            startHDVideoOutputWatch(item: item, videoID: video.id)
        }
        loadState = .readyToPlay
        updateNowPlaying()
        if autoplay { play() }
        stopProgressObservation()
        log.info("resolveAndPlay: finished happy-path for \(video.id, privacy: .public)")
        // Fire-and-forget queue fill — uses YouTube's `/next` (WEB) endpoint, independent of the
        // resolver's `/player` (IOS) endpoint, so it can't interfere with playback that's already
        // running. Failures are logged but never surface to the user; queue stays as-is on error.
        //
        // Suppressed only when the caller explicitly asks (playlist's Play all / Shuffle all).
        // Every other entry point — single video taps from Home/Search/Mini-player, queue-row
        // taps, Next/Previous, and even tapping an individual playlist video — gets the
        // autoplay-style recommendation fill, so the player keeps advancing past the seed.
        // Background-prefetch the **single** next queue item so it's ready when the user taps Next
        // (or auto-advance kicks in). We deliberately only preload one — `PythonRunner` serializes
        // every yt-dlp invocation and we don't want a long preload chain blocking the user's
        // explicit play taps. The current item is already fully on disk and playing from local
        // file at this point, so kicking off the next download doesn't interrupt anything.
        //
        // **Ordering matters.** For non-playlist taps, the queue starts with just `[currentVideo]`
        // — recommendations haven't arrived yet. If we fire prefetch here unconditionally,
        // `queue.upcomingItems(count: 1)` returns empty and the prefetch silently no-ops. So:
        //   - Playlist Play All / Shuffle All path (`skipRecommendations: true`): the caller has
        //     pre-populated the queue, so prefetch can run immediately.
        //   - Default path (recommendations enabled): defer prefetch to the tail of the
        //     recommendations Task so it sees the freshly-appended "up next".
        if !skipRecommendations {
            Task { [weak self] in
                await self?.fillQueueWithRecommendations(for: video)
                await self?.prefetchNextUpcoming()
            }
        } else {
            prefetchNextUpcoming()
        }
    }

    private func resolveAdaptiveHDItems(
        videoID: String,
        maxHeight: Int
    ) async -> (videoItem: AVPlayerItem, audioItem: AVPlayerItem, height: Int)? {
        do {
            let streams = try await VideoService().fetchLegacyAndroidAdaptiveStreams(
                id: videoID,
                maxHeight: maxHeight
            )
            // Do not call AVAsset.loadTracks here. YouTube serves these URLs as remote fragmented
            // MP4/DASH resources; metadata inspection may fail with an opaque AVFoundation error
            // even though AVPlayer can stream the same URL. Pass the same Android User-Agent to
            // the CDN for both tracks — some signed URLs reject AVFoundation's default UA.
            // `AVURLAssetHTTPHeaderFieldsKey` is an AVFoundation option-key string but is not
            // exported as a Swift symbol in every SDK overlay, so use its documented raw value.
            let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": streams.requestHeaders]
            let videoAsset = AVURLAsset(url: streams.videoURL, options: options)
            let audioAsset = AVURLAsset(url: streams.audioURL, options: options)
            let videoItem = AVPlayerItem(asset: videoAsset)
            let audioItem = AVPlayerItem(asset: audioAsset)
            videoItem.preferredForwardBufferDuration = 8
            audioItem.preferredForwardBufferDuration = 8
            hdDiagnosticMessage = "已获得 \(streams.height)p 直链，音源：\(streams.audioSourceLabel)，正在由原生播放器缓冲"
            return (videoItem, audioItem, streams.height)
        } catch {
            hdDiagnosticMessage = error.localizedDescription
            log.notice("HD stream resolution failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Fires `DownloadManager.ensureDownloaded` for just the next queued video, in the background.
    /// Idempotent: returns instantly if the file is already on disk, and coalesces with any
    /// existing in-flight download for the same ID, so re-prefetching on every successful play is
    /// cheap.
    ///
    /// **User-gated** by `UserPreferences.prefetchNextInQueue`. Off → no background download
    /// is started; Next-tap will then fall into the standard `ensureDownloaded` path with
    /// `.userInitiated` priority (still works, just no head-start).
    /// Disabled in the sideload-stable build because prefetch enters the same embedded-Python
    /// path that can SIGSEGV. Playback resolves native HLS/progressive URLs on demand.
    private func prefetchNextUpcoming() {
        log.debug("prefetch: disabled in sideload-stable build")
    }

    private func disabledPythonPrefetchNextUpcoming() {
        guard preferences.prefetchNextInQueue else {
            log.debug("prefetch: disabled in settings, skipping")
            return
        }
        guard let next = queue.upcomingItems(count: 1).first else { return }
        log.info("prefetch: queuing \(next.id, privacy: .public) for background download")
        Task { [preferredQuality = preferences.preferredQuality] in
            _ = try? await DownloadManager.shared.ensureDownloaded(
                video: next,
                quality: preferredQuality
            )
        }
    }

    /// Last-ditch URL resolver. Walks four tiers, returning the first one that produces a URL
    /// `AVPlayer` can open directly:
    ///   1. iOS-client HLS manifest (adaptive bitrate, best playback experience)
    ///   2. iOS-client progressive MP4 (muxed audio+video, no n-decoding needed)
    ///   3. TVHTML5 HLS manifest
    ///   4. TVHTML5 progressive MP4
    ///
    /// Why HLS is preferred: HLS chunks use short-lived signatures attached to the manifest
    /// rather than the player.js-derived `n` cipher, and YouTube doesn't typically PoT-stamp
    /// HLS the way it does DASH. When HLS isn't exposed (some kids/family content), the iOS
    /// client's `defaultFormats` still include direct progressive URLs that work without the
    /// player.js scrape — that's our second tier. Returns nil only when all four tiers fail.
    /// First-stage native stream resolver used before the dual-track 1080p attempt.
    /// It only returns HLS-based paths so a plain progressive MP4 cannot preempt the HD branch.
    private func resolvePreferredHLSURL(videoID: String) async -> URL? {
        let service = VideoService()

        if let hls = try? await service.fetchAuthenticatedSafariHLSURL(id: videoID) {
            playbackQualityLabel = "Adaptive HD · HLS"
            hdDiagnosticMessage = "已获得认证 HLS 高清流，优先使用原生自适应画面"
            return hls
        }
        if let info = try? await service.fetchInfo(id: videoID), let hls = info.streamingURL {
            playbackQualityLabel = "Adaptive HLS"
            hdDiagnosticMessage = "已获得 iOS 客户端 HLS，自适应播放中"
            return hls
        }
        if let info = try? await service.fetchInfoViaTVHTML5(id: videoID), let hls = info.streamingURL {
            playbackQualityLabel = "TVHTML5 HLS"
            hdDiagnosticMessage = "已获得 TVHTML5 HLS，正在回退到可显示画面"
            return hls
        }
        return nil
    }

    /// Post-HD fallback resolver. By the time we get here, authenticated HLS and the 1080p
    /// dual-track path have both failed, so returning a progressive MP4 is acceptable.
    private func resolveStreamingURL(videoID: String, quality: VideoQuality) async -> URL? {
        let service = VideoService()

        if let info = try? await service.fetchInfo(id: videoID) {
            logFormats(videoID: videoID, source: "IOS", formats: info.formats)
            if let progressive = Self.pickProgressiveURL(from: info.formats, maxHeight: quality.heightCap ?? .max) {
                playbackQualityLabel = "Progressive MP4"
                hdDiagnosticMessage = "HLS 与 1080p 双轨均失败，改用 iOS progressive MP4"
                return progressive
            }
        }
        if let info = try? await service.fetchInfoViaTVHTML5(id: videoID) {
            logFormats(videoID: videoID, source: "TVHTML5", formats: info.formats)
            if let progressive = Self.pickProgressiveURL(from: info.formats, maxHeight: quality.heightCap ?? .max) {
                playbackQualityLabel = "TVHTML5 MP4"
                hdDiagnosticMessage = "原生高清不可用，改用 TVHTML5 progressive MP4"
                return progressive
            }
        }

        // Final native tier: YouTubeKit fetches the active player.js and decodes
        // signatureCipher/n into direct URLs entirely in Swift. The download fallback already
        // uses this response, but playback previously skipped it and jumped straight to an error.
        // Prefer a muxed MP4 so AVPlayer can play it without Python, ffmpeg, or a web view.
        if let result = try? await service.fetchInfoWithFormats(id: videoID) {
            logFormats(videoID: videoID, source: "PLAYER_JS", formats: result.formats)
            if let progressive = Self.pickProgressiveURL(
                from: result.formats,
                maxHeight: quality.heightCap ?? .max
            ) {
                playbackQualityLabel = "Player.js MP4"
                hdDiagnosticMessage = "高清原生流不可用，改用 player.js 解析出的 MP4"
                return progressive
            }
        }

        // Only after every HD/native path has failed do we allow the well-known low-resolution
        // Android muxed fallback, and only when the user did not explicitly ask for 1080p.
        if quality.heightCap ?? .max < 1080,
           let androidURL = try? await service.fetchAndroidProgressiveURL(
            id: videoID,
            maxHeight: quality.heightCap ?? .max
        ) {
            playbackQualityLabel = "360p · MP4 fallback"
            hdDiagnosticMessage = "1080p/HLS 均不可用，已回退到 Android 360p 合并流"
            return androidURL
        }

        return nil
    }

    /// Dumps a one-line digest for each format so we can see what YouTube actually returned for
    /// content where the current heuristics produced no playable URL. Strips the URL down to its
    /// path prefix and the presence/absence of the `n=` cipher parameter — full URLs are sensitive
    /// (time-limited signed) and would leak into logs unredacted otherwise.
    private func logFormats(videoID: String, source: String, formats: [VideoFormat]) {
        log.info("formats[\(source, privacy: .public)] id=\(videoID, privacy: .public) count=\(formats.count, privacy: .public)")
        for f in formats {
            let hasURL = f.url != nil
            let hasN: Bool = {
                guard let q = f.url?.query else { return false }
                return q.contains("&n=") || q.hasPrefix("n=")
            }()
            let kind: String = f.containsBothTracks ? "muxed" : (f.isVideoOnly ? "videoOnly" : (f.isAudioOnly ? "audioOnly" : "?"))
            log.info("  itag=\(f.id, privacy: .public) kind=\(kind, privacy: .public) h=\(f.height ?? -1, privacy: .public) mime=\(f.mimeType, privacy: .public) hasURL=\(hasURL, privacy: .public) hasN=\(hasN, privacy: .public)")
        }
    }

    /// Picks the highest-quality progressive (audio+video muxed) format within the user's
    /// quality ceiling. AVPlayer can play these directly via `AVPlayerItem(url:)`; the audio-only
    /// and video-only adaptive streams would need an AVMutableComposition setup, which we skip
    /// here on purpose — this is the streaming-fallback path, not a full DASH player.
    private static func pickProgressiveURL(from formats: [VideoFormat], maxHeight: Int) -> URL? {
        formats
            .filter { $0.containsBothTracks && $0.url != nil }
            .filter { ($0.height ?? .max) <= maxHeight }
            .sorted { ($0.height ?? 0) > ($1.height ?? 0) }
            .first?
            .url
    }

    /// Fetches `MoreVideoInfosResponse` for the current video and appends the recommended videos to
    /// the queue. This is what makes the player behave like the YouTube app: tap any video and a
    /// fresh "up next" queue is ready to advance when the current track ends.
    private func fillQueueWithRecommendations(for seed: Video) async {
        do {
            let info = try await VideoService().fetchMoreInfo(id: seed.id)
            // Only append recommendations that aren't already queued, preserving the user's own
            // ordering if they came from a "Play all" playlist load.
            let existingIDs = Set(queue.items.map(\.id))
            let toAppend = info.recommended.filter { !existingIDs.contains($0.id) }
            for rec in toAppend {
                queue.append(rec)
            }
            log.info("Queued \(toAppend.count, privacy: .public) recommendations for \(seed.id, privacy: .public)")
        } catch {
            log.notice("Recommendation fetch failed for \(seed.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func installObservers() {
        // Periodic time observation via Combine-friendly bridging.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                if let item = self.player.currentItem {
                    let total = item.duration.seconds
                    if total.isFinite { self.duration = total }
                }
                self.correctAdaptiveAudioSync()
                self.updateNowPlaying()
            }
        }

        // Auto-advance on item end.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                // The adaptive AAC player also posts this notification. Advance only when the
                // visible/video item ends, otherwise one video could skip two queue entries.
                guard let endedItem = notification.object as? AVPlayerItem,
                      endedItem === self.player.currentItem else { return }
                if self.preferences.autoplayNext { self.playNext() }
            }
        }

        // Mirror AVPlayer's transport state into our `isPlaying` flag so the custom transport row
        // under the video title (and the popup-bar play/pause glyph) reflects taps on the native
        // AVPlayerViewController controls. Without this, hitting the native pause button on the
        // video surface left our SwiftUI button showing "Pause" forever.
        // Persist user-driven speed changes from AVPlayerViewController's built-in speed menu.
        // The menu writes to `defaultRate`; KVO catches the write and we save it to prefs so the
        // next app launch starts at the same speed.
        defaultRateObservation = player.observe(\.defaultRate, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            guard let newValue = change.newValue else { return }
            let rate = Double(newValue)
            // Sanity: defaultRate of 0 would mean "paused on play()" which YouTube/AVPlayerViewController
            // never offers as a user option. Ignore any such bogus write.
            guard rate > 0 else { return }
            Task { @MainActor in
                self.adaptiveAudioPlayer?.defaultRate = newValue
                if self.isPlaying,
                   self.adaptiveAudioPlayer?.currentItem?.status == .readyToPlay {
                    self.adaptiveAudioPlayer?.rate = newValue
                }
                if abs(rate - self.preferences.playbackRate) > 0.001 {
                    self.log.info("playbackRate changed → \(rate, privacy: .public) (persisting)")
                    self.preferences.playbackRate = rate
                }
            }
        }

        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] avPlayer, _ in
            guard let self else { return }
            let status = avPlayer.timeControlStatus
            Task { @MainActor in
                switch status {
                case .playing:
                    if !self.isPlaying {
                        self.log.info("KVO timeControlStatus → playing (sync isPlaying=true)")
                        self.isPlaying = true
                    }
                    // Native AVPlayerViewController controls only the visible player. Mirror its
                    // play/resume and any scrubbed position to the hidden AAC player.
                    if let audio = self.adaptiveAudioPlayer,
                       audio.currentItem?.status == .readyToPlay,
                       audio.timeControlStatus != .playing {
                        self.startAdaptiveAudioIfReady(forceAlign: true)
                    }
                case .paused:
                    self.adaptiveAudioPlayer?.pause()
                    if self.isPlaying {
                        self.log.info("KVO timeControlStatus → paused (sync isPlaying=false)")
                        self.isPlaying = false
                    }
                case .waitingToPlayAtSpecifiedRate:
                    // Do not let AAC run ahead while the 1080p video track is buffering. The next
                    // `.playing` transition force-aligns and resumes it.
                    self.adaptiveAudioPlayer?.pause()
                    // Buffering / stalled. Treat as "playing" so the UI still shows pause icon,
                    // matching what the native AVPlayerViewController shows.
                    if !self.isPlaying {
                        self.isPlaying = true
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    private func updateNowPlaying() {
        guard let video = currentVideo else { return }
        NowPlayingCenter.update(
            title: video.title,
            artist: video.channelName,
            duration: duration,
            elapsed: elapsed,
            rate: isPlaying ? 1.0 : 0.0,
            artwork: currentArtwork
        )
    }

    /// Resolves an artwork image for the given video and stores it in `currentArtwork`. Tries three
    /// sources in order:
    ///  1. Kingfisher's in-memory cache for the video's `thumbnailURL` (synchronous → no flicker).
    ///  2. `DownloadsStore`'s xattr-stored compressed thumbnail (for videos played from the Downloads tab,
    ///     where the constructed `Video` has `thumbnailURL == nil`).
    ///  3. Async network/disk fetch through Kingfisher.
    /// Clears artwork immediately so the previous video's preview doesn't linger on the lock screen.
    private func refreshArtwork(for video: Video) {
        currentArtwork = nil

        if let url = video.thumbnailURL,
           let cached = ImageCache.default.retrieveImageInMemoryCache(forKey: url.cacheKey) {
            currentArtwork = cached
            updateNowPlaying()
            return
        }

        // Xattr fallback for downloaded-only videos. `DownloadsStore.thumbnail(forVideoID:)`
        // is synchronous (the entries snapshot lives in memory) so we can decode + assign
        // inline rather than through a Task / background actor.
        let videoID = video.id
        if let data = DownloadsStore.shared.thumbnail(forVideoID: videoID),
           let image = UIImage(data: data) {
            currentArtwork = image
            updateNowPlaying()
        }

        // Async network/disk fetch as last resort.
        guard let url = video.thumbnailURL else { return }
        KingfisherManager.shared.retrieveImage(with: url) { [weak self, videoID = video.id] result in
            guard case .success(let value) = result else { return }
            Task { @MainActor in
                guard let self else { return }
                // Drop the result if the user switched videos while the fetch was inflight.
                guard self.currentVideo?.id == videoID else { return }
                self.currentArtwork = value.image
                self.updateNowPlaying()
            }
        }
    }
}
