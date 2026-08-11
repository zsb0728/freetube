import SwiftUI
import WebKit

/// Visible HD fallback for devices where YouTube's remote video-only DASH item is metadata-ready
/// but AVPlayer renders a permanently black surface. Uses the same persistent WKWebsiteDataStore
/// as LoginWebView, so the user's YouTube session is available to the official embed player.
@available(iOS 17.0, *)
struct WebHDPlayerSurface: UIViewRepresentable {
    let videoID: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .black
        webView.isOpaque = false
        load(videoID: videoID, in: webView)
        context.coordinator.loadedVideoID = videoID
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedVideoID != videoID else { return }
        context.coordinator.loadedVideoID = videoID
        load(videoID: videoID, in: webView)
    }

    private func load(videoID: String, in webView: WKWebView) {
        var components = URLComponents(string: "https://www.youtube.com/embed/\(videoID)")!
        components.queryItems = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "vq", value: "hd1080"),
            URLQueryItem(name: "rel", value: "0"),
            URLQueryItem(name: "modestbranding", value: "1")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        webView.load(request)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedVideoID: String?

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }
    }
}
