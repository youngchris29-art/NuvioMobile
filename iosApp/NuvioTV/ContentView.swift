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
    @StateObject private var cardDepth = CardDepthStyleModel()
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
                        selectedTab: $selectedTab,
                        // FEAT-25 (Codex beta.14 r8): the app-root deep-link cover (Top Shelf)
                        // presents over the whole shell without touching tab selection or push
                        // depth — it must count as covering Home, or the hero trailer plays
                        // audibly beneath DeepLinkTitleView/StreamPickerView.
                        rootCoverActive: deepLink != nil
                    )
                    .environmentObject(auth)
                } else {
                    ProfileSelectionView(model: profiles, onSelected: { entered = true })
                }
            }
        }
        .environment(\.posterStyle, posterStyle.style)
        .environment(\.cardDepthStyle, cardDepth.style)
        // Theme change → rebuild the tree so every static Theme.Palette.accent read re-evaluates.
        // (Navigation/focus state resets on change — acceptable; it only happens in Settings.)
        .id(appTheme.themeName)
        .onAppear {
            auth.start()
            posterStyle.start()
            cardDepth.start()
            appTheme.start()
            #if DEBUG
            // FEAT-5 device diagnostic: prints what the external-player probe sees. A scheme
            // missing from LSApplicationQueriesSchemes logs a "not allowed to query" console
            // error and returns false; a declared scheme with no installed handler returns
            // false silently — so this output distinguishes plist problems from the target
            // player simply not registering its URL scheme on tvOS.
            for scheme in ["infuse", "vlc-x-callback", "outplayer", "open-vidhub", "vidhub"] {
                if let url = URL(string: "\(scheme)://") {
                    print("[ExtPlayerProbe] canOpenURL(\(scheme)://) = \(UIApplication.shared.canOpenURL(url))")
                }
            }
            let players = ExternalPlayerPlatform.shared.availablePlayers()
            print("[ExtPlayerProbe] availablePlayers = \(players.map { "\($0.id):\($0.name)" })")
            #endif
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
            // Re-register this device/session on foreground (self-throttled to once per
            // 15 min inside DeviceSessionRegistration unless force is passed).
            Task {
                _ = try? await DeviceSessionRegistration.shared.registerIfAuthenticated(force: false)
            }
        }
        #if DEBUG
        // `debug.mpvSmokeURL`: present the real player over the root for sim validation of the
        // libmpv path (see MPVSmokeTest.swift).
        .modifier(MPVSmokeModifier())
        // `debug.settingsKitPreview`: throwaway stock-List Settings spike (beta.15 plan §C, task
        // C0 — see SettingsKitPreview.swift). Delete this line when that file is deleted.
        .modifier(SettingsKitPreviewModifier())
        #endif
    }
}

/// The main app shell once a profile is selected.
struct MainTabView: View {
    let activeProfile: NuvioProfile?
    let onSwitchProfile: () -> Void
    /// Owned by ContentView (above the theme `.id()` rebuild boundary) so changing the theme in
    /// Settings doesn't dump the user back onto the Home tab.
    @Binding var selectedTab: Int
    /// FEAT-25: true while ContentView's app-root deep-link cover is presented — a fourth way
    /// Home gets covered that neither tab selection nor push depth can see (Codex beta.14 r8).
    var rootCoverActive: Bool = false

    /// Single shared instance for the whole tab shell — provided to every tab root (and anything
    /// they push, like `DetailView`) via `.environment(\.tabBarVisibility,)` below. `@StateObject`
    /// here (not further up in `ContentView`) so it lives and dies with the tab shell itself.
    @StateObject private var tabBarVisibility = TabBarVisibility()

    var body: some View {
        // tvOS 26+ `Tab` syntax: gets the modern floating Liquid Glass top bar (the legacy
        // `.tabItem` API renders the older chrome).
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: 0) {
                HomeView()
                    .tabBarAutoHide(tabBarVisibility)
            }
            Tab("Search", systemImage: "magnifyingglass", value: 1) {
                SearchView()
                    .tabBarAutoHide(tabBarVisibility)
            }
            Tab("Library", systemImage: "books.vertical", value: 2) {
                LibraryView()
                    .tabBarAutoHide(tabBarVisibility)
            }
            Tab("Add-ons", systemImage: "puzzlepiece.extension", value: 3) {
                AddonsView()
                    .tabBarAutoHide(tabBarVisibility)
            }
            Tab("Settings", systemImage: "gearshape", value: 4) {
                SettingsView()
            }
            Tab("Profile", systemImage: "person.crop.circle", value: 5) {
                ProfileTabView(activeProfile: activeProfile, onSwitchProfile: onSwitchProfile)
            }
        }
        .environment(\.tabBarVisibility, tabBarVisibility)
        // FEAT-25: keep the "is Home frontmost" signal current from OUTSIDE the kept-alive tab
        // subtrees — this closure runs on the always-visible shell, so the hero trailer's
        // teardown can't be deferred along with a hidden tab's rendering.
        .onAppear {
            tabBarVisibility.setHomeTabSelected(selectedTab == 0)
            tabBarVisibility.setRootCoverActive(rootCoverActive)
        }
        .onChange(of: rootCoverActive) { _, active in
            tabBarVisibility.setRootCoverActive(active)
        }
        .onChange(of: selectedTab) { _, tab in
            tabBarVisibility.setHomeTabSelected(tab == 0)
            // A newly-selected tab starts with its bar visible from the scroll perspective — but
            // NOT via a blanket reset of `detailDepth` too: each tab keeps its own NavigationStack
            // alive across a tab switch, so a still-pushed DetailView elsewhere must keep counting
            // toward `hidden` (see TabBarVisibility's doc comment). In practice this is also the
            // only safe choice: the spike found the hidden bar safely absorbs the Up press needed
            // to reach it, so a tab switch literally can't happen while a push is keeping the bar
            // hidden — you have to pop back out (running `popImmersive()`) first.
            tabBarVisibility.setScrolled(false)
        }
    }
}

/// Applies the scroll-driven / detail-driven tab-bar auto-hide to one tab's root content. Kept as
/// a modifier (rather than inlined per `Tab`) since the same `.toolbarVisibility` + `.animation`
/// pair is identical across every scrolling tab root — only the shared `TabBarVisibility` instance
/// varies (there is exactly one, but this keeps each `Tab` closure above short and consistent).
private extension View {
    func tabBarAutoHide(_ vis: TabBarVisibility) -> some View {
        self
            // Round 4 (see TabBarVisibility.immersiveHidden): scroll no longer toggles bar
            // visibility at all — `.automatic` lets the tvOS 26 system bar do its native
            // minimize/expand as content scrolls, and only the immersive detail push
            // force-hides. Rounds 1–3 proved any hidden→shown reshow can freeze mid-slide
            // on hardware (clipped at the top until focus re-entered the bar), so the fix
            // is to not have a reshow.
            .toolbarVisibility(vis.immersiveHidden ? .hidden : .automatic, for: .tabBar)
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
                .buttonStyle(.chip)
            }
            .padding(Theme.Spacing.screen)
        }
    }
}
