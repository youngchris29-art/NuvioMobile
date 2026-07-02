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
    @State private var entered = false
    @State private var selectedTab = 0
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
        TabView(selection: $selectedTab) {
            HomeView(activeProfile: activeProfile, onSwitchProfile: onSwitchProfile)
                .tabItem { Label("Home", systemImage: "house") }
                .tag(0)
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(1)
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(2)
            AddonsView()
                .tabItem { Label("Add-ons", systemImage: "puzzlepiece.extension") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(4)
        }
    }
}
