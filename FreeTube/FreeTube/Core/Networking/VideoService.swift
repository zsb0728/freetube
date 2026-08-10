import Foundation
import OSLog
import YouTubeKit

struct NativeAdaptiveStreams: Sendable {
    let videoURL: URL
    let audioURL: URL
    let height: Int
}

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
    /// Legacy Android exposes direct DASH video+audio URLs for synchronized native AVPlayers.
    func fetchLegacyAndroidAdaptiveStreams(id: String, maxHeight: Int) async throws -> NativeAdaptiveStreams
    /// Authenticated Web-Safari HLS. AVPlayer can adapt this manifest up to HD/1080p.
    func fetchAuthenticatedSafariHLSURL(id: String) async throws -> URL
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
            // A player endpoint may return LOGIN_REQUIRED for one video because of PoToken,
            // bot verification, age, region, or client policy. That is not proof that the user's
            // account cookies expired. Never destroy the global session from a playback error.
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

    func fetchAuthenticatedSafariHLSURL(id: String) async throws -> URL {
        let cookies = client.cookies
        guard !cookies.isEmpty else { throw YouTubeServiceError.notAuthenticated }
        let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)"
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": "2.20260708.00.00",
                    "userAgent": safariUA,
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "videoId": id,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(safariUA, forHTTPHeaderField: "User-Agent")
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "X-Origin")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        if let authorization = client.model.generateSAPISIDHASHForCookies(cookies) {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streaming = json["streamingData"] as? [String: Any],
              let hlsString = streaming["hlsManifestUrl"] as? String,
              let url = URL(string: hlsString) else {
            throw YouTubeServiceError.streamExtractionFailed
        }
        log.info("Authenticated Web-Safari returned native HLS")
        return url
    }

    func fetchLegacyAndroidAdaptiveStreams(id: String, maxHeight: Int) async throws -> NativeAdaptiveStreams {
        // Android 20.26.01 predates the server-ABR-only response rollout and still returns
        // direct DASH URLs for H.264 video plus AAC audio. They are streamed by two synchronized
        // native AVPlayers; remote fragmented MP4 cannot be inserted into AVMutableComposition.
        let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        let userAgent = "com.google.android.youtube/20.26.01 (Linux; U; Android 11) gzip"
        let body: [String: Any] = [
            "context": ["client": [
                "clientName": "ANDROID",
                "clientVersion": "20.26.01",
                "androidSdkVersion": 30,
                "userAgent": userAgent,
                "osName": "Android",
                "osVersion": "11"
            ]],
            "videoId": id,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        func playerJSON(useAuthentication: Bool) async throws -> [String: Any] {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let cookies = client.cookies
            if useAuthentication, !cookies.isEmpty {
                request.setValue(cookies, forHTTPHeaderField: "Cookie")
                request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
                request.setValue("https://www.youtube.com", forHTTPHeaderField: "X-Origin")
                request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
                if let authorization = client.model.generateSAPISIDHASHForCookies(cookies) {
                    request.setValue(authorization, forHTTPHeaderField: "Authorization")
                }
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "FreeTubeHD", code: 1, userInfo: [NSLocalizedDescriptionKey: "高清接口 HTTP 请求失败"])
            }
            if let status = (json["playabilityStatus"] as? [String: Any])?["status"] as? String,
               status != "OK" {
                throw NSError(domain: "FreeTubeHD", code: 2, userInfo: [NSLocalizedDescriptionKey: "高清接口要求验证（\(status)）"])
            }
            return json
        }

        var lastError: Error?
        let attempts = client.cookies.isEmpty ? [false] : [false, true]
        for authenticated in attempts {
            do {
                let json = try await playerJSON(useAuthentication: authenticated)
                guard let streaming = json["streamingData"] as? [String: Any],
                      let formats = streaming["adaptiveFormats"] as? [[String: Any]] else {
                    throw NSError(domain: "FreeTubeHD", code: 3, userInfo: [NSLocalizedDescriptionKey: "高清接口未返回自适应格式"])
                }

                func directURL(_ format: [String: Any]) -> URL? {
                    guard let value = format["url"] as? String else { return nil }
                    return URL(string: value)
                }
                let videoCandidates: [(url: URL, height: Int)] = formats.compactMap { format in
                    guard let mime = format["mimeType"] as? String,
                          mime.lowercased().contains("video/mp4"),
                          let height = format["height"] as? Int,
                          height <= maxHeight,
                          let url = directURL(format) else { return nil }
                    return (url, height)
                }
                let audioCandidates: [(url: URL, bitrate: Int)] = formats.compactMap { format in
                    guard let mime = format["mimeType"] as? String,
                          mime.lowercased().contains("audio/mp4"),
                          let url = directURL(format) else { return nil }
                    return (url, format["bitrate"] as? Int ?? 0)
                }
                guard let video = videoCandidates.max(by: { $0.height < $1.height }) else {
                    throw NSError(domain: "FreeTubeHD", code: 4, userInfo: [NSLocalizedDescriptionKey: "未获得 1080p/720p 视频直链"])
                }
                guard let audio = audioCandidates.max(by: { $0.bitrate < $1.bitrate }) else {
                    throw NSError(domain: "FreeTubeHD", code: 5, userInfo: [NSLocalizedDescriptionKey: "未获得 AAC 音频直链"])
                }
                log.info("Legacy Android auth=\(authenticated, privacy: .public) selected native adaptive MP4 height=\(video.height, privacy: .public)")
                return NativeAdaptiveStreams(videoURL: video.url, audioURL: audio.url, height: video.height)
            } catch {
                lastError = error
                log.notice("Legacy Android HD auth=\(authenticated, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        throw lastError ?? YouTubeServiceError.streamExtractionFailed
    }

    func fetchAndroidProgressiveURL(id: String, maxHeight: Int) async throws -> URL {
        log.info("fetchAndroidProgressiveURL start id=\(id, privacy: .public)")
        let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        let userAgent = "com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip"
        let androidClient: [String: Any] = [
            "clientName": "ANDROID",
            "clientVersion": "21.26.364",
            "androidSdkVersion": 30,
            "userAgent": userAgent,
            "osName": "Android",
            "osVersion": "11"
        ]
        let mwebClient: [String: Any] = [
            "clientName": "MWEB",
            "clientVersion": "2.20260708.05.00",
            "userAgent": "Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1,gzip(gfe)"
        ]

        func request(clientContext: [String: Any], label: String, useAuthentication: Bool) async throws -> URL? {
            let body: [String: Any] = [
                "context": ["client": clientContext],
                "videoId": id,
                "contentCheckOk": true,
                "racyCheckOk": true
            ]
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            let cookies = client.cookies
            if useAuthentication, !cookies.isEmpty {
                request.setValue(cookies, forHTTPHeaderField: "Cookie")
                request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
                request.setValue("https://www.youtube.com", forHTTPHeaderField: "X-Origin")
                request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
                if let authorization = client.model.generateSAPISIDHASHForCookies(cookies) {
                    request.setValue(authorization, forHTTPHeaderField: "Authorization")
                }
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if let playability = json["playabilityStatus"] as? [String: Any],
               let status = playability["status"] as? String,
               status != "OK" {
                log.notice("\(label, privacy: .public) client auth=\(useAuthentication, privacy: .public) playability=\(status, privacy: .public)")
                return nil
            }
            guard let streaming = json["streamingData"] as? [String: Any],
                  let rawFormats = streaming["formats"] as? [[String: Any]] else {
                return nil
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
            guard let best = candidates.max(by: { $0.height < $1.height }) else { return nil }
            log.info("\(label, privacy: .public) client auth=\(useAuthentication, privacy: .public) selected muxed MP4 height=\(best.height, privacy: .public)")
            return best.url
        }

        // Public videos should not be poisoned by stale or partially accepted account cookies.
        // Rotate between two native clients, then retry both with the saved authenticated session.
        if let url = try await request(clientContext: androidClient, label: "ANDROID", useAuthentication: false) { return url }
        if let url = try await request(clientContext: mwebClient, label: "MWEB", useAuthentication: false) { return url }
        if !client.cookies.isEmpty {
            if let url = try await request(clientContext: mwebClient, label: "MWEB", useAuthentication: true) { return url }
            if let url = try await request(clientContext: androidClient, label: "ANDROID", useAuthentication: true) { return url }
        }
        throw YouTubeServiceError.streamExtractionFailed
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
            // Stream extraction failure must not sign the user out; account validity is checked
            // only by authenticated account endpoints.
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
