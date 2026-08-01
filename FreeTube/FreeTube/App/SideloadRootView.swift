import SwiftUI

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

                PlayerSurface(player: player.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(Color.black)
                    .overlay {
                        DownloadProgressOverlay(state: player.loadState)
                    }

                Spacer()

                if case .failed(let message) = player.loadState {
                    Text(message)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }
}
