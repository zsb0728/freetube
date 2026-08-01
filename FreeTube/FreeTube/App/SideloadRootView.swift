import SwiftUI
import WebKit

/// Conservative sideload shell for iOS 27 compatibility.
///
/// Video taps still use `PlayerStateManager`, but presentation is a native SwiftUI
/// `fullScreenCover` containing `AVPlayerViewController`. This intentionally bypasses every
/// LNPopupUI presentation/modifier path, which is the only major device-only variable left after
/// Python/yt-dlp was removed from playback.
@available(iOS 17.0, *)
struct SideloadRootView: View {
    @Environment(PlayerStateManager.self) private var player
    @State private var selectedTab: Tab = .search

    enum Tab: Hashable {
        case search, library, link, downloads, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeScreen()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            LibraryScreen()
                .tabItem { Label("Library", systemImage: "play.square.stack") }
                .tag(Tab.library)

            FetchScreen()
                .tabItem { Label("Link", systemImage: "link") }
                .tag(Tab.link)

            DownloadsScreen()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .tag(Tab.downloads)

            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .task {
            await SessionManager.shared.bootstrap()
        }
        .fullScreenCover(isPresented: playerPresentation) {
            NativePlayerScreen()
                .environment(player)
        }
        .onReceive(NotificationCenter.default.publisher(for: .freetubeSelectTab)) { note in
            if let tab = note.object as? RootView.Tab {
                switch tab {
                case .search: selectedTab = .search
                case .library: selectedTab = .library
                case .link: selectedTab = .link
                case .downloads: selectedTab = .downloads
                case .settings: selectedTab = .settings
                }
            }
        }
    }

    private var playerPresentation: Binding<Bool> {
        Binding(
            get: { player.miniPlayerVisible && player.currentVideo != nil },
            set: { presented in
                if !presented { player.dismiss() }
            }
        )
    }
}

@available(iOS 17.0, *)
private struct NativePlayerScreen: View {
    @Environment(PlayerStateManager.self) private var player

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button {
                        player.dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel("Close")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentVideo?.title ?? "FreeTube")
                            .font(.headline)
                            .lineLimit(1)
                        Text(player.currentVideo?.channelName ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                if case .failed = player.loadState,
                   let videoID = player.currentVideo?.id {
                    YouTubeWatchFallback(videoID: videoID)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    PlayerSurface(player: player.player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(Color.black)
                        .overlay {
                            DownloadProgressOverlay(state: player.loadState)
                        }
                    Spacer()
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }
}


@available(iOS 17.0, *)
private struct YouTubeWatchFallback: UIViewRepresentable {
    let videoID: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .default()

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        load(videoID: videoID, in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedVideoID != videoID else { return }
        load(videoID: videoID, in: view)
    }

    private func load(videoID: String, in view: WKWebView) {
        guard var components = URLComponents(string: "https://m.youtube.com/watch") else { return }
        components.queryItems = [
            URLQueryItem(name: "v", value: videoID),
            URLQueryItem(name: "app", value: "desktop")
        ]
        guard let url = components.url else { return }
        view.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedVideoID: String?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loadedVideoID = URLComponents(
                url: webView.url ?? URL(fileURLWithPath: "/"),
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "v" })?.value
        }
    }
}
