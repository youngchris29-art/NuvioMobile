import SwiftUI
import SharedCore

/// Root gate: shows the "Who's watching?" profile picker until a profile is chosen, then the main
/// tab shell. Choosing a profile drives per-profile data scoping (via `ActiveProfileProvider`).
struct ContentView: View {
    @StateObject private var profiles = ProfilesViewModel()
    @State private var entered = false

    var body: some View {
        if entered {
            MainTabView(
                activeProfile: profiles.activeProfile,
                onSwitchProfile: { entered = false }
            )
        } else {
            ProfileSelectionView(model: profiles, onSelected: { entered = true })
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
            AddonsView()
                .tabItem { Label("Add-ons", systemImage: "puzzlepiece.extension") }
        }
    }
}
