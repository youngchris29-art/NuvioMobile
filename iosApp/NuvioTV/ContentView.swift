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
    @State private var entered = false
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
                        onSwitchProfile: { entered = false }
                    )
                    .environmentObject(auth)
                } else {
                    ProfileSelectionView(model: profiles, onSelected: { entered = true })
                }
            }
        }
        .environment(\.posterStyle, posterStyle.style)
        .onAppear {
            auth.start()
            posterStyle.start()
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

    var body: some View {
        TabView {
            HomeView(activeProfile: activeProfile, onSwitchProfile: onSwitchProfile)
                .tabItem { Label("Home", systemImage: "house") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
            AddonsView()
                .tabItem { Label("Add-ons", systemImage: "puzzlepiece.extension") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
