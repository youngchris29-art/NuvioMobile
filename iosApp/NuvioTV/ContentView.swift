import SwiftUI
import SharedCore

/// Root gate. Auth state decides the outer screen (splash → welcome → app); once authenticated
/// (guest or account), the "Who's watching?" profile picker gates the main tab shell. Choosing a
/// profile drives per-profile data scoping (via `ActiveProfileProvider`) and, for signed-in
/// accounts, kicks off the full cloud pull for that profile.
struct ContentView: View {
    @StateObject private var auth = AuthViewModel()
    @StateObject private var profiles = ProfilesViewModel()
    @StateObject private var posterStyle = PosterStyleModel()
    @StateObject private var appTheme = AppThemeModel()
    @StateObject private var topShelf = TopShelfUpdater()
    @State private var entered = false
    @State private var selectedTab = 0
    /// Deep link currently presented (Top Shelf → resume / title). Held until the user is past
    /// the auth + profile gates when the app is cold-launched from the Top Shelf.
    @State private var deepLink: DeepLink?
    @State private var pendingDeepLinkURL: URL?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch auth.gate {
            case .loading:
                ZStack {
                    Theme.Palette.background.ignoresSafeArea()
                    ProgressView()
                        .tint(Theme.Palette.accent)
                }
            case .welcome:
                WelcomeView(model: auth)
            case .main:
                if entered {
                    MainTabView(
                        activeProfile: profiles.activeProfile,
                        onSwitchProfile: { entered = false },
                        selectedTab: $selectedTab
                    )
                    .environmentObject(auth)
                } else {
                    ProfileSelectionView(model: profiles, onSelected: { entered = true })
                }
            }
        }
        .environment(\.posterStyle, posterStyle.style)
        // Theme change → rebuild the tree so every static Theme.Palette.accent read re-evaluates.
        // (Navigation/focus state resets on change — acceptable; it only happens in Settings.)
        .id(appTheme.themeName)
        .onAppear {
            auth.start()
            posterStyle.start()
            appTheme.start()
        }
        .onChange(of: auth.gate) { _, newGate in
            // Signing out (or a remote session invalidation) tears the shell down to the gate.
            if newGate != .main { entered = false }
        }
        // Top Shelf snapshot mirrors the active profile's continue watching; only meaningful
        // once a profile is entered (data is profile-scoped).
        .onChange(of: entered) { _, isEntered in
            if isEntered {
                topShelf.start()
                if let url = pendingDeepLinkURL {
                    pendingDeepLinkURL = nil
                    deepLink = DeepLink.parse(url)
                }
            } else {
                // Sign-out wipes local progress first, so the watcher's final emission already
                // rewrote the snapshot empty before we stop observing.
                topShelf.stop()
            }
        }
        .onOpenURL { url in
            if auth.gate == .main, entered {
                deepLink = DeepLink.parse(url)
            } else {
                // Cold launch from the Top Shelf: apply once the profile gate is passed.
                pendingDeepLinkURL = url
            }
        }
        .fullScreenCover(item: $deepLink) { link in
            switch link {
            case .resume(let type, let videoId, let title, let parentMetaId, let season, let episode):
                StreamPickerView(
                    type: type,
                    videoId: videoId,
                    title: title,
                    parentMetaId: parentMetaId,
                    season: season,
                    episode: episode
                )
            case .title(let preview):
                DeepLinkTitleView(preview: preview)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Foreground refresh (mirrors mobile's AppForegroundMonitor → requestForegroundPull).
            // SyncManager self-guards: no-op unless signed in with a real account.
            guard newPhase == .active, auth.gate == .main, entered else { return }
            SyncManager.shared.requestForegroundPull(
                profileId: ProfileRepository.shared.activeProfileId,
                force: true
            )
        }
    }
}

/// The main app shell once a profile is selected.
struct MainTabView: View {
    let activeProfile: NuvioProfile?
    let onSwitchProfile: () -> Void
    /// Owned by ContentView (above the theme `.id()` rebuild boundary) so changing the theme in
    /// Settings doesn't dump the user back onto the Home tab.
    @Binding var selectedTab: Int

    var body: some View {
        // tvOS 26+ `Tab` syntax: gets the modern floating Liquid Glass top bar (the legacy
        // `.tabItem` API renders the older chrome).
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: 0) {
                HomeView()
            }
            Tab("Search", systemImage: "magnifyingglass", value: 1) {
                SearchView()
            }
            Tab("Library", systemImage: "books.vertical", value: 2) {
                LibraryView()
            }
            Tab("Add-ons", systemImage: "puzzlepiece.extension", value: 3) {
                AddonsView()
            }
            Tab("Settings", systemImage: "gearshape", value: 4) {
                SettingsView()
            }
            Tab("Profile", systemImage: "person.crop.circle", value: 5) {
                ProfileTabView(activeProfile: activeProfile, onSwitchProfile: onSwitchProfile)
            }
        }
    }
}

/// The Profile tab: shows the active profile's avatar and name with a button to return to the
/// "Who's watching?" picker. Replaces the old Home-header avatar shortcut.
struct ProfileTabView: View {
    let activeProfile: NuvioProfile?
    let onSwitchProfile: () -> Void

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.xl) {
                if let profile = activeProfile {
                    ProfileAvatar(profile: profile, size: 220)
                    Text(profile.name)
                        .font(Theme.Font.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }

                Button(action: onSwitchProfile) {
                    Label("Switch Profile", systemImage: "arrow.left.arrow.right")
                        .font(Theme.Font.body)
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.vertical, Theme.Spacing.md)
                }
                .buttonStyle(.card)
            }
            .padding(Theme.Spacing.screen)
        }
    }
}
