import SwiftUI
import SharedCore

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            AddonsView()
                .tabItem { Label("Add-ons", systemImage: "puzzlepiece.extension") }
        }
    }
}
