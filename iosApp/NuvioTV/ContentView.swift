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
    /// H-1B-ii (beta.15): Home's view model lives HERE, above the `.id(appTheme.themeName)` rebuild
    /// boundary applied to the `Group` below, so a theme flip (which a profile-scoped sync pull can
    /// deliver minutes after cold launch) rebuilds Home's VIEWS without rebuilding Home's DATA.
    /// While `HomeView` owned it via `@StateObject`, that rebuild produced a second
    /// `HomeViewModel` — replayed StateFlow publish (duplicate hero head), a second forced
    /// `HomeRepository.refresh`, and two hero paint pipelines alive across the swap: the tester's
    /// "doubled hero". `HomeView` now only `acquire()`s / `release()`s it (refcounted because
    /// SwiftUI inserts the incoming subtree before removing the outgoing one), and this view hard-
    /// stops it on profile exit below — the teardown Home's view lifetime used to do implicitly.
    ///
    /// Codex wave-4 (P1) — `@State`, NOT `@StateObject`, and load-bearing exactly like
    /// `MainTabView.tabBarVisibility` (T3): `@State` on a reference type stores the instance once
    /// with the same lifetime but WITHOUT subscribing this view to `objectWillChange`. With
    /// `@StateObject`, every hero/row/progress publication would re-evaluate the entire app root
    /// (Group + MainTabView) — restoring the shell-wide invalidation storm T3 removed. Only
    /// `HomeView` (via `@ObservedObject`) is supposed to observe this model.
    @State private var home = HomeViewModel()
    @StateObject private var topShelf = TopShelfUpdater()
    @State private var entered = false
    @State private var selectedTab = 0
    /// Which Settings category the split view is showing. Owned HERE, above the
    /// `.id(appTheme.themeName)` rebuild boundary, for exactly the reason `selectedTab` is: picking
    /// a theme swatch re-identifies the whole tree, and while this was a plain `@State` inside
    /// `SettingsView` the split snapped back to the first category (Account & Services) on every
    /// theme change — so pressing a colour looked like it had done nothing at all, which is how the
    /// "the theme picker doesn't work" report reads on screen.
    @State private var settingsCategory: SettingsCategory = .accountServices
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
                        // H-1B-ii: handed down (not re-created) so the theme `.id()` rebuild of
                        // this Group cannot re-create Home's data pipeline.
                        home: home,
                        onSwitchProfile: { entered = false },
                        selectedTab: $selectedTab,
                        settingsCategory: $settingsCategory,
                        // FEAT-25 (Codex beta.14 r8): the app-root deep-link cover (Top Shelf)
                        // presents over the whole shell without touching tab selection or push
                        // depth — it must count as covering Home, or the hero trailer plays
                        // audibly beneath DeepLinkTitleView/StreamPickerView.
                        rootCoverActive: deepLink != nil
                    )
                    .environmentObject(auth)
                } else {
                    // `reseedNow()` BEFORE `entered = true`: the chosen profile's theme must be
                    // applied while only this picker is mounted, or MainTabView mounts under the
                    // boot-time theme and the async watcher delivery remounts the whole shell
                    // ~70ms later (see AppThemeModel.reseedNow).
                    ProfileSelectionView(model: profiles, onSelected: { appTheme.reseedNow(); entered = true })
                }
            }
        }
        .environment(\.posterStyle, posterStyle.style)
        .environment(\.cardDepthStyle, cardDepth.style)
        // NOTE — deliberately NO app-root `.tint(Theme.Palette.accent)`. It looks like the obvious
        // way to make stock controls follow the theme, and it was tried (2026-08-25, sim-verified
        // via test43's `43b` capture): on tvOS it repaints the `Menu { Picker }` row's LABEL PILL
        // with the accent, and the pill's label is drawn in a colour chosen for the default grey
        // fill — the Settings Style / Size / Corners rows became solid accent bars with invisible
        // text. Settings gets its accent from explicit, per-element tinting in the row kit
        // (`SettingsAccentTint` in SettingsRowViews.swift) instead, which never touches a control's
        // background.
        // Theme change → rebuild the tree so every static Theme.Palette.accent read re-evaluates.
        // Focus resets on change; the state that would visibly strand the user — the selected tab
        // and the Settings category — is held above this boundary so it survives.
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
            if newGate != .main {
                entered = false
                // H-1B-ii: hard teardown of Home's (profile-scoped) watchers. `home` now outlives
                // `HomeView`, so leaving the signed-in state no longer implicitly stops them the
                // way the old view-lifetime `onDisappear → model.stop()` did. Redundant with the
                // `entered` handler below when we were entered (the hard stop is idempotent), but
                // required on its own when the gate drops while sitting on the profile picker.
                home.stop()
            }
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
                // H-1B-ii: `entered == false` is BOTH "switch profile" (the MainTabView
                // `onSwitchProfile` closure) and the sign-out path. Everything `home` observes is
                // profile-scoped, and it now outlives `HomeView`, so the profile exit must tear it
                // down explicitly — exactly what Home's view lifetime used to do implicitly. Hard
                // stop, not `release()`: it must drop regardless of who still holds it, and the
                // unmounting HomeView's own `release()` is absorbed by the model.
                home.stop()
                // Periodic activity polling is profile-scoped too, and "switch profile" keeps the
                // selected profile active in the repository — without this the loop started at
                // profile entry keeps pulling every 15 min while the picker is up. Idempotent
                // with the sign-out path's cancelAccountSync (Codex 2026-08-24).
                SyncManager.shared.stopPeriodicNuvioSyncPull()
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
            // Foreground/background sync lifecycle (mirrors mobile's AppVisibility collector in
            // MainAppContent). SyncManager self-guards: no-op unless signed in with a real account.
            // Divergence from mobile: iOS maps willResignActive → Background; on tvOS we only stop
            // the periodic loop on a real .background, not the transient .inactive that fires
            // during app-switcher overlays — restarting the loop is cheap, churn is not.
            switch newPhase {
            case .active:
                guard auth.gate == .main, entered else { return }
                // No force: the 2-minute activity-pull freshness gate inside SyncManager decides.
                SyncManager.shared.requestForegroundPull(
                    profileId: ProfileRepository.shared.activeProfileId,
                    force: false
                )
                SyncManager.shared.startPeriodicNuvioSyncPull(
                    profileId: ProfileRepository.shared.activeProfileId
                )
                // Re-register this device/session on foreground (self-throttled to once per
                // 15 min inside DeviceSessionRegistration unless force is passed).
                Task {
                    _ = try? await DeviceSessionRegistration.shared.registerIfAuthenticated(force: false)
                }
            case .background:
                SyncManager.shared.stopPeriodicNuvioSyncPull()
            default:
                break
            }
        }
        #if DEBUG
        // `debug.mpvSmokeURL`: present the real player over the root for sim validation of the
        // libmpv path (see MPVSmokeTest.swift).
        .modifier(MPVSmokeModifier())
        #endif
    }
}

