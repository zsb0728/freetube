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
        prepareAndLoad(videoID: videoID, in: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedVideoID != videoID else { return }
        prepareAndLoad(videoID: videoID, in: view, coordinator: context.coordinator)
    }

    private func prepareAndLoad(videoID: String, in view: WKWebView, coordinator: Coordinator) {
        // Mark before any asynchronous cookie work. SwiftUI may call updateUIView repeatedly while
        // the first navigation is pending; without this guard each pass reloads the full YouTube
        // page and creates a new media element/WebContent workload.
        coordinator.loadedVideoID = videoID

        let cookies = Self.cookiesFromStoredHeader()
        guard !cookies.isEmpty else {
            Self.loadWatchPage(videoID: videoID, in: view)
            return
        }

        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard coordinator.loadedVideoID == videoID else { return }
            Self.loadWatchPage(videoID: videoID, in: view)
        }
    }

    private static func loadWatchPage(videoID: String, in view: WKWebView) {
        guard var components = URLComponents(string: "https://m.youtube.com/watch") else { return }
        components.queryItems = [
            URLQueryItem(name: "v", value: videoID),
            URLQueryItem(name: "app", value: "desktop")
        ]
        guard let url = components.url else { return }
        view.load(URLRequest(url: url))
    }

    /// Converts the Keychain-only Cookie header into in-memory WebKit cookies. Values are never
    /// logged or persisted elsewhere. YouTube-scoped auth cookies let restricted watch pages pass
    /// the anonymous "confirm you're not a bot" interstitial when the user signed in in FreeTube.
    private static func cookiesFromStoredHeader() -> [HTTPCookie] {
        guard let header = CookieStore.shared.loadHeader(), !header.isEmpty else { return [] }
        return header.split(separator: ";").compactMap { field in
            let pair = field.trimmingCharacters(in: .whitespaces)
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let name = String(pair[..<separator])
            let value = String(pair[pair.index(after: separator)...])
            guard !name.isEmpty else { return nil }
            return HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: ".youtube.com",
                .path: "/",
                .secure: "TRUE"
            ])
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedVideoID: String?
    }
}
