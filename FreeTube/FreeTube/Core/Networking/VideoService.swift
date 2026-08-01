import Foundation
import OSLog
import YouTubeKit

struct VideoInfo: Sendable {
    let video: Video
    let descriptionText: String?
    let likeCount: Int?
    let isLikedByUser: Bool
    let isDislikedByUser: Bool
    let recommended: [Video]
    /// The HLS playlist URL (if available). Per `VideoInfosResponse` docs, this URL is consumable by
    /// `AVPlayer` directly. Prefer it over per-format URLs unless a specific quality is required.
    let streamingURL: URL?
    /// Formats already provided by `VideoInfosResponse` — combined audio+video streams (in `defaultFormats`)
    /// plus adaptive audio-only/video-only streams (in `downloadFormats`). These come from the iOS-client
    /// player endpoint and have direct URLs (no signature cipher), so they work without the player-JS scrape
    /// that `VideoInfosWithDownloadFormatsResponse` requires.
    let formats: [VideoFormat]
}

struct VideoInfoWithFormats: Sendable {
    let info: VideoInfo
    let formats: [VideoFormat]
}

protocol VideoServicing: Sendable {
    func fetchInfo(id: String) async throws -> VideoInfo
    func fetchInfoWithFormats(id: String) async throws -> VideoInfoWithFormats
    func fetchMoreInfo(id: String) async throws -> VideoInfo
    /// Alternate fetch using the `TVHTML5_SIMPLY_EMBEDDED_PLAYER` client — same response shape
    /// as `fetchInfo`, but the returned per-format URLs aren't PoT-protected. Used by the resolver
    /// as a fallback when the iOS client gives us only PoT-locked adaptive streams.
    func fetchInfoViaTVHTML5(id: String) async throws -> VideoInfo
    /// Raw Android InnerTube fallback. Returns a direct muxed MP4 URL without Python or WebKit.
    func fetchAndroidProgressiveURL(id: String, maxHeight: Int) async throws -> URL
}