/// The main app shell once a profile is selected.
struct MainTabView: View {
    let activeProfile: NuvioProfile?
    /// H-1B-ii: Home's view model, owned by `ContentView` above the theme `.id()` boundary and
    /// merely PASSED THROUGH here. Deliberately a plain `let` — NOT `@ObservedObject`. Observing it
    /// would re-couple `MainTabView.body` to `HomeViewModel.objectWillChange`, so every Home
    /// publish (hero commit, row rebuild, continue-watching tick) would invalidate the shell and
    /// re-evaluate every `Tab` closure — precisely the T3/BUG-66 class documented on
    /// `tabBarVisibility` below, which the tab-bar wave fixed by making these subtrees constant and
    /// prunable. `HomeView` is the only view that should observe it, and it does.
    let home: HomeViewModel
    let onSwitchProfile: () -> Void
    /// Owned by ContentView (above the theme `.id()` rebuild boundary) so changing the theme in
    /// Settings doesn't dump the user back onto the Home tab.
    @Binding var selectedTab: Int
    /// Also owned by ContentView (above the theme `.id()` boundary), same reasoning as
    /// `selectedTab`: a theme change must not dump the user out of the Settings category they were
    /// standing in. Passed straight through to `SettingsView`.
    @Binding var settingsCategory: SettingsCategory
    /// FEAT-25: true while ContentView's app-root deep-link cover is presented — a fourth way
    /// Home gets covered that neither tab selection nor push depth can see (Codex beta.14 r8).
    var rootCoverActive: Bool = false

