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
    /// Which Settings pane is open (the Settings `NavigationStack` path; empty = the category
    /// root). Owned HERE, above the `.id(...)` rebuild boundary, for exactly the reason
    /// `selectedTab` is: picking a theme swatch re-identifies the whole tree, and while the old
    /// split's category was a plain `@State` inside `SettingsView` it snapped back to the first
    /// category on every theme change — so pressing a colour looked like it had done nothing at
    /// all, which is how the "the theme picker doesn't work" report reads on screen. With the path
    /// held here, the rebuilt stack starts on Appearance again (FEAT-50).
    @State private var settingsPath: [SettingsCategory] = []
    /// The Settings category last opened: the root's preferred focus after a pop or a remount.
    /// Same ownership reason as `settingsPath`.
    @State private var settingsLastCategory: SettingsCategory? = nil
    /// Set when the user picks a theme swatch, cleared once the Appearance pane has taken focus
    /// back. Owned HERE for the same reason as `settingsPath`: the swatch press re-identifies
    /// the whole tree, and focus — unlike state — cannot survive a remount at all, so it fell to
    /// the tab bar and the user was thrown to the top of Settings. The hint lets the rebuilt pane
    /// put focus back on the swatch it was on. Not persisted: a cold launch must never steal
    /// focus into Appearance.
    @State private var pendingThemeSwatchFocus: String?
    /// FEAT-30/31: same job as `pendingThemeSwatchFocus`, for the Appearance rows that also
    /// remount the whole tree when pressed — the navigation-style picker (tabs ↔ rail), the rail
    /// visibility picker (H9) and the UI-font picker (see the `.id` below). Owned HERE for the
    /// identical reason: focus cannot
    /// survive a remount at all, so without a hint the rebuilt pane drops the user at the top of
    /// Settings and the row they just changed looks like it did nothing.
    ///
    /// Wave 1 (agent A) only OWNS the state and threads it as far as `MainTabView` — the Settings
    /// files belong to another wave, so `SettingsView`'s signature is deliberately untouched here.
    /// Not persisted: a cold launch must never steal focus into Appearance.
    @State private var pendingAppearanceRowFocus: String?
    /// H9 (FEAT-45, replacing FEAT-30's Sidebar): the navigation chrome mode (`"tabs"` default /
    /// `"rail"`; FEAT-30's stored `"sidebar"` reads as Rail and migrates once at launch). Read here
    /// for ONE purpose — it is part of the rebuild key below. `NavigationChrome.isRail()` is what
    /// the shell's own call sites read.
    @AppStorage(NavigationChrome.styleKey) private var navigationStyle = "tabs"
    /// H9: the rail's visibility (`"always"` default / `"browsing"`), also a rebuild-key input only.
    /// It changes the `Tab` closures structurally (Always Visible's inset), so it may only switch
    /// across a remount (T3 / BUG-66, the same reasoning as the style).
    @AppStorage(NavigationChrome.railVisibilityKey) private var railVisibility = "always"
    /// FEAT-31: the UI font family (`"system"` default / `"openSans"`). Also purely a rebuild-key
    /// input — `Theme.Font` resolves the family itself, and its tokens are static reads that only
    /// re-evaluate when the tree is re-identified, exactly like `Theme.Palette.accent`.
    @AppStorage(Theme.AppFontFamily.defaultsKey) private var uiFont = "system"
    /// Search & Discover batch 2026-10-06 (A5): where Discover lives. Tab presence must be
    /// launch-constant (T3), so the stored value joins the remount key below and `MainTabView`
    /// resolves `showsDiscoverTab` once per tree (and hands it to the rail). A value that arrives
    /// by sync (`hideDiscover`) is read inside the tree and takes effect at the next remount or
    /// launch.
    @AppStorage(DiscoverPlacement.defaultsKey) private var discoverPlacementRaw = ""
    /// Review r1 P2-1: bumped by every Settings pick, so a pick that leaves the stored string
    /// unchanged (it only cleared the synced flag) still remounts the tree.
    @AppStorage(DiscoverPlacement.revisionKey) private var discoverPlacementRevision = 0
    /// Deep link currently presented (Top Shelf → resume / title). Held until the user is past
    /// the auth + profile gates when the app is cold-launched from the Top Shelf.
    @State private var deepLink: DeepLink?
    @State private var pendingDeepLinkURL: URL?
    /// An external player's (Infuse) x-callback return that arrived before the profile gate was
    /// passed; replayed through `ExternalPlaybackReturnRouter` once `entered`, like
    /// `pendingDeepLinkURL` but never presented as a cover.
    @State private var pendingExternalReturnURL: URL?
    #if DEBUG
    /// rc13 (test68): one-shot latch for `-debug.openDeepLink <url>` so the `.task(id: entered)`
    /// below fires the debug link exactly once per launch, not on every later `entered` toggle
    /// (switch-profile, sign-out/in) a long-running UI test session might produce.
    @State private var debugDeepLinkConsumed = false
    #endif
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
                        settingsPath: $settingsPath,
                        settingsLastCategory: $settingsLastCategory,
                        pendingThemeSwatchFocus: $pendingThemeSwatchFocus,
                        pendingAppearanceRowFocus: $pendingAppearanceRowFocus,
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
        // and the Settings path — is held above this boundary so it survives.
        //
        // FEAT-30/31 (and H9's rail visibility) join the key. All are rare, deliberate user actions
        // in Appearance, and all change something a mid-session flip cannot safely carry:
        //  * `navigationStyle` decides the resolved `.toolbarVisibility` preference for the tab bar.
        //    Changing a resolved toolbar preference while the shell is live is the BUG-66 latch
        //    class exactly — three device rounds proved a hidden→shown bar can freeze mid-slide on
        //    hardware — so the mode switches the only way that has ever been safe: the shell is
        //    rebuilt, and the new tree resolves one constant value for its whole lifetime.
        //  * `railVisibility` decides whether the shell reserves the rail's leading width (the tab
        //    controller's UIKit safe area, set by the rail) and what `.railTabRoot` hands down as
        //    `\.railLeadingInset` / `\.rowEdgeMargins` (H9, P4 §4.3).
        //  * `uiFont` is read through `Theme.Font`'s static cache, the same static-read pattern
        //    `Palette.accent` uses, so it needs the same re-identification to take effect.
        // Selected tab, Settings path and the two focus hints above are all held ABOVE this
        // boundary, so a mode or font change costs the user nothing but the rebuild.
        .id("\(appTheme.paletteKey)|\(navigationStyle)|\(railVisibility)|\(uiFont)|\(discoverPlacementRaw)|\(discoverPlacementRevision)")
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
                if let url = pendingExternalReturnURL {
                    pendingExternalReturnURL = nil
                    ExternalPlaybackReturnRouter.handle(url)
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
            handleDeepLink(url)
        }
        #if DEBUG
        // rc13 (test68, BUG-117 season-poster shelf-width harness): a UI test has no way to
        // trigger a real `onOpenURL` (there is no Top Shelf/Springboard to click through in the
        // sim), so `-debug.openDeepLink <url>` drives the identical `handleDeepLink(_:)` path a
        // real deep link takes. Gated on `entered` — same as `pendingDeepLinkURL`'s replay above —
        // so it never fires ahead of the profile gate, plus a ~1 s settle so it lands after Home's
        // initial catalog fan-out rather than racing it.
        .task(id: entered) {
            guard entered, !debugDeepLinkConsumed,
                  let raw = UserDefaults.standard.string(forKey: "debug.openDeepLink"),
                  let url = URL(string: raw)
            else { return }
            debugDeepLinkConsumed = true
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                // Cancelled (e.g. `entered` flipped again mid-sleep, tearing this task down) —
                // don't fire a deep link the test/device state has already moved past.
                return
            }
            handleDeepLink(url)
        }
        #endif
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

    /// Shared by `.onOpenURL` (a real Top Shelf launch) and, in DEBUG builds, the
    /// `-debug.openDeepLink` test hook above — one code path so a UI test exercises exactly what a
    /// device deep link does, not a parallel imitation of it.
    private func handleDeepLink(_ url: URL) {
        // An external player's x-callback return (Infuse) is consumed here, before `DeepLink.parse`,
        // and never assigns `deepLink`: an unrecognised URL would nil it and close an open Top Shelf
        // cover. Before the profile gate it waits for `entered` (the position write and the sync
        // that follows want a restored session), then replays through the same router.
        if ExternalPlaybackReturnRouter.isCallback(url) {
            if auth.gate == .main, entered {
                ExternalPlaybackReturnRouter.handle(url)
            } else {
                pendingExternalReturnURL = url
            }
            return
        }
        if auth.gate == .main, entered {
            deepLink = DeepLink.parse(url)
        } else {
            // Cold launch from the Top Shelf: apply once the profile gate is passed.
            pendingDeepLinkURL = url
        }
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
    /// `selectedTab`: a theme change must not dump the user out of the Settings pane they were
    /// standing in. Passed straight through to `SettingsView`.
    @Binding var settingsPath: [SettingsCategory]
    /// Root focus restore for Settings; see `ContentView.settingsLastCategory`.
    @Binding var settingsLastCategory: SettingsCategory?
    /// See `ContentView.pendingThemeSwatchFocus` — threaded through for the same reason
    /// `settingsPath` is: it must live above the theme rebuild boundary.
    @Binding var pendingThemeSwatchFocus: String?
    /// FEAT-30/31: see `ContentView.pendingAppearanceRowFocus`. Threaded to here now so the state
    /// already lives above the rebuild boundary; the consumer is Wave 2's Settings work.
    @Binding var pendingAppearanceRowFocus: String?
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

    /// H9: the navigation rail's shared state, provided to every tab root alongside
    /// `tabBarVisibility` below. `@State` on a reference type for the SAME load-bearing reason as
    /// the property above (T3 / BUG-66) — see `NavigationChromeModel`'s own doc comment: observing
    /// it here would put every scroll crossing on every tab back into the shell's invalidation path,
    /// which is precisely what re-resolved `.toolbarVisibility` mid-transition. Only
    /// `NavigationRail` observes it.
    @State private var navigationChrome = NavigationChromeModel()
    /// FEAT-30 / H9: focus scope over the whole tab shell, so the rail can hand focus back to
    /// content with `resetFocus(in:)` (see `NavigationRail.fallbackHandOff`).
    @Namespace private var shellFocusScope
    /// A6: resolved once per tree identity (`@State`'s initial value), never re-read while this
    /// shell lives, so the set of tabs is constant for the tree's lifetime (T3). The rail's item
    /// list is fed from this same value.
    @State private var discoverPlacement = DiscoverPlacement.current()
    /// Own Tab adds `Tab(value: 6)` and the rail item; derived from the same once-per-tree value
    /// Search reads through `\.discoverPlacementResolved` (review r2 P3-1).
    private var showsDiscoverTab: Bool { discoverPlacement == .ownTab }

    var body: some View {
        // tvOS 26+ `Tab` syntax: gets the modern floating Liquid Glass top bar (the legacy
        // `.tabItem` API renders the older chrome).
        TabView(selection: $selectedTab) {
            // H9 (P4 §5.1): `.railTabRoot(value)` after `.tabBarImmersiveHide()` in every closure —
            // the tab index for return routes, Always Visible's leading inset and the per-tab gate
            // fallback. Structurally absent in Tabs mode, and launch-constant (T3).
            Tab("Home", systemImage: "house", value: 0) {
                HomeView(model: home)
                    .tabBarImmersiveHide()
                    .railTabRoot(0)
            }
            Tab("Search", systemImage: "magnifyingglass", value: 1) {
                SearchView()
                    // Review r2 P3-1: Search's entry row reads the same once-per-tree value.
                    .environment(\.discoverPlacementResolved, discoverPlacement)
                    .tabBarImmersiveHide()
                    .railTabRoot(1)
            }
            // Search & Discover batch 2026-10-06 (O3 Stage Discover, A6): the seventh tab, value
            // 6 so Profile keeps 5 (return routes, rail ids and tests key on it). Present only
            // when the placement setting resolves to Own Tab; `showsDiscoverTab` is resolved once
            // per tree (T3) and the placement key is part of the remount `.id` in `ContentView`.
            // Title and symbol must match `RailItem.discover`.
            if showsDiscoverTab {
                Tab("Discover", systemImage: "safari", value: 6) {
                    DiscoverTabRoot()
                        .tabBarImmersiveHide()
                        .railTabRoot(6)
                }
            }
            Tab("Library", systemImage: "books.vertical", value: 2) {
                LibraryView()
                    .tabBarImmersiveHide()
                    .railTabRoot(2)
            }
            Tab("Add-ons", systemImage: "puzzlepiece.extension", value: 3) {
                AddonsView()
                    .tabBarImmersiveHide()
                    .railTabRoot(3)
            }
            // T4: Settings and Profile don't scroll meaningfully, so they were left with no
            // tab-bar declaration at all — but that's not neutral. Without one, the resolved
            // `.toolbarVisibility` preference CHANGES on entering/leaving these two tabs (nothing
            // → whatever `.automatic` resolves to elsewhere), and a preference change is exactly
            // the kind of re-resolution that can latch the bar visible (BUG-66). `.automatic` via
            // `tabBarImmersiveHide()` is the only safe uniform value here: `.visible` would pin
            // the bar open (BUG-66 itself), and `.hidden` is wrong for a tab root.
            Tab("Settings", systemImage: "gearshape", value: 4) {
                SettingsView(
                    path: $settingsPath,
                    lastCategory: $settingsLastCategory,
                    pendingThemeSwatchFocus: $pendingThemeSwatchFocus,
                    pendingAppearanceRowFocus: $pendingAppearanceRowFocus
                )
                    .tabBarImmersiveHide()
                    .railTabRoot(4)
            }
            Tab("Profile", systemImage: "person.crop.circle", value: 5) {
                ProfileTabView(activeProfile: activeProfile, onSwitchProfile: onSwitchProfile)
                    .tabBarImmersiveHide()
                    .railTabRoot(5)
            }
        }
        .environment(\.tabBarVisibility, tabBarVisibility)
        .environment(\.navigationChrome, navigationChrome)
        // BUG-66 evidence probe (2026-09-10): arms `TabBarStateProbe`'s on-device tab-bar geometry
        // sampler once this view lands in a window. Hosted here (rather than inside a `Tab`
        // closure, or in `HomeView.swift`, which this task may not edit) because `MainTabView`'s
        // `TabView` is reachable from every tab and mounted exactly once for the whole shell —
        // zero-sized and a no-op when the probe's toggle is off. Mounted in EVERY build, not just
        // DEBUG: `TabBarStateProbe.enabled` is a launch-latched read of `debug.tabBarStateProbe`
        // (TabBarStateProbe.swift) which the About pane's toggle writes in Release too, so a
        // DEBUG-only armer meant every rc sample logged `NOT-FOUND state=unknown`.
        .background(TabBarProbeArmer())
        // FEAT-30 / H9: the shell-wide focus scope `resetFocus(in:)` targets. Rail mode only, so
        // tabs mode carries no new modifier at all (the byte-identical promise; test54's row walk
        // stopped finding tiles in the one run where this scope was declared in both modes).
        .modifier(ShellFocusScopeModifier(scope: shellFocusScope))
        // FEAT-30: keeps `Theme.Size.heroPinnedRowsViewportBudget` honest if hiding the system tab
        // bar moves the shell's top safe area. Ships as a no-op (the constant is 0 and the
        // modifier then applies nothing at all, in either mode) until the device spike measures
        // the delta — see that constant's doc comment.
        .railTopCompensation()
        // H9: the rail is mounted HERE — on the TabView and deliberately OUTSIDE every `Tab`
        // closure (FEAT-30's sidebar sat in the same place). Inside one it would live in that
        // tab's kept-alive subtree: pruned or deferred with it, re-created per tab, and
        // re-evaluated on every `Tab` closure rebuild — the T3 class again. As an overlay it is a
        // floating layer; the only content geometry it changes is Always Visible's leading inset,
        // UIKit safe area on the tab controller (`HiddenTabBarFocusBlocker.setReservedLeadingInset`)
        // plus `.railTabRoot`'s environment values, and tabs mode gets no view at all.
        //
        // BOTH shared objects are handed over as explicit parameters, and `tabBarVisibility` has
        // to be (rc2 fix, 2026-09-06). The `.environment(\.tabBarVisibility,)` above does NOT
        // reach this closure: overlay content is laid out by the `.overlay` modifier, which sits
        // outside the environment modifiers in this chain, so the child's
        // `@Environment(\.tabBarVisibility)` resolved to the key's unconnected default instance
        // and the immersive-push signal never arrived — the pill stayed painted over a pushed
        // DetailView. Passing the instance costs the shell nothing: a plain `let` hands the object
        // over without subscribing anyone, so the T3/BUG-66 property (this body never re-evaluates
        // on a visibility publish) is unchanged, and the overlay keeps the one narrow
        // `onReceive($immersiveHidden)`.
        //
        // The rail places itself (16 pt from the bezel, vertically centred, safe area ignored)
        // rather than being padded here: the numbers belong next to its own layout constants.
        .overlay(alignment: .topLeading) {
            if NavigationChrome.isRail() {
                NavigationRail(
                    selectedTab: $selectedTab,
                    activeProfile: activeProfile,
                    rootCoverActive: rootCoverActive,
                    shellFocusScope: shellFocusScope,
                    chrome: navigationChrome,
                    tabBarVisibility: tabBarVisibility,
                    showsDiscover: showsDiscoverTab
                )
            }
        }
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
        // Search & Discover batch 2026-10-06 (B3 g): Search's "All search sources are off" empty
        // state offers "Open Search Sources". The Search tab can't reach the Settings stack, so it
        // posts `.nuvioOpenSettings` with the category and this always-mounted shell does the jump.
        .onReceive(NotificationCenter.default.publisher(for: .nuvioOpenSettings)) { note in
            let raw = note.userInfo?["category"] as? String
            let category = raw.flatMap(SettingsCategory.init(rawValue:))
            selectedTab = 4
            if let category {
                settingsPath = [category]
                settingsLastCategory = category
            }
        }
        .onChange(of: selectedTab) { _, tab in
            tabBarVisibility.setHomeTabSelected(tab == 0)
            // beta.18 verdict (BUG-66): `r=tab` now and `r=tab2` 0.6 s later in the Tab Bar
            // Geometry pane — what the bar tracks after a switch is the half of BUG-66 the cold
            // launch never showed. No-op unless that probe is armed.
            TabBarStateProbe.noteTabSelected(tab)
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
        // FEAT-30 (Codex r2) / H9: Profile is a tab root too; with the system bar hidden in Rail
        // mode a Menu press here needs the same route to the rail the other roots have.
        .railMenuReveal()
    }
}

/// FEAT-30 / H9: `.focusScope` over the tab shell, structurally absent in tabs mode.
private struct ShellFocusScopeModifier: ViewModifier {
    let scope: Namespace.ID
    @ViewBuilder
    func body(content: Content) -> some View {
        if NavigationChrome.isRail() {
            content.focusScope(scope)
        } else {
            content
        }
    }
}

// MARK: - Cross-tab requests

extension Notification.Name {
    /// Posted by a tab that wants the shell to open Settings. `userInfo["category"]` carries a
    /// `SettingsCategory` raw value (optional). Search & Discover batch 2026-10-06.
    static let nuvioOpenSettings = Notification.Name("com.nuvio.tv.openSettings")
}