/// Wraps `VideoInfosResponse`, `VideoInfosWithDownloadFormatsResponse`, `MoreVideoInfosResponse`.
final class VideoService: VideoServicing {
    private let client: YouTubeKitClient
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "VideoService")

    nonisolated init(client: YouTubeKitClient = .shared) {
        self.client = client
    }

    func fetchInfo(id: String) async throws -> VideoInfo {
        log.info("fetchInfo[IOS] start id=\(id, privacy: .public)")
        // `VideoInfosResponse` requires a `visitorData` token. Bootstrap may not have completed yet
        // if the user taps a video immediately on launch; ensureVisitorData no-ops when one's already set.
        await client.ensureVisitorData()
        do {
            let response = try await VideoInfosResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.query: id]
            )
            let info = Self.videoInfo(from: response, id: id, recommended: [])
            log.info("fetchInfo[IOS] ok id=\(id, privacy: .public) hls=\(info.streamingURL != nil, privacy: .public) formats=\(info.formats.count, privacy: .public)")
            return info
        } catch {
            log.error("fetchInfo[IOS] FAILED id=\(id, privacy: .public): \(String(describing: error), privacy: .public)")
            await Self.clearSessionIfLoginRequired(error)
            throw YouTubeServiceError.network(error)
        }
    }

    func fetchInfoViaTVHTML5(id: String) async throws -> VideoInfo {
        log.info("fetchInfo[TVHTML5] start id=\(id, privacy: .public)")
        await client.ensureVisitorData()
        do {
            let response = try await VideoInfosResponse.sendThrowingRequest(
                youtubeModel: client.tvHtmlModel,
                data: [.query: id]
            )
            let info = Self.videoInfo(from: response, id: id, recommended: [])
            log.info("fetchInfo[TVHTML5] ok id=\(id, privacy: .public) hls=\(info.streamingURL != nil, privacy: .public) formats=\(info.formats.count, privacy: .public)")
            return info
        } catch {
            log.error("fetchInfo[TVHTML5] FAILED id=\(id, privacy: .public): \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
    }

    func fetchAndroidProgressiveURL(id: String, maxHeight: Int) async throws -> URL {
        log.info("fetchAndroidProgressiveURL start id=\(id, privacy: .public)")
        let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip",
            forHTTPHeaderField: "User-Agent"
        )
        let cookies = client.cookies
        if !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
            request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
            request.setValue("https://www.youtube.com", forHTTPHeaderField: "X-Origin")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            if let authorization = client.model.generateSAPISIDHASHForCookies(cookies) {
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
            }
        }
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "ANDROID",
                    "clientVersion": "21.26.364",
                    "androidSdkVersion": 30,
                    "userAgent": "com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip",
                    "osName": "Android",
                    "osVersion": "11"
                ]
            ],
            "videoId": id,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeServiceError.streamExtractionFailed
        }
        if let playability = json["playabilityStatus"] as? [String: Any],
           let status = playability["status"] as? String,
           status != "OK" {
            log.notice("Android client playability=\(status, privacy: .public)")
            throw YouTubeServiceError.streamExtractionFailed
        }
        guard let streaming = json["streamingData"] as? [String: Any],
              let rawFormats = streaming["formats"] as? [[String: Any]] else {
            throw YouTubeServiceError.streamExtractionFailed
        }
        let candidates: [(url: URL, height: Int)] = rawFormats.compactMap { format in
            guard let mime = format["mimeType"] as? String,
                  mime.lowercased().contains("video/mp4"),
                  mime.lowercased().contains("mp4a"),
                  let urlString = format["url"] as? String,
                  let url = URL(string: urlString) else { return nil }
            let height = format["height"] as? Int ?? 0
            guard height <= maxHeight || maxHeight <= 0 else { return nil }
            return (url, height)
        }
        guard let best = candidates.max(by: { $0.height < $1.height }) else {
            throw YouTubeServiceError.streamExtractionFailed
        }
        log.info("Android client selected muxed MP4 height=\(best.height, privacy: .public)")
        return best.url
    }

    func fetchInfoWithFormats(id: String) async throws -> VideoInfoWithFormats {
        log.info("Fetching video info+formats \(id, privacy: .public)")
        do {
            let response = try await VideoInfosWithDownloadFormatsResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.query: id]
            )
            let info = Self.videoInfo(from: response.videoInfos, id: id, recommended: [])
            let formats = (response.defaultFormats + response.downloadFormats).map(Mappers.format(from:))
            return VideoInfoWithFormats(info: info, formats: formats)
        } catch {
            log.error("VideoInfosWithDownloadFormatsResponse failed: \(String(describing: error), privacy: .public)")
            await Self.clearSessionIfLoginRequired(error)
            throw YouTubeServiceError.streamExtractionFailed
        }
    }

    func fetchMoreInfo(id: String) async throws -> VideoInfo {
        log.info("Fetching more video info \(id, privacy: .public)")
        do {
            let response = try await MoreVideoInfosResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [.query: id]
            )
            let recommended = response.recommendedVideos.compactMap { $0 as? YTVideo }.map(Mappers.video(from:))
            let descriptionText = response.videoDescription?.compactMap(\.text).joined()
            let video = Video(
                id: id,
                title: response.videoTitle ?? "",
                channelID: response.channel?.channelId ?? "",
                channelName: response.channel?.name ?? "",
                channelThumbnailURL: Mappers.bestThumbnailURL(response.channel?.thumbnails ?? []),
                thumbnailURL: nil,
                duration: nil,
                viewCount: nil,
                publishedAt: nil,
                descriptionSnippet: descriptionText,
                isLive: false,
                isShort: false
            )
            return VideoInfo(
                video: video,
                descriptionText: descriptionText,
                likeCount: response.likesCount.defaultState.flatMap { Int($0) },
                isLikedByUser: response.authenticatedInfos?.likeStatus == .liked,
                isDislikedByUser: response.authenticatedInfos?.likeStatus == .disliked,
                recommended: recommended,
                streamingURL: nil,
                formats: []
            )
        } catch {
            throw YouTubeServiceError.network(error)
        }
    }

    // MARK: - Cookie hygiene

    /// If the failure looks like YouTube rejecting a stale auth blob, wipe the cookies in Keychain
    /// + `YouTubeModel`. The next user attempt will run anonymously and should succeed. We catch
    /// `LOGIN_REQUIRED` and `UNPLAYABLE` strings emitted by `VideoInfosResponse.decodeJSON`'s guards.
    private static func clearSessionIfLoginRequired(_ error: Error) async {
        let description = String(describing: error)
        let signals = ["LOGIN_REQUIRED", "Login is required", "UNPLAYABLE"]
        guard signals.contains(where: { description.localizedCaseInsensitiveContains($0) }) else { return }
        await SessionManager.shared.handleExpiredSession()
    }

    // MARK: - Mapping helpers

    private static func videoInfo(from response: VideoInfosResponse, id: String, recommended: [Video]) -> VideoInfo {
        let video = Video(
            id: response.videoId ?? id,
            title: response.title ?? "",
            channelID: response.channel?.channelId ?? "",
            channelName: response.channel?.name ?? "",
            channelThumbnailURL: Mappers.bestThumbnailURL(response.channel?.thumbnails ?? []),
            thumbnailURL: Mappers.bestThumbnailURL(response.thumbnails),
            duration: nil,
            viewCount: response.viewCount.flatMap { Int($0) },
            publishedAt: nil,
            descriptionSnippet: response.videoDescription,
            isLive: response.isLive ?? false,
            isShort: false
        )
        let formats = (response.defaultFormats + response.downloadFormats).map(Mappers.format(from:))
        return VideoInfo(
            video: video,
            descriptionText: response.videoDescription,
            likeCount: nil,
            isLikedByUser: false,
            isDislikedByUser: false,
            recommended: recommended,
            streamingURL: response.streamingURL,
            formats: formats
        )
    }
}