    /// Single shared instance for the whole tab shell — provided to every tab root (and anything
    /// they push, like `DetailView`) via `.environment(\.tabBarVisibility,)` below. Declared here
    /// (not further up in `ContentView`) so it lives and dies with the tab shell itself.
    ///
    /// T3 (beta.14 regression fix, load-bearing — do NOT revert to `@StateObject`): `@State` on a
    /// reference type stores the SAME instance for the same lifetime `@StateObject` would, but
    /// without subscribing this view to the object's `objectWillChange`. `@StateObject` was the
    /// bug: it meant ANY `@Published` mutation on `tabBarVisibility` — including
    /// `homeSurfaceCovered`, which has nothing to do with the tab bar — invalidated `MainTabView`
    /// and re-evaluated every `Tab` closure's body, which is what re-resolved
    /// `.toolbarVisibility` mid-transition on every tab switch (the rounds 1–3 latch class,
    /// BUG-66). The tab bar's own presentation now flows through `tabBarImmersiveHide()`'s own
    /// `@Environment` read plus a narrow `onReceive(vis.$immersiveHidden)` — a targeted
    /// subscription to exactly the one publisher that should move it. A well-meaning revert to
    /// `@StateObject` here would silently restore the every-tab-switch toolbar re-resolution.
    @State private var tabBarVisibility = TabBarVisibility()

    var body: some View {
        // tvOS 26+ `Tab` syntax: gets the modern floating Liquid Glass top bar (the legacy
        // `.tabItem` API renders the older chrome).
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: 0) {
                HomeView(model: home)
                    .tabBarImmersiveHide()
            }
            Tab("Search", systemImage: "magnifyingglass", value: 1) {
                SearchView()
                    .tabBarImmersiveHide()
            }
            Tab("Library", systemImage: "books.vertical", value: 2) {
                LibraryView()
                    .tabBarImmersiveHide()
            }
            Tab("Add-ons", systemImage: "puzzlepiece.extension", value: 3) {
                AddonsView()
                    .tabBarImmersiveHide()
            }
            // T4: Settings and Profile don't scroll meaningfully, so they were left with no
            // tab-bar declaration at all — but that's not neutral. Without one, the resolved
            // `.toolbarVisibility` preference CHANGES on entering/leaving these two tabs (nothing
            // → whatever `.automatic` resolves to elsewhere), and a preference change is exactly
            // the kind of re-resolution that can latch the bar visible (BUG-66). `.automatic` via
            // `tabBarImmersiveHide()` is the only safe uniform value here: `.visible` would pin
            // the bar open (BUG-66 itself), and `.hidden` is wrong for a tab root.
            Tab("Settings", systemImage: "gearshape", value: 4) {
                SettingsView(selectedCategory: $settingsCategory)
                    .tabBarImmersiveHide()
            }
            Tab("Profile", systemImage: "person.crop.circle", value: 5) {
                ProfileTabView(activeProfile: activeProfile, onSwitchProfile: onSwitchProfile)
                    .tabBarImmersiveHide()
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
                .buttonStyle(.chip)
            }
            .padding(Theme.Spacing.screen)
        }
    }
}
