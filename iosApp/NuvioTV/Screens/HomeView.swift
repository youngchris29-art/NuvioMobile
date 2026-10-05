import Combine
import SwiftUI
import UIKit
import SharedCore

/// First real content screen for tvOS: a focus-navigable grid of catalog rows, fed entirely by the
/// shared Kotlin `HomeRepository`. Tapping a poster pushes the detail screen.
struct HomeView: View {
    /// H-1B-ii (beta.15): NOT `@StateObject` any more — the model is owned by `ContentView`, above
    /// the `.id(appTheme.themeName)` rebuild boundary, and handed down through `MainTabView`. A
    /// sync pull that flips the theme minutes after launch re-identifies this whole subtree; while
    /// this view owned the model that meant a second `HomeViewModel`, a replayed StateFlow publish
    /// (duplicate hero head), a second forced `HomeRepository.refresh` (fresh empty
    /// `lastRefreshSignature`) and two hero paint pipelines alive at once — the "doubled hero"
    /// report. Home's DATA lifetime is now independent of Home's VIEW identity; the view only
    /// retains/releases it (see `HomeViewModel.acquire()` for the ordering that forces refcounting).
    @ObservedObject var model: HomeViewModel
    @State private var resume: ResumeTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The Poster Style Home renders with. Read in RELEASE as well as debug builds as of Wave 10:
    /// `pinnedHeroCompression` sizes the pinned hero from `height`, so this is now production
    /// input, not just an audit hook.
    ///
    /// It used to live inside the `#if DEBUG` block below purely because the BUG-25 probe was its
    /// only consumer and an unused property in release is noise. That made the compression
    /// computation a Release-only build break ("cannot find 'debugPosterStyle' in scope") which a
    /// Debug-configured gate run cannot see — hence the rename and the promotion. It is the plain
    /// `\.posterStyle` key with no override of any kind, exactly as every other consumer reads it
    /// (`PosterCard`, `CatalogRowView`, `FolderTile`, `SearchView`), so any test override still
    /// flows through the environment the same way it always did.
    @Environment(\.posterStyle) private var posterStyle
    /// FEAT-30: the floating sidebar's shared state. Held, never OBSERVED — `@Environment` on a
    /// custom key hands over the object without subscribing to `objectWillChange`, which is the
    /// whole point here: Home must not re-render because the sidebar took focus or another tab
    /// crossed its scroll hysteresis. Home's only use is the Menu-press reveal below, and it reads
    /// the model inside that closure, at press time.
    @Environment(\.sidebarChrome) private var sidebarChrome
    /// rc13 (BUG-112 swipe): the shell's coverage signal, for `handleUpSwipe`'s "is Home even the
    /// frontmost surface" guard — `PinnedRowSettle.hostCovered` only knows about PUSHES over Home,
    /// and every tab stays mounted across a switch, so a swipe in Search would otherwise reach
    /// Home's window-level recognizer with nothing to stop it.
    ///
    /// Held, never OBSERVED, for the same reason `sidebarChrome` above is: `@Environment` on a
    /// custom key hands over an `ObservableObject` without subscribing to `objectWillChange`
    /// (`HomeHeroBackdrop` subscribes explicitly with `onReceive` where it needs to), so Home does
    /// not re-render on every tab switch. The one read happens inside a gesture callback, at swipe
    /// time — the same discipline as the Menu-press reveal.
    @Environment(\.tabBarVisibility) private var tabBarVisibility

    #if DEBUG
    /// BUG-25 audit hook (kept): exposes the depth environment Home actually renders with, as an
    /// invisible accessibility element the NuvioTVUITests harness reads (test10RenderCheck).
    /// DEBUG-only; costs nothing in release builds. Its poster-style half is now `posterStyle`
    /// above, which release code needs too.
    @Environment(\.cardDepthStyle) private var debugCardDepth
    #endif

    /// Whether the hero backdrop artwork only renders while the hero carousel is focused (the
    /// original behavior). A beta tester read the focus-gated fade as a bug ("hero posts don't
    /// work") since the artwork is invisible until you navigate down to it, so the default is now
    /// false — artwork always visible — with this Settings toggle to restore the old fade for
    /// anyone who preferred it. UserDefaults-backed and local-only (not synced): it's a per-device
    /// display preference, not account state, so no shared/Kotlin settings plumbing is needed.
    /// UX-7 precedence: a row poster that has taken over the hero (`focusModel.focusedItem`)
    /// always shows its artwork regardless of this toggle — the fade-on-focus behavior only
    /// governs the carousel's own idle state, not the focus-follows-backdrop takeover.
    /// FEAT-15 precedence: the toggle is IGNORED ENTIRELY in focus-panel mode (Show Hero off).
    /// There it would be self-contradictory — with no carousel, the artwork IS the browsing
    /// feedback, and "hide it while browsing" would blank the one thing the mode exists to show
    /// (it would also blank the resting state, where nothing holds focus yet). Its Settings row
    /// lives in the Appearance pane and stays visible; it simply has no effect while the hero is
    /// off, which is the same relationship "Nuvio-Style Hero" has (see `heroNuvioStyle`).
    @AppStorage("hero_poster_focus_only") private var heroPosterFocusOnly = false
    /// UX-2 hero redesign, v2 (opt-in): Nuvio-style hero — title/description on the LEFT,
    /// the backdrop artwork reading on the RIGHT behind a leading scrim, info panel raised
    /// toward the top (Christian's reference photos, 2026-07-30). Default stays the classic
    /// lower-left layout. Mirrored by HomeHeroForeground and the Home Screen settings pane.
    /// FEAT-15: this governs the CAROUSEL's layout only. The Show-Hero-off focus panel always
    /// renders the pinned Nuvio presentation regardless of this value — that layout is the one
    /// the request is modelled on, it is the only pinned geometry that has been device-tuned
    /// (`heroPinned*`), and the Settings row for this toggle is already hidden while Show Hero is
    /// off, so honoring a stored value the user cannot see or change would be invisible state.
    @AppStorage("hero_nuvio_style") private var heroNuvioStyle = false
    /// Home "Upcoming" row (next airing episodes of followed shows) — Settings › Home Screen ›
    /// Home Rows toggle, default ON. Local-only like `hero_nuvio_style`. Off = the shared
    /// repository is not even started, so no metadata sweep runs.
    @AppStorage("home_upcoming_row_enabled") private var upcomingRowEnabled = true
    /// FEAT-25: whether the hero plays its title's trailer on its own, with no focus anywhere near
    /// it (the Nuvio behavior). Default OFF, so an untouched install keeps exactly the static
    /// backdrop it has always had. Device-local for the same reason `inline_trailers_enabled` is —
    /// whether a living-room Apple TV should autoplay video is a per-device call. Settings › Home
    /// Screen owns the toggle UI.
    @AppStorage("hero_trailer_autoplay") private var heroTrailerAutoplay = false
    /// FEAT-25: mirrors `CatalogRowView`'s own key. Read here only so the two trailer surfaces stay
    /// off each other's toes — see `heroTrailerAutoplayActive`.
    @AppStorage("inline_trailers_enabled") private var inlineTrailersEnabled = false
    /// Where "Trailers on Focus" plays the focused title's trailer: `"poster"` (the default) keeps
    /// the original behavior — the focused card morphs into an inline trailer tile — while
    /// `"hero"` leaves every poster alone and hands the trailer to the pinned hero backdrop, which
    /// already follows focus through `HomeHeroFocusModel` (`displayHero`). Device-local for the
    /// same reason `inline_trailers_enabled` is; Settings › Home Screen owns the picker UI. Inert
    /// while Trailers on Focus is off — see `heroFocusTrailerMode`.
    @AppStorage("trailer_playback_location") private var trailerPlaybackLocation = "poster"
    /// BUG-87/89 (rc10): the two Appearance flags `CardFocusMode.resolve` branches on, read HERE
    /// because `pinnedPlan` is now mode-dependent — `PinnedRowGeometry.topReachFloor(lift:)` has to
    /// hold whatever the focus treatment raises a focused card's artwork by, so the row reaches and
    /// the hero compression differ between the zoom modes. `@AppStorage` rather than a bare
    /// `UserDefaults` read (which is what `FocusModeFlags.current` would have done) so returning from
    /// Settings re-plans: this is the same staleness class Codex r10 P2 closed for
    /// `PinnedRowTitleTracking`, where nothing in Home moves on a flag flip and the previous mode's
    /// geometry would otherwise stand until something happened to scroll.
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    /// Paired with `noZoomOnFocus` above — `FocusModeFlags` carries both, and the ring branch is the
    /// one that could make the lift height-dependent again (BUG-93 made the two zoom modes equal).
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    /// Home Stage & Strip (P1 E1): which Home this is. Read LIVE (`@AppStorage`, P2-7), so Settings ›
    /// Home Screen › Home Layout flips it at once; `-home_layout classic|stage` lands in the argument
    /// domain, which this reads too. Stage swaps the whole rows region for `StageStripHome` (E5) and
    /// sends Classic's hero machinery dormant (E2–E4); Classic is otherwise byte-identical.
    @AppStorage(HomeLayout.defaultsKey) private var homeLayoutRaw = HomeLayout.defaultValue.rawValue
    private var isStageLayout: Bool { HomeLayout.resolve(homeLayoutRaw) == .stage }
    /// rc12 BUG-87 follow-up: the No Zoom reach-hold (`AboutSettingsPane`'s "No Zoom Row Reach (A/B)"
    /// row), default ON since 2026-09-30. Read only to make this view observe the key; the value
    /// used is `PinnedRowTitle.resolveReachHoldsLift()` at the `pinnedPlan` call site below, which
    /// also honours a launch argument and the never-written default.
    @AppStorage(PinnedRowTitle.noZoomReachHoldsLiftKey) private var noZoomReachHoldsLift = true
    /// 2026-09-30 zoom-on reach hold (`FocusModeFlags.zoomReachHold`), default ON, no Settings row.
    /// Observed here; resolved at the `pinnedPlan` call site like the No Zoom hold above.
    @AppStorage(PinnedRowTitle.zoomReachHoldKey) private var zoomReachHold = true
    /// FEAT-15: the live "Show Hero" setting. `HomeCatalogSettingsRepository.snapshot()` rebuilds
    /// the entire preference map on every call, so it cannot be read from `body` at render
    /// frequency the way `reportRowFocus` used to read it per focus event — this watches the same
    /// flow SettingsViewModel does and republishes the single field Home renders from.
    @StateObject private var heroSettings = HomeHeroSettingsObserver()
    /// FEAT-25 (Codex beta.14 r2): the hero backdrop's dwell → resolve → play state machine, owned
    /// HERE so the carousel's auto-advance tick can poll the whole attempt (`phase != .idle`), not
    /// just the playback tail the coordinator's `playingKey` exposes — a cold-cache resolution can
    /// outlast the 7s tick, and advancing mid-resolve resets the model and churns forever.
    /// Observing this model is NOT the BUG-19/coordinator churn class the tick comment warns
    /// about: it publishes only the HERO's own phase — a handful of discrete changes per page
    /// cycle — never app-wide claim/release traffic.
    @StateObject private var heroTrailerModel = InlineTrailerCardModel()
    /// FEAT-25 (Codex beta.14 r5): the system Auto-Play Video Previews gate, mirrored into state
    /// because a bare `UIAccessibility.isVideoAutoplayEnabled` read in `heroTrailerAutoplayActive`
    /// re-evaluates only when something ELSE re-renders this view — flipping the setting while the
    /// app is backgrounded left the backdrop holding a stale `autoplaysTrailer == true`, and the
    /// foreground `syncTrailer()` restarted playback against the new preference. Refreshed by the
    /// status-change notification and, belt-and-braces, on every return to `.active` (the
    /// notification is not guaranteed to be delivered to a suspended process).
    @State private var systemVideoAutoplayEnabled = UIAccessibility.isVideoAutoplayEnabled
    /// FEAT-25 (Codex beta.14 r5): only for the `systemVideoAutoplayEnabled` refresh above —
    /// `HomeHeroBackdrop` owns its own copy for the play/pause lifecycle.
    @Environment(\.scenePhase) private var scenePhase
    /// FEAT-25 (device pass 2026-08-21): HOME's own NavigationStack path, bound explicitly so
    /// `homePath.isEmpty` is an EXACT "nothing pushed over Home" signal. Home's root never gets
    /// `onDisappear` on a push, and appearance-counting the pushed screens (the first attempt)
    /// conflates a destination hidden behind its own modal with a pop (Codex beta.14 r9 — a
    /// FolderDetail filter editor would have restarted the trailer under two layers). The path
    /// count can't be fooled by appearance noise: every link in the app is value-based, so every
    /// push lands here. Without this gate the hero trailer kept playing — audibly — under See
    /// All grids, EntityBrowse, and person pages.
    @State private var homePath = NavigationPath()

    // Hero carousel state, hoisted here so the full-bleed backdrop (behind the scroll) and the
    // focusable paged carousel (inside the scroll) share the same index. The carousel is a paged
    // TabView: D-pad left/right (and touch-surface swipes) page manually while the hero is
    // focused — the same interaction as the Apple TV+ feature carousel — and a timer advances it
    // while focus is elsewhere.
    @State private var heroIndex = 0
    /// Latch: the hero fan-out has produced at least one item this Home lifetime. Consumed by
    /// `heroFocusTrailerMode` as its hero-surface-existence term, and a LATCH on purpose: the
    /// hero publish path can legitimately emit nonempty → empty → nonempty mid-session (the
    /// BUG-42 "hero emptied" sequence — an addon refresh dropping the last hero-source catalog),
    /// and a term that tracked `heroCarouselActive` directly would re-branch every mounted
    /// `InlineTrailerCard` on each swing (the BUG-19 identity-churn class). Latched, the mode
    /// term moves false → true at most once per Home lifetime; during a transient empty the hero
    /// simply has nothing to play (fail-soft), and posters stay unmorphing rather than flickering
    /// through a morph-and-collapse. Never cleared until Home itself is torn down — which is the
    /// latch's honest residual (Codex pre-commit round 5): a PERMANENT mid-session hero loss (the
    /// user removes their only hero-source addon and keeps browsing) keeps suppression latched
    /// with no hero to play into until the next launch, where the empty fan-out never sets the
    /// latch and the poster morph returns. Accepted: unlatching on empty is exactly the
    /// nonempty→empty re-branch the latch exists to prevent, and the state self-heals at
    /// relaunch.
    @State private var heroSurfaceSeen = false
    @FocusState private var heroFocused: Bool
    /// Last time the hero page changed (manual or automatic). The auto-advance timer skips its
    /// tick unless the carousel has been still for most of its period, so a manual page never
    /// gets yanked forward moments later.
    @State private var lastHeroChange = Date.distantPast
    /// Held in @State so ONE publisher instance (and one onReceive subscription) survives parent
    /// re-evaluations. As a plain stored property, every ancestor emission re-created the
    /// publisher and restarted its 8s countdown — frequent upstream churn (sync, top shelf,
    /// profile publishers) starved it and the carousel silently stopped advancing.
    @State private var heroTimer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    /// BUG-27: mirrors the tab bar's scroll hysteresis (set by `reportsScrollToTabBar` below).
    /// While true, a Menu press jumps back to the top of Home and focuses the hero instead of
    /// bubbling up (which from a tab root would suspend the app) — the tvOS "long way down,
    /// short way back" convention (Netflix, TV app). At the top the handler detaches (nil), so
    /// Menu keeps its default behavior and the App Store exit convention stays intact.
    @State private var isScrolledDown = false

    /// BUG-30 device-verify probe: does tvOS focus-driven scrolling ever rest short of the true
    /// top? Six on-device fix attempts were reverted (see the do-not-retry marker below); this is
    /// instrumentation only, read once at init so toggling it never costs a UserDefaults lookup
    /// per scroll event. Kept out of `#if DEBUG` — testers run release builds and their console
    /// log is the only diagnostic we get (precedent: ProfilesViewModel.select(_:), kept out of
    /// DEBUG for the same reason). Runtime-gated instead, off by default:
    ///   defaults write com.nuvio.media.NuvioTV debug.homeScrollProbe -bool YES
    /// The same knob now also arms BUG-37's per-row title probe, so ONE walk logs both under the
    /// `[HomeScrollProbe]` prefix — see `HomeGeometryProbe` (BrowseComponents), which owns it.
    private let homeScrollProbeEnabled = HomeGeometryProbe.enabled

    /// BUG-30 companion knob, OFF by default so shipped behavior is byte-identical: applies an
    /// explicit HARD top scroll-edge treatment to the rows ScrollView. The tvOS 26 system tab bar
    /// is what renders clipped after a D-pad walk-up, and its edge presentation is driven by the
    /// scroll view's edge state — but a hard edge would also draw a crisp line across Home's
    /// full-bleed hero backdrop, which nothing but a device can judge. So it ships as an A/B knob
    /// the manual pass can flip between runs rather than an unverified visual change:
    ///   defaults write com.nuvio.media.NuvioTV debug.homeScrollEdgeHard -bool YES
    /// T5 (BUG-42): also exposed as a Settings → About toggle, since a sideloaded tester can't
    /// `defaults write`. `@AppStorage`, not a launch-latched `let`, so the switch takes effect
    /// live in the same session it's flipped in — the manual A/B pass can compare both states on
    /// one running app rather than needing a relaunch between each.
    @AppStorage("debug.homeScrollEdgeHard") private var homeScrollEdgeHard = false

    /// UX-7: always-on focus-follows-backdrop. Owns the row-focused item (if any) that should
    /// take over the hero from the carousel.
    @StateObject private var focusModel = HomeHeroFocusModel()
    /// Wave H: turns the hero TARGET (`displayHero`) into the hero that is actually PAINTED, once
    /// its backdrop and logo are both resolved. Every hero renderer below reads
    /// `heroResolver.presented`, never `displayHero` — see `HeroArtResolver`.
    @StateObject private var heroResolver = HeroArtResolver()
    /// Wave H: the hero artwork layer's own opacity, driven imperatively from `.onChange` so ONLY
    /// opacity animates. It used to be a `.animation(_:value:)` on the whole backdrop Group, which
    /// also animated GEOMETRY — a folder hero swapping a square cover for a 16:9 backdrop had its
    /// `scaledToFill` frame interpolated, which is the "mosaic pops in larger then shrinks into
    /// place" the tester filmed (BUG-86b). The image itself now changes with no implicit animation
    /// attached; `HeroCrossfadeImage` still cross-fades the bitmaps in place, which is a pure
    /// opacity effect at fixed geometry.
    @State private var heroArtOpacity: Double = 1
    /// BUG-38 round three: the folder page each hero-driving folder preview opens, keyed by the
    /// preview's synthetic id (`folderHeroPreview`). A `MetaPreview` can't carry a `FolderRoute`,
    /// and the hero CTA must open the FOLDER, never a Detail page for an id no addon knows.
    @State private var heroFolderRoutes: [String: FolderRoute] = [:]
    /// UX-7: rows whose backdrops have already been prefetch-warmed (keyed by report source),
    /// so each row pays the warm-up exactly once per Home lifetime.
    @State private var prefetchedBackdropRows = Set<String>()
    /// FEAT-33 leg 1/3 only: generation counter for the deferred folder→hero commit below. Each
    /// focus change on a collection row bumps it and captures the new value; the deferred block
    /// drops itself if the number has moved on, so walking quickly across a row commits ONE hero
    /// (the last one focused) instead of queueing a commit per tile. Never read when the A/B leg
    /// is off — the commit is immediate there, exactly as it ships today.
    @State private var folderFocusGeneration = 0

    /// Home Stage & Strip (P1 E2): empty in Stage, so the carousel, its 8 s timer, the hero page
    /// warm-up and the `heroSurfaceSeen` latch all stay dormant there.
    private var heroItems: [MetaPreview] { isStageLayout ? [] : Array(model.heroItems.prefix(8)) }
    private var currentHero: MetaPreview? {
        guard !heroItems.isEmpty else { return nil }
        return heroItems[min(heroIndex, heroItems.count - 1)]
    }

    // MARK: - Hero mode (FEAT-15)
    //
    // The hero region has exactly TWO live modes and they are mutually exclusive:
    //
    //  * CAROUSEL (`heroCarouselActive`) — Show Hero on and the fan-out has landed. Rotating
    //    pages, auto-advance timer, page dots, a focusable CTA, and the UX-7 focus takeover on
    //    top of all of it. Byte-for-byte what beta.10 shipped.
    //  * FOCUS PANEL (`focusHeroActive`) — Show Hero OFF. FEAT-15/BUG-24: the reporter has asked
    //    three times for the end state where there is no rotating banner at all, only the focused
    //    title's backdrop + text. beta.10 coupled the two (hero off killed the focus follow), so
    //    turning the carousel off cost them the description. Now hero-off KEEPS the UX-7 surface
    //    and drops only the carousel: no timer, no `heroItems`, no dots, and — deliberately — no
    //    CTA, so the panel is a pure reflection of row focus and never competes for it.
    //
    // Both modes are settings-driven, so the container split below flips only when a toggle
    // flips (the BUG-19 identity rule), never per scroll frame and never per focus event.

    /// Show Hero on AND the hero fan-out has landed: the rotating carousel exists.
    private var heroCarouselActive: Bool { !heroItems.isEmpty }

    /// Anything a row card can focus. The focus panel has nothing to reflect (and nothing to
    /// reserve space above) until Home has at least one row, so it mounts on this — a one-shot
    /// load-boundary flip, the same class as `heroItems` empty→loaded, NOT a per-focus value.
    private var hasFocusableRows: Bool {
        !model.rows.isEmpty || !model.continueWatching.isEmpty
    }

    /// FEAT-15: the hero region is the focus-only panel. Gated on the SETTING, never on
    /// `heroItems.isEmpty` — the latter is also true during the hero-on fan-out window, and
    /// mounting a panel there would pin/unpin the header inside that window in classic mode.
    /// Codex review: gated on `heroPanelSeed` rather than `hasFocusableRows` — a Home whose rows
    /// can never produce a preview (collection rows whose folders carry no hero artwork) has
    /// focusable rows but nothing the panel can represent, and mounting it there reserved a
    /// permanently blank band. BUG-38 round three: a collection folder WITH a backdrop or logo
    /// now does report a preview (`folderHeroPreview`), so such a folder also seeds the panel —
    /// a collection-only Home built from Fusion collections gets its hero. With no seed the
    /// layout degenerates to pure rows, which is also the only way a "rows only, no hero region"
    /// configuration remains reachable. Still a content/load-boundary value, never per-focus.
    private var focusHeroActive: Bool { !heroSettings.heroEnabled && heroPanelSeed != nil }

    /// Whether a hero header is mounted above the rows ScrollView at all.
    private var heroHeaderVisible: Bool {
        focusHeroActive || (heroNuvioStyle && heroCarouselActive)
    }

    /// Which CONTAINER the rows ScrollView lives in (BUG-19: this may change only when a Settings
    /// toggle flips). Pinned-capable configurations keep the VStack split permanently — the header
    /// appearing/disappearing inside it at the load boundary is a value change, not a structural
    /// one, so the rows' identity survives. `heroSettings.heroEnabled` starts at its `true` default
    /// until the settings flow publishes (very early on the Home path — `AddonRepository.initialize`
    /// and `CollectionRepository.initialize` both drive `ensureLoaded` → `publish`), so a hero-off
    /// user sees at most one container flip, before rows exist.
    private var heroContainerPinned: Bool { heroNuvioStyle || !heroSettings.heroEnabled }

    /// FEAT-15 resting state for the focus panel: the first title of the first CATALOG row.
    ///
    /// Why a resting item at all — the focus model's natural empty state is `nil`, and with no
    /// carousel underneath, `nil` means a blank hero band. That happens twice in normal use: for
    /// the frame or two between rows appearing and the first card's 0.2s commit, and every time
    /// focus leaves the rows entirely (walking up to the tab bar), where the revert grace fires a
    /// `nil` with nothing to fall back to. A deterministic resting title is stabler than a panel
    /// that blinks empty.
    ///
    /// Why a CATALOG row is preferred over the first VISIBLE row: a Continue Watching entry is
    /// adapted through `previewFromEntry`, which carries no description at all, so seeding from CW
    /// would open Home on a title with an empty synopsis. Catalog previews carry the addon's
    /// description (and BUG-42's shared publish localizes them). A CW preview is still the
    /// LAST-RESORT seed (Codex review): on a CW-only Home the alternative was a panel that sat
    /// blank until a focus commit and blanked again whenever focus left the row — title+backdrop
    /// without a synopsis beats an empty band.
    ///
    /// Deliberately STATELESS — it is derived, never committed into `HomeHeroFocusModel`, so it
    /// cannot fight a real focus claim, cannot take a `claimSource`, and cannot leave a stale
    /// pending commit. The cost is that a resting title with no description gets no TMDB gap-fill
    /// (that runs on commit only); the first focus fixes it.
    ///
    /// `heroPanelSeed` is the settings-independent content lookup (it also GATES the panel via
    /// `focusHeroActive`, so it must not consult it — that would be circular).
    private var heroPanelSeed: MetaPreview? {
        // BUG-86 hero-off rows (beta.18): no seed until the rows gate has opened. Continue Watching
        // and the collections publish ahead of the gated rows, and seeding from them painted a title
        // that the rows' first publish then replaced (test31 leg D, first fixture run: CW title at
        // 5659 ms, first-catalog-row title at 6507 ms). The "Loading catalogs…" placeholder stays up
        // instead — the same hold the carousel hero already gets from `HeroPublishRoute.hold`.
        guard model.rowsGateOpen else { return nil }
        for row in model.rows {
            if case .catalog(let section) = row, let first = section.items.first { return first }
        }
        if let firstEntry = model.continueWatching.first { return previewFromEntry(firstEntry) }
        // BUG-38 round three (Codex r2): a collection-only Home — no catalog rows, no Continue
        // Watching — still has something the panel can represent when a folder carries its own
        // hero artwork. Same load-boundary character as the branches above (it moves when the
        // collections publish, never per focus).
        for row in model.rows {
            if case .collection(let collection) = row,
               let first = collection.folders.lazy.compactMap({ folderHeroPreview(collection: collection, folder: $0) }).first {
                return first
            }
        }
        return nil
    }

    private var heroRestingItem: MetaPreview? {
        guard focusHeroActive else { return nil }
        return heroPanelSeed
    }

    /// UX-7: the item the hero should actually display — a row-focused poster wins over the
    /// carousel's own current page while one is committed. Gated on the hero MODE here, at display
    /// time, not at report time: rows report unconditionally, so a card focused while the hero
    /// fan-out is still loading takes over the moment `heroItems` arrives (no re-report exists at
    /// that boundary — `@FocusState` hasn't changed).
    /// FEAT-15: in focus-panel mode there is no carousel to fall back to, so the fallback is the
    /// resting item instead. Both modes off ⇒ nil ⇒ no hero region at all, exactly as Show Hero
    /// OFF behaved before this change.
    private var displayHero: MetaPreview? {
        // Home Stage & Strip (P1 E3): the stage owns its own focus/art pipeline
        // (`StageController`); Classic's resolver presents nil and fetches nothing.
        if isStageLayout { return nil }
        if heroCarouselActive { return focusModel.focusedItem ?? currentHero }
        if focusHeroActive { return focusModel.focusedItem ?? heroRestingItem }
        return nil
    }

    /// Wave H: hand the current target to the resolver. Called from `.onAppear`, from the target's
    /// identity changing, and from its PAYLOAD changing — the latter so a late synopsis can still
    /// gap-fill (the resolver keeps the committed artwork and never repaints for it).
    private func presentHero() {
        let target = displayHero
        // beta.19-rc1 verdict (I1, BUG-134): the form decides how large the post-commit sharpen
        // decodes the backdrop. Set before `present` so the commit it may cause plans with it.
        heroResolver.setSharpenForm(heroSharpenForm)
        heroResolver.present(target, isFolder: target.map(isCollectionHero) ?? false)
    }

    /// beta.19-rc1 verdict (I1, BUG-134): which form the hero backdrop is drawn in, for the
    /// resolver's post-commit sharpen (`HeroSharpen`): the same test `HomeHeroBackdrop(nuvioStyle:)`
    /// is given. Nuvio-style decodes the 1250 pt panel (the 3072 bucket), classic decodes full bleed.
    private var heroSharpenForm: HeroSharpen.Form {
        (heroNuvioStyle || focusHeroActive) ? .nuvio : .classic
    }

    /// beta.19-rc1 verdict (M5, BUG-138): freezes the hero focus model while anything covers Home —
    /// a pushed screen (`homePath`), the Continue Watching stream picker (`resume`), or the shell
    /// (a tab switch, a cross-stack cover). Without it the push took focus off the row, the nil
    /// report reverted the hero to the carousel page after 0.3 s behind the folder page, and on pop
    /// the carousel title showed for about a second before the folder re-committed (Steven's
    /// video, 2:57.5). See `HomeHeroFocusModel.setCovered`. `shellCovered` is the `@Published`
    /// payload when the call comes from its publisher (willSet: the property still holds the old
    /// value there).
    ///
    /// beta.19-rc1 verdict (review r1, A P3): `restoresFocus` names the covers tvOS hands row focus
    /// back from when they lift (a push, the stream picker), so the model waits long enough for that
    /// restored report before it reverts (`HomeHeroFocusModel.uncoverDelay`); the shell alone keeps
    /// the short check (focus comes back on the tab bar).
    private func syncHeroFocusCover(shellCovered: Bool? = nil) {
        let restoresFocus = !homePath.isEmpty || resume != nil
        focusModel.setCovered(restoresFocus || (shellCovered ?? tabBarVisibility.homeSurfaceCovered),
                              restoresFocus: restoresFocus)
    }

    /// Wave H: changes to the target's own fields, at the same identity. Cheap to recompute (a
    /// join over eight components) and only ever consumed by an `.onChange`.
    ///
    /// Codex r1 (P2): every field the hero actually RENDERS has to be in here, or a same-id update
    /// leaves stale text on screen forever, because nothing else calls `presentHero()` at a stable
    /// identity. The previous version carried only the description, the genre COUNT and the two
    /// artwork URLs, so a folder renamed on mobile, or genres replaced by a same-length list, was
    /// invisible. What `HomeHeroForeground` draws, and therefore what is listed below:
    /// `name` (`HeroLogo`'s text stand-in and the CTA's accessibility label), `description_`
    /// (the synopsis), `releaseInfo` + `genres` (the meta line), `logo` and `banner` (the resolved
    /// artwork), `poster` (`heroBackdropURL`'s last fallback, so it can BE the backdrop), and
    /// `type` (picks "Go to Movie" vs "Go to Show", and is not covered by the id-only `.onChange`).
    /// `imdbRating` is deliberately absent: `metaLine` does not render it, so including it would
    /// only buy needless `present` calls.
    private var heroPayloadSignature: String {
        guard let hero = displayHero else { return "-" }
        let description: String? = hero.description_
        let banner: String? = hero.banner
        let logo: String? = hero.logo
        let poster: String? = hero.poster
        let releaseInfo: String? = hero.releaseInfo
        return [
            hero.name,
            description ?? "",
            hero.genres.joined(separator: ","),
            releaseInfo ?? "",
            banner ?? "",
            logo ?? "",
            poster ?? "",
            hero.type,
        ].joined(separator: "|")
    }

    /// Whether the hero ARTWORK layer should be visible. `heroPosterFocusOnly` fades it while the
    /// carousel idles unengaged; every other configuration shows it always (UX-7/FEAT-15 precedence
    /// — see the toggle's own doc). Driven through `heroArtOpacity` rather than an `.animation`
    /// modifier so the fade cannot animate the artwork's geometry with it.
    private var heroArtVisible: Bool {
        guard heroPosterFocusOnly && heroCarouselActive else { return true }
        return heroFocused || focusModel.focusedItem != nil
    }

    /// FEAT-25: whether the hero backdrop may run a trailer right now. Three gates on top of the
    /// user's own toggle:
    /// * tvOS Accessibility ▸ Motion ▸ Auto-Play Video Previews, exactly as `CatalogRowView`
    ///   gates the inline card — a system-wide "no video previews" must silence this surface too;
    /// * the artwork being visible at all: with `heroPosterFocusOnly` on, the whole backdrop layer
    ///   sits at opacity 0 until the hero is engaged, and decoding a trailer nobody can see is
    ///   pure cost;
    /// * a row-focused poster that has taken over the hero while Trailers on Focus is also on —
    ///   that card is already growing its own tile for the same title, and both surfaces racing
    ///   the single player slot (`InlineTrailerCoordinator`) would collapse one of them mid-morph.
    ///
    /// Precedence contract with the focus-driven siblings below (`heroFocusTrailerMode` /
    /// `heroFocusTrailerActive`, folded together by `heroTrailerActive`): the third gate above —
    /// `if inlineTrailersEnabled && focusModel.focusedItem != nil { return false }` — is unchanged
    /// and applies in BOTH trailer locations. It means this property never claims the player while
    /// a poster holds committed focus, whichever surface that focus is destined to play on. In
    /// poster location the card takes the slot as before; in hero location `heroFocusTrailerActive`
    /// takes exactly that slot instead, on the same backdrop, for the same `displayHero` title.
    /// Once focus leaves the rows and the 0.3s revert grace lands `focusedItem` back on nil, this
    /// property resumes (if the user has Hero Trailer Autoplay on) and the carousel title dwells
    /// afresh. When focus arrives on the title the hero is ALREADY showing, the handoff changes no
    /// `trailerKey`, so `HomeHeroBackdrop.syncTrailer` keeps the existing playback running rather
    /// than restarting it. In every state exactly one of the two is the claimant of the single
    /// player slot.
    private var heroTrailerAutoplayActive: Bool {
        guard heroTrailerAutoplay, heroTrailerSharedGatesOpen else { return false }
        let heroEngaged = heroFocused || focusModel.focusedItem != nil
        if heroPosterFocusOnly && heroCarouselActive && !heroEngaged { return false }
        if inlineTrailersEnabled && focusModel.focusedItem != nil { return false }
        return true
    }

    /// Gates shared by BOTH hero-trailer claimants (`heroTrailerAutoplayActive` /
    /// `heroFocusTrailerActive`), hoisted so a future cover source cannot silence one trailer
    /// location and miss the other — the gates have accreted one by one on device evidence and
    /// will again:
    /// * the mirrored system Auto-Play Video Previews preference (`systemVideoAutoplayEnabled`);
    /// * device pass 2026-08-21: anything covering Home from Home's own presentation machinery —
    ///   a pushed screen (See All grid, EntityBrowse, folder, person, Detail) via `homePath`, or
    ///   the Continue Watching stream-picker cover via `resume`. Tab switches and cross-stack
    ///   coverage are the shell-level `homeSurfaceCovered` signal in `HomeHeroBackdrop`.
    private var heroTrailerSharedGatesOpen: Bool {
        guard systemVideoAutoplayEnabled else { return false }
        return homePath.isEmpty && resume == nil
    }

    /// Whether "Trailers on Focus" should play in the HERO backdrop instead of morphing the
    /// focused poster — Trailers on Focus on, the location picker set to hero, and a layout that
    /// actually pins a hero above the rows (a classic, scroll-away hero would carry the trailer
    /// off-screen the moment the user browsed downward, which is the opposite of the request).
    ///
    /// NEAR-pure composition of settings: it is NOT gated on `heroHeaderVisible`, on
    /// `displayHero`, or on any other per-focus/per-frame state. Rows read this through the
    /// environment to decide whether the poster morph exists at all, so a value that churned at
    /// arbitrary boundaries would structurally re-branch every mounted `InlineTrailerCard`
    /// mid-session — the BUG-19 identity-churn class, on the one subtree that owns a live
    /// `AVPlayer`.
    ///
    /// The one non-settings term is hero-surface EXISTENCE (`heroSurfaceSeen ||
    /// !heroSettings.heroEnabled`): without it, a zero-hero configuration — Show Hero on,
    /// Nuvio-Style on, but every hero source toggled off or returning empty — would suppress the
    /// poster morph forever while mounting no hero to play into: a permanent, silent no-trailers
    /// state (Codex pre-commit round 1). With it, "no hero surface" falls back to the poster
    /// morph instead. Both halves are single-flip by construction, matching the
    /// `heroContainerPinned` precedent: `heroSurfaceSeen` is a LATCH (false → true at the first
    /// nonempty fan-out, never back — deliberately NOT `heroCarouselActive`, whose publish path
    /// can swing nonempty → empty → nonempty mid-session per the BUG-42 "hero emptied" evidence,
    /// see the latch's own doc), and the Show-Hero-off half is `!heroSettings.heroEnabled`, NOT
    /// `focusHeroActive` (Codex pre-commit round 3): the latter also tracks the focus panel's
    /// SEED item, which can vanish mid-session (last Continue Watching entry finished on a
    /// CW-only Home) and would re-branch every mounted card. Settings-off is seed-independent
    /// and safe: whenever a poster exists to morph, the panel has a seed and mounts — a seedless
    /// Home has nothing to morph, so suppression is vacuous. So posters morph during the initial
    /// fan-out window and hand the trailer to the hero in one structural flip when it lands —
    /// never per focus, never per frame. The flip's honest cost (Codex pre-commit round 6): a
    /// poster morph IN FLIGHT at that instant (a cold launch racing a slow fan-out) is torn out
    /// structurally — `InlineTrailerCard.onDisappear → model.reset(abortStages: true)` releases
    /// the player cleanly and (beta.19-rc1 verdict R2) collapses the tile to the poster in one
    /// frame, so that one card snaps closed and the title re-dwells on the hero. Once per Home
    /// lifetime at worst, accepted over any
    /// load-state-tracking alternative. Classic (unpinned) layouts evaluate false, which is a
    /// silent fallback to the poster morph; there is no user-visible error state for "hero
    /// location requested but unavailable".
    private var heroFocusTrailerMode: Bool {
        inlineTrailersEnabled && trailerPlaybackLocation == "hero" && heroContainerPinned
            && (heroSurfaceSeen || !heroSettings.heroEnabled)
    }

    /// Whether the hero backdrop should be running the FOCUSED title's trailer right now — the
    /// hero-location counterpart to `heroTrailerAutoplayActive`, sharing its coverage gates
    /// through `heroTrailerSharedGatesOpen`.
    ///
    /// No `heroPosterFocusOnly` gate is needed here, unlike the carousel's claim: that toggle only
    /// fades the backdrop while nothing is engaged, and a committed `focusModel.focusedItem` forces
    /// the backdrop layer's opacity to 1 (see the `.opacity` gate on the hero group below). If
    /// this is true, the artwork is on screen by construction.
    ///
    /// Engagement is a COMMITTED focus (`HomeHeroFocusModel`'s 0.2s commit), never a skim — which
    /// is also the exact event that flips `displayHero` to this title, so the backdrop and the
    /// trailer claim always name the same thing.
    private var heroFocusTrailerActive: Bool {
        guard heroFocusTrailerMode, heroTrailerSharedGatesOpen else { return false }
        return focusModel.focusedItem != nil
    }

    /// The single Bool handed to `HomeHeroBackdrop` as `autoplaysTrailer`. The backdrop never needs
    /// to know WHICH mode wants a trailer: `displayHero` already resolves to the right title for
    /// whichever claim is live (the focused poster's, or the carousel page's), and `syncTrailer`
    /// re-arms on `trailerKey`/`autoplaysTrailer` changes either way. Mutually exclusive by
    /// construction — see the precedence contract on `heroTrailerAutoplayActive`.
    private var heroTrailerActive: Bool {
        // BUG-38 round three: a focused collection folder drives the hero with its own artwork;
        // it has no trailer to resolve (its synthetic id is not a title), so neither claimant may
        // arm an attempt while a folder is on the backdrop.
        // Wave H: "on the backdrop" is the PRESENTED item now, not the target. `HomeHeroBackdrop`
        // keys its trailer off what it is actually drawing, so testing the target instead would,
        // for the length of one resolve, let a title's claim arm an attempt against the folder
        // still on screen (a synthetic id no extractor can resolve) — and conversely stop a
        // playing trailer a second before its own artwork leaves.
        if let hero = heroResolver.presented?.item, isCollectionHero(hero) { return false }
        return heroFocusTrailerActive || heroTrailerAutoplayActive
    }

    /// FEAT-25: whether the hero currently owns a trailer ATTEMPT — dwell, resolution, or
    /// playback. Polled by the carousel's auto-advance tick. The phase check is the real signal
    /// (every attempt path, including "nothing to play", lands back on `.idle` within bounded
    /// time — see `InlineTrailerCardModel.expand`'s skip paths); the coordinator check is a
    /// belt-and-braces for the playback tail. Gated on `heroTrailerActive`, not FEAT-25's claim
    /// alone, so the hold also covers the hero-location focus window and the handback that follows
    /// it: a focus-driven attempt is playing on the very same backdrop, and the carousel paging
    /// underneath it would reset the model exactly as it would mid-carousel-resolve.
    private var heroTrailerHolding: Bool {
        guard heroTrailerActive, let hero = displayHero else { return false }
        if heroTrailerModel.phase != .idle { return true }
        return InlineTrailerCoordinator.shared.playingKey == TrailerResolutionCache.key(type: hero.type, id: hero.id)
    }

    #if DEBUG
    /// Last settle line from the pinned settle re-reveal, surfaced to the harness as
    /// `debug_pinned` (test47). One write per SETTLE — not per scroll frame — so the churn is the
    /// same order as `heroIndex`'s, and in release the sink below is nil and nothing is written at
    /// all.
    @State private var debugPinnedSettle = "-"
    #endif

    // MARK: - BUG-112 (Item A): the Up fallback

    /// The row that currently owns focus — the same key `pinnedRowSettleTracking(rowKey:)` uses.
    /// The fallback needs it twice: to find the row ABOVE the focused one, and to tell whether a
    /// hand-off landed.
    ///
    /// Review fix (F3): the SOLE writer is `handleRowFocusOwnership`, fed by each row's own
    /// `pinnedRowFocusOwnership` report (`PinnedRowUpFallback.swift`) — which fires straight off
    /// the row's `@FocusState` binding. Earlier this was claimed inside `reportRowFocus`/the
    /// collection-folder callback, gated on a non-nil hero preview; that went stale the moment
    /// focus landed on a row's "See All" tile or an unconfigured folder, both of which report a
    /// nil preview. `@FocusState` cannot disagree with itself the way a preview report could.
    @State private var focusedRowKeyState: String?
    /// beta.18 verdict (BUG-126): reads go through the input box (never `body`); writes hit the box
    /// and, unless `RowStepAB.handlerOnlyRowStateOffBody` is set, the `@State` mirror too so the
    /// legacy body re-evaluation per row hop is preserved for the A/B.
    private var focusedRowKey: String? {
        get { upInput.focusedRowKey }
        nonmutating set {
            upInput.focusedRowKey = newValue
            if !RowStepAB.isSet(RowStepAB.handlerOnlyRowStateOffBody, in: RowStepAB.mask) {
                focusedRowKeyState = newValue
            }
        }
    }
    /// `systemUptime` of the last time `focusedRowKey` changed to a different row. Feeds
    /// `HomeUpPressConsumption` so a press the engine already acted on does not start the ladder.
    @State private var lastRowFocusChangeAtState: TimeInterval?
    private var lastRowFocusChangeAt: TimeInterval? {
        get { upInput.lastRowFocusChangeAt }
        nonmutating set {
            upInput.lastRowFocusChangeAt = newValue
            if !RowStepAB.isSet(RowStepAB.handlerOnlyRowStateOffBody, in: RowStepAB.mask) {
                lastRowFocusChangeAtState = newValue
            }
        }
    }
    /// rc14 (BUG-112 residue): when the last Up INPUT (press via `handleRowsMove`, swipe via the
    /// catcher's `onAnySwipeUp`) arrived, consumed or not; when a row last released focus; and
    /// whether the rows ScrollView currently sits past its top. See `revealTopAfterUpIntoHero`.
    /// A reference box, not `@State` fields (review r1 P3): the swipe catcher sits on the WINDOW,
    /// so an Up swipe anywhere — Search, Settings, under the player — would otherwise write Home
    /// state and re-evaluate its body. None of these values are rendered.
    @State private var upInput = HomeRowInputBox()
    @State private var rowsScrolledPastTop = false
    /// The live focus request the rows observe (`PinnedRowUpFallback.swift`).
    @State private var rowFocusRequest = PinnedRowFocusRequest.none
    @State private var rowFocusRequestSeq = 0
    /// Stales every scheduled rung of an older fallback — the same discipline
    /// `SidebarOverlay.handOffFocusToContent` uses for its verified re-issues.
    @State private var upFallbackGeneration = 0
    /// Review fixes F1/F2: the row key the CURRENT attempt is trying to focus, or nil when no
    /// attempt is live. The sole reader/writer outside `endUpFallback` is `beginUpFallback`
    /// (sets it) and `handleRowFocusOwnership` (reads it to tell a landed claim from a
    /// diversion) — every other transition retires through `endUpFallback`, which always
    /// clears it back to nil.
    @State private var activeUpFallbackTarget: String?
    /// The row the live attempt started FROM, captured at `beginUpFallback` — the `landed`
    /// probe line reads it rather than `focusedRowKey`, which can be nil for a beat while the
    /// origin row has already released its claim and the target has not yet made its own.
    @State private var activeUpFallbackOrigin: String?
    /// rc13 — which INPUT started the live attempt: `press` (a directional button the focus engine
    /// did not consume) or `swipe` (a touch-surface flick it did not consume, `HomeUpSwipeCatcher`).
    ///
    /// Carried on the attempt rather than only on its first log line, and that is a deliberate
    /// change from this batch's own first draft. `debug_upfallback` holds the LAST line only; the
    /// rung-1 line is overwritten the moment the hand-off lands — 30–260 ms on Steven's hardware —
    /// so a token written there alone is unobservable to the harness and nearly unphotographable on
    /// the pane. Every line of one attempt carries it now, which costs a `key=value` token and
    /// makes "which input was this?" answerable wherever the reader happens to look.
    ///
    /// Sticky between attempts on purpose: every `logUpFallback` call that reads it belongs to a
    /// live attempt (`beginUpFallback` sets it before its first line; the cancel guards and the
    /// landed line only run while one is in flight), and resetting it in `endUpFallback` would
    /// clear it out from under the landed line, which is composed by the caller and passed IN.
    @State private var activeUpFallbackSource = "press"
    /// rc13 (BUG-114) — stales `handleHeroUp`'s delayed retry, the same discipline
    /// `upFallbackGeneration` applies to the ladder's rungs.
    ///
    /// Codex round 1: the retry was scheduled unconditionally 0.6 s out and only re-read
    /// `isScrolledDown`, so anything that happened in between — focus leaving the CTA for a row,
    /// a second unresolved Up, a tab switch, the Continue-Watching cover coming up — left it
    /// armed and it animated the shelf out from under whatever was there. Every `handleHeroUp`
    /// bumps this, and so does every change of `heroFocused` (in either direction: leaving the
    /// hero and coming back inside the window must not look like nothing happened); a retry that
    /// finds the counter moved is not the newest intent and stands down silently.
    @State private var heroUpGeneration = 0
    #if DEBUG
    /// Last fallback event, surfaced to the harness as `debug_upfallback`. One write per Up press
    /// the engine could not resolve, so the churn is far below `debug_pinned`'s.
    @State private var debugUpFallback = "-"
    #endif

    /// DEBUG-only sink handed to `PinnedRowSettleRevealModifier`. nil in release: the corrector
    /// itself is release code (the bug is a release bug), but its readout is harness-only.
    private var settleProbeSink: ((String) -> Void)? {
        #if DEBUG
        return { debugPinnedSettle = $0 }
        #else
        return nil
        #endif
    }

    #if DEBUG
    /// Short code for the hero trailer model's live phase, for the `debug_hero` probe's `hph=`
    /// field — the harness reads fixed-width-ish tokens, not Swift's synthesized descriptions
    /// (`playing(_:)` would otherwise splat a resolved URL key into the string).
    private var debugHeroTrailerPhase: String {
        switch heroTrailerModel.phase {
        case .idle: return "idle"
        case .dwelling: return "dwell"
        case .expandedStatic: return "exp"
        case .playing: return "play"
        }
    }
    #endif

    var body: some View {
        NavigationStack(path: $homePath) {
            ZStack(alignment: .top) {
                Theme.Palette.background.ignoresSafeArea()

                #if DEBUG
                // BUG-25 diagnostic (invisible, harness-readable): the env values Home renders with.
                // BUG-87 (beta.18): the resolved pinned geometry, APPENDED — the harness parses
                // `w>=260` and the existing tokens keep their exact spelling and order. `comp` is
                // the hero's yield, `topR`/`botR` the reaches the rows actually render with,
                // `fits` whether the focus engine's link frame is inside the rows viewport (the
                // whole point of the fix), and `slack` the width of the legal-rest set.
                Text("debug_env cr=\(Int(posterStyle.cornerRadius)) w=\(Int(posterStyle.width)) depth=\(debugCardDepth.enabled ? 1 : 0) edge=\(debugCardDepth.edgeStrength) comp=\(Int(pinnedPlan.compression.rounded())) topR=\(Int(pinnedPlan.topReach.rounded())) botR=\(Int(pinnedPlan.bottomReach.rounded())) fits=\(pinnedPlan.fits ? 1 : 0) slack=\(Int(pinnedPlan.restRange.rounded())) railW=\(Int(CardDepthStyle.railWidth(edgeStrength: debugCardDepth.edgeStrength))) railA=\(Int((CardDepthStyle.railTopAlpha(edge: min(max(Double(debugCardDepth.edgeStrength), 0), 100) / 100) * 100).rounded()))")
                    .font(.system(size: 8))
                    .opacity(0.011)
                    .accessibilityIdentifier("debug_env")
                // BUG-23 diagnostic (invisible, harness-readable): the hero carousel's live
                // selection + focus state, so the UITest can watch exactly what a left press
                // does to the index (one-press page? two? snap-back?).
                // Append-only: existing fields keep their exact spelling (the harness asserts on
                // substrings like `pin=1`, `src=c`, `fitem=`). `tloc` is the trailer LOCATION the
                // rows are actually rendering under, `hph` the hero trailer model's live phase.
                //
                // 2026-09-05: `pitem`/`pbd`/`plg` are the PRESENTED hero — what `HeroArtResolver`
                // actually committed (`fitem` above is only the TARGET focus asked for). They exist
                // because the `present`-line oracle they replace could not survive its own walk:
                // `HomeHeroProbe`'s buffer keeps a 32-line rolling tail, and reaching a collection
                // row on a 35-row Home costs ~40 Down presses plus `openTab`'s ~40-press climb back
                // to the tab bar — ~150 probe lines between the folder's own `present` and the
                // About-pane read, so the evidence was always evicted before test31 Leg C could
                // read it (proved 2026-09-05: the console `[HomeHero]` stream carried a healthy
                // `present item=nuvio.folder:… backdrop=fetched logo=fetched waited=98 same=0` for
                // the very focus the leg then failed to find a line for). Read live off the
                // resolver, this is the same fact with no buffer in between.
                //
                // rc13 (BUG-114): `sd=<0|1>` (append-only, at the END) is `isScrolledDown` — the
                // rows shelf's own "not at the top" hysteresis. test66 needs it to tell the two
                // halves of the fix apart: `sd=1` with the hero focused is the wedge (deep shelf,
                // bar stranded), `sd=0` after an Up is the shelf having actually moved back. No
                // reader is positional — every one of them matches by key or by `contains("foc=1")`
                // — so appending here breaks nothing.
                //
                // FEAT-42: `plgs=<addon|tmdb|metahub|none>` (append-only, right after `plg=`) is
                // WHERE the presented logo bitmap came from — `heroResolver.presentedLogoSource`,
                // set in the same commit transaction as `presented` (see that property's own doc
                // comment), so it can never disagree with what `plg=` just reported.
                Text("debug_hero idx=\(heroIndex) foc=\(heroFocused ? 1 : 0) n=\(heroItems.count) src=\(focusModel.focusedItem == nil ? "c" : "f") fitem=\(focusModel.focusedItem?.id ?? "-") pin=\(heroNuvioStyle ? 1 : 0) mode=\(heroCarouselActive ? "carousel" : (focusHeroActive ? "focus" : "none")) tloc=\(heroFocusTrailerMode ? "h" : "p") hph=\(debugHeroTrailerPhase) pitem=\(heroResolver.presented?.identity ?? "-") pbd=\(heroResolver.presented?.backdrop != nil ? 1 : 0) plg=\(heroResolver.presented?.logo != nil ? 1 : 0) plgs=\(heroResolver.presentedLogoSource.rawValue) sd=\(isScrolledDown ? 1 : 0)")
                    .font(.system(size: 8))
                    .opacity(0.011)
                    .accessibilityIdentifier("debug_hero")
                // 2026-08-30 settle re-reveal (invisible, harness-readable): the last settled
                // pinned rest, as the corrector itself measured it — `margin`/`net` are the exact
                // quantities the `[HomeScrollProbe] title` line reports, so test47 asserts on the
                // app's own geometry rather than on pixels. A pixel oracle cannot do this job
                // here: the title's AX frame does NOT include its `visualEffect` slide (that is
                // the whole point of using `visualEffect`), and its rendered luma is not separable
                // from bright poster art.
                Text("debug_pinned \(debugPinnedSettle)")
                    .font(.system(size: 8))
                    .opacity(0.011)
                    .accessibilityIdentifier("debug_pinned")
                // BUG-112 (invisible, harness-readable): the last Up-fallback event. Its own label
                // rather than more fields on `debug_pinned` — the settle line is an append-only
                // contract parsed by test47/test48/test58/test61/test63, and a fallback is not a
                // settle. Append-only in its own right: `row= prev= action=` keep their spelling.
                Text("debug_upfallback \(debugUpFallback)")
                    .font(.system(size: 8))
                    .opacity(0.011)
                    .accessibilityIdentifier("debug_upfallback")
                // FEAT-30 (invisible, harness-readable): which navigation chrome this build is
                // rendering under, and the top compensation it applied. `comp` is what a device
                // bisect of `debug.sidebarTopCompensation` reads back to confirm the launch
                // argument actually landed — the sidebar's own state lives in the overlay's
                // separate `sidebar_state` probe, which only exists while the panel is shown.
                Text("debug_sidebar mode=\(SidebarChrome.isEnabled() ? 1 : 0) comp=\(Int(SidebarChrome.topCompensation))")
                    .font(.system(size: 8))
                    .opacity(0.011)
                    .accessibilityIdentifier("debug_sidebar")
                // beta.19-rc1 verdict (M3/R2 BUG-133, B2 BUG-131): the trailer event and listener
                // lifecycle readouts for the UI legs (test85/85B/86/91). LEAF views, each observing
                // its own DEBUG sink, so a trailer event re-renders one label and never this body
                // (critique #11). `debug_heroText` lives in `HeroTextLayer`.
                TrailerMorphDebugLabel()
                TrailerListenerDebugLabel()
                #endif

                // Full-bleed hero backdrop runs to every edge (and under the floating glass tab
                // bar); the rows scroll over it, Detail-style.
                // Default: always show the artwork, so it's visible the moment Home appears
                // (see heroPosterFocusOnly doc comment above). With the Settings toggle on,
                // fall back to the original behavior — only show it while the hero itself is
                // highlighted, fading to the flat dark background once focus moves down into
                // Continue Watching / the catalogs.
                // Nuvio-style additionally pins the hero FOREGROUND (see `pinnedHeroHeader`, the
                // fixed top half of a VStack split), so backdrop and info panel stay together as
                // one persistent hero region no matter how far down the rows are scrolled — this
                // layer is unchanged either way, it was already outside the scroll.
                // Wave H: the PRESENTED hero, not the target — this layer paints only once the
                // resolver has both bitmaps (or gave up on one), so the backdrop can no longer lag
                // the text it belongs to (BUG-86 phenomenon C).
                // Home Stage & Strip (P1 E4): Classic only — the stage draws its own masked art
                // over the ambient wash (S5).
                if !isStageLayout, let presentation = heroResolver.presented {
                    Group {
                        // Nuvio-style: right-anchored artwork whose left edge fades to the
                        // flat background — the info panel never sits over the art.
                        // FEAT-15: the focus panel always uses that treatment (see heroNuvioStyle).
                        HomeHeroBackdrop(
                            presentation: presentation,
                            nuvioStyle: heroNuvioStyle || focusHeroActive,
                            autoplaysTrailer: heroTrailerActive,
                            trailerModel: heroTrailerModel
                        )
                        HomeHeroScrim()
                    }
                    // UX-7: a row-focused poster (focusModel.focusedItem != nil) always shows
                    // its artwork — heroPosterFocusOnly only gates the carousel's own idle fade.
                    // FEAT-15: and only the CAROUSEL's. In focus-panel mode the toggle is inert —
                    // hiding the artwork "while browsing" there would hide it always, since
                    // browsing is the only thing that mode ever shows (see heroPosterFocusOnly).
                    // Wave H: the value is `heroArtOpacity`, animated from `.onChange` below —
                    // see that state's doc for why an `.animation(_:value:)` modifier here was the
                    // resizing-mosaic bug.
                    .opacity(heroArtOpacity)
                    // Purely decorative background art — the same title/synopsis is exposed by
                    // the focusable HomeHeroForeground button in front of it, so VoiceOver
                    // shouldn't stop on this layer too.
                    .accessibilityHidden(true)
                }

                // Pinned Nuvio hero (UX-7 extension): the hero foreground becomes the FIXED
                // top of a VStack and the rows ScrollView takes whatever height is left, so the
                // scroll view's bounds are honest — they contain the rows and nothing else.
                //
                // Why not `.safeAreaInset(edge: .top)` (the first attempt, reverted after the sim
                // pass): an inset changes LAYOUT but not the focus engine's scroll-to-reveal
                // target, so at deep scroll tvOS slid rows up THROUGH the inset region and rested
                // the focused card behind the hero's text. A real VStack split shrinks the
                // ScrollView's frame, which the focus engine does respect.
                //
                // BUG-19: the ScrollView changes container ONLY when the Settings toggle flips —
                // never per scroll frame. The `heroItems` empty→loaded check is inside the VStack
                // around the HEADER alone, so the rows' identity is untouched at that boundary.
                //
                // `pinned` is passed as `heroHeaderVisible`, NOT the bare setting: before the
                // fan-out loads (or before rows exist in FEAT-15's focus-panel mode) no header is
                // mounted, and the rows must keep the CLASSIC geometry — full 60pt overscan top
                // inset and lift-friendly disabled clipping — instead of the compact insets that
                // only make sense under a mounted header. This is a value change (paddings,
                // clip flag, the in-scroll hero condition), not a structural one, so flipping at
                // the load boundary re-identifies nothing.
                //
                // FEAT-15: the container test is `heroContainerPinned` (Nuvio-style OR Show Hero
                // off) — still purely settings-driven. Show Hero off now pins the focus panel
                // above the rows for the same reason Nuvio mode pins the carousel: a description
                // panel that scrolls away with the rows cannot follow focus down the page, which
                // is the whole request.
                // ScrollViewReader + the Menu handler sit ABOVE the mode split: in pinned mode
                // the hero CTA is a SIBLING of the rows ScrollView, so a handler attached to the
                // ScrollView alone would not cover it — a Menu press with focus on the CTA while
                // `isScrolledDown` hadn't cleared yet (e.g. a reflexive double-Menu during the
                // jump-to-top animation) would bubble to the tab root and suspend the app. One
                // handler on the common ancestor covers rows and CTA in both modes; scrollTo
                // resolves the "home_top" anchor through the descendant ScrollView.
                //
                // Home Stage & Strip (P1 E5): the Stage layout replaces this whole region (and the
                // BUG-27 `.onExitCommand` inside it) with `StageStripHome`; the Classic branch below
                // is unchanged, kept at its original indentation so its diff stays empty.
                if isStageLayout {
                    StageStripHome(model: model,
                                   actions: StageHomeActions(resume: { resume = $0 },
                                                             push: { homePath.append($0) }),
                                   cover: StageCover(pushed: !homePath.isEmpty, resume: resume != nil),
                                   isScrolledDown: $isScrolledDown)
                } else {
                ScrollViewReader { scrollProxy in
                    Group {
                        if heroContainerPinned {
                            VStack(spacing: 0) {
                                if heroHeaderVisible {
                                    pinnedHeroHeader(proxy: scrollProxy)
                                }
                                rowsScroll(pinned: heroHeaderVisible, settleReveal: true, proxy: scrollProxy)
                            }
                            // BUG-89 (beta.18): a Poster Size switch (Medium → Large) changes the
                            // hero's height, both card reaches and the rows' bottom inset AT ONCE.
                            // Attached HERE, on the common ancestor of the hero and the rows, so
                            // all of it moves inside ONE transaction and reads as the layout
                            // resizing. Before this it was three unanimated jumps followed, a beat
                            // later, by the settle corrector dragging the second-to-last row into
                            // place — the "regresses until you restart the app" half of the report.
                            //
                            // `.animation(_, value:)` rather than a `withAnimation` around the
                            // change: the plan is a COMPUTED value derived from the synced
                            // `posterStyle`, so there is no single mutation site to wrap — the new
                            // value simply arrives with the repository's publish, from Settings on
                            // this device or from a sync push on another. Keying it on the whole
                            // `Plan` (Equatable) means a regime that resolves to identical geometry
                            // animates nothing at all.
                            .animation(.easeInOut(duration: 0.28), value: pinnedPlan)
                            // The corrector has to be told, in the same breath, that every margin
                            // it has measured for this regime is stale and that the rows want one
                            // fresh reveal — otherwise its first post-switch sample reads the old
                            // geometry as a fight and corrects against it. `fits` tells it whether
                            // it is even in play: when the plan cannot make the frame fit, the belt
                            // owns the residue exactly as it did before this fix.
                            // Codex beta.18 r1 (P1): `initial: true` registers the launch regime on
                            // appearance. Without it the first Medium → Large switch was ALSO
                            // `noteRegimeChange`'s first call, whose no-previous-key guard only records
                            // and never resets the brakes — the exact first-switch regression this fixes.
                            .onChange(of: pinnedPlan.regimeKey, initial: true) { _, key in
                                PinnedRowSettle.noteRegimeChange(key: key, fits: pinnedPlan.fits)
                                // BUG-89 (rc2): the ONE settle-probe line that has to be emitted
                                // from here rather than from `noteRegimeChange` — the corrector is
                                // told only `key` and `fits`, and the numbers a photographed pane
                                // needs to read a deep last-row park (the viewport the plan
                                // produced, the link frame it has to fit, the rest range that
                                // bounds a correction, and the bottom inset this file sizes from
                                // them) all live on the plan, which only `HomeView` holds.
                                // Diagnostics only — reads computed properties, mutates nothing.
                                if PinnedRowSettleProbe.enabled {
                                    PinnedRowSettleProbe.log(
                                        "plan \(key) vh=\(Int(pinnedPlan.viewport.rounded()))"
                                            + " link=\(Int(pinnedPlan.linkFrame.rounded()))"
                                            + " rest=\(Int(pinnedPlan.restRange.rounded()))"
                                            + " comp=\(Int(pinnedPlan.compression.rounded()))"
                                            + " topR=\(Int(pinnedPlan.topReach.rounded()))"
                                            + " botR=\(Int(pinnedPlan.bottomReach.rounded()))"
                                            + " fits=\(pinnedPlan.fits ? 1 : 0)"
                                            + " botInset=\(Int(pinnedRowsBottomInset.rounded()))"
                                            + " lastRowH=\(Int((pinnedLastRowHeight ?? 0).rounded()))")
                                }
                            }
                            // Codex rc5 r1 (P2): the `plan` line above fires on a REGIME change, but the
                            // last row and the inset sized from it arrive with the rows, later — on a
                            // hero-off cold launch the photographed line would read `botInset=60
                            // lastRowH=0` forever. This companion line follows the last row's own
                            // height (nil → measured, and a replaced last row), deduplicated by
                            // `onChange`'s equality. Diagnostics only.
                            .onChange(of: pinnedLastRowHeight) { _, height in
                                if PinnedRowSettleProbe.enabled {
                                    PinnedRowSettleProbe.log(
                                        "lastRow \(pinnedLastRowId ?? "none")"
                                            + " lastRowH=\(Int((height ?? 0).rounded()))"
                                            + " botInset=\(Int(pinnedRowsBottomInset.rounded()))"
                                            + " rest=\(Int(pinnedPlan.restRange.rounded()))")
                                }
                            }
                        } else {
                            rowsScroll(pinned: false, settleReveal: false, proxy: scrollProxy)
                        }
                    }
                    // BUG-27: from down the page, Menu jumps back to the top and hands focus to
                    // the hero CTA — one press instead of dozens of Ups, and from there a single
                    // Up reaches the (now visible again) tab bar. The handler is nil at the top
                    // so Menu keeps its default root behavior there; it only attaches when the
                    // hero exists, because jumping without a focus anchor would let the focus
                    // engine drag the scroll right back down to the still-focused row.
                    //
                    // FEAT-15 leaves this gate on `heroItems` deliberately, so the focus-panel
                    // mode keeps EXACTLY the Menu behavior Show Hero off has always had (handler
                    // detached — Menu is the tab root's). The panel has no CTA on purpose, so
                    // there is no focus anchor at the top to hand off to, and the comment block
                    // below records that scrolling to the top WITHOUT taking focus first is the
                    // documented failure mode. Giving hero-off users Menu-to-top needs a
                    // device-verified anchor plan, not a flag change here.
                    //
                    // FEAT-30 adds the OTHER branch and touches nothing in this one: the
                    // scrolled-down BUG-27 handler above is byte-identical in both chrome modes,
                    // and the `else` — which is `nil` today, i.e. "Menu keeps its default root
                    // behaviour" — becomes the sidebar reveal in sidebar mode only. Ordering is
                    // deliberate: from down the page Menu still means "back to the top", the way
                    // it does now and the way every tvOS app does it; the sidebar is what Menu
                    // means once you are already at the top, where the handler used to detach.
                    // In tabs mode `sidebarMenuRevealHandler` is `nil`, so this site resolves
                    // exactly as it always has.
                    .onExitCommand(perform: (isScrolledDown && !heroItems.isEmpty) ? {
                        if heroNuvioStyle {
                            // Pinned hero: the CTA lives above the ScrollView in the VStack, so
                            // it is ALWAYS mounted — there is no "wait for the lazy top region
                            // to build" window to lose the handoff in. Take focus FIRST and
                            // synchronously: focus leaves the deep row on this very frame, so
                            // nothing down the page is left for the focus engine to drag the
                            // scroll back toward while the proxy animates (the classic branch's
                            // whole failure mode).
                            heroFocused = true
                            withAnimation(.easeInOut(duration: 0.45)) {
                                scrollProxy.scrollTo("home_top", anchor: .top)
                            }
                            // Retries are gated on `isScrolledDown`, NOT on `!heroFocused` the
                            // way the classic branch below is: focus lands on the statement
                            // above, so a `!heroFocused` guard would disarm every retry before
                            // it ran. The tab bar's scroll hysteresis is the signal that
                            // actually says whether the scroll landed at the top.
                            for delay in [0.6, 1.3] {
                                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                    guard isScrolledDown else { return }
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        scrollProxy.scrollTo("home_top", anchor: .top)
                                    }
                                    if !heroFocused { heroFocused = true }
                                }
                            }
                        } else {
                            withAnimation(.easeInOut(duration: 0.45)) {
                                scrollProxy.scrollTo("home_top", anchor: .top)
                            }
                            // Focus can only land on the hero CTA once the lazy top region is
                            // built — and a one-shot handoff that fires too early is silently
                            // dropped, leaving focus on the deep row so the focus engine drags
                            // the scroll straight back down ("Menu only scrolls up two
                            // categories", device pass 2026-08-02). Retry: re-issue the scroll
                            // and the focus grab until it sticks.
                            for (attempt, delay) in [0.55, 1.2, 2.0].enumerated() {
                                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                    guard !heroFocused else { return }
                                    if attempt > 0 {
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            scrollProxy.scrollTo("home_top", anchor: .top)
                                        }
                                    }
                                    heroFocused = true
                                }
                            }
                        }
                    } : sidebarMenuRevealHandler)
                    // FEAT-30 (2026-09-05) briefly added an `.onMoveCommand` here too, summoning
                    // the sidebar on an Up press the focus engine could not place — see
                    // `SidebarOverlay.swift`'s `SidebarMenuRevealModifier` doc comment for the full
                    // arc (device spike → settle-window gate → BUG-98 gate removal → the 2026-09-09
                    // rc7 tester verdict that reveal-on-Up is unusable at all). Christian's decision
                    // was to drop the Up-reveal path everywhere, so that modifier (and the
                    // `sidebarUpRevealHandler` it read) is gone; Menu (above) is the only reveal.
                    // Tab-bar clip after a D-pad walk back to the top: STILL OPEN (see tracker).
                    // Rounds 5–6 tried completing the scroll to the true top when focus
                    // re-entered the hero; both caused worse regressions on device (wedged Down
                    // navigation, interrupted Menu-to-top) and were reverted. Do not reintroduce
                    // a hero-focus-triggered scroll here without a device-verified plan — the
                    // harness cannot see the system bar's hardware-only mid-expansion state.
                    // (The pinned-hero branch above is outside this banned class: it is
                    // Menu-triggered, exactly like the classic branch it sits next to, not
                    // triggered by the hero gaining focus.)
                    //
                    // rc13 (BUG-114, GitHub issue #3) adds a THIRD member of that exempt family,
                    // and states the boundary explicitly rather than leaving it to the
                    // parenthetical above: `handleHeroUp` scrolls the shelf to the top on an
                    // unresolved Up PRESS or SWIPE from the CTA — an input the engine gave up on,
                    // the same class as the Menu handler here and as the ladder's HERO rung — and
                    // never on a focus change. The ban is on `.onChange(of: heroFocused)` scrolls
                    // specifically, and that site (below) is untouched. The reporter's own patch
                    // (scroll when the hero GAINS focus) is exactly the banned shape and was not
                    // taken.
                    //
                    // Round 7 (2026-08-05) deliberately does NOT touch this site: instead of
                    // correcting the scroll after the fact, it removes the reason the scroll
                    // stops short — the classic hero now carries its top padding as a
                    // transparent frame reach, so the topmost revealable frame IS the content
                    // top (see `heroCarousel(compact:topReach:)` and `rowsInsets`). That is a
                    // geometry change on the way UP, invisible to Menu-to-top, which already
                    // scrolls to "home_top" explicitly and is unaffected either way. Unverified
                    // until a device walk says the probe's `residual` dropped from 67 toward 0.
                }
                }  // Home Stage & Strip (P1 E5): closes the Classic `else`.
            }
            .onReceive(heroTimer) { _ in
                // Reduce Motion: pause auto-advance entirely rather than rebasing the TabView
                // selection without animation — that desyncs tvOS's paged TabView (see the
                // comment below), so the only safe accommodation is to stop advancing and let
                // the carousel sit still until the user pages manually (still animated).
                guard !reduceMotion else { return }
                // FEAT-15: no carousel, nothing to advance. Implied by the `heroItems.count > 1`
                // test below (Show Hero off publishes an empty hero list), but stated explicitly
                // because "the auto-advance timer never runs in focus-panel mode" is part of the
                // feature's contract, not an accident of how the shared repo publishes.
                guard heroCarouselActive else { return }
                // UX-7: a row-focused poster owns the hero right now — the carousel must not
                // advance underneath it.
                guard heroItems.count > 1, !heroFocused, focusModel.focusedItem == nil,
                      Date().timeIntervalSince(lastHeroChange) >= 7 else { return }
                // FEAT-25: an ACTIVE hero trailer attempt owns the page — dwell, resolution, and
                // playback alike (Codex beta.14 r2). Holding only the playing phase was not
                // enough: a cold-cache resolution (1s dwell + metadata + extraction) can outlast
                // this tick, and advancing mid-resolve resets the model, discards the in-flight
                // result, and re-resolves the same title every time it cycles back around. Every
                // attempt path is bounded (meta 5s, extraction 15s, failure → `.idle`), and
                // playback is single-pass (`loops: false`), so the page always resumes.
                guard !heroTrailerHolding else { return }
                // Wave H: a hero commit is pending — the resolver is fetching this page's artwork
                // right now. Paging underneath it discards that resolve (the next `present`
                // cancels it) and starts the following page cold, so the carousel would advance
                // through pages it never actually painted. Bounded by the resolver's own deadline
                // (400ms, 1.5s for folders), so the page always resumes on a later tick.
                guard heroResolver.isIdle else { return }
                // Plain animated selection write, including the wrap back to page 0 — programmatic
                // non-animated selection rebasing desyncs tvOS's paged TabView (the visible page
                // freezes while the binding keeps moving), so never get clever here.
                withAnimation(.easeInOut(duration: 0.6)) {
                    heroIndex = (min(heroIndex, heroItems.count - 1) + 1) % heroItems.count
                }
            }
            .onChange(of: heroIndex) { _, _ in
                lastHeroChange = Date()
            }
            // UX-7: focusing the CTA is the carousel reclaiming the hero — drop any row-focused
            // poster immediately (no grace period; this is a deliberate hand-back, not a
            // between-cards focus hop).
            .onChange(of: heroFocused) { _, focused in
                if focused { focusModel.cancelAndRevert() }
                // rc13 (BUG-114): stale any pending `handleHeroUp` retry. Focus moving off the CTA
                // (or back onto it) means the scroll that retry was going to finish is no longer
                // the newest thing the user asked for. This is a counter bump only — emphatically
                // NOT a scroll, so the standing ban on hero-focus-triggered scrolls
                // (`.onExitCommand`'s comment block above) is untouched.
                heroUpGeneration &+= 1
            }
            .onChange(of: heroItems.count) { _, newCount in
                if heroIndex >= newCount { heroIndex = 0 }
                if newCount > 0 { heroSurfaceSeen = true }
            }
            // FEAT-25 (Codex beta.14 r5): keep the mirrored system autoplay gate current — see
            // `systemVideoAutoplayEnabled`. The state write re-renders, recomputing
            // `heroTrailerAutoplayActive`, and the backdrop's `.onChange(of: autoplaysTrailer)`
            // funnel does the actual start/stop.
            .onReceive(NotificationCenter.default.publisher(
                for: UIAccessibility.videoAutoplayStatusDidChangeNotification)) { _ in
                systemVideoAutoplayEnabled = UIAccessibility.isVideoAutoplayEnabled
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    systemVideoAutoplayEnabled = UIAccessibility.isVideoAutoplayEnabled
                }
            }
            // Wave H: the hero TARGET changed identity — hand it to the resolver, which decides
            // when (and as one transaction, with what artwork) it may actually be painted. Keyed on
            // the id alone, exactly like the renderers used to be: a payload change at the same
            // identity is a separate, non-repainting path (see `heroPayloadSignature` below).
            .onChange(of: displayHero?.id) { _, _ in
                presentHero()
            }
            // Wave H: the target's own fields changed without its identity changing — a TMDB
            // gap-fill landing on a focused row poster (`HomeHeroFocusModel.enrichIfNeeded`), or a
            // shared-publish payload edit. The resolver adopts the text and keeps the committed
            // artwork; without this trigger a late synopsis would never reach the panel at all.
            .onChange(of: heroPayloadSignature) { _, _ in
                presentHero()
            }
            // beta.19-rc1 verdict (I1, BUG-134): Nuvio-style flipped (or the focus panel came or
            // went) under a hero that stays: the resolver re-checks its sharpen against the new form.
            .onChange(of: heroSharpenForm) { _, form in
                heroResolver.setSharpenForm(form)
            }
            // Wave H: the artwork layer's fade (see `heroArtOpacity`). Opacity only — never the
            // implicit animation on the Group that used to interpolate the artwork's frame too.
            .onChange(of: heroArtVisible) { _, visible in
                withAnimation(.easeInOut(duration: 0.4)) { heroArtOpacity = visible ? 1 : 0 }
            }
            .onChange(of: heroItems.map(\.id)) { _, _ in
                prefetchHeroArt()
            }
            // FEAT-15: the focus panel has no hero pages to warm, but it DOES paint the resting
            // item the moment rows land — warm that one title's backdrop/logo so Home doesn't
            // open on a placeholder. Inert in carousel mode: `heroRestingItem` is nil there, so
            // this fires once (nil → nil) and never again.
            .onChange(of: heroRestingItem?.id) { _, _ in
                prefetchHeroArt()
            }
            .navigationDestination(for: TitleRoute.self) { route in
                DetailView(preview: route.preview)
            }
            .navigationDestination(for: CatalogRoute.self) { route in
                CatalogGridView(route: route)
            }
            .navigationDestination(for: PersonRoute.self) { route in
                PersonDetailView(personId: route.id, personName: route.name)
            }
            .navigationDestination(for: EntityRoute.self) { route in
                EntityBrowseView(route: route)
            }
            .navigationDestination(for: FolderRoute.self) { route in
                FolderDetailView(route: route)
            }
            .fullScreenCover(item: $resume) { target in
                StreamPickerView(
                    type: target.entry.parentMetaType,
                    videoId: target.entry.videoId,
                    title: target.entry.title,
                    parentMetaId: target.entry.parentMetaId,
                    season: target.entry.seasonNumber?.value,
                    episode: target.entry.episodeNumber?.value,
                    // Info header: series poster + the entry's episode still / pause synopsis when
                    // present (blank values count as missing).
                    poster: target.entry.poster,
                    episodeStill: { let still: String? = target.entry.episodeThumbnail; return (still ?? "").isEmpty ? nil : still }(),
                    synopsis: { let d: String? = target.entry.pauseDescription; return (d ?? "").isEmpty ? nil : d }(),
                    forceManual: target.forceManual,
                    startFromBeginning: target.startFromBeginning
                )
            }
        }
        .onAppear {
            #if DEBUG
            LaunchTrace.mark("home_appear")  // BUG-26: profile gate passed, Home mounting
            #endif
            // BUG-109: seed the pinned-row corrector's covered flag for the case where Home is
            // re-entered with a non-empty `homePath` (e.g. a theme `.id()` swap while a folder page
            // is pushed) — the `.onChange(of: homePath.count)` below only sees CHANGES from here on.
            PinnedRowSettle.setCovered(!homePath.isEmpty)
            // beta.19-rc1 verdict (M5, BUG-138): the hero focus model's freeze, seeded the same way.
            syncHeroFocusCover()
            // beta.19-rc1 verdict (M3, BUG-133): the hero trailer's dwell waits for the rows to rest.
            // Pinned Home reads the settle corrector (plus the rows' motion clock); classic Home has
            // no corrector, only the clock the rows ScrollView stamps (`rowsMotionStamp` below).
            heroTrailerModel.restSource = heroContainerPinned ? .pinnedHome : .motionClock
            // beta.19-rc1 verdict (review r1, A P2): the hero's post-commit sharpen waits on the same
            // rest signal before it fetches and before it adopts (a plain stored property, no
            // observation).
            heroResolver.restSource = heroContainerPinned ? .pinnedHome : .motionClock
            // H-1B-ii: retain, don't start. During a theme `.id()` swap SwiftUI inserts the
            // incoming subtree BEFORE removing the outgoing one, so this runs while the previous
            // HomeView still holds the model — the count goes 1 → 2 → 1 and the pipeline never
            // stops, restarts, or republishes.
            model.acquire()
            if upcomingRowEnabled { model.startUpcoming() }
            heroSettings.start()
            prefetchHeroArt()
            // Wave H: the repository cache can already have published hero items before this view
            // appeared, in which case no `.onChange` will ever fire for them — seed the resolver
            // from the current target here, exactly as the `heroSurfaceSeen` latch below seeds
            // itself for the same reason. Also sets the artwork layer's opacity without animating
            // it (a fade-in from 0 on the very first frame is not the same thing as the toggle's
            // browse-time fade).
            presentHero()
            heroArtOpacity = heroArtVisible ? 1 : 0
            // UX-7: when a row-focused poster reverts (grace period elapsed, or the CTA
            // reclaimed the hero), re-stamp the carousel's "last change" clock — otherwise the
            // auto-advance timer's next tick would immediately yank the page the instant focus
            // moves away, before the user even sees the carousel resume.
            focusModel.onRevert = { lastHeroChange = Date() }
            // BUG-55 class: hero-location suppression can't ride `InlineTrailerGateProbe` (its
            // global dedupe would flip-flop between Home and Search — see
            // `CatalogRowView.inlineTrailersActive`), so Home states its own mode here and on
            // change: once at mount, once per actual flip, never per render. Logged BEFORE the
            // latch's initial write below — the pre-latch value is the truth at mount, and if
            // the write flips the mode, `.onChange` records that flip as its own line (logging
            // after would double-report the same state).
            NSLog("[TrailerPipeline] trailerLocation heroMode=%@", heroFocusTrailerMode ? "YES" : "NO")
            // The latch's initial read: heroItems can already be populated at mount (repository
            // cache published before this view appeared), and `.onChange` only sees changes.
            if !heroItems.isEmpty { heroSurfaceSeen = true }
        }
        // BUG-109: tell the pinned-row corrector when Home is covered by a pushed screen (folder
        // page, Detail, See All, …) so it never applies a `position.scrollTo(y:)` correction against
        // a scroll view the user cannot see — see `PinnedRowSettle.hostCovered`. `homePath.count`
        // going 0 -> nonzero is a push; back to 0 is every pop landing on Home's root, at which point
        // `setCovered(false)` re-arms a fresh settle judged against the focus the pop just restored.
        .onChange(of: homePath.count) { _, count in
            PinnedRowSettle.setCovered(count > 0)
            syncHeroFocusCover()
        }
        // beta.19-rc1 verdict (M5, BUG-138): the other two covers the hero focus freeze honours —
        // the Continue Watching stream-picker cover and the shell (a tab switch, a cross-stack
        // cover). `@Published` emits on willSet, so the shell path passes the payload, not the
        // property (the `HomeHeroBackdrop` rule).
        .onChange(of: resume != nil) { _, _ in
            syncHeroFocusCover()
        }
        .onReceive(tabBarVisibility.$homeSurfaceCovered) { covered in
            syncHeroFocusCover(shellCovered: covered)
        }
        .onChange(of: heroFocusTrailerMode) { _, mode in
            NSLog("[TrailerPipeline] trailerLocation heroMode=%@", mode ? "YES" : "NO")
        }
        // beta.19-rc1 verdict (M3, BUG-133): follows the container (see `.onAppear`).
        .onChange(of: heroContainerPinned) { _, pinnedContainer in
            heroTrailerModel.restSource = pinnedContainer ? .pinnedHome : .motionClock
            // beta.19-rc1 verdict (review r1, A P2): the sharpen's rest signal follows too.
            heroResolver.restSource = pinnedContainer ? .pinnedHome : .motionClock
        }
        .onDisappear {
            // H-1B-ii: balanced against the `acquire()` above. This fires effectively only on shell
            // teardown (neither a Detail push nor a tab switch fires `onDisappear` on Home's root —
            // see `HomeHeroBackdrop`) and, transiently, as the outgoing half of a theme swap, where
            // the incoming view has already retained the model so the pipeline stays up. Profile
            // exit / sign-out is NOT handled here any more: `ContentView` hard-stops the model
            // there, because it now outlives this view.
            model.release()
            heroSettings.stop()
        }
        .onChange(of: upcomingRowEnabled) { _, enabled in
            if enabled { model.startUpcoming() } else { model.stopUpcoming() }
        }
    }

    /// The scrolling rows region — the SAME builder for both hero layouts, so row content is
    /// never duplicated. `pinned` (Nuvio-style) flips exactly three things and nothing else:
    /// the in-scroll hero branch (classic only), scroll clipping, and the content insets.
    ///
    /// `settleReveal` arms the pinned settle re-reveal (2026-08-30) on this ScrollView. It is a
    /// per-call-site CONSTANT, deliberately not `pinned`: `pinned` is the header's LOAD boundary
    /// and flips empty→loaded mid-session, and gating a modifier on it would re-identify the whole
    /// rows subtree at that boundary (the one thing this function's comments have protected since
    /// device round 4). The pinned CONTAINER, which is what this flag follows, only changes with
    /// the Settings toggle — the same boundary that already swaps containers in `body`. Inside the
    /// pinned container before the header loads, rows carry `rowCardTopReach == 0`, so there is no
    /// overlaid title to protect and the armed modifier simply never receives a measurement.
    ///
    /// Clipping: classic keeps `.scrollClipDisabled()` so focused cards may lift past the scroll
    /// bounds. Pinned deliberately keeps DEFAULT clipping — that hard edge just under the pinned
    /// hero is what hides rows scrolled past the viewport top (it replaces the fade mask the sim
    /// pass falsified). The focus lift stays inside the clip because the content insets below
    /// keep every card away from the viewport edges.
    @ViewBuilder
    private func rowsScroll(pinned: Bool, settleReveal: Bool, proxy: ScrollViewProxy) -> some View {
        ScrollView(.vertical) {
            // Lazy so row construction (and each row's poster loads) is deferred to
            // scroll position — an eager VStack builds every catalog row up front,
            // which on catalog-heavy accounts stalls the main thread past the
            // watchdog and bursts artwork decodes past jetsam (BUG-11).
            //
            // Spacing: pinned rows are SELF-CONTAINED — each row's shelf carries the
            // `rowCardTopReach` band (title overlaid inside it) and bottom reach within its
            // own frame, so no external gap is needed and every focusable frame stays inside
            // its row's focus section (out-of-bounds frames froze the focus engine — device
            // rounds 5–7, sim-reproduced). Classic keeps the plain 48pt sectionGap.
            LazyVStack(alignment: .leading,
                       spacing: pinned ? 0 : Theme.Spacing.sectionGap) {
                if !heroItems.isEmpty && !pinned {
                    // Classic only: the hero scrolls away with the rows, its info panel
                    // sitting on the lower third of the backdrop, Detail-style.
                    // Pinned (Nuvio-style) doesn't render a hero here at all — it sits
                    // ABOVE this ScrollView as the fixed top of the VStack split (see
                    // `pinnedHeroHeader`), which owns its own compacted paddings.
                    //
                    // BUG-30 reframe (2026-08-05, classic-only): the hero's `.padding(.top,)`
                    // and the LazyVStack's 60pt top inset used to be PADDING — layout that sits
                    // outside every frame the focus engine can reveal, so the topmost thing the
                    // engine could ever align was ~400pt below the content's true top and the
                    // walk-up rest landed short of it (`[HomeScrollProbe]` 2026-08-02: rest
                    // y=-90 vs true top -157, deterministic 67pt; the tab bar only expands fully
                    // at the true top, which is why it comes back clipped). Both are now carried
                    // as the hero's OWN transparent top reach instead — same pixels, but the
                    // hero's frame (and its `.focusSection()`) starts at content y=0, so a
                    // reveal that satisfies the hero IS the true top. Layout is unchanged to the
                    // point: the inner fixed-height frame is bottom-aligned inside the extended
                    // one, so the info panel renders exactly where it always did.
                    heroCarousel(compact: false, topReach: Self.classicHeroTopReach)
                }

                if model.rows.isEmpty {
                    placeholder
                }

                if !model.continueWatching.isEmpty {
                    ContinueWatchingRow(
                        entries: model.continueWatching,
                        onSelect: { resume = ResumeTarget(entry: $0) },
                        onRemove: { WatchProgressRepository.shared.clearProgress(videoId: $0.videoId, parentMetaId: $0.parentMetaId) },
                        onGoToDetails: { homePath.append(TitleRoute(preview: previewFromEntry($0))) },
                        onPlayManually: { resume = ResumeTarget(entry: $0, forceManual: true) },
                        onStartOver: { resume = ResumeTarget(entry: $0, startFromBeginning: true) },
                        onMarkWatched: { entry in
                            // Same pair a finished playback leaves behind: the episode joins watched
                            // history and its half-played progress row stops showing in the shelf.
                            // The helper has no default on the Swift side; WatchedRepository
                            // restamps the mark time on write anyway (review r2 #6).
                            WatchedRepository.shared.markWatched(
                                item: WatchingActionsKt.watchedItemFromProgress(
                                    entry: entry,
                                    markedAtEpochMs: Int64(Date().timeIntervalSince1970 * 1000)
                                )
                            )
                            WatchProgressRepository.shared.clearProgress(videoId: entry.videoId, parentMetaId: entry.parentMetaId)
                        },
                        shuffleParentIds: model.shuffleParentIds,
                        posterPattern: model.continueWatchingPosterPattern,
                        // UX-7 (see reportRowFocus for the gating rationale).
                        onItemFocusChange: { entry in
                            reportRowFocus(entry.map(previewFromEntry), source: "continue-watching",
                                           prefetch: { model.continueWatching.prefix(8).flatMap { heroBackdropPrefetchURLs(for: $0) } })
                        }
                    )
                    // rc14 (BUG-122): the short-row floor — see `pinnedShortRowLinkFrameFloor`.
                    .environment(\.rowCardLinkFrameFloor, pinnedShortRowLinkFrameFloor(pinned: pinned))
                }

                // Upcoming: next airing episode per followed show, directly under Continue
                // Watching and above every settings-ordered row (like CW, not part of
                // `model.rows`). Hidden while empty or toggled off.
                if upcomingRowEnabled, !model.upcoming.isEmpty {
                    UpcomingRow(
                        items: model.upcoming,
                        onItemFocusChange: { item in
                            reportRowFocus(item?.toMetaPreview(), source: "upcoming",
                                           prefetch: { model.upcoming.prefix(8).flatMap { heroBackdropPrefetchURLs(for: $0.toMetaPreview()) } })
                        }
                    )
                    // rc14 (BUG-122): the short-row floor — see `pinnedShortRowLinkFrameFloor`.
                    .environment(\.rowCardLinkFrameFloor, pinnedShortRowLinkFrameFloor(pinned: pinned))
                }

                // Catalog sections and collection folder-tile rows, interleaved per the
                // user's Home Rows settings order.
                ForEach(model.rows) { row in
                    Group {
                        switch row {
                        case .catalog(let section):
                            CatalogRowView(
                                section: section,
                                previewLimit: CatalogRowView.homePreviewLimit,
                                // UX-7 (see reportRowFocus for the gating rationale).
                                onItemFocusChange: { item in
                                    reportRowFocus(item, source: section.key,
                                                   logoCandidates: {
                                                       section.items.prefix(CatalogRowView.homePreviewLimit)
                                                           .filter { TitleLogoStore.isLookupCandidate($0.logo) }
                                                   },
                                                   prefetch: { section.items.prefix(8).flatMap { heroBackdropPrefetchURLs(for: $0) } })
                                }
                            )
                            // BUG-35 (beta.12): localize this row's leading items when it scrolls
                            // into view. LazyVStack fires onAppear per row as it mounts; the shared
                            // repo dedups per item+language for the session, so re-appearing rows
                            // cost nothing (see HomeRepository.requestRowEnrichment).
                            .onAppear { model.rowAppeared(sectionKey: section.key) }
                        case .collection(let collection):
                            CollectionRowView(collection: collection, onFolderFocusChange: { folder in
                                // FEAT-33 leg 1/3 (Codex r1+r2): EVERY focus event — including the
                                // `nil` that fires when focus leaves the row — supersedes any
                                // deferred commit still in flight, so a hero queued for a folder
                                // the user has already left never lands. Gated on the leg: with it
                                // off (the default) this `@State` is never written, so the folder
                                // focus path schedules no extra Home update.
                                if CollectionFocusAB.deferHeroCommit { folderFocusGeneration &+= 1 }
                                // BUG-112 review fix (F3): row ownership used to be claimed here
                                // (from the FOLDER event, since a folder with no configured
                                // backdrop/logo reports `preview == nil` and `reportRowFocus`
                                // never saw a claim to make). That claim now comes from the row's
                                // own `@FocusState` via `pinnedRowFocusOwnership` — see
                                // `handleRowFocusOwnership` — which cannot go stale the way a
                                // preview-gated report could (landing on "See All" or an
                                // unconfigured folder still owns the row).
                                // BUG-38 round three: a focused folder tile hands its configured
                                // backdrop + title logo to the hero, the Fusion behaviour the
                                // reporter asked for on the HOME page. Folders with neither asset
                                // report nil — the hero stays where it was, exactly as before.
                                let preview = folder.flatMap { folderHeroPreview(collection: collection, folder: $0) }
                                if let folder, let preview {
                                    heroFolderRoutes[preview.id] = FolderRoute(collectionId: collection.id, folder: folder)
                                }
                                // The route registration above stays immediate on purpose — it is
                                // pure bookkeeping the CTA reads later, and deferring it would let
                                // a fast press land before the map knew the folder.
                                let commit = {
                                    reportRowFocus(preview, source: collection.id, prefetch: {
                                        // Backdrops AND logos (Codex r3): a folder with its own cover never
                                        // warms its logo on the tile (FolderTile suppresses it there), so the
                                        // hero's HeroLogo would otherwise start cold and flash the text name.
                                        // Wave H: no `prefix(8)` any more — a folder hero has NO poster
                                        // fallback (see `folderHeroPreview`), so an unwarmed folder past the
                                        // eighth holds the previous hero for the full 1.5s folder deadline.
                                        // Rows are small (a Fusion collection is a handful of folders) and
                                        // `ArtworkStore.prefetch` skips anything already resident.
                                        collectionHeroPrefetchURLs(collection)
                                    })
                                }
                                // FEAT-33 leg 1/3 (`debug.collectionFocusAB` 1 or 3): hold the
                                // hero commit for `heroCommitDeferral` so the row's own focus-step
                                // animation runs on a main thread that is not simultaneously
                                // starting a hero resolve — the hypothesis behind the tester's
                                // "our folder row animates at 30fps, official Nuvio's at 60".
                                // Superseded commits are DROPPED, not queued: walking three tiles
                                // in 200ms must still commit one hero, not three in sequence.
                                // Nothing downstream changes — `HeroCommitGate`/`Coordinator`/
                                // `ArtResolver` see the identical call, just later. With the leg
                                // off (the default, `leg == 0`) this is the same immediate call
                                // the row has always made.
                                if CollectionFocusAB.deferHeroCommit {
                                    let generation = folderFocusGeneration
                                    DispatchQueue.main.asyncAfter(deadline: .now() + CollectionFocusAB.heroCommitDeferral) {
                                        guard folderFocusGeneration == generation else { return }
                                        commit()
                                    }
                                } else {
                                    commit()
                                }
                            })
                            // Wave H: warm every folder's hero artwork when the ROW appears, not
                            // when a tile is first focused — the focus report and the artwork it
                            // needs used to fire on the same event, so the first focused folder
                            // always waited on a cold fetch (BUG-86 phenomenon D). Shares
                            // `prefetchedBackdropRows` with `reportRowFocus`, so whichever runs
                            // first pays for the row and the other is a no-op.
                            .onAppear { prefetchCollectionHeroArt(collection) }
                        }
                    }
                    // BUG-89: tells the settle tracker (BrowseComponents `PinnedRowSettleTracking`)
                    // this row is the one `PinnedRowSettle` exempts from the canonical rest (no row
                    // below to reveal into) — see `PinnedRowEnvironment.swift`. The bottom inset
                    // below (`rowsInsets`) is the actual fix; this flag is what lets the tracker's
                    // `debug_pinned` line say `last=1` instead of reading an unreachable rest as a
                    // fresh failure.
                    .environment(\.pinnedRowIsLast, row.id == model.rows.last?.id)
                    // BUG-87/89 (rc11): the frame-shaping half of the last-row fix. Published on the
                    // row `pinnedRowIsLast` marks, because that row has no content below it to force
                    // the engine deeper — and only in pinned mode, where the reaches exist.
                    //
                    // rc14 (BUG-122): and on every COLLECTION row too — the mixed-shape row whose
                    // square/landscape tiles make its label frame short. Catalog rows are uniform
                    // (their label IS the plan's link frame) and stay unfloored. See
                    // `pinnedShortRowLinkFrameFloor` for why a short label parks low.
                    .environment(\.rowCardLinkFrameFloor,
                                 pinned && (row.id == model.rows.last?.id
                                            || (pinnedShortRowFloor && Self.isCollectionRow(row)))
                                     ? pinnedLastRowLinkFrameFloor : 0)
                }
            }
            // Pinned only (device rounds 4–5): every row card extends its focusable frame
            // UPWARD by the row band and DOWNWARD past its caption (transparent,
            // layout-compensated inside each row component) so the focus engine's
            // scroll-to-reveal — the ONLY scroll driver on tvOS, swipes included — always
            // reveals the section title above AND the full art/caption below, even with the
            // device's short-rest error in either direction. Rounds 2–3 proved padding
            // OUTSIDE the card frame can't do this: the reveal target simply doesn't
            // include it. See rowCardTopReach / rowCardBottomReach (BrowseComponents).
            //
            // BUG-87 (beta.18): the reaches come from `pinnedPlan`, not straight off Theme. They
            // are two thirds of the frame the engine reveals, so when the hero's elastic give
            // cannot cover the whole demand the plan spends them — bottom reach first (44 → 24: no
            // content below it to protect), then, only if still short, the top reach (88 → 64, and
            // never above 88, which is the dial that kills focus resolution). At every Poster Size
            // that fits today these are exactly `heroPinnedRowTopPad` / `heroPinnedRowBottomReach`.
            .environment(\.rowCardTopReach, pinned ? pinnedPlan.topReach : 0)
            .environment(\.rowCardBottomReach, pinned ? pinnedPlan.bottomReach : 0)
            // "Trailer Location: Hero" — tell every row card to skip the inline morph, because
            // the focused title's trailer is playing in the pinned hero backdrop instead. Passed
            // unconditionally (the computed is already false in every other configuration, and
            // `pinned` is the wrong test: it is the header's LOAD boundary, not the setting).
            .environment(\.trailerPlaysInHero, heroFocusTrailerMode)
            // beta.19-rc1 verdict (M3, BUG-133): which rest signal a dwelling card trailer waits on
            // before it may start. `settleReveal` (the per-call-site container constant), never
            // `pinned` (the header's load boundary): the pinned container has the settle corrector
            // to wait for, classic Home only the motion clock stamped below.
            .environment(\.rowRestSource, settleReveal ? .pinnedHome : .motionClock)
            // BUG-30: `heroInScroll` moves the classic top inset into the hero's own reach (see
            // the hero branch above). Every other configuration keeps its inset unchanged.
            .padding(rowsInsets(pinned: pinned, heroInScroll: !heroItems.isEmpty && !pinned))
            // beta.18 verdict (BUG-66): tells UIKit this ScrollView is the one the top tab bar
            // follows (`TabBarContentScrollLink`) instead of leaving it to UIKit's heuristic, which
            // found these rows at a cold launch (before the pinned header mounted) and lost them
            // after a tab switch. UNCONDITIONAL, with the A/B knob read inside the attacher: the
            // BUG-112 rule below (never conditionally re-identify the rows at the load boundary)
            // applies to this modifier exactly as to the anchor. A `.background`, not a stack
            // child — classic's 48pt `sectionGap` would open a gap around a zero-height row.
            // `settleReveal` (the per-call-site container constant), never `pinned` (the header's
            // load boundary), picks the pinned inset policy. Fallback if a device log shows
            // `[TabBarLink]` never firing (SwiftUI hosting a lazy stack's `.background` outside the
            // UIScrollView): `.overlay`, then a zero-height first row in the pinned container only.
            .background(alignment: .topLeading) {
                TabBarContentScrollLinkAttacher(pinnedContainer: settleReveal)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            // Menu-to-top scroll anchor (BUG-27). On the LazyVStack itself, not the
            // hero — the anchor must exist even while the hero row is lazily culled.
            // In pinned (Nuvio-style) mode the hero isn't in this stack at all, so the
            // anchor's `.top` is simply the top of the rows region — which, with the
            // hero pinned above the ScrollView, is exactly where "the top" now means.
            .id("home_top")
        }
        // Classic keeps clipping disabled so a focused card may lift past the scroll
        // bounds. Pinned mode must NOT: default clipping is what hides rows once they
        // scroll past the viewport top, i.e. the hard edge just below the pinned hero
        // (this replaces the fade mask, which the sim pass falsified — its geometry
        // never anchored to the ScrollView frame and blanked every row). The focus
        // lift stays inside the clip thanks to `rowsInsets`.
        .scrollClipDisabled(!pinned)
        // beta.19-rc1 verdict (M3, BUG-133): stamps `RowsMotionClock` while the rows move
        // vertically (a static timestamp write from the geometry action, never view state), so a
        // trailer dwell in either container sees the rows' own motion. UNCONDITIONAL, like the
        // modifiers around it: `pinned` is a load boundary, not a container.
        .rowsMotionStamp(.vertical)
        // BUG-112 (Item A): the Up the focus engine could not resolve. Attached UNCONDITIONALLY
        // and guarded inside `handleRowsMove` rather than wrapped in an `if pinned` modifier —
        // `pinned` is `heroHeaderVisible`, which flips at the fan-out LOAD boundary, and a
        // conditional modifier there would re-identify (and remount) the whole rows ScrollView.
        // A handler that early-returns is a value change, which is what this boundary is allowed
        // to be (see the `scrollClipDisabled` / `.environment` neighbours).
        .onMoveCommand { handleRowsMove($0, pinned: pinned, proxy: proxy) }
        // rc13 (BUG-112, the half rc12 left open): the same Up, arriving as a touch-surface SWIPE.
        // `onMoveCommand` above is fed by directional-button presses only, which is why Steven's
        // rc12 verdict was "the fallback lands on a button press, never on a swipe" — see
        // `HomeUpSwipeCatcher` for the full grammar and for why the recognizer has to live on the
        // window rather than on this view.
        //
        // Attached UNCONDITIONALLY, exactly like the `.onMoveCommand` above and for the identical
        // reason: `pinned` flips at the fan-out LOAD boundary, and a conditional modifier there
        // would re-identify (and remount) the whole rows ScrollView. A callback that early-returns
        // is a value change, which this boundary is allowed to be.
        //
        // Zero-size and non-hit-testing: it contributes no layout and participates in no hit
        // testing — the recognizer reaches the window from `didMoveToWindow`, so the view's own
        // frame is irrelevant to whether the swipe is seen.
        .background(alignment: .topLeading) {
            HomeUpSwipeCatcher(onUnconsumedSwipeUp: { handleUpSwipe(pinned: pinned, proxy: proxy) },
                               onAnySwipeUp: {
                                   upInput.lastUpInputAt = ProcessInfo.processInfo.systemUptime
                                   // beta.18 verdict (BUG-112): symmetric trigger — whichever of
                                   // (hero focus gain, input stamp) arrives second runs the gate.
                                   _ = revealTopAfterUpIntoHero(pinned: pinned, proxy: proxy, source: "swipe-any")
                               },
                               onAnyUpPress: {
                                   upInput.lastUpInputAt = ProcessInfo.processInfo.systemUptime
                                   _ = revealTopAfterUpIntoHero(pinned: pinned, proxy: proxy, source: "press-any")
                               })
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        // rc14 (BUG-112, the swipe residue in Steven's rc13 verdict): whether the rows have left
        // the first row behind at all. A Bool mapping, so this writes state only when the offset
        // crosses the threshold — never per frame. Read by `revealTopAfterUpIntoHero`.
        .onScrollGeometryChange(for: Bool.self, of: { geo in
            geo.contentOffset.y + geo.contentInsets.top > Theme.Size.heroPinnedRowsHeadroom + 2
        }, action: { _, past in
            rowsScrolledPastTop = past
        })
        // rc14 (BUG-112 residue): an Up INPUT — press or swipe — that the engine resolved straight
        // into the hero CTA from a row leaves the rows wherever that row rested; on an up-walk the
        // first row rests ~100pt under the hero (the rc12 deep park), so Genres sits half-covered
        // with its title faded and nothing moves it until the next Down or Up ("it first goes back
        // to the Hero, then I sometimes have to press Down or Up to make the Genres row appear").
        // The swipe catcher declines a consumed swipe by design, and the press never reaches
        // `handleRowsMove` with a row key. So the scroll is driven from here, INPUT-gated: it runs
        // only within half a second of an Up input AND of a row releasing focus — the same class as
        // rc13's BUG-114 CTA scroll, not the focus-triggered scroll the ban at `.onExitCommand`
        // forbids (a hero focus gained any other way — launch, a tab switch, Menu — has no recent
        // Up input and does nothing here).
        .onChange(of: heroFocused) { _, focused in
            guard focused else { return }
            if revealTopAfterUpIntoHero(pinned: pinned, proxy: proxy, source: "focus") { return }
            // Review r1 P2: the swipe catcher can stamp AFTER the engine's focus update (its own
            // `consumedBeforeCallback` case), so one deferred re-check accepts an input stamped
            // just after the gain. Generation-guarded so a later focus change voids it.
            upInput.revealGeneration &+= 1
            let generation = upInput.revealGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard heroFocused, generation == upInput.revealGeneration else { return }
                _ = revealTopAfterUpIntoHero(pinned: pinned, proxy: proxy, source: "focus-deferred")
            }
        }
        .modifier(forcedUpFallbackTrigger(pinned: pinned, proxy: proxy))
        // BUG-112 (Item A): the rows' half of the fallback — each row watches this for a request
        // naming its own key and writes its OWN `@FocusState`. Default `.none` matches no row.
        .environment(\.pinnedRowFocusRequest, rowFocusRequest)
        // BUG-112 review fix (F3): the rows' ownership report — each row calls this straight off
        // its own `@FocusState` binding, so `focusedRowKey` can never go stale the way the old
        // preview-gated claim in `reportRowFocus` could.
        .environment(\.pinnedRowFocusOwnership, PinnedRowFocusOwnership(report: { key, owns in
            handleRowFocusOwnership(key, owns: owns)
        }))
        // BUG-37: names this exact view (the rows viewport, whose top edge is the pinned clip
        // edge) so a pinned row title can always resolve the rect it must stay inside, even if
        // `.scrollView(axis: .vertical)` doesn't resolve through the row's nested horizontal
        // shelf. Inert otherwise — naming a coordinate space changes no layout.
        .coordinateSpace(.named(PinnedRowTitle.rowsScrollSpace))
        .reportsScrollToTabBar(tab: "Home", isScrolledDown: $isScrolledDown)
        // BUG-30 device-verify probe (instrumentation only, behavior-neutral): logs raw
        // contentOffset/contentInsets — and the RESIDUAL they imply — on every change, plus a
        // debounced REST line, so `log show` after a D-pad walk-up shows exactly where
        // focus-driven scrolling stopped vs. the true top, in a named hero mode. Off by
        // default; the modifier is only attached when the knob is set, so disabled testers pay
        // nothing.
        //   defaults write com.nuvio.media.NuvioTV debug.homeScrollProbe -bool YES
        .modifier(HomeScrollProbeModifier(enabled: homeScrollProbeEnabled,
                                          mode: probeMode(pinned: pinned)))
        // Settle re-reveal (rc1 tester report, sim-reproduced 2026-08-30: a settled pinned rest
        // logging `margin=-86..-100 slide=72 net=-14..-28` at Poster Size = Large, i.e. the row
        // title painted 46pt into the artwork it is supposed to sit above). Only the ROWS scroll
        // view moves; the pinned hero is a sibling above it in the VStack split. Full mechanism,
        // bounds and anti-oscillation argument: `PinnedRowSettle` in BrowseComponents.
        .modifier(PinnedRowSettleRevealModifier(enabled: settleReveal,
                                               compression: pinnedPlan.compression,
                                               showsCTA: heroCarouselActive,
                                               onSettle: settleProbeSink))
        // BUG-30 A/B knob (see `homeScrollEdgeHard`). Not attached unless the knob is set, so
        // the shipped tree is unchanged.
        .modifier(HomeScrollEdgeStyleModifier(hard: homeScrollEdgeHard))
        // The BUG-27 Menu handler is NOT here: it lives on the common ancestor in `body`,
        // because in pinned mode the hero CTA is a sibling of this ScrollView and a handler
        // attached here would not cover it (Menu on the CTA would suspend the app).
    }

    // MARK: - BUG-112 (Item A): the Up press the focus engine could not resolve

    /// History: SwiftUI was believed to deliver `onMoveCommand` to the focused view chain ONLY for
    /// moves the focus engine did not consume — the same property `HeroCarouselInteractionModifier`
    /// (and the BUG-23 hero fix) relies on. On hardware, with rows resting ~100pt deeper on an up-walk than on the way
    /// down, row 1 sits entirely above the rows viewport, the engine finds no legal Up candidate,
    /// and the press does nothing at all: the reported BUG-112 wedge. So an Up that arrives HERE
    /// was taken to be an Up the engine gave up on, and Home reveals + focuses the previous
    /// row itself.
    ///
    /// Hardware FALSIFIED that premise on 2026-09-30 (Apple TV 4K, tvOS 27): all 28 press-started
    /// ladders were logged 30-180 ms after a `focusUpdate` showing the engine had already moved
    /// focus up a row, so `previousRowTarget` resolved one row too far and a single press moved
    /// focus two rows (rung 1 then yanked it back to the anchor tile). The guard below therefore
    /// declines a `press` when the row focus changed within `HomeUpPressConsumption.consumedWindow`
    /// (the engine already consumed it). `swipe` is exempt: `HomeUpSwipeCatcher` snapshots focus
    /// at touch-down and only fires when focus did not move.
    ///
    /// Guards, in order and each for its own reason:
    ///  - `.up` only. Down/left/right arrive here too (the last row's Down, a row's leading/trailing
    ///    edge), and every one of them is a legitimate "nothing there" the engine already decided.
    ///  - PINNED only. In classic mode the rows are not clipped, nothing is ever hidden above the
    ///    fold, and this screen's contract is that classic geometry is untouched.
    ///  - Not while Home is COVERED (BUG-109). A folder page or Detail is pushed over the rows;
    ///    scrolling or focusing underneath it is exactly what `PinnedRowSettle.hostCovered` exists
    ///    to prevent, and native focus restoration on the pop would then resolve by geometry.
    ///  - Never on the TOPMOST row. The hero (and above it the tab bar) is what Up means there, and
    ///    the engine reaches both on its own — `previousRowTarget` returns nil and we decline.
    ///
    /// rc13: `source` names which input produced this — `press` (the `.onMoveCommand` above, and
    /// the DEBUG press proxy) or `swipe` (`handleUpSwipe`). It reaches exactly one place, the
    /// rung-1 `upFallback` line, as a trailing ` src=` token.
    private func handleRowsMove(_ direction: MoveCommandDirection,
                                pinned: Bool,
                                proxy: ScrollViewProxy,
                                source: String = "press",
                                enforceConsumedGuard: Bool = true) {
        guard direction == .up, pinned else { return }
        // rc14: every Up input is stamped before any guard, consumed or not — the stamp is what
        // lets `revealTopAfterUpIntoHero` tell an Up that landed on the hero from a hero focus
        // gained some other way.
        if source == "press" { upInput.lastUpInputAt = ProcessInfo.processInfo.systemUptime }
        guard !PinnedRowSettle.hostCovered else { return }
        guard let rowKey = focusedRowKey,
              let target = previousRowTarget(for: rowKey) else { return }
        if source == "press", enforceConsumedGuard {
            let now = ProcessInfo.processInfo.systemUptime
            if HomeUpPressConsumption.isConsumed(now: now, lastRowFocusChange: lastRowFocusChangeAt) {
                let ms = Int(((now - (lastRowFocusChangeAt ?? now)) * 1000).rounded())
                logUpFallback("row=\(rowKey) prev=\(target.key) action=declined reason=consumed sinceFocus=\(ms) src=press")
                return
            }
        }
        beginUpFallback(from: rowKey, to: target, proxy: proxy, source: source)
    }

    /// rc13 (BUG-112, the half rc12 left open) — an Up SWIPE that moved no focus at all.
    ///
    /// Steven's rc12 verdict: the fallback lands on a button press and never on a touchpad swipe.
    /// That is SwiftUI's move grammar, not a bug in the ladder — `onMoveCommand` is fed by
    /// directional-button presses, while a touch-surface flick is an indirect touch sequence the
    /// focus engine reads itself, with no unconsumed *press* to hand anywhere when it finds no
    /// candidate. `HomeUpSwipeCatcher` (window-level recognizer) supplies the missing event; this
    /// decides whether it means anything here.
    ///
    /// The recognizer is app-wide by necessity — see that file — so every guard that makes it
    /// inert everywhere else lives right here, in order and each for its own reason:
    ///  - PINNED only. Same contract as the press path: classic geometry is untouched, and nothing
    ///    is ever hidden above the fold there for the engine to fail on.
    ///  - Not while Home is COVERED by a PUSH (`PinnedRowSettle.hostCovered`, BUG-109) — a folder
    ///    page or Detail is over the rows, and its own swipes must not reach back here.
    ///  - Not while Home's surface is covered at the SHELL level (`homeSurfaceCovered`): another
    ///    tab is selected, or the root deep-link cover is up. Tabs stay mounted across a switch
    ///    (that is what `homeSurfaceCovered` exists to say), so without this a swipe in Search or
    ///    Settings would run Home's ladder underneath them.
    ///  - Not while the SIDEBAR chrome holds focus. The rc7 verdict stands — no Up gesture
    ///    anywhere may surface or drive the sidebar — and a swipe while its rows have focus is
    ///    the sidebar's own business.
    ///  - Not while Home's own Continue-Watching COVER is up (`resume`). It presents the stream
    ///    picker and, through it, the player: neither `hostCovered` (a `NavigationPath` push) nor
    ///    `homeSurfaceCovered` (tab selection / push depth / the root deep-link cover) sees a
    ///    `fullScreenCover` presented from Home's own tree. `heroTrailerSharedGatesOpen` gates on
    ///    the same pair for the same reason, and its doc records the device pass that found it.
    ///    The routing below would decline anyway — focus is inside the cover, so neither
    ///    `focusedRowKey` nor `heroFocused` is set — but "would decline anyway" is an assumption
    ///    about somebody else's focus bookkeeping, and this is the swipe that reaches the player.
    ///  - Not while a fallback attempt is already live (`activeUpFallbackTarget`). A swipe inside
    ///    an in-flight ladder must not restart it: the rungs are staged 0.3/0.9/1.5 s apart
    ///    precisely so each gets its chance.
    ///
    /// Then the routing. With a row focused this is the press path verbatim, which is the whole
    /// request. With the HERO focused there is no `focusedRowKey`, so the ladder has no origin and
    /// `handleRowsMove` would decline anyway — and an unresolved Up from the hero CTA is exactly
    /// BUG-114, whose handler is right below. Sending it there gives the swipe the same reach the
    /// press has, from one gesture, with `handleHeroUp`'s own guards deciding whether anything
    /// happens.
    private func handleUpSwipe(pinned: Bool, proxy: ScrollViewProxy) {
        guard pinned else { return }
        guard !PinnedRowSettle.hostCovered else { return }
        guard !tabBarVisibility.homeSurfaceCovered else { return }
        guard !sidebarChrome.isFocusedChrome else { return }
        guard resume == nil else { return }
        guard activeUpFallbackTarget == nil else { return }
        if focusedRowKey != nil {
            handleRowsMove(.up, pinned: pinned, proxy: proxy, source: "swipe")
        } else if heroFocused {
            handleHeroUp(proxy: proxy, source: "swipe")
        }
    }

    /// rc13 (BUG-114, GitHub issue #3) — an Up from the hero CTA that the focus engine could not
    /// place scrolls the rows shelf back to the top.
    ///
    /// The report: walk down a few rows, then walk back up. The engine resolves the last Up from
    /// row 1 into the CTA natively — so the rc12 ladder never runs, it is only reached by a move
    /// the engine gave up on — but the rows shelf keeps the offset it had, and with it the system
    /// tab bar stays minimized and unreachable. The next Up dies in the carousel's paging closure.
    ///
    /// **Why this is not the banned class.** The `.onExitCommand` neighbour carries a standing ban
    /// on hero-FOCUS-triggered scrolls: rounds 5–6 completed the scroll when focus re-entered the
    /// hero and both caused worse device regressions (wedged Down navigation, interrupted
    /// Menu-to-top). That ban is on the `.onChange(of: heroFocused)` class, and its own
    /// parenthetical exempts input-triggered scrolls — which is what the pinned Menu branch beside
    /// it already is, and what the ladder's HERO rung already is. This is the third member of that
    /// family: it runs on an unresolved Up PRESS or SWIPE and never on a focus change.
    /// `.onChange(of: heroFocused)` is untouched. The reporter's own patch — scroll to `home_top`
    /// when the hero GAINS focus — is precisely the banned shape and is deliberately not taken.
    ///
    /// **Why it must move the shelf.** `isScrolledDown` does not drive the bar: the tvOS 26 bar is
    /// `.toolbarVisibility(.automatic)` and expands natively off the rows ScrollView's own offset
    /// (`TabBarVisibility`'s doc records the three rounds that established this, and
    /// `TabBarScrollAutoHide` only mirrors a hysteresis for the Menu handler and the sidebar). So
    /// "report the bar as expanded" is not a thing that exists — the only honest fix is to put the
    /// shelf back where the bar expands on its own, which is the top.
    ///
    /// Guards, each for its own reason:
    ///  - PINNED (`heroHeaderVisible`) and the hero actually focused. Belt and braces: the only
    ///    caller is the pinned header's own hook, and `handleUpSwipe` already checked both.
    ///  - `isScrolledDown` — at the top there is nothing to scroll and the bar is already there;
    ///    firing anyway would animate a no-op scroll under the user on every Up at rest.
    ///  - NOT in sidebar mode. There is no system bar to reach: `SidebarOverlay` replaces it and
    ///    the hidden `UITabBar` is deliberately made unfocusable (`HiddenTabBarFocusBlocker`).
    ///    Menu is the scroll-to-top there, by the same rc7 decision that removed every Up-reveal.
    ///  - Not while Home is COVERED (BUG-109) — the same rule every other scroll on this screen
    ///    follows.
    ///  - Not while Home's surface is covered at the SHELL level (`homeSurfaceCovered`) or by its
    ///    own Continue-Watching cover (`resume`). `handleUpSwipe` already checks both, but the
    ///    PRESS path does not: it arrives from `HeroCarouselInteractionModifier.onMove`, which is
    ///    a live `.onMoveCommand` on a tab that stays mounted across a tab switch and underneath a
    ///    `fullScreenCover`. Without these two, an Up in Search — or in the stream picker Home
    ///    itself presented — would animate Home's shelf underneath it.
    ///
    /// No `heroFocused` write anywhere: focus is already on the CTA and is meant to STAY there, so
    /// the user's next Up is the one that reaches the re-expanded bar. Writing it would be the
    /// rounds 5–6 shape again.
    ///
    /// The single 0.6 s retry mirrors the Menu handler's ladder, and re-checks EVERY guard the
    /// entry did rather than only `isScrolledDown` (Codex round 1). 0.6 s is a long time on this
    /// screen: focus can leave the CTA, another Up can arrive, a tab can be switched, the cover can
    /// come up. `heroUpGeneration` catches the cases a re-check cannot see on its own — a second
    /// `handleHeroUp` that has already scheduled its own retry, and focus leaving the hero and
    /// returning inside the window (where `heroFocused` reads true again but the intent is stale).
    /// The re-checks cover the rest. Both together, and the retry is gated on `isScrolledDown` for
    /// the reason the Menu handler states — the scroll landing, not focus, is what says whether
    /// this worked.
    private func handleHeroUp(proxy: ScrollViewProxy, source: String = "press") {
        // rc14 (review r1 P2): this is where the press that moved a row's focus onto the CTA
        // arrives (30–180 ms after the focus update on hardware, to the NEW focus owner). Stamp it
        // as the Up input and, when a row released focus just now with the first row still under
        // the hero, reveal the top — the BUG-112 swipe/press residue. `isScrolledDown` is not
        // required for that case (a ~100pt deep park never arms its 300pt latch); the BUG-114
        // scroll below keeps its own gate.
        if source == "press" { upInput.lastUpInputAt = ProcessInfo.processInfo.systemUptime }
        if revealTopAfterUpIntoHero(pinned: heroHeaderVisible, proxy: proxy, source: source) { return }
        guard heroHeaderVisible, heroFocused, isScrolledDown else { return }
        guard !SidebarChrome.isEnabled() else { return }
        guard !PinnedRowSettle.hostCovered else { return }
        guard !tabBarVisibility.homeSurfaceCovered else { return }
        guard resume == nil else { return }
        heroUpGeneration &+= 1
        let generation = heroUpGeneration
        logUpFallback("row=hero prev=tabbar action=top src=\(source)")
        PinnedRowSettle.noteExternalScroll(reason: "hero-up-top")
        withAnimation(.easeInOut(duration: 0.45)) {
            proxy.scrollTo("home_top", anchor: .top)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard heroUpGeneration == generation else { return }
            guard heroHeaderVisible, heroFocused, isScrolledDown else { return }
            guard !PinnedRowSettle.hostCovered else { return }
            guard !tabBarVisibility.homeSurfaceCovered else { return }
            guard resume == nil else { return }
            PinnedRowSettle.noteExternalScroll(reason: "hero-up-top-retry")
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo("home_top", anchor: .top)
            }
        }
    }

    /// BUG-112 review fix (F3): the single writer of `focusedRowKey`, fed by every row's
    /// `pinnedRowFocusOwnership` report (`PinnedRowUpFallback.swift`) — which fires straight off
    /// that row's own `@FocusState`, `owns == true` the instant it gains focus, `false` the
    /// instant it loses it. Replaces the old preview-gated claims in `reportRowFocus` and the
    /// collection-folder callback, which went stale on a row's "See All" tile or an unconfigured
    /// folder (both report a nil hero preview and so never claimed the row).
    ///
    /// Review fix (F2a): a claim for a DIFFERENT row than the one `focusedRowKey` already names
    /// retires whatever attempt is currently live via `endUpFallback` — the same discipline
    /// `SidebarOverlay.handOffFocusToContent` uses for its own re-issues. This is what stops a
    /// landed fallback from later pulling focus back: the moment the target row's own claim
    /// lands, generation moves past every rung's captured value, so a rung that fires afterward
    /// (whether because the user pressed Down immediately, or for any other reason) finds
    /// `generation != upFallbackGeneration` and no-ops — silently, because this IS the normal
    /// "already landed" case, not a cancellation.
    ///
    /// Review fix (F1): the claim change is the ONLY place that can tell a landed hand-off from
    /// a diversion (the user moving on to some OTHER row before the requested target ever
    /// mounts), so it is also the only place that can retire the request correctly for both —
    /// `origin` is `focusedRowKey`'s value from just before this claim, which for a real
    /// up-fallback is the row the Up press originated from. If the new owner is the row the
    /// active attempt is aiming at, that is a landing; otherwise it is a diversion, and either
    /// way `endUpFallback` clears `rowFocusRequest` UNCONDITIONALLY — not only when it happens
    /// to name this row — because the request only ever belongs to the attempt that is ending.
    /// The old conditional clear (`if rowFocusRequest.rowKey == rowKey`) left a request naming
    /// some earlier, now-abandoned target row alive across a diversion, and that row's own
    /// `.onAppear` re-apply (`PinnedRowUpFallbackTarget.applyIfMatching`) could steal focus back
    /// onto it whenever it later mounted.
    ///
    /// The `owns == false` branch does NOT retire anything on its own — it only clears the key
    /// when the row giving it up is the one currently on record (a stale `false` from a row that
    /// already lost the claim to someone else must not blank a newer claim). A row that loses
    /// focus with no other row yet claiming it (an in-flight hop, or focus leaving Home entirely)
    /// leaves `focusedRowKey` nil for a beat; `shouldContinueUpFallback`'s own
    /// `focusedRowKey == rowKey` re-check (F2b) is what catches a pending rung in exactly that
    /// window, since nil can never equal the origin row's key.
    private func handleRowFocusOwnership(_ rowKey: String, owns: Bool) {
        if owns {
            if focusedRowKey != rowKey {
                let origin = focusedRowKey
                // beta.18 verdict (BUG-126): one frame-timing window per row hop (no-op unless
                // `debug.collectionFrameProbe` is on).
                CollectionFocusFrameSampler.shared.arm(rowKey: rowKey, gif: false)
                focusedRowKey = rowKey
                lastRowFocusChangeAt = ProcessInfo.processInfo.systemUptime
                if rowKey == activeUpFallbackTarget {
                    endUpFallback(reason: "row=\(activeUpFallbackOrigin ?? origin ?? "-") prev=\(rowKey) action=landed src=\(activeUpFallbackSource)",
                                  log: true)
                } else {
                    endUpFallback(reason: "superseded", log: false)
                }
            }
            // F5: a completed request cannot be picked up again by a row that mounts later —
            // clear it the moment the row it named actually takes the claim. (`endUpFallback`
            // above already clears it unconditionally on a claim change; this covers the
            // narrower case where `owns` fires again for the row that already owns focus.)
            if rowFocusRequest.rowKey == rowKey {
                rowFocusRequest = .none
            }
        } else if focusedRowKey == rowKey {
            focusedRowKey = nil
            // rc14: when the hero's focus gain arrives before this release (the two are separate
            // SwiftUI updates with no guaranteed order), `revealTopAfterUpIntoHero` reads this
            // stamp on the hero side; when it arrives after, the hero-side check already saw the
            // row key. Either order qualifies the reveal.
            upInput.lastRowReleasedAt = ProcessInfo.processInfo.systemUptime
        }
    }

    /// rc14 (BUG-112 residue): scroll the rows back to the top after an Up input moved focus from a
    /// row into the hero CTA while the first row was still scrolled under the hero. See the
    /// `.onChange(of: heroFocused)` on the rows ScrollView for the full rationale and the input
    /// gate. Same situational guards as `handleHeroUp`, minus `isScrolledDown` (the deep-parked
    /// first row sits ~100pt down — well under that latch's 300pt arm).
    /// Returns whether it scrolled. Three callers: the hero's focus gain (and its deferred
    /// re-check), and `handleHeroUp`, which receives the PRESS that moved a row's focus onto the
    /// CTA — tvOS delivers that press to the newly focused hero, never to the rows' handler, so
    /// the press path stamps the input there (review r1 P2).
    @discardableResult
    private func revealTopAfterUpIntoHero(pinned: Bool, proxy: ScrollViewProxy, source: String) -> Bool {
        // beta.18 verdict (BUG-112 / BUG-126): every decline is logged (the success path alone used
        // to log, so a tester's "nothing happened" was undiagnosable). Gated on the probe by
        // `logUpFallback`; a no-op otherwise.
        // review r1 (P3-1): the window-level `press-any` / `swipe-any` sources fire for EVERY Up
        // app-wide, so a row-to-row walk would write one structural decline per press into the
        // Row Settle pane. For those two sources the cheap structural guards return silently;
        // `focus`, `focus-deferred` and `press` keep full logging.
        let quietStructuralDeclines = (source == "press-any" || source == "swipe-any")
        func decline(_ reason: String, structural: Bool = false) -> Bool {
            if structural && quietStructuralDeclines {
                // Quiet for the pane and the console, but the DEBUG AX label still carries it so the
                // simulator leg (test74) can prove the window-level press path fires at all.
                #if DEBUG
                debugUpFallback = "row=hero prev=row action=declined reason=\(reason) src=\(source) quiet=1"
                #endif
                return false
            }
            logUpFallback("row=hero prev=row action=declined reason=\(reason) src=\(source)")
            return false
        }
        guard pinned else { return decline("notPinned", structural: true) }
        guard heroHeaderVisible else { return decline("heroHidden", structural: true) }
        guard heroFocused else { return decline("heroNotFocused", structural: true) }
        let now = ProcessInfo.processInfo.systemUptime
        let verdict = HomeUpIntoHeroGate.evaluate(now: now,
                                                  lastUpInputAt: upInput.lastUpInputAt,
                                                  lastRowReleasedAt: upInput.lastRowReleasedAt,
                                                  focusedRowKey: focusedRowKey,
                                                  rowsScrolledPastTop: rowsScrolledPastTop,
                                                  window: Self.upIntoHeroWindow)
        if case .declined(let reason) = verdict { return decline(reason) }
        guard !SidebarChrome.isEnabled() else { return decline("sidebar") }
        guard !PinnedRowSettle.hostCovered else { return decline("covered") }
        guard !tabBarVisibility.homeSurfaceCovered else { return decline("covered") }
        guard resume == nil else { return decline("resume") }
        // review r1 (P3-3): one physical Up can arrive via focus / focus-deferred / handleHeroUp /
        // press-any. A reveal issued inside the last 0.5 s is still scrolling (0.45 s), so a repeat
        // declines WITHOUT bumping `heroUpGeneration`, keeping the landing retry keyed to the first.
        if let last = upInput.lastRevealAt, now - last < 0.5 { return decline("alreadyRevealing") }
        upInput.lastRevealAt = now
        let sinceUp = now - upInput.lastUpInputAt
        logUpFallback("row=hero prev=row action=top reason=upIntoHero sinceUp=\(Int((sinceUp * 1000).rounded())) src=\(source)")
        heroUpGeneration &+= 1
        let generation = heroUpGeneration
        // Voids any pending deferred re-check so the scroll fires once per gain.
        upInput.revealGeneration &+= 1
        PinnedRowSettle.noteExternalScroll(reason: "up-into-hero-top")
        withAnimation(.easeInOut(duration: 0.45)) {
            proxy.scrollTo("home_top", anchor: .top)
        }
        // Fix B: landing retry. The first scroll can land before the engine's own reveal settles
        // (the rows end up ~100pt short); re-check once after it and scroll again if still off.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard heroUpGeneration == generation else { return }
            guard heroFocused, rowsScrolledPastTop else { return }
            guard !PinnedRowSettle.hostCovered else { return }
            guard !tabBarVisibility.homeSurfaceCovered else { return }
            guard resume == nil else { return }
            logUpFallback("row=hero prev=row action=top-retry reason=upIntoHero src=\(source)")
            PinnedRowSettle.noteExternalScroll(reason: "up-into-hero-top-retry")
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo("home_top", anchor: .top)
            }
        }
        return true
    }

    /// How recent an Up input (and a row's focus release) must be for `revealTopAfterUpIntoHero`
    /// to treat a hero focus gain as that input's doing.
    /// Beta.18 verdict: 0.5 -> 0.8 s — a slow swipe is recognised at gesture END, so its stamp can
    /// land well after the focus gain it caused.
    private static let upIntoHeroWindow: TimeInterval = 0.8

    /// The row ABOVE `rowKey` in `rowsScroll`'s actual render order — Continue Watching, then
    /// Upcoming, then `ForEach(model.rows)` — together with the scroll anchor that reveals it.
    /// `nil` when `rowKey` is the topmost row, or is not a row this screen renders.
    ///
    /// Only the `ForEach` publishes per-row scroll ids (SwiftUI derives them from `HomeRow.id`), so
    /// CW/Upcoming — plain siblings above it — are revealed through "home_top", the BUG-27 anchor
    /// on the `LazyVStack` itself. That is the top of the rows region in pinned mode, which reveals
    /// both of them whole.
    ///
    /// `key` (what this returns, and what every caller compares against `focusedRowKey`) and
    /// `anchor` (the id `proxy.scrollTo` needs) are NOT the same string for a collection row:
    /// `HomeRow.id` namespaces collections as `"collection_\(collection.id)"` (see `HomeRow.id`,
    /// HomeViewModel.swift) to avoid colliding with a catalog section's own `key`, but every
    /// focus/settle call site (`reportRowFocus`'s `source`, `pinnedRowSettleTracking(rowKey:)`,
    /// `pinnedRowUpFallbackTarget(rowKey:)`) uses the BARE `collection.id`. So `order` is built
    /// from the bare key, with the ForEach's own `HomeRow.id` carried alongside it purely for the
    /// scroll anchor — using `HomeRow.id` as the key here would silently never match
    /// `focusedRowKey` for any collection row and the fallback would never fire past row 2.
    private func previousRowTarget(for rowKey: String) -> (key: String, anchor: String)? {
        var order: [(key: String, anchor: String)] = []
        if !model.continueWatching.isEmpty { order.append((key: "continue-watching", anchor: "home_top")) }
        if upcomingRowEnabled, !model.upcoming.isEmpty { order.append((key: "upcoming", anchor: "home_top")) }
        for row in model.rows {
            switch row {
            case .catalog(let section):
                // `HomeRow.id` for `.catalog` IS `section.key` (HomeViewModel.swift) — no
                // divergence here, but named explicitly rather than reused so the collection
                // branch's divergence below doesn't read as an inconsistency.
                order.append((key: section.key, anchor: section.key))
            case .collection(let collection):
                order.append((key: collection.id, anchor: row.id))
            }
        }
        guard let index = order.firstIndex(where: { $0.key == rowKey }), index > 0 else { return nil }
        return order[index - 1]
    }

    /// The hand-off ladder. Each rung is cheaper-first and only runs if the one before it did not
    /// land, verified against `focusedRowKey` — the pattern `SidebarOverlay.handOffFocusToContent`
    /// established (a reset issued into a subtree that is still building lands nowhere, so it is
    /// re-issued and finally escalated rather than assumed).
    ///
    ///  1. t=0    ASK. Write the row's own `@FocusState` through the environment request. When the
    ///            previous row is still MOUNTED (the common case — it is one row above the fold),
    ///            this alone moves focus and the engine performs its own scroll-to-reveal. No
    ///            programmatic scroll at all, so there is nothing for the engine to pull back.
    ///  2. t=0.3  REVEAL, then ask again. The row was culled by the `LazyVStack` (or refused the
    ///            write), so the request was dropped. Scroll it into view first; mounting is what
    ///            makes the second write land.
    ///  3. t=0.9  TOP. Still nowhere: scroll to "home_top" and ask once more.
    ///  4. t=1.5  HERO — only when the target is the topmost row. This is the proven Menu path
    ///            (`heroFocused = true` first, synchronously, then the scroll; see `onExitCommand`).
    ///            For a DEEPER target we deliberately stop instead (`giveup`): the page has already
    ///            moved up, so the user's next Up press has a fully visible row to resolve against.
    ///
    /// Every programmatic scroll tells the corrector first (`PinnedRowSettle.noteExternalScroll`):
    /// an outstanding verification measured against an offset WE moved is a false MISS, and two
    /// false MISSes disarm the corrector for the session. Review fix (F4): this now includes the
    /// hero rung — `heroFocused = true` moves the rows scroll to the true top exactly as the
    /// scroll call right after it does, so it needs the same notice, and it is called first,
    /// before the focus write, so the corrector never judges a stale outstanding verification
    /// against the hero taking over.
    ///
    /// Review fix (F2b): every scheduled rung re-validates through `shouldContinueUpFallback`
    /// instead of the old inline `generation == upFallbackGeneration, focusedRowKey != target.key`
    /// pair — see that function's doc for what changed and why.
    ///
    /// Review fix (F1/F2): if an older attempt is still live (`activeUpFallbackTarget != nil`) —
    /// a second Up press landing before the first attempt resolved — it is retired silently
    /// through `endUpFallback` before this one starts, so its request and rungs cannot outlive
    /// the attempt that superseded them. `activeUpFallbackTarget` is then set to this attempt's
    /// target so `handleRowFocusOwnership` can recognise the landing when it happens.
    ///
    /// rc13: `source` (`press` / `swipe`) names which input started the attempt — a directional
    /// button the focus engine did not consume, or a touch-surface flick it did not consume
    /// (`HomeUpSwipeCatcher`). It is appended as a trailing ` src=` token to EVERY line this
    /// attempt writes, not just the first, and it is stashed on `activeUpFallbackSource` so the
    /// lines composed outside this function (the cancel guards, the `landed` line) can carry it
    /// too. See that property for why: `debug_upfallback` holds only the LAST line, so a token on
    /// the rung-1 line alone is gone by the time any reader — harness or device photo — gets to it.
    /// `debug_upfallback` stays append-only and key-parsed, so test65 is unaffected.
    private func beginUpFallback(from rowKey: String,
                                 to target: (key: String, anchor: String),
                                 proxy: ScrollViewProxy,
                                 source: String = "press") {
        if activeUpFallbackTarget != nil {
            endUpFallback(reason: "restarted", log: false)
        }
        upFallbackGeneration &+= 1
        let generation = upFallbackGeneration
        activeUpFallbackTarget = target.key
        activeUpFallbackOrigin = rowKey
        // After the `restarted` retire above, so a superseded attempt's source can never label
        // this one's lines.
        activeUpFallbackSource = source
        let isTopTarget = previousRowTarget(for: target.key) == nil

        logUpFallback("row=\(rowKey) prev=\(target.key) action=focus anchor=\(target.anchor) src=\(source)")
        // rc13 (BUG-112, second half): rung 1 scrolls NOTHING — it asks the row above to take its
        // own focus and lets the ENGINE reveal it. That is still a walk step, so the corrector is
        // told with `noteFocusHop`, not `noteExternalScroll`: the latter also calls
        // `pullBack.forgetHop()`, which drops the row/offset pair the next settle derives `dir=`
        // from, so the up-walk would never flip to −1 and Item B's direction-scoped brake would
        // stay spent from the down-walk that preceded it. Its other half matters just as much: a
        // fallback-entered rest that the engine's reveal did not have to move produced NO settle at
        // all in rc12 — his pane showed a gap where a line should be, and the titles faded with
        // nothing on the wire to explain it. The armed `external` token is what makes that rest
        // evaluated and logged. The three scrolling rungs below keep `noteExternalScroll`: those
        // ARE programmatic jumps, and a jump is not a walk step.
        PinnedRowSettle.noteFocusHop(reason: "upfallback-ask")
        requestRowFocus(target.key)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard shouldContinueUpFallback(generation: generation, rowKey: rowKey, target: target) else { return }
            logUpFallback("row=\(rowKey) prev=\(target.key) action=scroll anchor=\(target.anchor) src=\(source)")
            PinnedRowSettle.noteExternalScroll(reason: "upfallback")
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(target.anchor, anchor: .top)
            }
            requestRowFocus(target.key)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard shouldContinueUpFallback(generation: generation, rowKey: rowKey, target: target) else { return }
            logUpFallback("row=\(rowKey) prev=\(target.key) action=top src=\(source)")
            PinnedRowSettle.noteExternalScroll(reason: "upfallback-top")
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo("home_top", anchor: .top)
            }
            requestRowFocus(target.key)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard shouldContinueUpFallback(generation: generation, rowKey: rowKey, target: target) else { return }
            guard isTopTarget, !heroItems.isEmpty, heroNuvioStyle else {
                logUpFallback("row=\(rowKey) prev=\(target.key) action=giveup src=\(source)")
                endUpFallback(reason: "giveup", log: false)
                return
            }
            logUpFallback("row=\(rowKey) prev=\(target.key) action=hero src=\(source)")
            // F1: the attempt is handing over to the hero rung — retire it (and drop the row
            // request with it) BEFORE flipping focus, so nothing is left behind for a later-
            // mounting row's `.onAppear` to pick back up.
            endUpFallback(reason: "hero", log: false)
            PinnedRowSettle.noteExternalScroll(reason: "upfallback-hero")
            heroFocused = true
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo("home_top", anchor: .top)
            }
        }
    }

    /// BUG-112 review fix (F2b): the shared eligibility re-check every scheduled rung runs before
    /// acting, replacing the old bare `generation == upFallbackGeneration, focusedRowKey !=
    /// target.key` pair. `false` covers two outcomes callers must not conflate:
    ///
    ///  - LANDED, silent. `handleRowFocusOwnership` (F2a) bumps `upFallbackGeneration` the instant
    ///    ANY row's claim changes `focusedRowKey` to a new value — including the target row's own
    ///    landing. So by the time a later rung's closure runs, a landed attempt has already left
    ///    `generation` behind `upFallbackGeneration`, and the very first guard below returns
    ///    `false` before anything is logged. This is what stops a rung from firing again after a
    ///    successful hand-off and pulling focus back (F2, the original finding): the prior
    ///    inline check only asked "have we not yet reached the target", which stayed true even
    ///    after landing if the user then moved on to a THIRD row — this asks "is this still the
    ///    attempt in progress" instead.
    ///  - CANCELLED, logged once. Home became covered (a Detail or folder page pushed over the
    ///    rows — BUG-109's `PinnedRowSettle.hostCovered`), the page left pinned mode, or the
    ///    origin row lost focus without the target ever claiming it (an in-flight hop, or focus
    ///    leaving Home entirely — the `owns == false` branch of `handleRowFocusOwnership` does not
    ///    bump generation on its own, so this is the guard that actually catches that window).
    ///    Each of these logs `action=cancelled reason=…` exactly once, THEN retires the attempt
    ///    through `endUpFallback` (bumping generation again and dropping any outstanding request
    ///    naming the target, F5) — kept as a second, separate call rather than folded into
    ///    `endUpFallback` itself because the `reason=…` suffix differs per guard and the
    ///    generation guard above must stay the FIRST thing this function checks. Review fix (F2):
    ///    retiring here (not just clearing the request) is what stops a rung SCHEDULED BEHIND
    ///    this one from re-running the same cancellation check and re-logging — it dies silently
    ///    on the generation guard instead, exactly like the landed case above.
    ///
    /// `heroHeaderVisible` is re-read live rather than captured at `beginUpFallback` time — a
    /// snapshot would not notice the page leaving pinned mode mid-ladder.
    private func shouldContinueUpFallback(generation: Int,
                                          rowKey: String,
                                          target: (key: String, anchor: String)) -> Bool {
        guard generation == upFallbackGeneration else { return false }
        guard !PinnedRowSettle.hostCovered else {
            logUpFallback("row=\(rowKey) prev=\(target.key) action=cancelled reason=covered src=\(activeUpFallbackSource)")
            endUpFallback(reason: "cancelled", log: false)
            return false
        }
        guard heroHeaderVisible else {
            logUpFallback("row=\(rowKey) prev=\(target.key) action=cancelled reason=unpinned src=\(activeUpFallbackSource)")
            endUpFallback(reason: "cancelled", log: false)
            return false
        }
        guard focusedRowKey == rowKey else {
            logUpFallback("row=\(rowKey) prev=\(target.key) action=cancelled reason=refocused src=\(activeUpFallbackSource)")
            endUpFallback(reason: "cancelled", log: false)
            return false
        }
        return true
    }

    private func requestRowFocus(_ key: String) {
        rowFocusRequestSeq &+= 1
        rowFocusRequest = PinnedRowFocusRequest(rowKey: key, generation: rowFocusRequestSeq)
    }

    /// BUG-112 review fixes F1/F2: the single place every attempt retires, however it ends —
    /// landed, superseded by a diversion, cancelled, given up, handed to the hero, or restarted
    /// by a second Up press. Bumping `upFallbackGeneration` here (not only in `beginUpFallback`)
    /// is what makes F2's fix work: a cancellation branch in `shouldContinueUpFallback` calls
    /// this once and every rung still scheduled behind it dies on THAT function's generation
    /// guard (kept first) instead of re-running its own cancellation check. Clearing
    /// `rowFocusRequest` UNCONDITIONALLY — not only when it happens to name the row that just
    /// changed ownership — is what F1 needed: the request belongs to the attempt that is ending,
    /// full stop, so a diversion to some OTHER row must not leave the OLD target's request alive
    /// for that row's own `.onAppear` re-apply (`PinnedRowUpFallbackTarget.applyIfMatching`) to
    /// pick up whenever it later mounts.
    ///
    /// `reason` is opaque here: every caller that already logged its own full
    /// `row=…prev=…action=…` line (each rung in `beginUpFallback`, each guard in
    /// `shouldContinueUpFallback`) passes `log: false` with a bare word, purely so the call site
    /// reads clearly — nothing more is logged. The one caller with nothing already on the wire —
    /// `handleRowFocusOwnership`'s landed case — passes the complete log line as `reason` with
    /// `log: true`.
    private func endUpFallback(reason: String, log: Bool) {
        upFallbackGeneration &+= 1
        rowFocusRequest = .none
        activeUpFallbackTarget = nil
        activeUpFallbackOrigin = nil
        if log {
            logUpFallback(reason)
        }
    }

    /// One line per fallback rung, to the three readers a device pass and the harness have:
    /// the console (`HomeGeometryProbe`-gated, same token grammar as the corrector's lines), the
    /// photographable About pane (`PinnedRowSettleProbe`, where the settle lines already land), and
    /// the DEBUG `debug_upfallback` AX label the UI tests read.
    private func logUpFallback(_ text: String) {
        if HomeGeometryProbe.enabled { NSLog("[HomeScrollProbe] upFallback %@", text) }
        if PinnedRowSettleProbe.enabled { PinnedRowSettleProbe.log("upFallback " + text) }
        #if DEBUG
        debugUpFallback = text
        #endif
    }

    /// DEBUG-only proxy trigger for `-debug.homeUpFallbackForce YES` (see `HomeUpFallbackKnobs`).
    /// The shipped trigger cannot be forced: `onMoveCommand` is only DELIVERED for moves the engine
    /// did not consume, and the simulator's engine always consumes Up (test63/test64 both reach
    /// row 1 from row 2 across a fully off-screen gap). So the knob binds the identical fallback
    /// body to Play/Pause, which is free on Home's rows. `forced` is a launch-latched `static let`,
    /// constant for the process, so the conditional branch can never re-identify the rows mid-session.
    ///
    /// rc13: "free" only holds with inline trailers off. A focused card whose inline trailer is
    /// currently playing claims Play/Pause for itself first — `CatalogRowView` attaches
    /// `.onPlayPauseCommand(perform: muteToggle(for: item))` (`BrowseComponents.swift`, the card's
    /// mute toggle, Trailer Location = Hero mode) — so this proxy is unreachable on that card while
    /// its trailer plays. test65/test67 pin `-inline_trailers_enabled NO` for exactly this reason.
    private func forcedUpFallbackTrigger(pinned: Bool, proxy: ScrollViewProxy) -> some ViewModifier {
        ForcedUpFallbackTriggerModifier(enabled: HomeUpFallbackKnobs.forced || HomeUpFallbackKnobs.swipeForced) {
            // rc13: with the SWIPE knob armed the proxy enters through the catcher's own door
            // (`simulateSwipeUp`), not through the ladder — so the settle window, the
            // did-focus-move check and the rows/hero routing all run for real and the `src=swipe`
            // token on the rung-1 line is earned rather than asserted. Play/Pause moves no focus,
            // which is exactly what makes the did-focus-move check pass honestly. The swipe knob
            // wins when both are set: it exercises a strict superset of the press path.
            #if DEBUG
            if HomeUpFallbackKnobs.swipeForced {
                HomeUpSwipeCatcher.simulateSwipeUp()
                return
            }
            #endif
            // The proxy exists because the simulator's engine does not move focus on these
            // presses, so the consumed-press guard must not apply to it.
            handleRowsMove(.up, pinned: pinned, proxy: proxy, enforceConsumedGuard: false)
        }
    }

    /// The hero region's foreground: the paged carousel plus its (static) page dots, or — with
    /// Show Hero off (FEAT-15) — the same info panel with every carousel affordance stripped.
    /// Fixed height everywhere: paging, auto-advancing, or a focus takeover swaps content inside a
    /// constant frame, so the rows below never move.
    ///
    /// FEAT-15 removes exactly three things in focus-panel mode, and adds none:
    ///  - the CTA (`showsCTA: false`). It is the hero's ONLY focusable element, and leaving it in
    ///    would break the mode two ways: initial focus would land on it instead of the first row
    ///    (so the panel would open empty and the user would have to press Down to fill it), and
    ///    `onChange(of: heroFocused)` treats CTA focus as the carousel reclaiming the hero — it
    ///    calls `cancelAndRevert()`, which with no carousel underneath just blanks the panel.
    ///    Nothing is lost: the CTA opened the focused title's detail screen, which is what
    ///    pressing Select on the row card under it already does.
    ///  - `focusSection()` + `onMoveCommand` (via `HeroCarouselInteractionModifier`). Both are
    ///    inert with no focusable descendant, but declaring a focus section over a region the
    ///    engine can never enter is exactly the kind of empty-container edge this screen has been
    ///    burned by before, so the modifiers are simply not attached.
    ///  - the page dots (already `heroItems.count > 1`, i.e. never in this mode).
    ///
    /// `topReach` (BUG-30, classic only) extends the hero's frame UPWARD by that many transparent
    /// points with the fixed-height content bottom-aligned inside it — the same "the reveal target
    /// must physically contain the region" mechanism the row cards use (`rowCardTopReach`), scaled
    /// to the one focusable thing at the top of the classic scroll. It replaces an identical
    /// amount of PADDING at the call site, so nothing moves; what changes is that the padding is
    /// now inside the hero's own frame and `.focusSection()` rather than outside them. 0 (the
    /// pinned header's value) collapses the modifier entirely — pinned geometry is untouched.
    ///
    /// rc13 (BUG-114, GitHub issue #3): `onUnresolvedUp` — what an Up the focus engine could not
    /// place from the CTA should do. nil (the classic call site, and any future one) keeps the
    /// pre-rc13 behaviour exactly: the move falls through to the paging switch's `default: return`.
    /// The pinned header passes `handleHeroUp`, which scrolls the shelf back to the top so the
    /// system tab bar is reachable again — see that function.
    private func heroCarousel(compact: Bool,
                              topReach: CGFloat = 0,
                              onUnresolvedUp: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // BUG-23 round 2 (device finding): the paged TabView is GONE. The sim fix caught
            // dropped D-pad presses via onMoveCommand, but the real Siri Remote pages by
            // touch-surface SWIPE, which drives the TabView's native interactive paging —
            // and dragging toward the culled previous page can't commit, so it visibly
            // snapped back ("jumps back to the right"). With no native pager competing, BOTH
            // input styles (presses and swipes) arrive here as move commands, the single CTA
            // button keeps focus across page changes (no focus hop), and the whole
            // culled-page/selection-fight class is gone. The backdrop crossfade (outside,
            // keyed off currentHero) and the auto-advance timer are unchanged.
            Group {
                // UX-7: a row-focused poster (displayHero) takes over the info panel too, so
                // the title/synopsis on screen always matches the backdrop behind it. The CTA's
                // NavigationLink is bound to `item`, so it follows along automatically.
                // Wave H: the PRESENTED hero, so the text on screen and the artwork behind it are
                // always the same item's — they are two halves of one committed value now.
                //
                // beta.19-rc1 verdict (M5, BUG-138): `HeroTextLayer` owns and observes the text swap
                // model (fade the old text out, swap while invisible, fade the new one in), so a hero
                // change re-renders that layer and `HomeHeroForeground`, never this body (critique
                // #11). The `if let` stays the region-existence test.
                if let presentation = heroResolver.presented {
                    HeroTextLayer(presentation: presentation, heroFocused: $heroFocused, compact: compact,
                                  showsCTA: heroCarouselActive,
                                  forceNuvioLayout: focusHeroActive,
                                  compression: compact ? pinnedPlan.compression : 0,
                                  folderRoutes: heroFolderRoutes)
                }
            }
            // Compact (pinned) trims ~100pt so the rows viewport below can fit a reach-
            // extended focus frame plus the engine's reveal margin — see the Theme comment
            // on heroCarouselHeightPinned (device round 6). FEAT-15's panel keeps the SAME
            // fixed height for THIS frame — the freed CTA slot is redistributed to the synopsis
            // INSIDE the panel (see HomeHeroForeground). The pinned HEADER is not the same height,
            // though (corrected 2026-09-30): the panel has no `HeroPageDots` child below this
            // frame, so the header loses `Spacing.sm + HeroPageDots.height` (38pt) and the rows
            // viewport gains it. `Theme.Size.heroPinnedRowsViewportBudget(showsCTA:)` accounts for
            // that (455 carousel, 493 panel); device evidence `hero viewport live=561 expected=522`.
            // Wave 10: in pinned mode the hero yields `pinnedHeroCompression` so the focused row
            // fits below the clip edge at the canonical rest. The inner slots below shrink by the
            // same amount (see `HomeHeroForeground.compression`), so this is a graceful compression
            // rather than a frame clipped around fixed content. 0 at Small/Medium — those layouts
            // are bit-identical to Wave 9.
            .frame(height: compact ? Theme.Size.heroCarouselHeightPinned - pinnedPlan.compression
                                   : Theme.Size.heroCarouselHeight)
            // BUG-30 (classic only, `topReach > 0`): grow the frame upward to the content top,
            // bottom-aligning the fixed-height slot above so the panel does not move a pixel.
            // Applied BEFORE the focus section so the section covers the extended frame — the
            // whole point is that the engine's reveal target now reaches the true top. The
            // extension is transparent and holds nothing focusable, so it adds no focus stop
            // (and in FEAT-15's panel mode, where there is deliberately no focusable element at
            // all, `topReach` is 0 and this modifier is not applied).
            //
            // OPEN QUESTION FOR THE DEVICE PASS (Codex review, unresolved by design): the engine
            // may align its reveal to the focused CTA's own frame rather than this enlarged
            // container/section — in which case `REST classic` will still log residual≈67 and
            // this reach did nothing. The CTA is `.glass`-styled, so the row-card fix (reach as
            // padding INSIDE the focusable label) would balloon its platter; restyling the CTA
            // blind is the exact failure mode of BUG-30's six reverted rounds. If the probe says
            // residual is unchanged, the next round extends the CTA's focusable frame with a
            // device in the loop (likely a borderless custom-glass restyle), not before.
            .modifier(HeroTopReachModifier(
                extendedHeight: topReach > 0
                    ? (compact ? Theme.Size.heroCarouselHeightPinned
                               : Theme.Size.heroCarouselHeight) + topReach
                    : 0
            ))
            .modifier(HeroCarouselInteractionModifier(enabled: heroCarouselActive) { direction in
                // FEAT-30 (2026-09-05) briefly routed an Up with no focus target reaching HERE
                // (the hidden bar's band is a dead zone — device spike + test52) to the sidebar,
                // gated same-day on a 0.45s "deliberate Up" settle window to tell a press apart
                // from a Siri Remote swipe's trailing overshoot at a row's top. BUG-98 (2026-09-08)
                // removed that gate on a misread of u/mrStevenx3's rc6 video. His rc7 verdict
                // (2026-09-09): reveal-on-Up is unusable on his hardware regardless of gating — the
                // panel opened "no matter where he is" and navigation became impossible; a clickpad
                // Up never opened anything here before FEAT-30 and that is what he wants back. The
                // actual rc6 bug was a touch-surface swipe flicking the panel open and immediately
                // closed again, not a lost deliberate press. Christian's decision: no Up-reveal
                // path at all, in the carousel or anywhere else — the sidebar opens on Menu only
                // (`SidebarMenuRevealModifier` / Home's own `.onExitCommand` grammar below). So an
                // Up here is exactly what it was before FEAT-30 ever touched this closure: it falls
                // through to the paging switch's `default: return`, a no-op.
                //
                // rc13 (BUG-114, GitHub issue #3): that no-op is the reporter's wedge. From a deep
                // row the engine resolves Up → CTA natively; the NEXT Up arrives here, finds
                // nothing above the hero it can focus, and dies — while the rows shelf is still
                // holding its scrolled-down offset and the system tab bar, which expands off that
                // offset, stays stranded. `onUnresolvedUp` is the pinned header's answer (scroll
                // the shelf to the top), and it runs FIRST, before the paging guard: a single-item
                // hero returns on that guard, and a multi-item one would fall to `default: return`
                // — either way the Up would be swallowed by the pager's own bookkeeping. Nothing
                // changes for left/right, and a nil handler (classic) is byte-identical to before.
                if direction == .up, let onUnresolvedUp {
                    onUnresolvedUp()
                    return
                }
                guard heroItems.count > 1 else { return }
                let count = heroItems.count
                let clamped = min(heroIndex, count - 1)
                let next: Int
                switch direction {
                case .left: next = (clamped - 1 + count) % count
                case .right: next = (clamped + 1) % count
                default: return
                }
                withAnimation(.easeInOut(duration: 0.4)) { heroIndex = next }
            })

            // Both layouts keep the info panel on the left, so the dots stay leading. Never
            // conditionally removed while a row poster owns the hero (UX-7) — faded out via
            // opacity instead, so the carousel's layout never reflows around them.
            //
            // Wave H: and never conditionally removed at the COUNT boundary either. `if heroItems
            // .count > 1` meant a hero that published one item and then more — the ordinary
            // cold-launch fan-in — grew its region by the dots' slot at that moment and pushed
            // every row below it down, one of the vertical steps the pinned-title corrector then
            // chases (BUG-87). The dots now mount with the CAROUSEL and carry their visibility in
            // opacity, the same rule the focus takeover above already followed; `count` is floored
            // at 1 so a single-item hero reserves the same slot height as a multi-item one.
            //
            // The mount is gated on `heroCarouselActive`, not on nothing at all: FEAT-15's focus
            // panel (Show Hero off) has never rendered dots, and mounting an invisible slot there
            // would take 38pt (`Spacing.sm + HeroPageDots.height`) off its pinned rows viewport.
            // The two forms therefore have different viewport budgets (455 carousel, 493 panel —
            // `Theme.Size.heroPinnedRowsViewportBudget(showsCTA:)`, 2026-09-30); the carousel's own
            // load boundary is the one this fixes. Deliberately still OUTSIDE the fixed 352pt frame.
            if heroCarouselActive {
                let dotsVisible = heroItems.count > 1 && focusModel.focusedItem == nil
                HeroPageDots(count: max(heroItems.count, 1),
                             index: min(heroIndex, max(heroItems.count - 1, 0)))
                    .padding(.leading, Theme.Spacing.lg)
                    .opacity(dotsVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: dotsVisible)
            }
        }
    }

    /// The PINNED hero header (UX-7 extension, Nuvio-style only): the exact same `heroCarousel`
    /// the classic layout embeds in the scroll, hosted here as the FIXED top of a VStack whose
    /// second child is the rows ScrollView. Nothing about the focus model changes — the carousel
    /// keeps rendering `displayHero`, so a row poster taking over the hero updates the pinned
    /// panel live exactly as before.
    ///
    /// This replaced a `.safeAreaInset(edge: .top)` host after the sim pass: an inset changes
    /// layout but NOT the focus engine's scroll-to-reveal target, so tvOS slid rows up through the
    /// inset region and rested focused cards behind the hero's text. Splitting the screen with a
    /// VStack gives the ScrollView below honest bounds, and the focus engine then reveals focused
    /// cards fully inside them — i.e. below the hero.
    ///
    /// BUG-19 identity rule: `heroCarousel` may move between the in-scroll container and this one
    /// ONLY when the Settings toggle flips — never per scroll frame, and never at the `heroItems`
    /// empty→loaded boundary (that check wraps this header alone, not the ScrollView beside it).
    /// No `.id()` is introduced here.
    ///
    /// FEAT-15: this same header also hosts the Show-Hero-off focus panel — the request is for the
    /// focused title's backdrop and text and nothing else, which is precisely what this header
    /// already renders during a UX-7 takeover. The only difference is that with no carousel
    /// underneath, the takeover is the header's entire life rather than a temporary override.
    ///
    /// Paddings are the COMPACTED pinned set (`heroPinnedTopPad` / `heroPinnedRowsGap`), not the
    /// in-scroll ones: pinned mode shares one screen between hero and rows, so the hero has to
    /// give the rows viewport ~450pt to fit a poster row. See the height budget on those tokens.
    ///
    /// rc13 (BUG-114): takes the shared `ScrollViewReader` proxy now, purely to hand `handleHeroUp`
    /// to the carousel's unresolved-Up hook. The classic in-scroll call site passes no hook and is
    /// unchanged.
    private func pinnedHeroHeader(proxy: ScrollViewProxy) -> some View {
        heroCarousel(compact: true, onUnresolvedUp: { handleHeroUp(proxy: proxy) })
            .padding(.top, Theme.Size.heroPinnedTopPad)
            .padding(.horizontal, Theme.Spacing.screen)
            .padding(.bottom, Theme.Size.heroPinnedRowsGap)
    }

    /// Content insets for the rows `LazyVStack`. Classic keeps the uniform overscan-safe
    /// `Theme.Spacing.screen` on all four edges, byte-for-byte what it always had. Pinned uses
    /// `heroPinnedRowsHeadroom` (8) on top: NOT spacing — it is the buffer that absorbs the
    /// device-only BUG-30 walk-up residual (~67pt short of the sim's rest position), which the
    /// pinned clip edge otherwise turns into cropped poster tops / a bisected row title (device
    /// round 1, 2026-08-03). The horizontal/bottom insets stay at 60 — with clipping ENABLED in
    /// pinned mode they are also what keeps a focused card's lift inside the clip.
    ///
    /// BUG-30: in CLASSIC mode WITH the in-scroll hero, the 60pt top inset moves into the hero's
    /// own `topReach` (see the hero branch in `rowsScroll`) and this returns 0 — same pixels, but
    /// carried inside a frame the focus engine can reveal instead of a padding gap it can't. Every
    /// other configuration is byte-identical to beta.10, including classic BEFORE the hero fan-out
    /// lands (no hero to carry the inset ⇒ the rows keep their own 60).
    private func rowsInsets(pinned: Bool, heroInScroll: Bool) -> EdgeInsets {
        if pinned {
            return EdgeInsets(top: Theme.Size.heroPinnedRowsHeadroom, leading: Theme.Spacing.screen,
                              bottom: pinnedRowsBottomInset, trailing: Theme.Spacing.screen)
        }
        return EdgeInsets(top: heroInScroll ? 0 : Theme.Spacing.screen,
                          leading: Theme.Spacing.screen,
                          bottom: Theme.Spacing.screen, trailing: Theme.Spacing.screen)
    }

    /// BUG-89 (Steven's beta.17 report — a hidden-title square-tile Fusion folder shelf left
    /// visible for seconds under "Genres" once it became the last row focused): the last pinned row
    /// is the row `PinnedRowSettle`'s canonical-rest corrector (BrowseComponents) most often cannot
    /// help. Not by exemption — `settlePlan` has no `isLastRow` branch, and `last=` on its line is
    /// reporting only — but by arithmetic: there is no row below it to reveal into, so an upward
    /// correction runs out of scroll range and the honest `endOfContent` / upward-no-room branches
    /// return `targetY: nil`. Nothing else then pulls the scroll content far enough to clear a
    /// short last row above the pinned clip edge.
    ///
    /// The fix is a bottom content inset sized so the scroll range ALONE can reveal the last row
    /// fully, with no corrector involved: `vh` (the pinned rows viewport, STATIC — never the live
    /// viewport, the same rule `pinnedPlan` follows) minus the last row's own height, plus the same
    /// title-inset/dead-zone slack a settled correction would leave (`heroPinnedRowTitleInset` 48,
    /// `heroPinnedRowSettleDeadZone` 4), plus 8pt of breathing room.
    ///
    /// BUG-87 (beta.18): both terms move with `pinnedPlan` — `vh` is the plan's viewport (which
    /// grows with the compression) and `pinnedLastRowHeight` is measured with the plan's REACHES
    /// (which shrink the row when the hero's give runs out). Reading one from the plan and the
    /// other from the Theme constants would mis-size this inset by exactly the reach spend, which
    /// is the BUG-89 half of the report.
    ///
    /// ── The floor (BUG-89 round two, beta.18-rc2) ────────────────────────────────────────────
    /// The floor used to be the bare uniform `Theme.Spacing.screen` (60), on the reasoning that a
    /// TALL last row (a catalog shelf) needs no help — the formula goes negative for it, so the
    /// uniform inset every other edge carries is exactly right. Steven's rc2 video says otherwise,
    /// at BOTH Large and Medium: his LAST row rests about 90pt DEEPER than a middle row does, with
    /// the previous row's tiles showing clipped above it. That is the hardware-only park depth the
    /// simulator has never reproduced (BUG-66 family; `Theme.Size.heroPinnedRowsDeviceParkSlack`).
    ///
    /// The corrector could fix that rest — `settlePlan` has NO `isLastRow` exemption, `last=` on
    /// its line is reporting only — except that at a bottom-anchored park it has nothing to spend:
    /// `scrollRoomUp` is `restRange` (≤32) plus the device's extra depth short of what it needs, so
    /// the `endOfContent` branch fires (`nudge=0 endOfContent=1 room=…`), which is the honest
    /// answer to "the scroll range is spent" and the wrong outcome for "the engine parked deeper
    /// than we sized for". So the floor now carries that room explicitly:
    ///
    ///     floor = Spacing.screen (60) + plan.restRange (0…32) + deviceParkSlack (96)
    ///
    /// `restRange` is the plan's own width for the set of legal rests (`viewport − linkFrame`), so
    /// a regime with several legal rests is given room to reach any of them; `deviceParkSlack` is
    /// the measured device-vs-sim park depth. A content inset can only ADD scroll range at the
    /// bottom — it moves no rest, no band edge and no correction — so over-providing costs nothing
    /// but a little unused range past the last row, while under-providing is the bug.
    ///
    /// At Large (poster 403.3, `vh` 523.3, `restRange` 0): a catalog last row (626.8pt) now gets
    /// the floor 156 instead of 60; a hidden-title square-tile collection last row (436.9pt) keeps
    /// its 146-from-the-formula only if that still exceeds the floor, otherwise the floor wins; a
    /// captioned one (471.9pt) takes the floor. The `max` keeps whichever term is larger, so the
    /// short-last-row case the original fix was written for is untouched wherever it still binds.
    private var pinnedRowsBottomInset: CGFloat {
        guard let lastRowHeight = pinnedLastRowHeight else { return Theme.Spacing.screen }
        let vh = pinnedPlan.viewport
        // See the floor block above: uniform inset + this regime's rest range + the measured
        // device park depth. Never smaller than the old bare `Theme.Spacing.screen`.
        let floor = Theme.Spacing.screen
            + pinnedPlan.restRange
            + Theme.Size.heroPinnedRowsDeviceParkSlack
        let inset = max(floor,
                         vh - lastRowHeight + Theme.Size.heroPinnedRowTitleInset
                            + Theme.Size.heroPinnedRowSettleDeadZone + 8)
        #if DEBUG
        if homeScrollProbeEnabled {
            // `slack=` is the only token added to this line: with a non-constant floor a device
            // log otherwise cannot tell which of the two `max` terms won, which is the whole
            // question when a last row still parks deep.
            NSLog("[HomeScrollProbe] trailingInset=%.1f lastRow=%@ lastRowH=%.1f slack=%.1f",
                  inset, pinnedLastRowId ?? "none", lastRowHeight, floor)
        }
        #endif
        return inset
    }

    /// The bottom-most row `pinnedRowsBottomInset` must clear. Mirrors `rowsScroll`'s actual
    /// render order: `model.rows.last` in the common case (a catalog or collection row); Continue
    /// Watching / Upcoming only stand in when `model.rows` is empty, because they always render
    /// ABOVE the `ForEach` (see `rowsScroll`) and so are never actually last while any row exists.
    /// `nil` when Home has nothing to lay out yet (placeholder only) — the caller floors to the
    /// uniform inset in that case.
    private var pinnedLastRowHeight: CGFloat? {
        // BUG-87/89 (rc11): the last row's cards carry `rowCardLinkFrameFloor`, so its shelf is the
        // LARGER of its own tallest label and that floor. For a uniform catalog row the two are equal
        // by construction (the floor IS `plan.linkFrame`); for a short-tile collection row the floor
        // wins and the row is `floor − naturalLabel` taller than the pre-rc11 arithmetic said.
        let floor = pinnedLastRowLinkFrameFloor
        if let last = model.rows.last {
            switch last {
            case .catalog:
                let artworkHeight = posterStyle.landscapeCatalogRows
                    ? Theme.Size.landscapeHeight : posterStyle.height
                let caption = posterStyle.showTitle ? PinnedRowTitle.cardLockupCaptionChrome : 0
                // `pinnedUniformShelfChrome` bundles the two `Spacing.lg` shelf paddings with the
                // reaches; pull the label (topReach + artwork + caption + bottomReach) back out so
                // the floor is compared against the label alone, not the whole shelf.
                let label = pinnedPlan.topReach + artworkHeight + caption + pinnedPlan.bottomReach
                return Theme.Spacing.lg + max(label, floor) + Theme.Spacing.lg
            case .collection(let collection):
                // BUG-87 (beta.18): `pinnedRowHeight` states the FIXED pinned reaches
                // (`heroPinnedRowTopPad` / `heroPinnedRowBottomReach`) because they were the only
                // values `HomeView` ever set. When the plan spends a reach, that helper overstates
                // the row by exactly the spend, so correct it here rather than reaching into
                // `CollectionsUI` — this is the helper's only caller, and it is the same
                // "`HomeView` supplies the reaches" contract its own doc comment names.
                let natural = CollectionRowView.pinnedRowHeight(collection: collection, style: posterStyle)
                    + pinnedPlanReachDelta
                // `natural` already includes this row's own `lg` top and `sm` bottom padding, so the
                // floor is compared against its shelf, not against the whole row.
                let shelf = natural - Theme.Spacing.lg - Theme.Spacing.sm
                return Theme.Spacing.lg + max(shelf, floor) + Theme.Spacing.sm
            }
        }
        // Codex r3 (P2): the caption term is gated exactly like the catalog branch above.
        // `LandscapeCard`'s caption is drawn under `titleVisible` (`showTitle ?? style.showTitle`,
        // `PosterCard.swift`), and neither the Upcoming nor the Continue Watching call site passes
        // `showTitle:`, so with Hide Labels on both rows are 43.5pt shorter than this used to
        // claim. Overstating the last row's height understates `pinnedRowsBottomInset` by the same
        // amount, which is the one thing that inset exists to get right.
        let fallbackCaption = posterStyle.showTitle ? PinnedRowTitle.cardLockupCaptionChrome : 0
        if upcomingRowEnabled, !model.upcoming.isEmpty {
            return Theme.Size.landscapeHeight + fallbackCaption + pinnedUniformShelfChrome
        }
        if !model.continueWatching.isEmpty {
            return Theme.Size.landscapeHeight + fallbackCaption + pinnedUniformShelfChrome
        }
        return nil
    }

    /// BUG-87/89 (rc11): the label-height floor Home's LAST pinned row publishes — see
    /// `PinnedRowGeometry.lastRowLinkFrameFloor` and `EnvironmentValues.rowCardLinkFrameFloor`.
    /// `0` outside pinned mode (the reaches are 0 there and the floor would be a visible gap).
    private var pinnedLastRowLinkFrameFloor: CGFloat {
        PinnedRowGeometry.lastRowLinkFrameFloor(plan: pinnedPlan)
    }

    /// rc14 (BUG-122, every 2026-09-30 device walk): the SAME floor, published on the short rows
    /// above the catalogs — Continue Watching, Upcoming — and on collection rows. Their label
    /// frames are 120–200pt shorter than the plan's link frame (a 203pt landscape card or a square
    /// tile against a 403pt poster), so the engine's tolerated rest interval is wide and it parks
    /// them at the BOTTOM of it: Continue Watching +55, Upcoming +130/+160, the first folder row
    /// +128, then the corrector pulled each one up 11–117pt — the one visible jump left after the
    /// rest-law fix. With the label floored to the plan's frame the engine reveals the same frame
    /// for every row and parks them where it parks the poster rows (rest ≈ −8, in band). The
    /// layout growth the floor would cause between rows is cancelled inside each row component by a
    /// matching negative bottom padding (`PinnedRowGeometry.shortRowLayoutCompensation`), so only
    /// the focusable frame grows, never the visible spacing.
    ///
    /// Only while catalog rows exist below them: with `model.rows` empty one of these rows IS the
    /// last row, and that case keeps rc11's bottom-inset accounting (`pinnedLastRowHeight`).
    private func pinnedShortRowLinkFrameFloor(pinned: Bool) -> CGFloat {
        guard pinned, pinnedShortRowFloor, !model.rows.isEmpty else { return 0 }
        return pinnedLastRowLinkFrameFloor
    }

    /// rc14 (BUG-122): About → "Short Row Floor (A/B)", default ON. Reactive, so flipping it
    /// re-publishes the floor env without a relaunch.
    @AppStorage("debug.pinnedShortRowFloor") private var pinnedShortRowFloor = true

    private static func isCollectionRow(_ row: HomeRow) -> Bool {
        if case .collection = row { return true }
        return false
    }

    /// How much SHORTER (negative) a row is than the fixed-reach arithmetic assumes, because
    /// `pinnedPlan` spent one or both reaches. 0 at every Poster Size that fits without spending
    /// them, which is every configuration that shipped before BUG-87.
    private var pinnedPlanReachDelta: CGFloat {
        (pinnedPlan.topReach - Theme.Size.heroPinnedRowTopPad)
            + (pinnedPlan.bottomReach - Theme.Size.heroPinnedRowBottomReach)
    }

    /// Identifies `pinnedLastRowHeight`'s row for the probe line — `HomeRow.id` in the common
    /// case, the fixed row keys `rowsScroll` uses for CW/Upcoming otherwise.
    private var pinnedLastRowId: String? {
        if let id = model.rows.last?.id { return id }
        if upcomingRowEnabled, !model.upcoming.isEmpty { return "upcoming" }
        if !model.continueWatching.isEmpty { return "continue-watching" }
        return nil
    }

    /// The fixed vertical chrome every UNIFORM-card pinned shelf (catalog, Continue Watching,
    /// Upcoming — every row whose cards go through `CatalogRowView`'s or `UpcomingRow`'s/
    /// `ContinueWatchingRow`'s identical shelf padding) carries around its artwork, verified
    /// against the shelf's own vertical padding (`BrowseComponents.swift:2795`
    /// `.padding(.vertical, Theme.Spacing.lg)`, top AND bottom) and the pinned row reaches:
    ///     Spacing.lg (24) + topReach (88) + bottomReach (44) + Spacing.lg (24) = 180
    /// `CollectionRowView` does NOT use this — its shelf padding is asymmetric top/bottom, so it
    /// states its own arithmetic in `CollectionRowView.pinnedRowHeight`.
    ///
    /// BUG-87 (beta.18): the two reach terms come from `pinnedPlan`, which is what the rows are
    /// actually rendering with (`\.rowCardTopReach` / `\.rowCardBottomReach` above). They equal the
    /// Theme constants at every Poster Size that fits without spending them.
    private var pinnedUniformShelfChrome: CGFloat {
        Theme.Spacing.lg + pinnedPlan.topReach + pinnedPlan.bottomReach + Theme.Spacing.lg
    }

    /// BUG-87 (beta.18): structural fit. The ONE resolved geometry every pinned-mode consumer on
    /// this screen reads — the hero's compression, both card reaches, the rows viewport, and
    /// whether the focus engine's link frame fits inside it at all.
    ///
    /// It replaces Wave 10's `pinnedHeroCompression` (which sized the hero against `Spacing.lg +
    /// topReach + artwork + cushion` and charged neither the caption chrome nor the DOWNWARD reach,
    /// leaving Steven's shape 12pt over its viewport and the settle corrector fighting the engine
    /// forever). `PinnedRowTitle.pinnedHeroCompression` still exists and is still the scope gate
    /// inside the plan — it is simply no longer read directly from here.
    ///
    /// Inputs, and why each is the right one:
    ///  - `posterStyle.height` — the tallest artwork a PORTRAIT pinned row can present. Landscape
    ///    catalog rows (203) and square/landscape folder tiles (height from the WIDTH dial) are
    ///    shorter, and Continue Watching/Upcoming are landscape cards.
    ///  - `posterStyle.showTitle` — Hide Labels. The caption is INSIDE the focusable label, so it
    ///    is part of the frame the engine reveals.
    ///  - `heroCarouselActive` — exactly what `heroCarousel` passes as `showsCTA`, so the plan's
    ///    give matches the hero form actually on screen (FEAT-15's panel can give 142, not 70).
    ///  - `posterStyle.landscapeCatalogRows` — a landscape page's rows are 203pt tall and need
    ///    nothing spent for them.
    ///
    ///  - `mode` (BUG-87/89 rc10) — the two Appearance focus flags. The top reach's floor holds the
    ///    FOCUS LIFT now (`PinnedRowGeometry.topReachFloor(lift:)`), so the plan is mode-dependent:
    ///    reach 86 and compression 90.33 at Large with zoom on, 66 and 70.33 with No Zoom. Reading
    ///    the flags as `@AppStorage` is what makes a flip in Settings re-plan on return (the
    ///    `.animation(.easeInOut(duration: 0.28), value: pinnedPlan)` in `body` cross-fades the hero
    ///    into the new numbers) instead of leaving the rows describing the previous mode — the r10 P2
    ///    staleness class, which on this path would also have published a stale `regimeKey`/`fits`
    ///    pair to the settle corrector.
    ///
    /// STATIC in the Wave 10 sense: it changes when a Settings/Appearance value changes and at no
    /// other time — never per row, per focus, or per rest.
    private var pinnedPlan: PinnedRowGeometry.Plan {
        PinnedRowGeometry.plan(posterHeight: posterStyle.height,
                               captionVisible: posterStyle.showTitle,
                               showsCTA: heroCarouselActive,
                               landscapeRows: posterStyle.landscapeCatalogRows,
                               mode: PinnedRowTitle.FocusModeFlags(noZoom: noZoomOnFocus,
                                                                   accentRing: accentFocusRing,
                                                                   reachHoldsLift: PinnedRowTitle.resolveReachHoldsLift(observing: noZoomReachHoldsLift),
                                                                   zoomReachHold: PinnedRowTitle.resolveZoomReachHold(observing: zoomReachHold)))
    }

    /// BUG-30: how far the classic in-scroll hero's frame reaches ABOVE its content — the exact
    /// padding it gives up in exchange (`heroForegroundTopPad`, which placed the info panel on the
    /// lower third of the backdrop, plus the `Spacing.screen` top inset `rowsInsets` no longer
    /// applies in that configuration). Sum, not a new token: it must track those two by
    /// construction, or the hero moves.
    private static let classicHeroTopReach = Theme.Size.heroForegroundTopPad + Theme.Spacing.screen

    /// Which geometry a `[HomeScrollProbe]` line was measured in. BUG-30's 67pt capture is a
    /// CLASSIC measurement (full-screen rows ScrollView under the tab bar — its 157pt top content
    /// inset is the tab bar's safe area), and the reframe above is scoped there, so every line has
    /// to name its mode rather than leave the reader to infer it.
    private func probeMode(pinned: Bool) -> String {
        guard pinned else { return "classic" }
        return heroCarouselActive ? "pinned-hero" : "pinned-panel"
    }


    /// Warm the artwork caches for every hero page (backdrop + logo) as soon as the items are
    /// known, so manual paging and the auto-advance crossfade never flash a placeholder.
    /// FEAT-15: in focus-panel mode there are no pages, so the one title the panel paints before
    /// anything is focused — the resting item — is warmed instead. Every OTHER title's backdrop is
    /// still warmed the same way it always was: one batch per row, on that row's first focus
    /// report (`reportRowFocus`), which is unchanged and now runs in both hero modes.
    private func prefetchHeroArt() {
        var items: [ArtworkPrefetchItem] = []
        // Every render candidate — primary backdrop, poster fallback AND logo — in the same chain
        // the hero actually resolves; see heroBackdropPrefetchURLs, which carries the logo itself
        // as of Wave H (the resolver waits on it, so a cold logo is a cold hero).
        // beta.19-rc1 verdict (review r2, P3-1): typed, so the logo is warmed at the request the
        // resolver looks it up with (`heroArtPrefetchItems`).
        for item in heroItems {
            items.append(contentsOf: heroArtPrefetchItems(for: item))
        }
        if let resting = heroRestingItem {
            items.append(contentsOf: heroArtPrefetchItems(for: resting))
        }
        ArtworkStore.prefetch(items)
    }

    /// Wave H: every folder's hero backdrop AND title logo in one collection row. A folder hero has
    /// no poster fallback, so these two URLs are the whole of what its hero can ever paint.
    /// Home Stage & Strip (P1 E6): the body lives in `HomeRowPreviews.collectionArtURLs`.
    private func collectionHeroPrefetchURLs(_ collection: NuvioCollection) -> [String] {
        HomeRowPreviews.collectionArtURLs(collection)
    }

    /// Wave H: warm a collection row's folder artwork when the ROW appears. Shares the per-row
    /// dedup set with `reportRowFocus`, so a row pays for its warm-up exactly once per Home
    /// lifetime whichever of the two events happens first.
    /// Home Stage & Strip (P1 E6): the body lives in `HomeRowPreviews.warmCollection`.
    private func prefetchCollectionHeroArt(_ collection: NuvioCollection) {
        HomeRowPreviews.warmCollection(collection, done: &prefetchedBackdropRows)
    }

    /// UX-7: single funnel for every row's focus report. The gating history here is worth keeping
    /// straight, because FEAT-15 removed one of its three layers and the reason matters:
    ///
    ///  - The Show Hero SETTING used to gate all work — reports, enrichment, backdrop prefetch —
    ///    and called `cancelAndRevert()` on every event while the hero was off. The premise was
    ///    "with the hero deliberately off, browsing must not generate artwork/metadata traffic for
    ///    a feature that cannot render" (Codex review finding). That premise is now false: with
    ///    Show Hero off the focus panel IS the hero region (see the hero-mode block at the top of
    ///    this file), so the feature renders in both settings states and there is no wasted
    ///    traffic to suppress. Leaving the guard in place is what made hero-off silently kill the
    ///    description panel — FEAT-15/BUG-24, the same request three times over — so the guard is
    ///    gone rather than inverted: there is no configuration left in which a report is dead
    ///    work, and adding a second setting to recreate one would just recreate the trap.
    ///  - The temporary loading state (`heroItems` still empty during the fan-out) does NOT gate
    ///    reports — `displayHero` gates at display time instead, so a card focused before the
    ///    fan-out lands takes over the moment `heroItems` arrives (no re-report exists at that
    ///    boundary, and a construction-time gate got cached dead by the LazyVStack). That window
    ///    is the one place reports can still outrun a renderable hero, and it is deliberate.
    ///  - Backdrop prefetch warms once per row, on its first non-nil report, through the same
    ///    `heroBackdropURL` chain the hero renders. Unchanged, and now warm in both hero modes.
    ///  - FEAT-42: the SAME first-focus gate additionally batches a `TitleLogoStore` lookup for
    ///    the row's own logo candidates — `logoCandidates` defaults to an empty array (a plain
    ///    no-op) so Continue Watching/Upcoming/collection rows stay byte-identical; only the
    ///    catalog-row call site passes one. This is a row-scale PREWARM, not the thing that makes
    ///    a focused item's logo appear — `HomeHeroFocusModel.requestLogoIfNeeded` (fired from
    ///    `reportFocus`'s own dwell) is what a single focused card depends on; this just gives it
    ///    a head start for items later in the row the shared TMDB overlay never reached (past
    ///    `HOME_ROW_ENRICHMENT_PREFIX`, or a TMDB-id catalog it skips outright).
    ///
    /// Note the removed `cancelAndRevert()` had a second job — dropping a claim made while the
    /// hero was enabled so that re-enabling later could not resurrect a stale title. That job is
    /// obsolete for the same reason: the claim is never orphaned now, because both settings states
    /// display it. Toggling Show Hero mid-browse simply moves the committed title from the
    /// carousel's hero to the focus panel and back.
    private func reportRowFocus(_ item: MetaPreview?, source: String,
                                logoCandidates: () -> [MetaPreview] = { [] },
                                prefetch: () -> [String]) {
        // Home Stage & Strip (P1 E6): the warm-up half lives in `HomeRowPreviews.warmRow`, which the
        // Stage controller's report funnel runs too. Gated on `item != nil` HERE as well, so the
        // `@State` dedup set is touched exactly when the original `if item != nil, …insert…` did.
        if item != nil {
            HomeRowPreviews.warmRow(source: source, item: item, done: &prefetchedBackdropRows,
                                    logoCandidates: logoCandidates, prefetch: prefetch)
        }
        // BUG-112 review fix (F3): row ownership (`focusedRowKey`) used to be claimed HERE, gated
        // on `item != nil` — which meant landing on a row's "See All" tile or an unconfigured
        // folder (both report `item == nil`) never claimed the row, so the Up-fallback's idea of
        // "who has focus" went stale the moment a user stopped on one. Ownership now comes
        // straight from the row's own `@FocusState` binding via `pinnedRowFocusOwnership` (see
        // `handleRowFocusOwnership`), which cannot disagree with what is actually focused.
        focusModel.reportFocus(item, from: source)
    }

    /// FEAT-30: Home's half of the sidebar Menu grammar — the `else` of the BUG-27 ternary in the
    /// body above.
    ///
    /// `nil` unless sidebar mode is on AND the page is at the top, which keeps two invariants:
    /// tabs mode resolves that site to `nil` exactly as it does today (byte-identical), and while
    /// the page is scrolled down the BUG-27 Menu-to-top branch owns the press — the sidebar never
    /// competes with "the long way down, the short way back".
    ///
    /// Search/Library/Add-ons get the same behaviour from `.sidebarMenuReveal()`; Home cannot use
    /// that modifier because its exit handler has to compose with the branch above.
    ///
    /// FEAT-30 (2026-09-05) briefly added a sibling `sidebarUpRevealHandler` here too — Up with no
    /// focus target reveal + focus the sidebar, same as the hero carousel's own branch. Removed
    /// 2026-09-09 on the rc7 tester verdict (BUG-98's follow-up): reveal-on-Up proved unusable on
    /// hardware regardless of gating, so Christian's call was Menu-only, everywhere. See
    /// `SidebarOverlay.swift`'s `SidebarMenuRevealModifier` doc comment for the full arc.
    private var sidebarMenuRevealHandler: (() -> Void)? {
        guard SidebarChrome.isEnabled(), !isScrolledDown else { return nil }
        return {
            // Read at press time, not as a body dependency — `@Environment` on the custom key
            // gives Home the object without subscribing it to `objectWillChange` (see the
            // property's doc comment). The guard is belt-and-braces: with focus in the sidebar
            // this handler is not in the responder chain at all, since the panel is a sibling of
            // the whole TabView rather than a descendant of Home.
            guard !sidebarChrome.isFocusedChrome else { return }
            sidebarChrome.requestReveal()
        }
    }

    /// BUG-38 round three: adapts a collection folder to the hero's `MetaPreview` shape so a
    /// focused folder tile can drive the hero with the folder's OWN artwork — `banner` is the
    /// configured `heroBackdropUrl`, `logo` the `titleLogoUrl` (both read by the existing
    /// `heroBackdropURL(for:)` / `heroLogoURL(for:)` chains with no special casing), and `poster`
    /// the cover (the backdrop chain's last fallback). `type` is the `collectionHeroType`
    /// sentinel the trailer, enrichment and CTA gates key on. `releaseInfo` is deliberately nil —
    /// beta.14.5 shipped the parent collection's title ("Genres", "Services de Streaming") here
    /// as the hero's meta line, but a tester flagged it 2026-08-22 as an unwanted tvOS-only
    /// caption with no mobile counterpart, so H-2 removes it: the folder hero is logo-only.
    /// `genres` is already empty for a folder preview, so `metaLine` resolves to "" and the
    /// `Theme.Size.heroMetaSlotHeight`-framed slot at the call sites just holds empty — no layout
    /// jump. Nil when the folder carries neither a backdrop nor a logo — such a folder has
    /// nothing of its own to show, so focusing it leaves the hero alone rather than painting a
    /// poster-shaped cover across the backdrop.
    /// Home Stage & Strip (P1 E6): the body (and its history) lives in `HomeRowPreviews.folder`,
    /// which the Stage strip and the folder Rows page use too (S6).
    private func folderHeroPreview(collection: NuvioCollection, folder: CollectionFolder) -> MetaPreview? {
        HomeRowPreviews.folder(collection: collection, folder: folder)
    }

    /// rc14 (BUG-119): the one-line description the hero-off panel shows under a focused
    /// collection folder — the folder's own name (its wordmark may be an image) and how many
    /// sources feed it. Pure so it can be read in a test.
    nonisolated static func folderHeroDescription(collection: NuvioCollection, folder: CollectionFolder) -> String {
        let name = folder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sources = folder.resolvedSources.count
        let count: String
        switch sources {
        case 0: count = String(localized: "Collection folder")
        case 1: count = String(localized: "1 source")
        default: count = String(localized: "\(sources) sources")
        }
        return name.isEmpty ? count : "\(name) \u{00B7} \(count)"
    }

    /// UX-7: adapts a Continue Watching entry to the hero's `MetaPreview` shape so a focused CW
    /// card can drive the hero the same way a catalog poster does. Kotlin default args aren't
    /// exported to Swift, so every `MetaPreview` field has to be supplied explicitly — the fields
    /// CW doesn't carry (rating, popularity, etc.) go in as nil/empty rather than guessed.
    /// Home Stage & Strip (P1 E6): the body lives in `HomeRowPreviews.entry`.
    private func previewFromEntry(_ entry: WatchProgressEntry) -> MetaPreview {
        HomeRowPreviews.entry(entry)
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.isLoading {
            HStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Loading catalogs\u{2026}")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.vertical, Theme.Spacing.xl)
        } else if let message = model.errorMessage {
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.accent)
                .padding(.vertical, Theme.Spacing.xl)
        } else if let message = model.addonManifestError {
            // Upstream 085e8dc6: all add-on manifests failed. Retry is the focusable anchor for
            // this branch (BUG-47 rule) and the honest recovery — the add-ons are installed, their
            // manifests just didn't load.
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Couldn't load your add-ons.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.accent)
                Text(message)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(2)
                Button {
                    AddonRepository.shared.refreshAll()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .buttonStyle(.chip)
            }
            .padding(.vertical, Theme.Spacing.xl)
        } else {
            Text("Setting up your catalogs\u{2026}")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.vertical, Theme.Spacing.xl)
        }
    }
}

/// BUG-30 instrumentation: reports Home's vertical ScrollView contentOffset/contentInsets so an
/// on-device `log show` after a D-pad walk-up can compare where focus-driven scrolling actually
/// rests against the true top. Instrumentation only — attaching/detaching this modifier changes
/// no scrolling, focus, or tab-bar behavior. When `enabled` is false the probe modifier isn't
/// attached at all (see call site), so this type's body never runs and there is zero log output
/// and zero measurable work.
///
/// Each line now carries `residual` and the hero `mode`, and a settled scroll emits one extra
/// `REST` line, so the manual pass MEASURES the walk-up instead of eyeballing the tab bar:
///     grep 'HomeScrollProbe] REST'
/// `residual` is 0 at the true top and positive by exactly how far the rest fell short of it.
fileprivate struct HomeScrollProbeModifier: ViewModifier {
    let enabled: Bool
    /// "classic" / "pinned-hero" / "pinned-panel" — see `HomeView.probeMode(pinned:)`.
    let mode: String

    func body(content: Content) -> some View {
        // `enabled == false` returns bare `content` — onScrollGeometryChange is never attached to
        // the view tree, so there's no closure evaluation, no comparison, and no log output.
        if enabled {
            // Captured by value so the geometry closures hold a plain String, not this modifier.
            let modeName = mode
            content.onScrollGeometryChange(for: String.self, of: { geo in
                let residual = geo.contentOffset.y + geo.contentInsets.top
                return "y=\(Int(geo.contentOffset.y.rounded())) inset=\(Int(geo.contentInsets.top.rounded())) residual=\(Int(residual.rounded()))"
            }, action: { _, v in
                NSLog("[HomeScrollProbe] %@ %@", modeName, v)
                HomeScrollProbeRest.schedule(mode: modeName, line: v)
            })
        } else {
            content
        }
    }
}

/// Debounce behind the probe's `REST` line: the walk-up's animation emits a line per frame, and
/// only the value the scroll SETTLES on answers "did focus-driven scrolling reach the true top".
/// Re-armed on every sample; the last one standing after 400ms of stillness logs. Plain static
/// storage rather than `@State`: every writer is a SwiftUI scroll-geometry callback on the main
/// thread, and a state write here would invalidate Home on every scroll frame — the probe must
/// not perturb the geometry it is measuring.
fileprivate enum HomeScrollProbeRest {
    nonisolated(unsafe) private static var generation = 0

    nonisolated static func schedule(mode: String, line: String) {
        generation &+= 1
        let scheduled = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard scheduled == generation else { return }
            NSLog("[HomeScrollProbe] REST %@ %@", mode, line)
        }
    }
}

/// BUG-30 A/B knob (`debug.homeScrollEdgeHard`, default off): an explicit HARD top scroll-edge
/// treatment for the rows ScrollView. The system tab bar's clipped re-appearance is an edge-state
/// presentation, and this is the only supported lever over it on tvOS 26 — but a hard edge also
/// draws a crisp line across Home's full-bleed hero backdrop, which no simulator gate can judge.
/// Shipping it as a knob lets one device pass compare both states without a rebuild, and leaves
/// the default tree byte-identical. NOT one of the six banned rounds: those all moved the SCROLL
/// (visibility overrides, animation removal, a hero-refocus completion scroll that wedged Down
/// navigation); this changes no scroll position, no focus, and nothing about Menu-to-top.
fileprivate struct HomeScrollEdgeStyleModifier: ViewModifier {
    let hard: Bool

    func body(content: Content) -> some View {
        if hard {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}

/// BUG-112 (Item A), DEBUG-only: see `HomeView.forcedUpFallbackTrigger`. Disabled it applies
/// nothing at all, so the shipped tree is byte-identical.
///
/// BUG-112 review fix (F6): the `#if DEBUG` here is load-bearing, not decorative. `enabled` is
/// already always `false` in Release (`HomeUpFallbackKnobs.forced` is hardcoded there), so the
/// `if enabled` branch below is unreachable in a Release build on its own — but the body is
/// gated too, so Release never even builds an `onPlayPauseCommand` handler wired to this action,
/// and a future edit to `forced` cannot silently reopen the proxy trigger without also touching
/// this file.
fileprivate struct ForcedUpFallbackTriggerModifier: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        #if DEBUG
        if enabled {
            content.onPlayPauseCommand(perform: action)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// BUG-30: extends the classic in-scroll hero's frame upward to the scroll content's true top,
/// bottom-aligning its fixed-height content inside the taller frame so the visible layout is
/// unchanged. `extendedHeight == 0` (the pinned header) collapses to bare `content`, so pinned
/// mode — whose geometry took eight device rounds to settle — is not touched at all. The flag is
/// per call site and constant there, so this never re-identifies the hero mid-browse.
fileprivate struct HeroTopReachModifier: ViewModifier {
    let extendedHeight: CGFloat

    func body(content: Content) -> some View {
        if extendedHeight > 0 {
            content.frame(height: extendedHeight, alignment: .bottom)
        } else {
            content
        }
    }
}

/// FEAT-15: attaches the CAROUSEL's interaction affordances — a focus section around the hero
/// page and the left/right paging handler — only when a carousel actually exists. With Show Hero
/// off the hero region is a display-only panel with no focusable descendant, and neither modifier
/// has anything to act on; `enabled` flips solely with the Show Hero setting, so this never
/// re-identifies the hero mid-browse.
fileprivate struct HeroCarouselInteractionModifier: ViewModifier {
    let enabled: Bool
    let onMove: (MoveCommandDirection) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .focusSection()
                .onMoveCommand(perform: onMove)
        } else {
            content
        }
    }
}

/// FEAT-15: republishes the one Home-catalog setting the Home SCREEN renders from — "Show Hero".
///
/// Why a dedicated observer rather than `HomeCatalogSettingsRepository.shared.snapshot()`: that
/// call runs `ensureLoaded()` and rebuilds the entire preferences map into fresh
/// `HomeCatalogPreference` values every time. `reportRowFocus` could afford that per focus event;
/// `body` cannot afford it per render, and the hero mode is now a rendering decision. This watches
/// the same `uiState` flow `SettingsViewModel` does (so the two never disagree) and keeps a single
/// Bool. Deliberately NOT folded into `HomeViewModel` — that type is shared with other in-flight
/// work; this is a self-contained, cancellable watcher with the same start/stop lifecycle.
@MainActor
final class HomeHeroSettingsObserver: ObservableObject {
    /// Defaults to `true` (the repository's own default) so the first frames behave exactly as
    /// they did before this change. The Home path drives `ensureLoaded()` → `publish()` early —
    /// `AddonRepository.initialize()` → `syncCatalogs`, `CollectionRepository.initialize()` →
    /// `syncCollections` — so a hero-off user's real value lands before rows do.
    @Published private(set) var heroEnabled = true

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        // Codex review: the watcher dies with stop() while Home's tab is hidden, so a Show Hero
        // change made from Settings in the meantime would leave this stale — and a returning
        // Home would mount the retained rows in the WRONG container branch, then structurally
        // swap them when the fresh flow value landed (resetting scroll/focus). Seed
        // synchronously from the repository snapshot before re-subscribing; one snapshot() per
        // Home appearance, not per body pass.
        let current = HomeCatalogSettingsRepository.shared.snapshot().heroEnabled
        if heroEnabled != current { heroEnabled = current }
        watcher = FlowWatcherKt.watch(HomeCatalogSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? HomeCatalogSettingsUiState else { return }
            // Guarded assignment: this flow republishes on every catalog reorder/rename too, and
            // an unconditional write would invalidate Home on each one.
            if self.heroEnabled != state.heroEnabled { self.heroEnabled = state.heroEnabled }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    deinit { watcher?.cancel() }
}

/// UX-7: drives the always-on "focus-follows-backdrop" hero. When focus rests on a poster in a
/// Home catalog row or Continue Watching, the hero adopts that title's artwork/text live; when
/// focus moves to the hero CTA or off every row, the carousel resumes.
///
/// FEAT-15: with Show Hero off this model drives the hero region outright — there is no carousel
/// to resume to, so `focusedItem == nil` resolves to Home's resting title (`heroRestingItem`)
/// instead. Nothing in this class changes between the two modes; the difference lives entirely in
/// what `HomeView.displayHero` falls back to.
///
/// Generation-guarded exactly like `InlineTrailerCardModel`'s dwell timer (see
/// `InlineTrailerCard.swift`): a fast D-pad scrub across a row reports a new item on every card
/// it crosses, and only the one the hand actually stops on may commit — a stale pending Task from
/// an already-superseded report must never land.
@MainActor
final class HomeHeroFocusModel: ObservableObject {
    /// The row-focused item currently driving the hero, or nil when the carousel owns it again.
    @Published private(set) var focusedItem: MetaPreview?
    /// Fired the moment `focusedItem` reverts to nil — either the grace period elapsed or
    /// `cancelAndRevert()` was called. Home uses this to re-stamp its auto-advance timer's "last
    /// change" clock, so the carousel doesn't immediately jump on the very next tick after focus
    /// looks away.
    var onRevert: (() -> Void)?

    /// How long a poster must hold focus before it takes over the hero. Long enough that a fast
    /// scrub across a row commits nothing until the hand actually stops.
    private static let commitDelay: TimeInterval = 0.2
    /// Test seam for `RowStepAB.deferHeroCommitUntilRest`: seconds since the last Home scroll motion.
    nonisolated(unsafe) static var motionClock: () -> TimeInterval = { PinnedRowSettle.secondsSinceMotion() }
    /// Grace period before reverting to nil once focus reports nothing. Bridges the brief gap
    /// between one card losing focus and the next gaining it (row-to-row hops, diagonal D-pad
    /// moves), so the hero doesn't flicker back to the carousel mid-navigation.
    private static let revertGrace: TimeInterval = 0.3

    private var generation = 0
    private var pendingTask: Task<Void, Never>?
    /// Which row's report currently backs `focusedItem` (or the pending commit). Rows update
    /// their `@FocusState` independently on a cross-row hop, so the DESTINATION often reports its
    /// item before the departing row reports `nil` — without this tag, that trailing `nil` would
    /// cancel the destination's pending commit and revert the hero under a still-focused poster
    /// (Codex review finding).
    private var claimSource: String?

    /// beta.19-rc1 verdict (M5, BUG-138): stale hero after a folder. A push takes focus off the
    /// row, the nil report used to revert the hero to the carousel page after `revertGrace`
    /// (painted behind the folder page), and on pop the folder re-reported and paid a commit plus a
    /// resolve, so the carousel title showed for about a second (Steven's video, 2:57.5). While
    /// Home is covered (`HomeView.syncHeroFocusCover`: a push, the Continue Watching stream picker,
    /// the shell) the model is FROZEN: a nil report is ignored and a pending revert is cancelled,
    /// so `focusedItem` and `claimSource` survive the cover.
    private var covered = false
    /// Armed by an uncover: if no report arrives within `uncoverDelay(restoresFocus:)`, the hero
    /// reverts as a nil report would have (focus came back somewhere other than the rows, e.g. the
    /// tab bar). Generation-guarded, and cleared by any report: the FIRST report after the uncover is
    /// the answer, the timer is only the fallback for an uncover that never gets one.
    private var uncoverVerifyTask: Task<Void, Never>?
    /// The fallback after a cover tvOS does not restore row focus from: the shell alone (a tab
    /// switch; focus comes back on the tab bar, never on the card). Short, so a hero left behind by
    /// focus that went elsewhere is corrected quickly.
    nonisolated static let uncoverVerifyDelay: TimeInterval = 0.6
    /// beta.19-rc1 verdict (review r1, A P3): the fallback after a cover tvOS DOES restore focus from
    /// (a pushed folder/Detail page, the Continue Watching stream picker). The restored card's report
    /// is the answer there, and on hardware it may land later than 0.6 s after `homePath` empties
    /// (the pop animation runs first; test90 proves the timing on the simulator only). A 0.6 s check
    /// that lost that race reverted the hero to the carousel, and the late report then re-committed
    /// the folder through a 0.2 s commit plus a resolve: the double swap BUG-138 removes. 1.2 s
    /// doubles the window and still corrects an uncover that never reports; the device pass reads
    /// `[HomeHero] present` after a pop for a second commit to confirm it is enough.
    nonisolated static let uncoverRestoreDelay: TimeInterval = 1.2
    /// Whether the cover in force (or any cover that joined it before it lifted) is one tvOS restores
    /// row focus from. Decides which fallback the uncover arms.
    private var coverRestoresFocus = false

    /// The uncover fallback for a cover of that kind (pure; `HeroFocusCoverTests`).
    nonisolated static func uncoverDelay(restoresFocus: Bool) -> TimeInterval {
        restoresFocus ? uncoverRestoreDelay : uncoverVerifyDelay
    }

    /// Whether `pendingTask` is a revert (a nil report's grace) rather than a commit. A cover
    /// cancels a pending revert but lets a pending COMMIT land: that commit is the card the user
    /// selected from (a select inside the 0.2 s dwell), which is what the pop will restore focus to.
    private var pendingIsRevert = false

    /// beta.19-rc1 verdict (M5, BUG-138): see `covered`. Idempotent.
    ///
    /// beta.19-rc1 verdict (review r1, A P3): `restoresFocus` says whether tvOS hands focus back to
    /// the row card when this cover lifts (a push or the stream picker: true; the shell alone: false).
    /// It picks the uncover fallback (`uncoverDelay`). A cover that joins one already in force can
    /// only lengthen the fallback, never shorten it. Defaults to true, the conservative (longer) wait.
    func setCovered(_ isCovered: Bool, restoresFocus: Bool = true) {
        if isCovered, covered {
            if restoresFocus { coverRestoresFocus = true }
            return
        }
        guard isCovered != covered else { return }
        covered = isCovered
        uncoverVerifyTask?.cancel()
        uncoverVerifyTask = nil
        if isCovered {
            coverRestoresFocus = restoresFocus
            if pendingIsRevert {
                generation &+= 1
                pendingTask?.cancel()
                pendingTask = nil
                pendingIsRevert = false
            }
            return
        }
        let delay = Self.uncoverDelay(restoresFocus: coverRestoresFocus)
        coverRestoresFocus = false
        let generationAtUncover = generation
        uncoverVerifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.covered,
                  self.generation == generationAtUncover else { return }
            self.uncoverVerifyTask = nil
            self.claimSource = nil
            guard self.focusedItem != nil else { return }
            self.focusedItem = nil
            self.onRevert?()
        }
    }

    /// Called on every focus change a row reports — `nil` when nothing in that row holds focus.
    /// `source` is a stable identity for the reporting row (`section.key`, "continue-watching").
    func reportFocus(_ item: MetaPreview?, from source: String) {
        // A nil from a row that doesn't own the current claim is the trailing edge of a
        // cross-row hop; the row that DOES own the claim already spoke for itself.
        if item == nil, let claimSource, claimSource != source { return }
        // beta.19-rc1 verdict (M5, BUG-138): frozen while Home is covered — the nil is focus
        // leaving for the covering screen, not the user leaving the row. A pending revert dies; a
        // pending commit (the card selected inside its dwell) is left to land.
        if item == nil && covered {
            if pendingIsRevert {
                generation &+= 1
                pendingTask?.cancel()
                pendingTask = nil
                pendingIsRevert = false
            }
            return
        }
        // Any real report answers the uncover check (a non-nil one by itself; a nil one through
        // the ordinary revert grace below).
        uncoverVerifyTask?.cancel()
        uncoverVerifyTask = nil
        if item != nil { claimSource = source }

        // Already the committed TITLE (or already nil, reporting nil again): don't restart timers
        // — otherwise every re-render-driven refocus of the same card would keep pushing the
        // commit out. But a PENDING task must still die here: without that, a commit scheduled
        // for a card the focus already left lands late and drives the hero from a stale poster
        // (e.g. skim onto a card, then into a collection row before the 0.2s commit — the leaving
        // row's nil report matched this guard and the stale commit fired anyway; Codex review
        // finding).
        if (item == nil && focusedItem == nil)
            || (item != nil && focusedItem?.id == item?.id && focusedItem?.type == item?.type) {
            generation &+= 1
            pendingTask?.cancel()
            pendingTask = nil
            pendingIsRevert = false
            if item == nil { claimSource = nil }
            // Same title ≠ same preview: one id can be represented by different previews across
            // rows (a Continue Watching adaptation carries no description; a catalog card does).
            // Adopt the newly focused card's content immediately — the title is already
            // committed, so there's no dwell to honor — and leave a byte-identical re-report as
            // the pure no-op it should be (Codex review finding).
            if let item, focusedItem?.isEqual(item) != true {
                requestLogoIfNeeded(item)
                focusedItem = item
                enrichIfNeeded(item)
            }
            return
        }

        generation &+= 1
        let generationAtStart = generation
        pendingTask?.cancel()

        if let item {
            pendingIsRevert = false
            pendingTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.commitDelay * 1_000_000_000))
                guard !Task.isCancelled, let self, self.generation == generationAtStart else { return }
                // beta.18 verdict (BUG-126): with `RowStepAB.deferHeroCommitUntilRest`, hold the
                // commit (logo lookup, hero crossfade, enrichment) until the engine's reveal motion
                // has been quiet for 0.12 s, polling every 50 ms, capped at 0.5 s. A newer focus
                // report bumps `generation` and voids the wait.
                if RowStepAB.isSet(RowStepAB.deferHeroCommitUntilRest, in: RowStepAB.mask) {
                    var elapsed: TimeInterval = 0
                    while let wait = RowStepAB.heroCommitDelay(sinceMotion: Self.motionClock(), elapsed: elapsed) {
                        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                        elapsed += wait
                        guard !Task.isCancelled, self.generation == generationAtStart else { return }
                    }
                }
                self.requestLogoIfNeeded(item)
                self.focusedItem = item
                self.enrichIfNeeded(item)
            }
        } else {
            pendingIsRevert = true
            pendingTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.revertGrace * 1_000_000_000))
                guard !Task.isCancelled, let self, self.generation == generationAtStart else { return }
                self.pendingIsRevert = false
                self.focusedItem = nil
                self.claimSource = nil
                self.onRevert?()
            }
        }
    }

    /// FEAT-42: kicks a `TitleLogoStore` lookup for a card that is ABOUT to take over the hero —
    /// called immediately before both `focusedItem = item` publishes above (the same-title
    /// fast-path and the dwell-committed path), never from the raw per-card focus report, so a
    /// fast scrub across a row spends nothing: only the item the hand actually settles on (or
    /// re-settles on) ever reaches this. `HeroArtResolver.present`'s own `logoPlan` reads whatever
    /// this starts, so by the time `present` runs for this item a lookup already has a head start
    /// on the resolve's `laterSwapDeadline` window.
    ///
    /// Two guards: a collection folder already carries its OWN logo (`titleLogoUrl`, via
    /// `folderHeroPreview`) or none at all — either way it has no sensible TMDB id to look up
    /// under, matching `logoPlan`'s own folder short-circuit. And `isLookupCandidate` skips an
    /// item that already has a usable `logo` string — nothing to look up.
    private func requestLogoIfNeeded(_ item: MetaPreview) {
        guard !isCollectionHero(item) else { return }
        guard TitleLogoStore.isLookupCandidate(item.logo) else { return }
        TitleLogoStore.shared.lookupIfNeeded([item])
    }

    /// Addons frequently represent absent metadata as `""` rather than nil (HomeCatalogParser
    /// preserves whatever the addon sent), so "missing" must cover both.
    private func nonBlank(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// A catalog/CW preview commonly omits `description`/`banner` (Home only fetches the light
    /// list shape). Once a card commits to being the hero, fill those two gaps from TMDB — same
    /// service Detail already leans on — so the hero shows a synopsis instead of blank space.
    /// Fire-and-forget: on any miss (TMDB disabled, no key, no match, network failure) the hero
    /// simply keeps showing what it already had.
    ///
    /// BUG-42 scope decision (2026-08-05). The shared publish is now enrichment-FIRST: the hero
    /// carousel's items, and any row item the hero already fetched, arrive from
    /// `HomeRepository.publishCurrentState` already localized, so this layer is no longer the
    /// carousel's enrichment path — it only ever runs for a row poster that took over the hero
    /// (UX-7), and only for items the shared overlay does not cover. It is kept for exactly that
    /// surface, and reduced to a strict GAP FILL: it may add a synopsis/backdrop/logo/genres the
    /// preview never had, but it may NEVER replace a field that is already on screen. Replacing
    /// the committed title with TMDB's localized one is what produced the raw-then-localized
    /// double commit this fix removes ("The Devil's Mouth" swapping to "La Bouche du Diable"), and
    /// the focus takeover has no hold to hide it behind — it must commit the instant focus dwells.
    /// Consequence to know about: a focused row card outside the hero's fetched set shows its
    /// addon (usually English) title — matching the card under it — while its filled-in synopsis
    /// can be localized. Closing that gap means localizing row metadata broadly, which is the
    /// fetch-volume product call flagged in `HomeRepository.withTmdbEnrichment`, not a change here.
    private func enrichIfNeeded(_ item: MetaPreview) {
        // BUG-38 round three: a collection folder's preview is not a title — TMDB has nothing
        // for its synthetic id, and its artwork is already the user's configured assets.
        guard !isCollectionHero(item) else { return }
        guard nonBlank(item.description_) == nil || nonBlank(item.banner) == nil else { return }
        let settings = TmdbSettingsRepository.shared.snapshot()
        // rc13: `hasApiKey` is gone — the TMDB key is bundled at build time (`TmdbConfig.API_KEY`),
        // so "enabled" is the whole gate now.
        guard settings.enabled,
              settings.useArtwork || settings.useBasicInfo else { return }
        // suspend fun → Swift completion; result may arrive off the main thread, so hop back
        // (same convention as PersonDetailViewModel.start()).
        // FEAT-42 crash fix (2026-09-12): calls `fetchPreviewEnrichmentChecked`, not the
        // unchecked `fetchPreviewEnrichment` — a suspend function exported without `@Throws`
        // treats any non-cancellation exception as unhandled and aborts the process, which is
        // what `TitleLogoStore.lookupOne` hit under `-debug.heroLogoStoreOnly` (see its doc).
        TmdbMetadataService.shared.fetchPreviewEnrichmentChecked(
            type: item.type, id: item.id, settings: settings
        ) { [weak self] enrichment, error in
            DispatchQueue.main.async {
                guard error == nil else {
                    NSLog("[HomeHeroFocusModel] enrichIfNeeded failed item=%@ error=%@", item.id, String(describing: error))
                    return
                }
                // Merge whenever THIS title still (or again) owns the hero — identity, not
                // generation: a same-item refocus inside the grace window bumps the generation
                // without recommitting, and a generation gate here silently threw away the
                // in-flight enrichment for the title actually on screen (Codex review finding).
                // A different committed title fails the id/type check and rejects as before.
                // The merge BASE is the currently committed preview, not this request's `item`:
                // the same id may have been re-adopted from a richer row (CW → catalog) while the
                // fetch was in flight, and rebuilding from the stale capture would roll that back.
                guard let self, let enrichment, enrichment.hasContent(),
                      let base = self.focusedItem,
                      base.id == item.id, base.type == item.type
                else { return }
                // Field gating mirrors the shared hero path (HomeRepository.withTmdbEnrichment):
                // artwork fields only under useArtwork, text fields only under useBasicInfo — a
                // focused-row hero must not bypass the user's TMDB category preferences.
                let useArtwork = settings.useArtwork
                let useBasicInfo = settings.useBasicInfo
                let mergedBanner = self.nonBlank(base.banner) ?? (useArtwork ? enrichment.backdrop : nil)
                let mergedLogo = self.nonBlank(base.logo) ?? (useArtwork ? enrichment.logo : nil)
                let mergedDescription = self.nonBlank(base.description_) ?? (useBasicInfo ? enrichment.description_ : nil)
                let mergedGenres = base.genres.isEmpty && useBasicInfo ? enrichment.genres : base.genres
                // H-1C (beta.15): `enrichment.hasContent()` above only says the RESPONSE carried
                // something — not that the merge just computed actually ADDED anything to THIS
                // base. Every field it could fill may already be non-blank (the gap-fill guard at
                // the top of this function already required BOTH description and banner to be
                // present for it to have run at all — description alone, or banner alone, still
                // gets here with nothing left to fill), or gating (useArtwork/useBasicInfo off)
                // may zero out everything enrichment offered. A same-content reassignment still
                // republishes `focusedItem` — `@Published` doesn't check equality — which restarts
                // `HeroCrossfadeImage`'s `.task(id:)` for the row-focus hero path with nothing to
                // show for it. Skip the assignment entirely when nothing actually changed.
                // Codex wave-3 r2 (P2): compare NORMALIZED against normalized — an absent field is
                // commonly `""` in addon previews, which `nonBlank` maps to nil; comparing the
                // merged nil against the raw `""` would read as a change and republish a
                // semantically identical item, restarting the image task for nothing.
                guard mergedBanner != self.nonBlank(base.banner) || mergedLogo != self.nonBlank(base.logo) ||
                      mergedDescription != self.nonBlank(base.description_) || mergedGenres != base.genres
                else { return }
                self.focusedItem = MetaPreview(
                    id: base.id,
                    type: base.type,
                    // BUG-42: the committed title is left alone. Carousel parity no longer needs an
                    // override here — a row item the hero also carries is localized by the SHARED
                    // publish, so both copies already agree — and swapping a title the viewer is
                    // reading is the exact double commit this fix removes (see the doc comment).
                    name: base.name,
                    poster: base.poster,
                    banner: mergedBanner,
                    logo: mergedLogo,
                    posterShape: base.posterShape,
                    description: mergedDescription,
                    releaseInfo: base.releaseInfo,
                    rawReleaseDate: base.rawReleaseDate,
                    popularity: base.popularity,
                    voteCount: base.voteCount,
                    imdbRating: base.imdbRating,
                    genres: mergedGenres,
                    rawPosterUrl: nil,
                    landscapePoster: nil,
                    rawLandscapePosterUrl: nil,
                    customPosterApplied: false
                )
            }
        }
    }

    /// Hard reset: the CTA reclaimed the hero, or the row is going away. No grace period — this
    /// is a deliberate hand-back, not a between-cards focus hop.
    func cancelAndRevert() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
        pendingIsRevert = false
        uncoverVerifyTask?.cancel()
        uncoverVerifyTask = nil
        claimSource = nil
        let wasCommitted = focusedItem != nil
        focusedItem = nil
        if wasCommitted { onRevert?() }
    }
}

/// Wave H (BUG-86 phenomena B/C/D, BUG-90): everything the hero paints for ONE item, committed as a
/// single value. Before this type the hero was three independent paint pipelines racing each other —
/// text driven straight off `displayHero`, the backdrop cross-fading inside `HeroCrossfadeImage`
/// 0.3–0.5s behind it, and `HeroLogo` running its own `.task` that swapped Text→Image under its own
/// `withAnimation`. The tester filmed all three: the old backdrop under the new title (C), the title
/// text and the title logo drawn superimposed on every hero change (B), and a folder cover painting
/// before the folder backdrop (D). One value, committed once, removes the races by construction:
/// there is no state in which the hero shows one item's text over another item's artwork.
///
/// `backdrop`/`logo` are the DECODED bitmaps, not URLs — resolution happens in `HeroArtResolver`
/// before the commit, so a renderer can never be mid-fetch. `logo == nil` after the resolver's
/// deadline means "this item has no logo (or it did not arrive in time)": `HeroLogo` draws the text
/// wordmark, and a logo that lands later is DROPPED rather than swapped in behind the reader's eyes.
struct HeroPresentation: Equatable {
    let item: MetaPreview
    let backdrop: UIImage?
    let logo: UIImage?
    /// `"\(type):\(id)"` — the same stable identity `HeroCrossfadeImage` keys its paint bookkeeping
    /// on, so the two agree about what "the same item" means.
    let identity: String
    /// beta.19-rc1 verdict (M5, BUG-138): how `HeroLogo` must draw `logo` (`.dark` = a near-black
    /// wordmark drawn as a white silhouette). Decided by `HeroArtResolver` before the commit. A
    /// `.blank` verdict is committed with `logo == nil` (the text wordmark), so `HeroLogo` never
    /// receives a bitmap marked blank; the verdict is kept for the `present … logoInk=` probe. A
    /// `var` with a default so the memberwise init stays source-compatible (critique #25).
    var logoInk: HeroLogoInk = .legible

    /// `MetaPreview` is a Kotlin export and does not conform to Swift's `Equatable`, so the
    /// synthesized conformance is unavailable; images compare by REFERENCE (`ArtworkStore` hands out
    /// one decoded instance per URL, so identity is the honest test and pixel comparison would be
    /// absurd here).
    static func == (lhs: HeroPresentation, rhs: HeroPresentation) -> Bool {
        lhs.identity == rhs.identity
            && lhs.backdrop === rhs.backdrop
            && lhs.logo === rhs.logo
            && lhs.logoInk == rhs.logoInk
            && lhs.item.isEqual(rhs.item)
    }
}

/// Wave H rule (3): a hero item is painted only when its backdrop AND its logo are resolved, or a
/// deadline passed — and text, logo and backdrop then change in ONE transaction.
///
/// beta.19-rc1 verdict (M5, BUG-138): still one commit, but the TEXT (logo wordmark, meta line,
/// synopsis) is then phased by `HeroTextLayer`: the old text fades out over 0.12 s and the new text
/// is swapped in while invisible, so the two are never on screen together. The artwork follows the
/// commit at once, as before.
///
/// `HomeView.displayHero` remains the TARGET (what focus/the carousel/the settings say the hero
/// SHOULD be showing); `presented` is what is actually on screen. They differ only for the length of
/// one resolve, which is bounded by `laterSwapDeadline` (`folderDeadline` for collection folders).
///
/// Cache-warm path (the overwhelmingly common one, since every row focus prefetches its backdrops
/// and logos): both bitmaps are already resident, `present` commits synchronously inside one
/// `withAnimation`, and nothing ever renders half a hero. Cold path: the PREVIOUS presentation stays
/// on screen — never a blank, never a poster stand-in — while both fetches race a deadline, and
/// whatever has landed when the deadline (or the second fetch) fires is committed, once.
///
/// Late arrivals are dropped on purpose. A logo that resolves after its item was committed with the
/// text wordmark would be exactly the Text→Image swap this class exists to remove (BUG-90); the item
/// picks it up from cache the next time it is presented.
///
/// FEAT-42: which of four places the currently PRESENTED logo bitmap came from (or `.none` for no
/// logo / the text wordmark) — see `presentedLogoSource` and `HeroLogoPlan`.
enum HeroLogoSource: String {
    /// The item's own `logo` field, already populated by the shared layer or a row's addon.
    case addon
    /// `TitleLogoStore`'s own TMDB preview-enrichment lookup — the FEAT-42 path that reaches
    /// catalog items the shared enrichment overlay never touched (past `HOME_ROW_ENRICHMENT_PREFIX`,
    /// or a TMDB-id catalog the overlay skips entirely).
    case tmdb
    /// The synthesized `images.metahub.space/logo/medium/<imdb id>/img` guess for IMDb-backed
    /// items — synchronous by construction (no lookup to wait on), so Cinemeta rows never pay the
    /// `.pending` cost.
    case metahub
    /// No logo bitmap is presented — no candidate resolved (a plain miss, or nothing to look up),
    /// or the resolve hit its deadline before one arrived. `HeroLogo` draws the text wordmark.
    case none
}

/// FEAT-42: what `HeroArtResolver.logoPlan` decided to do about a target's logo BEFORE any fetch
/// runs. `.url` already carries the `HeroLogoSource` it will present if the fetch lands; `.pending`
/// means a `TitleLogoStore` lookup is already in flight and worth waiting on (inside the existing
/// `laterSwapDeadline` — no new budget); `.none` means there is nothing to look up or wait for.
enum HeroLogoPlan: Equatable {
    case url(URL, HeroLogoSource)
    case pending
    case none
}

extension RowRestSource {
    /// beta.19-rc1 verdict (review r1, A P2): the rows have not moved for
    /// `TrailerStartGate.restQuiet`, whatever the settle corrector's pending flag says: `isAtRest()`
    /// with `restPending` read as false, over the same clocks per source. The hero sharpen's rest
    /// ceiling releases only on a quiet stretch (`HeroSharpen.restStep`'s `quietAge`), so a stuck
    /// settle decision gives way and real motion never does.
    @MainActor var rowsQuiet: Bool {
        let since: TimeInterval
        switch self {
        case .motionClock:
            since = RowsMotionClock.secondsSinceMotion()
        case .pinnedHome:
            since = min(PinnedRowSettle.secondsSinceMotion(), RowsMotionClock.secondsSinceMotion())
        case .custom(let signal):
            since = signal.secondsSinceMotion
        }
        return TrailerStartGate.isAtRest(sinceMotion: since, restPending: false)
    }
}

@MainActor
final class HeroArtResolver: ObservableObject {
    /// The hero that is actually painted. `nil` = no hero region at all (the same state
    /// `displayHero == nil` produced before this type existed).
    @Published private(set) var presented: HeroPresentation?

    /// FEAT-42: where `presented`'s logo bitmap came from — `.none` when `presented` has no logo
    /// (or `presented` itself is nil). Set inside the SAME animation transaction as `presented` in
    /// every commit path (`commit`, the same-identity gap-fill branch, `adoptLateBackdrop`, and the
    /// nil-target revert in `present`), so a viewer can never observe `presented` and
    /// `presentedLogoSource` disagreeing about the same hero. Not part of `HeroPresentation`
    /// itself/`HeroPresentation.==` — it is diagnostic (the `debug_hero` `plgs=` field, the
    /// `hero_probe_blob` `logoSrc=` field), not something any renderer branches on.
    @Published private(set) var presentedLogoSource: HeroLogoSource = .none

    /// How long a swap between two TITLES waits for cold artwork before committing with whatever
    /// landed. Titles always have a poster on their card, and the resolve now falls back to it
    /// inside this same budget, so a miss here is a short wait on the previous hero and then the
    /// poster, never a blank screen.
    static let laterSwapDeadline: UInt64 = 400_000_000
    /// Collection folders get longer: their artwork is the user's own configured backdrop/logo, it
    /// has no poster stand-in (`folderHeroPreview` passes `poster: nil` on purpose), and the row's
    /// `.onAppear` prefetch usually makes this moot anyway.
    ///
    /// 2026-09-08: rig-only knob so `HeroFolderSwapTests` can force a deadline miss and prove the
    /// `adoptLateBackdrop` late-arrival path — on the simulator's real image hosts the fetch
    /// routinely answers in under 60 ms, well inside even a shortened deadline, so the rig needs a
    /// way to make the miss happen on demand rather than hoping for a slow network. `#if DEBUG`
    /// only: the `debug.heroFolderDeadlineMs` launch/default override is never read in a release
    /// build, where `folderDeadline` stays the plain compile-time constant it always was — the
    /// `#if DEBUG` guard is the whole point, not an incidental detail. Read via
    /// `UserDefaults.integer(forKey:)`, not `object(forKey:) as? Int` — a `-debug.heroFolderDeadlineMs
    /// <ms>` launch argument lands in the argument domain as a STRING, and `as? Int` on a string
    /// always fails, silently disarming the knob; `integer(forKey:)` coerces it (and answers `0`,
    /// treated below as "absent", for any key that is missing entirely). Read once (`UserDefaults`
    /// lookups are not free on a hot path this is adjacent to) and cached in a `static let`, so a
    /// value set before launch (via `-debug.heroFolderDeadlineMs <ms>` or a prior `defaults write`)
    /// applies for the whole process lifetime.
    #if DEBUG
    private static let debugFolderDeadlineOverrideMs: Int =
        UserDefaults.standard.integer(forKey: "debug.heroFolderDeadlineMs")
    static var folderDeadline: UInt64 {
        if debugFolderDeadlineOverrideMs > 0 { return UInt64(debugFolderDeadlineOverrideMs) * 1_000_000 }
        return 1_500_000_000
    }
    #else
    static let folderDeadline: UInt64 = 1_500_000_000
    #endif

    /// `defaults write com.nuvio.media.NuvioTV debug.heroLogoStoreOnly -bool YES`, or as a launch
    /// argument on device/CI/UI tests. When set, `present` calls `logoPlan` with `addonLogo: nil`
    /// and `allowMetahub: false`, so a logo can only ever come from `TitleLogoStore` (steps 3/5 of
    /// `logoPlan`'s doc comment) — never the item's own logo (step 1) or the synchronous metahub
    /// guess (step 4).
    ///
    /// Exists so `test62HeroLogoOnRowFocus` can prove the store path deterministically. In
    /// production, and on the fixture `test62` walks, a row's own logo (filled in by the Kotlin row
    /// overlay for its leading items) or the metahub guess almost always resolves before the store
    /// does, so `plgs=tmdb` on any given card was only ever provable by timing luck, not by
    /// contract. This knob removes both faster candidates so every read that produces a logo at all
    /// is forced through the store, without changing `logoPlan`'s priority order for anyone who
    /// hasn't passed it.
    ///
    /// Production never sets this — an item's own logo and the metahub guess are both legitimate
    /// candidates, and disabling them here would blank real heroes that have neither a resolved
    /// store URL nor a pending lookup. `#if DEBUG` only, matching `debugFolderDeadlineOverrideMs`
    /// immediately above: never read in a release build, where `heroLogoStoreOnly` is a compile-time
    /// `false` and `present` always passes `allowMetahub: true` and the item's own logo unchanged.
    #if DEBUG
    private static let heroLogoStoreOnlyByKnob =
        UserDefaults.standard.bool(forKey: "debug.heroLogoStoreOnly")
    static var heroLogoStoreOnly: Bool { heroLogoStoreOnlyByKnob }
    #else
    static let heroLogoStoreOnly: Bool = false
    #endif

    /// The in-flight resolve, if any. Also the whole of `isIdle` — the carousel's auto-advance tick
    /// must not page while a commit is pending, or the resolve it started is thrown away and the
    /// next page starts cold (the same reason the tick already holds for a trailer attempt).
    private var resolveTask: Task<Void, Never>?
    /// The identity the newest `present` call asked for. A resolve that finishes after a newer call
    /// has superseded it fails this check and commits nothing.
    private var targetIdentity: String?
    /// The item the newest `present` call asked for, kept whole so a repeat call with a
    /// byte-identical target can be recognised as the no-op it is — see the guard in `present`.
    private var lastTarget: MetaPreview?

    /// rc12 (Codex Finding A): when the FIRST `present` for the CURRENT `targetIdentity` started
    /// resolving, so a later `present` for that same identity inherits the original budget instead
    /// of restarting it (see `resolveDeadline` and the wiring in `present`). nil whenever no resolve
    /// is outstanding for the current target: cleared with the target itself, reset to nil the
    /// moment the identity changes, and cleared again on the cache-warm path that commits without
    /// starting a resolve at all.
    private var targetResolveStartedAt: Date?

    // beta.19-rc1 verdict (I1, BUG-134): the post-commit sharpen (`HeroSharpen`). None of these is
    // `@Published`: they decide what to fetch, never what to draw, so nothing re-renders on them.

    /// The form the presented backdrop is drawn in. `HomeView` sets it (`setSharpenForm`).
    private(set) var sharpenForm: HeroSharpen.Form = .classic
    /// The URL the presented backdrop bitmap was decoded from. nil when there is no backdrop, and for
    /// the poster stand-in: a different picture, which is never sharpened.
    private var presentedBackdropURL: URL?
    /// beta.19-rc1 verdict (review r2, P3-2): the presented backdrop is the card-size stand-in (the
    /// same picture, `backdrop=small`), committed because the legacy re-decode missed the deadline.
    /// That legacy decode, landing late, may replace it (`adoptLateBackdrop`); nothing else may. Set
    /// by `commit`, cleared by any commit or sharpen that puts another backdrop on screen. A plain
    /// stored property: nothing draws from it.
    private var presentedBackdropIsStandIn = false
    /// beta.19-rc1 verdict (review r3, P3 #1): which `commit` put the presentation on screen (bumped
    /// by every commit that changes it) and when (`systemUptime`). The late stand-in replacement
    /// waits out that commit's own backdrop cross-fade (`lateStandInFadeWait`) and replaces only the
    /// stand-in of the commit it was called for. Plain stored properties: nothing draws from them.
    private var presentedCommitSerial = 0
    private var presentedCommittedAt: TimeInterval = 0
    /// The URL the presented logo bitmap was decoded from (nil = the text wordmark). The `.pending`
    /// path learns it from `TitleLogoStore.awaitLogoURL` (`HeroPresentArtWait.logoURL`).
    private var presentedLogoURL: URL?
    /// The dwell, then the fetch, for the hero on screen. Cancelled by any `present` that moves the
    /// hero to another identity; not counted by `isIdle`, so it never holds the carousel tick.
    private var sharpenTask: Task<Void, Never>?
    /// Bumped by every schedule and cancel. A sharpen whose generation moved adopts nothing.
    private var sharpenGeneration = 0
    /// beta.19-rc1 verdict (review r1, A P2): the rows' rest signal the sharpen waits on before it
    /// fetches and again before it adopts (`HeroSharpen.restStep`). `HomeView` assigns it from the
    /// same place, and with the same value, as the hero trailer model's (`.onAppear` and
    /// `.onChange(of: heroContainerPinned)`): pinned Home reads the settle corrector plus the rows'
    /// motion clock, classic Home the clock alone. A plain stored property: nothing draws from it,
    /// and HomeView's body observes nothing new.
    var restSource: RowRestSource = .motionClock

    var isIdle: Bool { resolveTask == nil }

    /// rc12 (Codex Finding A): the ABSOLUTE deadline rule for a resolve that is restarted for the
    /// SAME target identity.
    ///
    /// `present` is driven from two `.onChange`s and a same-identity payload update (a synopsis or
    /// a genre list landing from TMDB, `heroPayloadSignature` moving) cancels the resolve in flight
    /// and starts a new one. The same-identity branch further up only short-circuits an
    /// already-PRESENTED title, so while the FIRST resolve is still running each such update used
    /// to hand the new resolve a fresh `laterSwapDeadline` — Codex measured an update at 300 ms
    /// holding the PREVIOUS title on screen until 496 ms, where the pre-rc12 warm-backdrop case
    /// committed immediately. Budgets must not be stackable: the viewer is looking at a stale hero
    /// for the sum, not for one 400 ms window.
    ///
    /// So the wait inherits the first present's clock. `previousStart` is when this identity first
    /// began resolving (nil for a genuinely new target, which gets the whole `budget`); the answer
    /// is whatever is LEFT of `budget`, and 0 once it is spent — a zero-nanosecond sleep, which
    /// fires the deadline on the next turn and commits whatever is ready (the existing
    /// deadline-commit path, unchanged). A non-positive `elapsed` (a clock that moved backwards)
    /// answers the full budget rather than a negative remainder.
    ///
    /// BUG-90 is untouched: this only ever SHORTENS how long the previous hero is held, and a logo
    /// or backdrop that lands after the deadline is still dropped by `HeroPresentArtWait`, never
    /// swapped in behind the reader's eyes.
    nonisolated static func resolveDeadline(previousStart: Date?, now: Date, budget: UInt64) -> UInt64 {
        guard let previousStart else { return budget }
        let elapsed = now.timeIntervalSince(previousStart)
        guard elapsed > 0 else { return budget }
        let elapsedNanos = elapsed * 1_000_000_000
        let budgetNanos = Double(budget)
        guard elapsedNanos < budgetNanos else { return 0 }
        return UInt64((budgetNanos - elapsedNanos).rounded())
    }

    /// FEAT-42: decides where (if anywhere) a target's presented logo should come from, in
    /// priority order, BEFORE any fetch runs. Pure and `nonisolated static` so
    /// `HeroLogoPlanTests` can drive every combination directly.
    ///
    /// 1. `addonLogo` — the item's own `logo` field wins outright when it is non-blank and
    ///    parses as a URL. A blank string or one that fails `URL(string:)` falls through to the
    ///    next step rather than producing a broken `.url`.
    /// 2. `isFolder` — a collection folder never gets a store/metahub lookup: it has no sensible
    ///    TMDB id to look up under (`folderHeroPreview` already sets its OWN `logo` from
    ///    `titleLogoUrl` when it has one, which step 1 already covers), so this stops here at
    ///    `.none` rather than falling through to metahub with a folder's synthetic id.
    /// 3. `storeURL` — `TitleLogoStore`'s own resolved TMDB lookup, when one already landed.
    ///    Checked BEFORE metahub deliberately: metahub is a synthesized guess that often 404s,
    ///    while a resolved TMDB URL is a confirmed hit — a stale metahub source must never win
    ///    once the real answer is in hand.
    /// 4. Metahub — synthesized only for IMDb-backed ids (`tt…`, and season/episode-suffixed ids
    ///    like `tt…:1:1`, whose first `:`-separated component is checked). Synchronous by
    ///    construction (no network round trip to decide this branch), so Cinemeta rows never pay
    ///    the `.pending` wait — and it is checked BEFORE `.pending` so an IMDb item with a lookup
    ///    still in flight uses the synchronous guess rather than waiting on the store (a lookup
    ///    that finishes later still wins on this item's NEXT presentation via step 3). Skipped
    ///    entirely when `allowMetahub` is `false` — the plan falls straight through to step 5.
    /// 5. `storePending` — a `TitleLogoStore` lookup is in flight and this item has no faster
    ///    candidate; `.pending` tells `present` to wait for it inside the existing
    ///    `laterSwapDeadline`, never a new budget.
    /// 6. `.none` — nothing to show and nothing to wait for. This is also where a TMDB-disabled
    ///    session lands by construction: with TMDB off `TitleLogoStore` never writes a `.pending`
    ///    entry (`lookupIfNeeded`'s own settings guard), so `storeURL` is always nil and
    ///    `storePending` is always false here — no separate "is TMDB on" parameter is needed.
    ///
    /// `allowMetahub` defaults to `true` for every existing caller and test. `present` passes
    /// `false` only under the `debug.heroLogoStoreOnly` `#if DEBUG` launch knob (see
    /// `HeroArtResolver.heroLogoStoreOnly`'s doc comment) — a UI-test-only way to prove the store
    /// path deterministically on a fixture whose faster candidates (an item's own logo, or the
    /// metahub guess) would otherwise almost always win first. Production never passes `false`.
    nonisolated static func logoPlan(addonLogo: String?, id: String, isFolder: Bool,
                                     storeURL: String?, storePending: Bool,
                                     allowMetahub: Bool = true) -> HeroLogoPlan {
        if let addonLogo, !addonLogo.isEmpty, let url = URL(string: addonLogo) {
            return .url(url, .addon)
        }
        if isFolder { return .none }
        if let storeURL, !storeURL.isEmpty, let url = URL(string: storeURL) {
            return .url(url, .tmdb)
        }
        if allowMetahub {
            let imdbId = id.split(separator: ":").first.map(String.init) ?? id
            if imdbId.hasPrefix("tt"),
               let url = URL(string: "https://images.metahub.space/logo/medium/\(imdbId)/img") {
                return .url(url, .metahub)
            }
        }
        if storePending { return .pending }
        return .none
    }

    /// Point the hero at `target`. Cancels any resolve in flight; the previous presentation stays on
    /// screen until this one can be committed whole.
    func present(_ target: MetaPreview?, isFolder: Bool) {
        // Idempotent by contract. `HomeView` drives this from TWO `.onChange`s — the target's
        // identity and the target's payload — and a genuinely new hero changes both, so the second
        // one arrives with nothing left to do. Without this guard that repeat would cancel and
        // restart a resolve that had just started, resetting its deadline clock, and re-run the
        // same-identity branch below for a payload that had not moved at all.
        if let target, let last = lastTarget,
           "\(target.type):\(target.id)" == targetIdentity, last.isEqual(target) { return }
        if target == nil, targetIdentity == nil, lastTarget == nil { return }
        lastTarget = target
        resolveTask?.cancel()
        resolveTask = nil

        guard let target else {
            targetIdentity = nil
            targetResolveStartedAt = nil
            // beta.19-rc1 verdict (I1, BUG-134): no hero, nothing to sharpen.
            cancelSharpen()
            guard presented != nil else { return }
            presentedBackdropURL = nil
            presentedBackdropIsStandIn = false
            presentedLogoURL = nil
            // FEAT-42: reset together with `presented`, in the same transaction — see
            // `presentedLogoSource`'s doc comment on why the two may never disagree.
            withAnimation(.easeInOut(duration: 0.3)) {
                presented = nil
                presentedLogoSource = .none
            }
            return
        }

        let identity = "\(target.type):\(target.id)"
        // rc12 (Codex Finding A): read the OUTGOING target before overwriting it. A present for the
        // identity that is already the target inherits that target's resolve clock (see
        // `resolveDeadline`); any other present is a genuinely new swap and starts a fresh budget,
        // which is what a nil inheritance means.
        let inheritedResolveStart = targetIdentity == identity ? targetResolveStartedAt : nil
        targetIdentity = identity
        targetResolveStartedAt = inheritedResolveStart

        // Same item, new payload: the ONE change allowed after a commit (Wave H invariant 2) is a
        // silent gap-fill of text the item did not carry when it was committed — a synopsis landing
        // from TMDB, say. The artwork is kept exactly as it is: re-resolving it here is the
        // raw-then-enriched repaint the tester filmed, and `same=1` on the probe line is precisely
        // the signature a healthy launch must not contain.
        if identity == presented?.identity, let current = presented {
            // beta.19-rc1 verdict (M5): the logo's ink verdict rides along with the logo bitmap.
            let refreshed = HeroPresentation(item: target, backdrop: current.backdrop,
                                             logo: current.logo, identity: identity,
                                             logoInk: current.logoInk)
            // beta.19-rc1 verdict (I1, BUG-134): a gap-fill keeps the artwork, so it keeps a
            // pending sharpen as well. A hero the target has come BACK to (A → B → A before B
            // committed, which cancelled A's sharpen) arms one again; `HeroSharpen.plan` makes a
            // re-arm on a hero that is already sharp a no-op (`sharpen none`).
            if sharpenTask == nil { scheduleSharpen(identity: identity) }
            guard refreshed != current else { return }
            // `same=1` means REPAINT: the probe line the photo contract forbids on a healthy
            // launch.
            //
            // Internal review r1 (P2), the contract it now encodes. The old test compared the two
            // BITMAPS, which could never differ - `refreshed` is built from `current.backdrop` and
            // `current.logo` by construction, so `!==` was structurally false and `same=1` was
            // unreachable. That made test31's `same=1` filter vacuous and, worse, hid the one
            // same-identity path that DOES repaint text the viewer is reading: `enrichIfNeeded`
            // (and a Kotlin re-publish) moving `name` / `genres` / `releaseInfo` / `description` at
            // a stable identity - the English-replaced-by-French flip the tester filmed.
            //
            // So the test is now what actually changes ON SCREEN (see `isVisibleRepaint`), and a
            // text repaint after the commit IS a violation. The ONE exception, the allowed silent
            // gap-fill, is a field that was empty or nil being FILLED - a synopsis or a genre list
            // landing from TMDB for an item committed without one. That adds text, replaces
            // nothing, and stays silent.
            //
            // A refresh that changes nothing visible still logs nothing at all, deliberately,
            // rather than a `same=0` line: Leg C counts one `paint` per `present` for the focused
            // folder and a present-with-no-paint would break that count.
            if HeroArtResolver.isVisibleRepaint(current: current.item, target: target) {
                // FEAT-42: the logo bitmap is untouched here (built from `current.logo` above,
                // same as the backdrop) — `presentedLogoSource` is passed through unchanged for
                // the log line, never recomputed, since a gap-fill never re-resolves artwork.
                logPresent(identity: identity,
                           backdrop: refreshed.backdrop != nil ? "cached" : "none",
                           logo: refreshed.logo != nil ? "cached" : "text",
                           logoOrigin: presentedLogoSource,
                           logoInk: refreshed.logoInk,
                           waitedMs: 0, same: true)
            }
            presented = refreshed   // deliberately unanimated: a gap-fill must not move anything
            return
        }

        // beta.19-rc1 verdict (I1, BUG-134): the hero is moving to another identity, so the one on
        // screen no longer sharpens (the commit below arms the newcomer's own).
        cancelSharpen()

        let backdropURL = heroBackdropURL(for: target).flatMap { URL(string: $0) }
        // FEAT-42 (decision b′): resolver-side lookup, no payload merge. `logoPlan` decides in
        // priority order (own logo → folder stops → `TitleLogoStore`'s resolved URL → a
        // synchronous metahub guess for IMDb ids → a `TitleLogoStore` lookup already in flight →
        // nothing) — see that function's own doc comment. The URL never enters `MetaPreview`, so
        // `heroPayloadSignature`/`isVisibleRepaint`/`headHashHex` are untouched by construction.
        //
        // Under the `debug.heroLogoStoreOnly` knob (`#if DEBUG` only, see `heroLogoStoreOnly`'s doc
        // comment) the item's own logo is withheld and the metahub guess is disallowed, so the
        // plan can only resolve through the store — a UI-test-only override, never live in a
        // release build.
        let storeOnly = HeroArtResolver.heroLogoStoreOnly
        let plan = HeroArtResolver.logoPlan(
            addonLogo: storeOnly ? nil : target.logo, id: target.id, isFolder: isFolder,
            storeURL: TitleLogoStore.shared.logoURL(for: target),
            storePending: TitleLogoStore.shared.isLookupPending(for: target),
            allowMetahub: !storeOnly
        )
        // The origin this presentation will log/commit IF a logo bitmap actually ends up
        // resolved — `.pending` always implies a `TitleLogoStore`/TMDB answer by construction (see
        // `logoPlan`'s doc comment, step 5). Every commit site below still gates this on the final
        // `logo != nil`: a plan that names a source whose fetch then misses presents no logo at
        // all, and `presentedLogoSource` must read `.none` for that, not the source that failed.
        let planLogoOrigin: HeroLogoSource = {
            switch plan {
            case .url(_, let source): return source
            case .pending: return .tmdb
            case .none: return .none
            }
        }()
        let logoURL: URL? = {
            if case .url(let url, _) = plan { return url }
            return nil
        }()
        // beta.19-rc1 verdict (review r1, B P2-1): the legacy-size lookup, not the any-bucket seed. A
        // Continue Watching / landscape / Upcoming / saga card decodes the same backdrop URL at its
        // drawn size (768–1024 px), and the seed form handed that card bitmap to the hero, which
        // committed it 3–5× upscaled. `.legacy` accepts only a decode ≥ min(1920, source) (or a
        // sharper rendition, the sharpen's `original`); a card-only entry is a miss, and the
        // backdrop fetch below re-decodes it from the URLCache bytes inside the same deadline. The
        // backdrop fetch below already decodes `.legacy` (its default) with the same floor on its
        // memory check.
        let cachedBackdrop = ArtworkStore.cached(backdropURL, decode: .legacy)
        // beta.19-rc1 verdict (review r2, P3-1): the logo is drawn in a bounded slot, so it is looked
        // up (and fetched, below) at that slot's request, not `.legacy`: the legacy floor is 1920 px
        // for a URL never decoded itself, so a `w500` logo refused the `original` Detail had decoded
        // for its slot, and the `w500` fetch then had to make the 400 ms deadline or the hero
        // committed the text wordmark. Any decode of the picture that covers the slot is a hit now.
        let logoRequest = HeroSharpen.heroLogoRequest
        let cachedLogo = ArtworkStore.cached(logoURL, decode: logoRequest)
        let needsBackdrop = backdropURL != nil && cachedBackdrop == nil
        // beta.19-rc1 verdict (review r1, B P2-1): the SAME picture at a card's size, when that is
        // all memory holds for a title's backdrop. Never committed while the legacy re-decode makes
        // the deadline (it normally does: the bytes are in the URLCache, and the fetch below goes to
        // the front of the six-slot gate). If it misses, this stands in rather than the item's
        // poster (a different picture, which `adoptLateBackdrop` then never replaces): it records
        // the backdrop URL like any backdrop, so the post-commit sharpen upgrades it at rest. Title
        // heroes only, the same gate as the poster stand-in: folders keep their `none` → `late`
        // path untouched. Review r2 (P3-2): the legacy re-decode that missed the deadline replaces
        // it when it lands, at the next rest (`adoptLateBackdrop`), usually well before the sharpen.
        let backdropStandIn: UIImage? = needsBackdrop && !isFolder && !isCollectionHero(target)
            ? ArtworkStore.cached(backdropURL) : nil
        // `.pending` has no `logoURL` of its own yet (the fetch only starts once
        // `TitleLogoStore.awaitLogoURL` answers), so it must opt into the wait independently of
        // the `logoURL != nil` check below.
        let needsLogo = (logoURL != nil && cachedLogo == nil) || plan == .pending

        // Codex branch review: the poster stand-in for a primary that never lands.
        //
        // `heroBackdropURL(for:)` synthesizes `images.metahub.space/background/medium/tt…/img` for
        // any IMDb-backed item that carries no `banner`, and that URL 404s for plenty of real
        // titles. The image-driven `HeroCrossfadeImage` used to own the recovery (it took a
        // `fallbackURL` and swapped to the poster when the primary failed); the Wave H resolver
        // hands it a decoded bitmap instead, so with no fallback here those titles committed a
        // BLANK hero even though their poster was on screen in the row below.
        //
        // Title heroes ONLY. A collection folder must never paint its cover: a square cover
        // scaled-to-fill into the 16:9 hero and then replaced is the "background pops in larger
        // then shrinks" the tester filmed (Wave H hole H2), which is why `folderHeroPreview` passes
        // `poster: nil` in the first place. The `isFolder` flag and the type predicate both gate
        // it, since either alone would be a single point of failure for that regression.
        let posterFallbackURL: URL? = {
            // Review r1 (B P2-1): a same-picture stand-in (above) beats the poster.
            guard !isFolder, !isCollectionHero(target), needsBackdrop, backdropStandIn == nil else { return nil }
            guard let poster = target.poster, !poster.isEmpty,
                  let url = URL(string: poster), url != backdropURL else { return nil }
            return url
        }()
        // beta.19-rc1 verdict (review r1, B P2-1): the poster stand-in deliberately keeps the
        // any-bucket seed lookup (spec P-B §I1.7 item 2): the card's own decode of the poster is the
        // right stand-in, and requiring a legacy-size one would put a fresh decode (or, when the card
        // drew an upgraded rendition the item's own poster URL never fetched, a fresh download) inside
        // the 400 ms deadline.
        let cachedPosterFallback = ArtworkStore.cached(posterFallbackURL)
        let needsPosterFallback = posterFallbackURL != nil && cachedPosterFallback == nil

        guard needsBackdrop || needsLogo else {
            // Nothing to wait for, so there is no clock to carry: a same-identity payload update
            // after this point is handled by the gap-fill branch above (this commit makes
            // `presented.identity` match), and should the hero ever be re-resolved for this
            // identity later it deserves the whole budget (rc12, Codex Finding A).
            targetResolveStartedAt = nil
            // beta.19-rc1 verdict (M5, BUG-138): a cache-warm logo (prefetched by a row) has no
            // ink memo yet the first time; `inkedLogo` samples it here, synchronously, once per URL.
            let inked = Self.inkedLogo(cachedLogo, url: logoURL)
            commit(item: target, backdrop: cachedBackdrop, logo: inked.logo, identity: identity,
                   backdropSource: cachedBackdrop != nil ? "cached" : "none",
                   logoSource: inked.logo != nil ? "cached" : "text",
                   logoOrigin: inked.logo != nil ? planLogoOrigin : .none,
                   logoInk: inked.ink,
                   waitedMs: 0,
                   backdropURL: backdropURL, logoURL: logoURL)
            return
        }

        let started = Date()
        // rc12 (Codex Finding A): the budget is absolute per TARGET, not per resolve. A resolve
        // restarted for the identity that is already resolving keeps the first present's clock, so
        // the previous hero is held for at most one `laterSwapDeadline` no matter how many
        // same-identity payload updates land inside it. `started` itself stays "now" on purpose:
        // `waited=` on the probe line measures THIS resolve's own segment, the way every existing
        // oracle reads it.
        targetResolveStartedAt = inheritedResolveStart ?? started
        let deadline = Self.resolveDeadline(previousStart: inheritedResolveStart, now: started,
                                            budget: isFolder ? Self.folderDeadline : Self.laterSwapDeadline)
        let wait = HeroPresentArtWait(backdrop: cachedBackdrop, logo: cachedLogo,
                                      needsBackdrop: needsBackdrop, needsLogo: needsLogo,
                                      posterFallback: cachedPosterFallback,
                                      needsPosterFallback: needsPosterFallback)

        // Round 3: the two fetches are unstructured and are NEVER cancelled, exactly as
        // `HeroCommitCoordinator.prepare(_:)` issues the head's pair. The task-group form this
        // replaced could not honour its own deadline: a group awaits every child on the way out
        // even after `cancelAll()`, and `ArtworkStore.fetch` parks on shared unstructured work that
        // ignores waiter cancellation by design (a cancelled awaiter still lets the image land in
        // the cache for the next viewer). So one stalled backdrop deferred the whole PRESENTATION
        // by the URLSession timeout instead of by 400 ms, holding the previous hero on screen for
        // tens of seconds. `deadline` is now a real ceiling: `present` commits at most ~deadline
        // after the target changed, whatever the network is doing.
        //
        // Nothing is wasted by letting the fetches run on. `ArtworkStore` caches what lands, so a
        // backdrop that misses this deadline is already warm the next time the item is presented.
        //
        // `.head` admission (`ArtworkStore.FetchAdmission`): this IS the hero being shown, so it
        // goes to the front of the six-slot gate rather than queueing behind a screenful of row
        // poster prefetches.
        if needsBackdrop, let backdropURL {
            Task { @MainActor [weak self] in
                let image = try? await ArtworkStore.fetch(backdropURL, admission: .head)
                wait.resolveBackdrop(image)
                // 2026-09-08 finding: on a cold cache this fetch routinely lands AFTER the deadline
                // already committed with no backdrop (see `adoptLateBackdrop`'s doc comment). Past
                // the deadline `wait.resolveBackdrop` above is a no-op (pinned by
                // `HeroPresentArtWaitTests.testStalledBackdropResumesAtTheDeadlineWithTheCachedLogo`),
                // so the image reaching here is read off this closure's own local, never off `wait`.
                if wait.hitDeadline, let image {
                    self?.adoptLateBackdrop(image, identity: identity, startedAt: started, url: backdropURL)
                }
            }
        }
        if needsLogo, let logoURL {
            // `.url` case (the plan already names a concrete URL — addon, TMDB store, or
            // metahub) and it wasn't cached.
            Task { @MainActor [weak self] in
                let image = try? await ArtworkStore.fetch(logoURL, decode: logoRequest, admission: .head)
                // beta.19-rc1 verdict (M5, BUG-138): sample the ink OFF the main actor and memoize
                // it BEFORE the wait sees the bitmap, so the commit reads the memo (`inkedLogo`).
                if let image { _ = await HeroLogoInk.prepare(image, url: logoURL.absoluteString) }
                wait.resolveLogo(image, url: logoURL)
                // FEAT-42 repair: metahub is a synthesized GUESS (BUG-17) — a miss here does not
                // mean the item has no logo, only that this guess was wrong. Kick a real
                // `TitleLogoStore` lookup so the item's NEXT presentation can use step 3 of
                // `logoPlan` (a confirmed TMDB URL) instead of repeating the same bad guess. Only
                // for the metahub source: an addon-supplied or already-cached TMDB URL that 404s
                // is a dead link, not a guess worth re-resolving.
                guard image == nil, case .url(_, .metahub) = plan else { return }
                self?.repairMetahubMiss(for: target)
            }
        } else if needsLogo, plan == .pending {
            // `.pending` case — no URL to fetch yet; await the in-flight `TitleLogoStore` lookup
            // first, then fetch whatever it resolves to. Past `deadline` this is a no-op the same
            // way every other late arrival in this class is: `wait.resolveLogo` guards on
            // `!finished` and drops it.
            Task { @MainActor in
                guard let resolvedURLString = await TitleLogoStore.shared.awaitLogoURL(for: target),
                      let resolvedURL = URL(string: resolvedURLString) else {
                    wait.resolveLogo(nil)
                    return
                }
                let image = try? await ArtworkStore.fetch(resolvedURL, decode: logoRequest, admission: .head)
                // beta.19-rc1 verdict (M5): same off-main ink sample as the `.url` path, keyed on
                // the URL the store resolved (handed to the wait so the commit can read the memo).
                if let image { _ = await HeroLogoInk.prepare(image, url: resolvedURL.absoluteString) }
                wait.resolveLogo(image, url: resolvedURL)
            }
        }
        // Concurrent with the primary, deliberately, so the fallback costs the commit no extra
        // time: the poster is either in hand by the moment the primary misses, or it is still in
        // flight and the same `deadline` covers both. Starting it only after the miss would push
        // a cold poster past the budget on exactly the titles that need it. `.head` for the same
        // reason the other two are: the hero is what the whole screen is waiting on.
        // beta.19-rc1 verdict (I1, BUG-134): the same URL and the same download as before, decoded
        // into the poster prewarm's 896 px bucket (`HeroCommitCoordinator.posterPixelsDecode`) so
        // the entry also serves the row's poster card. The lookup above (`cached`, any bucket, any
        // rendition) already finds the card's own decode when the row drew it first.
        if needsPosterFallback, let posterFallbackURL {
            Task { @MainActor in
                let image = try? await ArtworkStore.fetch(posterFallbackURL,
                                                          decode: HeroCommitCoordinator.posterPixelsDecode,
                                                          admission: .head)
                wait.resolvePosterFallback(image)
            }
        }

        resolveTask = Task { [weak self] in
            let deadlineTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: deadline)
                guard !Task.isCancelled else { return }
                wait.deadlineElapsed()
            }
            // Resumed by the last needed fetch, by `deadlineTask`, or by cancellation, whichever
            // is first. A superseded `present` cancels this task; the handler stops the wait and
            // the identity guard below then commits nothing.
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    wait.attach(continuation)
                }
            } onCancel: {
                Task { @MainActor in wait.cancelWait() }
            }
            deadlineTask.cancel()
            guard !Task.isCancelled, let self, self.targetIdentity == identity else { return }
            self.resolveTask = nil
            // Review r1 (B P2-1): the legacy decode when it made the deadline, else the same picture
            // at card size (`backdropStandIn`), probe token `small` (append-only vocabulary).
            let usedStandIn = wait.backdrop == nil && backdropStandIn != nil
            let backdrop = wait.backdrop ?? backdropStandIn
            // beta.19-rc1 verdict (M5, BUG-138): a `.blank` logo commits as no logo (the text
            // wordmark); a `.dark` one carries its verdict to `HeroLogo`. A fetched logo's verdict
            // is already memoized (above); the wait names the URL it came from, else it is the
            // cached `logoURL` bitmap.
            let inked = Self.inkedLogo(wait.logo, url: wait.logoURL ?? logoURL)
            let logo = inked.logo
            let backdropSource = wait.usedPosterFallback
                ? "poster"
                : (usedStandIn ? "small" : Self.source(cached: cachedBackdrop, resolved: backdrop, empty: "none"))
            self.commit(item: target, backdrop: backdrop, logo: logo, identity: identity,
                        backdropSource: backdropSource,
                        logoSource: logo == nil
                            ? "text" : Self.source(cached: cachedLogo, resolved: logo, empty: "text"),
                        logoOrigin: logo != nil ? planLogoOrigin : .none,
                        logoInk: inked.ink,
                        waitedMs: Int(Date().timeIntervalSince(started) * 1000),
                        // beta.19-rc1 verdict (I1): the poster stand-in is not the backdrop's
                        // picture, so it records no backdrop URL and is never sharpened.
                        backdropURL: wait.usedPosterFallback ? nil : backdropURL,
                        logoURL: wait.logoURL ?? logoURL,
                        // Review r2 (P3-2): the late legacy decode may replace a `small` stand-in.
                        backdropIsStandIn: usedStandIn)
            // 2026-09-08 finding: a backdrop that lands during the deadline hand-off ITSELF — after
            // `deadlineElapsed()` above already finished the wait, but before this task's `commit`
            // just above runs — is lost by both existing paths. `resolveBackdrop`'s own `!finished`
            // guard drops it (see `wait.lateBackdrop` below, which is exactly this image, retained
            // for this one read). And the fetch closure's `adoptLateBackdrop` call is rejected too:
            // `resolveTask` was still non-nil at that moment, since clearing it is `self.resolveTask
            // = nil` above, a few lines into THIS task. By the time execution reaches here,
            // `resolveTask` is nil, `presented` already carries this identity (the `commit` just
            // above set it), and `presented`'s backdrop is nil (that commit had nothing to paint) —
            // every `shouldAdoptLateBackdrop` guard now passes. The fetch closure's own
            // `adoptLateBackdrop` call stays for the ordinary later-arrival case (the ordering above
            // is a hand-off race, not the common case); a second call here is harmless because
            // `presentedBackdrop == nil` fails after the first adoption commits one.
            // beta.19-rc1 verdict (review r2, P3-2): the same race when the commit painted the
            // card-size stand-in instead of nothing (the second call is just as harmless: the first
            // adoption clears `presentedBackdropIsStandIn`).
            if backdrop == nil || usedStandIn, let late = wait.lateBackdrop {
                self.adoptLateBackdrop(late, identity: identity, startedAt: started, url: backdropURL)
            }
        }
    }

    /// `cached` / `fetched` / the caller's empty token, for the probe line. The backdrop's fourth
    /// token, `poster`, is decided by the wait rather than here: it is the one value a bitmap
    /// alone cannot identify.
    private static func source(cached: UIImage?, resolved: UIImage?, empty: String) -> String {
        if cached != nil { return "cached" }
        return resolved != nil ? "fetched" : empty
    }

    /// beta.19-rc1 verdict (M5, BUG-138): the logo a commit may paint, and how. `.blank` (nothing
    /// readable: transparent, a placeholder, an opaque dark box) drops the bitmap so `HeroLogo`
    /// draws the title text; `.dark` keeps it, marked for the white-silhouette treatment; anything
    /// else is drawn as it always was. Reads the per-URL memo, which the fetch tasks fill off the
    /// main actor; a cache-warm logo with no memo yet (prefetched by a row) is sampled here,
    /// synchronously, and memoized — a 32×32 draw, its cost logged once per process.
    private static func inkedLogo(_ logo: UIImage?, url: URL?) -> (logo: UIImage?, ink: HeroLogoInk) {
        guard let logo else { return (nil, .legible) }
        let key = url?.absoluteString
        let ink: HeroLogoInk
        if let key, let memo = HeroLogoInk.cachedVerdict(for: key) {
            ink = memo
        } else {
            let start = ProcessInfo.processInfo.systemUptime
            ink = HeroLogoInk.verdict(of: logo)
            if let key { HeroLogoInk.remember(ink, for: key) }
            if !loggedLogoInkSyncSample {
                loggedLogoInkSyncSample = true
                let line = String(format: "logoInk sync-sample ms=%.2f",
                                  (ProcessInfo.processInfo.systemUptime - start) * 1000)
                if HomeHeroProbe.enabled { HomeHeroProbe.log(line) } else { NSLog("[HomeHero] %@", line) }
            }
        }
        return (ink == .blank ? nil : logo, ink)
    }

    /// One-shot latch for `inkedLogo`'s cost line.
    private static var loggedLogoInkSyncSample = false

    /// THE commit. One assignment, one animation, every field of the hero at once.
    ///
    /// BUG-95 (beta.18) note on the `withAnimation` below, because the fix plan for that bug
    /// explicitly asked this line to lose it and this comment is the record of why it did not.
    /// The bug itself was that this transaction reached `HeroCrossfadeImage`'s ZStack while it had
    /// NO children (no bitmap resolved yet) and so no size of its own; SwiftUI then interpolated
    /// that size from collapsed to full the moment the first bitmap landed, so a fixed
    /// `.scaledToFill()` computed its crop against a box that was still growing — the tester's
    /// "blank panel → logo → heavily-cropped mosaic → settles ~35 frames later" (full mechanism on
    /// `HeroCrossfadeImage.body`, which fixes it: `Color.clear` makes that container's size
    /// INVARIANT, so there is no longer any geometry here for a transaction to reach).
    ///
    /// beta.19-rc1 verdict (M5, BUG-138): this transaction NO LONGER drives the hero text. It used
    /// to: `HomeHeroForeground` keyed its info block on `.id(presentation.identity)` +
    /// `.transition(.opacity)` off this publish, so for 0.3 s the old and the new title, meta line
    /// and synopsis cross-dissolved in one slot (Steven's "doubled title"). The text now reads
    /// `HeroTextLayer`'s `TextSwapModel` (fade the old text out, swap while invisible, fade the new
    /// one in), its block is `.transition(.identity)`, and every write of that model runs in an
    /// animation-free transaction with only its own scoped opacity curve, so nothing here reaches
    /// it. The `withAnimation` itself stays: this batch leaves the artwork path exactly as it was
    /// (`HeroCrossfadeImage` cross-fades the bitmaps in place and its two layers opt out of this
    /// transaction, `.transaction { $0.animation = nil }`), and the hero region's own
    /// insert/remove at the nil boundary keeps its fade. Dropping it is a separate, device-checked
    /// change.
    ///
    /// beta.19-rc1 verdict (I1, BUG-134): `backdropURL` / `logoURL` are where the two bitmaps were
    /// decoded from (nil for the poster stand-in and for the text wordmark), kept for the post-commit
    /// sharpen, which every commit arms (`scheduleSharpen`).
    ///
    /// beta.19-rc1 verdict (review r2, P3-2): `backdropIsStandIn` marks a `backdrop=small` commit (see
    /// `presentedBackdropIsStandIn`).
    private func commit(item: MetaPreview, backdrop: UIImage?, logo: UIImage?, identity: String,
                        backdropSource: String, logoSource: String, logoOrigin: HeroLogoSource,
                        logoInk: HeroLogoInk, waitedMs: Int, backdropURL: URL?, logoURL: URL?,
                        backdropIsStandIn: Bool = false) {
        logPresent(identity: identity, backdrop: backdropSource, logo: logoSource,
                   logoOrigin: logoOrigin, logoInk: logoInk, waitedMs: waitedMs, same: false)
        let next = HeroPresentation(item: item, backdrop: backdrop, logo: logo, identity: identity,
                                    logoInk: logoInk)
        guard next != presented else { return }
        presentedBackdropURL = backdrop != nil ? backdropURL : nil
        presentedBackdropIsStandIn = backdrop != nil && backdropIsStandIn
        presentedLogoURL = logo != nil ? logoURL : nil
        // Review r3 (P3 #1): the backdrop cross-fade this commit starts runs from here.
        presentedCommitSerial &+= 1
        presentedCommittedAt = ProcessInfo.processInfo.systemUptime
        // FEAT-42: set in the SAME transaction as `presented` — see `presentedLogoSource`'s doc
        // comment.
        withAnimation(.easeInOut(duration: 0.3)) {
            presented = next
            presentedLogoSource = logoOrigin
        }
        scheduleSharpen(identity: identity)
    }

    // MARK: beta.19-rc1 verdict (I1, BUG-134): post-commit sharpen

    /// `HomeView` reports the hero form (`heroSharpenForm`). A change under a hero that stays re-arms
    /// its sharpen: a classic hero needs a larger bitmap than a Nuvio-style one, and the plan skips a
    /// bitmap that is already large enough.
    func setSharpenForm(_ form: HeroSharpen.Form) {
        guard form != sharpenForm else { return }
        sharpenForm = form
        guard let identity = presented?.identity, targetIdentity == identity, resolveTask == nil else { return }
        scheduleSharpen(identity: identity)
    }

    /// Arms the sharpen for the hero just committed: after `HeroSharpen.dwell` on the same identity,
    /// `runSharpen`. Replaces any sharpen already armed or running.
    ///
    /// Timeline (warm cache): the commit lands at t0 (the art cross-fades t0 → t0 + 0.3, the text
    /// swaps by t0 + 0.24). From t0 + 0.6 the sharpen waits for the rows to have rested
    /// `HeroSharpen.fetchRestHold` (beta.19-rc1 verdict, review r1, A P2); then the plan runs and,
    /// when the bitmap on screen is short of what the form draws, the sharper file is fetched with no
    /// deadline; when it lands (the backdrop and the logo both, or `fetchCeiling`) the sharpen waits
    /// for the next at-rest reading, and only then does `adoptSharpened` cross-fade the backdrop to
    /// it over 0.3 s and swap the logo bitmap in place. A `present` for another identity at any point
    /// before then cancels it, so a row walk (rows never at rest between presses) starts no fetch and
    /// no adoption can land inside a slide.
    private func scheduleSharpen(identity: String) {
        cancelSharpen()
        let generation = sharpenGeneration
        sharpenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(HeroSharpen.dwell * 1_000_000_000))
            guard !Task.isCancelled, let self, self.sharpenGeneration == generation else { return }
            await self.runSharpen(identity: identity, generation: generation)
        }
    }

    private func cancelSharpen() {
        sharpenTask?.cancel()
        sharpenTask = nil
        sharpenGeneration &+= 1
    }

    /// Plans from the bitmaps on screen (`HeroSharpen.plan` / `logoPlan`), fetches the backdrop and
    /// the logo concurrently with `.normal` admission, no deadline and no request timeout (the hero is
    /// already painted, so nothing waits on these and the six-slot gate's `.head` front stays for the
    /// fetches that do), waits at most `HeroSharpen.fetchCeiling` for both, then hands whatever
    /// landed to `adoptSharpened`. A sharpened file stays in `ArtworkStore`, so presenting this hero
    /// again in the session commits the sharp bitmap straight from the cache (the `.legacy` lookup
    /// returns the largest adequate decode of any rendition) and the next plan finds nothing to do.
    ///
    /// beta.19-rc1 verdict (review r1, A P2): both ends are held off row motion. The fetch starts only
    /// once the rows have rested `HeroSharpen.fetchRestHold`, so a held hero mid-walk queues no 1–5 MB
    /// `original` on the six-slot gate the row posters share (`ArtworkStore` work cannot be
    /// cancelled once it starts, so not starting it is the only cancellation there is); and the
    /// adoption waits for an at-rest reading, so its body re-evaluation and full-screen cross-fade
    /// never land inside a slide, a settle or a morph scroll.
    private func runSharpen(identity: String, generation: Int) async {
        defer { if sharpenGeneration == generation { sharpenTask = nil } }
        guard let fetchRest = await waitForRowsAtRest(hold: HeroSharpen.fetchRestHold, generation: generation) else {
            return
        }
        // TODO(I1): skip under a "Reduce Data" setting once tvOS has one (there is none today).
        guard let presented, presented.identity == identity, targetIdentity == identity,
              resolveTask == nil else { return }
        let scale = ArtworkDecodeMath.screenScale
        let form = sharpenForm
        let backdropSize = HeroSharpen.pixelSize(of: presented.backdrop)
        let logoSize = HeroSharpen.pixelSize(of: presented.logo)
        let backdropFrom = presented.backdrop != nil ? presentedBackdropURL : nil
        let logoFrom = presented.logo != nil ? presentedLogoURL : nil
        let sourceSize = backdropFrom.flatMap { ArtworkStore.recordedSourceSize($0) }
        let backdropPlan = backdropFrom.flatMap {
            HeroSharpen.plan(backdropURL: $0, presentedPixelSize: backdropSize, form: form,
                             scale: scale, sourceSize: sourceSize)
        }
        let logoPlan = logoFrom.flatMap {
            HeroSharpen.logoPlan(logoURL: $0, presentedPixelSize: logoSize, scale: scale)
        }
        guard backdropPlan != nil || logoPlan != nil else {
            HeroSharpen.log("none item=\(identity) form=\(form.rawValue) bd=\(HeroSharpen.sizeToken(backdropSize)) "
                            + "logo=\(HeroSharpen.sizeToken(logoSize))")
            return
        }
        // Review r1 (A P2): ` rest=<rest|ceiling> restMs=<n>` appended LAST (append-only vocabulary):
        // how the fetch's rest wait ended and how long it took.
        HeroSharpen.log("start item=\(identity) form=\(form.rawValue) "
                        + "bd=\(HeroSharpen.urlToken(from: backdropFrom, plan: backdropPlan)) "
                        + "req=\(HeroSharpen.requestBucket(backdropPlan, aspect: sourceSize ?? backdropSize)) "
                        + "logo=\(HeroSharpen.urlToken(from: logoFrom, plan: logoPlan)) "
                        + "lreq=\(HeroSharpen.requestBucket(logoPlan, aspect: logoSize))"
                        + HeroSharpen.restToken(fetchRest))
        let started = Date()
        // The same first-terminal-event wait `present` resolves with, here bounded by the ceiling
        // instead of the swap deadline, and with no poster stand-in.
        let wait = HeroPresentArtWait(backdrop: nil, logo: nil,
                                      needsBackdrop: backdropPlan != nil, needsLogo: logoPlan != nil)
        if let backdropPlan {
            Task { @MainActor in
                let image = try? await ArtworkStore.fetch(backdropPlan.url, decode: backdropPlan.request)
                wait.resolveBackdrop(image)
            }
        }
        if let logoPlan {
            Task { @MainActor in
                let image = try? await ArtworkStore.fetch(logoPlan.url, decode: logoPlan.request)
                wait.resolveLogo(image, url: logoPlan.url)
            }
        }
        let ceiling = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(HeroSharpen.fetchCeiling * 1_000_000_000))
            guard !Task.isCancelled else { return }
            wait.deadlineElapsed()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                wait.attach(continuation)
            }
        } onCancel: {
            Task { @MainActor in wait.cancelWait() }
        }
        ceiling.cancel()
        guard !Task.isCancelled, sharpenGeneration == generation else { return }
        // Review r1 (A P2): the bitmaps are decoded; the adoption lands at the next at-rest reading
        // (a press since then moved the identity and cancelled this sharpen).
        guard let adoptRest = await waitForRowsAtRest(hold: HeroSharpen.adoptRestHold, generation: generation) else {
            return
        }
        adoptSharpened(backdrop: wait.backdrop, logo: wait.logo, identity: identity,
                       backdropURL: backdropPlan?.url, logoURL: logoPlan?.url,
                       timedOut: wait.hitDeadline, startedAt: started, rest: adoptRest)
    }

    /// beta.19-rc1 verdict (review r1, A P2): polls `restSource` every `HeroSharpen.restPoll` until
    /// the rows have been at rest for `hold`, or, past `HeroSharpen.restCeiling`, still for `hold`
    /// with only a settle decision outstanding (`HeroSharpen.restStep` decides; real motion never
    /// passes the ceiling). Returns how the wait ended (`rest` / `ceiling`) and how long
    /// it took, or nil when the sharpen was cancelled or superseded meanwhile (its generation moved).
    /// A timestamp read and a few comparisons per poll, on the main actor; no view state is written.
    private func waitForRowsAtRest(hold: TimeInterval, generation: Int) async -> HeroSharpen.RestOutcome? {
        await waitForRowsAtRest(hold: hold, while: { self.sharpenGeneration == generation })
    }

    /// The rest wait itself. `isCurrent` is re-read before every poll; the wait answers nil the first
    /// time it is false (the hero moved on). beta.19-rc1 verdict (review r2, P3-2): factored out of
    /// the generation form above so the late stand-in replacement (`adoptLateBackdrop`) waits on the
    /// same signal, guarded by its own condition.
    private func waitForRowsAtRest(hold: TimeInterval, while isCurrent: () -> Bool) async -> HeroSharpen.RestOutcome? {
        let started = ProcessInfo.processInfo.systemUptime
        var restBegan: TimeInterval?
        var quietBegan: TimeInterval?
        while true {
            guard !Task.isCancelled, isCurrent() else { return nil }
            let now = ProcessInfo.processInfo.systemUptime
            if restSource.isAtRest() {
                if restBegan == nil { restBegan = now }
            } else {
                restBegan = nil
            }
            if restSource.rowsQuiet {
                if quietBegan == nil { quietBegan = now }
            } else {
                quietBegan = nil
            }
            switch HeroSharpen.restStep(restAge: restBegan.map { now - $0 }, quietAge: quietBegan.map { now - $0 },
                                        hold: hold, waited: now - started) {
            case .go(let via):
                return HeroSharpen.RestOutcome(via: via, waitedMs: Int(((now - started) * 1000).rounded()))
            case .wait(let seconds):
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    /// Adopts a sharpened backdrop and/or logo onto the hero on screen: a same-identity update of
    /// `presented`, built from the LIVE presentation's item (a gap-fill that landed during the fetch
    /// is kept, as in `adoptLateBackdrop`) and its live `logoInk` (the same picture at a higher
    /// resolution has the same ink; spec P-A §9.2 item 2). `presentedLogoSource` is unchanged: the
    /// logo still comes from the same place.
    ///
    /// On screen: `HeroCrossfadeImage` cross-fades the backdrop in place (0.3 s, two versions of one
    /// picture, same aspect, same crop); `HeroTextLayer`'s `TextSwapModel` sees the same identity and
    /// takes the update as a silent gap-fill, so the title, meta line and synopsis do not move and the
    /// logo bitmap is replaced in the same slot at the same geometry.
    ///
    /// Not routed through `commit`: that logs a `present` line, and the probe oracles read a second
    /// `present` for one item with nothing between as a double paint (test62). The sharpen logs its
    /// own `sharpen adopt` line, and `HeroCrossfadeImage` logs its cross-fade as `sharpen paint`.
    ///
    /// beta.19-rc1 verdict (review r1, A P2): `rest` is how the adoption's rest wait ended; it rides
    /// the `adopt`/`skip` lines LAST as ` rest=<rest|ceiling> restMs=<n>`, and `ms=` (fetch start →
    /// now) now includes that wait.
    private func adoptSharpened(backdrop: UIImage?, logo: UIImage?, identity: String,
                                backdropURL: URL?, logoURL: URL?, timedOut: Bool, startedAt: Date,
                                rest: HeroSharpen.RestOutcome) {
        let waitedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        guard HeroSharpen.shouldAdoptSharpened(targetIdentity: targetIdentity,
                                               presentedIdentity: presented?.identity,
                                               resolveTaskIsNil: resolveTask == nil,
                                               identity: identity),
              let presented else {
            HeroSharpen.log("skip item=\(identity) reason=superseded ms=\(waitedMs)" + HeroSharpen.restToken(rest))
            return
        }
        let sharpBackdrop = HeroSharpen.adoptable(backdrop, over: presented.backdrop)
        let sharpLogo = HeroSharpen.adoptable(logo, over: presented.logo)
        guard sharpBackdrop != nil || sharpLogo != nil else {
            HeroSharpen.log("skip item=\(identity) reason=\(timedOut ? "timeout" : "nogain") "
                            + "bd=\(HeroSharpen.sizeToken(HeroSharpen.pixelSize(of: backdrop))) ms=\(waitedMs)"
                            + HeroSharpen.restToken(rest))
            return
        }
        let next = HeroPresentation(item: presented.item,
                                    backdrop: sharpBackdrop ?? presented.backdrop,
                                    logo: sharpLogo ?? presented.logo,
                                    identity: identity,
                                    logoInk: presented.logoInk)
        if let sharpBackdrop {
            HeroSharpen.noteAdopted(sharpBackdrop)
            presentedBackdropURL = backdropURL
            // Review r2 (P3-2): the stand-in is gone; a late legacy decode must not replace this.
            presentedBackdropIsStandIn = false
        }
        if sharpLogo != nil { presentedLogoURL = logoURL }
        HeroSharpen.log("adopt item=\(identity) bd=\(HeroSharpen.adoptToken(from: presented.backdrop, to: sharpBackdrop)) "
                        + "logo=\(HeroSharpen.adoptToken(from: presented.logo, to: sharpLogo)) ms=\(waitedMs)"
                        + HeroSharpen.restToken(rest))
        withAnimation(.easeInOut(duration: 0.3)) {
            self.presented = next
        }
    }

    /// 2026-09-08 finding (simulator rig, the tester's real collections): when Home focus lands on
    /// a collection folder, `present`'s backdrop fetch routinely misses `folderDeadline` (1.5 s) on
    /// a cold cache — the probe logs `present item=nuvio.folder:… backdrop=none logo=text
    /// waited=1509` — and `commit` paints the hero with NO backdrop. Unlike a title hero, which
    /// falls back to its poster (`posterFallbackURL` above), a folder has no stand-in —
    /// `folderHeroPreview` passes `poster: nil` on purpose, so a square cover never gets scaled
    /// into the 16:9 hero and then replaced (Wave H hole H2). So the deadline miss is a BLANK
    /// screen, not a poster, and it used to stay blank until focus moved to a different folder
    /// whose art happened to already be cached. The fetch itself is never cancelled by the
    /// deadline (round 3's design: the image still lands in `ArtworkStore` for next time) — this
    /// method is where that late image gets painted onto the CURRENT hero instead of being wasted
    /// on a folder the viewer has since left.
    ///
    /// The safety argument is entirely `presentedBackdrop == nil`, mirrored in
    /// `shouldAdoptLateBackdrop` below so it can be pinned by a unit test with no `ArtworkStore`
    /// and no live view (`HeroArtResolverLateBackdropTests`). A hero that already has ANY bitmap on
    /// screen — a title's primary, a title's poster stand-in, or a folder's own earlier-landed
    /// backdrop — must never have that bitmap swapped out from under the viewer; that is exactly
    /// the late-arrival repaint BUG-90 forbids and the "double commit" BUG-42 exists to prevent.
    /// `presented?.backdrop == nil` is true in exactly the one case this method exists for: the
    /// deadline already committed with nothing to show, so painting something can only help. The
    /// other guards (`targetIdentity`, `presented?.identity`, `resolveTask == nil`) only rule out a
    /// newer `present` having superseded this one in the meantime.
    ///
    /// Commits with `presented.item` — the LIVE presentation's item — never the item `present`
    /// captured when this resolve started. A same-identity payload refresh (the allowed silent
    /// gap-fill in `present`'s identity-match branch: a synopsis or genre list landing from TMDB
    /// after the commit) can land in the gap between this resolve starting and this method running.
    /// Identity does not change on a gap-fill, so `presented` is updated directly without going
    /// through `commit` — which means `presented.item` is always at least as fresh as the item this
    /// resolve started with. Committing the stale captured item instead would rewind that text, and
    /// because the identity is unchanged, `commit`'s `same=0` line would make the rollback invisible
    /// to the photo oracle: nothing would look wrong that flags this class of regression.
    ///
    /// beta.19-rc1 verdict (review r2, P3-2): the one bitmap a late arrival may replace is the
    /// card-size stand-in (`backdrop=small`, `presentedBackdropIsStandIn`): the SAME picture at a
    /// card's size, committed only because this very legacy re-decode missed the deadline (the
    /// six-slot gate busy, the URLCache re-decode landing 50 ms late). It used to be dropped here, so
    /// the hero stayed on a 768 px card bitmap (3.3× upscaled on the Nuvio form, 5× on classic)
    /// through the sharpen's dwell, its rest hold and a TMDB `original` download, while a 1280–1920 px
    /// decode of the same picture sat in memory. Now it replaces the stand-in, but only with a
    /// strictly larger bitmap (`HeroSharpen.adoptable`), only while the stand-in is still on screen
    /// for this identity, and only at the next at-rest reading (the sharpen's own rest wait,
    /// `HeroSharpen.adoptRestHold`), so its full-screen cross-fade never lands inside a slide (review
    /// r1, A P2). Review r3 (P3 #1): that rest wait starts only once the stand-in commit's own
    /// cross-fade is over (`lateStandInFadeWait`), so the previous title's backdrop always finishes
    /// fading out. It is a same-identity update: `HeroTextLayer` takes it as a silent gap-fill (no text
    /// fade), the logo and its ink verdict are carried, `HeroCrossfadeImage` cross-fades two versions
    /// of one picture and logs it as `sharpen paint` (`HeroSharpen.noteAdopted`), never
    /// `paint … same=1`, and the probe reads `present … backdrop=late`, the one same-item re-present
    /// test62 allows. The poster stand-in (a different picture) is still never replaced.
    private func adoptLateBackdrop(_ image: UIImage, identity: String, startedAt: Date, url: URL?) {
        guard HeroArtResolver.shouldAdoptLateBackdrop(
            targetIdentity: targetIdentity, presentedIdentity: presented?.identity,
            presentedBackdrop: presented?.backdrop, presentedIsSmallStandIn: presentedBackdropIsStandIn,
            resolveTaskIsNil: resolveTask == nil, identity: identity
        ), let presented else { return }
        guard presented.backdrop != nil else {
            commitLateBackdrop(image, over: presented, identity: identity, startedAt: startedAt, url: url)
            return
        }
        // Review r2 (P3-2): over the `small` stand-in. Larger only, and at rest.
        guard HeroSharpen.adoptable(image, over: presented.backdrop) != nil else { return }
        // beta.19-rc1 verdict (review r3, P3 #1): and never inside the stand-in commit's own
        // cross-fade. The rest wait alone does not hold it off: the rows read at rest right after a
        // Right onto a card already in view (nothing scrolls, so nothing stamps), on classic Home,
        // and on a pinned step that arms no settle. The legacy decode landing 50 ms after the
        // commit then started `HeroCrossfadeImage`'s next swap with the previous title's backdrop
        // still ~90 % opaque, and `crossfade(to:)` drops that outgoing bitmap in one frame. So the
        // replacement first sleeps out the rest of that commit's span (`lateStandInFadeWait`), and
        // replaces only the stand-in of THIS commit (`commitSerial`): a newer commit restarts its
        // own fade, and its own resolve makes its own call here.
        let commitSerial = presentedCommitSerial
        let fadeWait = Self.lateStandInFadeWait(
            sinceCommit: ProcessInfo.processInfo.systemUptime - presentedCommittedAt)
        Task { @MainActor [weak self] in
            if fadeWait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(fadeWait * 1_000_000_000))
            }
            guard let self else { return }
            let standInStillUp = {
                self.presentedBackdropIsStandIn && self.targetIdentity == identity
                    && self.presented?.identity == identity && self.presentedCommitSerial == commitSerial
            }
            guard await self.waitForRowsAtRest(hold: HeroSharpen.adoptRestHold, while: standInStillUp) != nil,
                  HeroArtResolver.shouldAdoptLateBackdrop(
                    targetIdentity: self.targetIdentity, presentedIdentity: self.presented?.identity,
                    presentedBackdrop: self.presented?.backdrop,
                    presentedIsSmallStandIn: self.presentedBackdropIsStandIn,
                    resolveTaskIsNil: self.resolveTask == nil, identity: identity),
                  self.presentedCommitSerial == commitSerial,
                  let live = self.presented,
                  HeroSharpen.adoptable(image, over: live.backdrop) != nil else { return }
            HeroSharpen.noteAdopted(image)
            self.commitLateBackdrop(image, over: live, identity: identity, startedAt: startedAt, url: url)
        }
    }

    /// `adoptLateBackdrop`'s commit: the live presentation with `image` as its backdrop.
    private func commitLateBackdrop(_ image: UIImage, over presented: HeroPresentation, identity: String,
                                    startedAt: Date, url: URL?) {
        // FEAT-42: the logo (if any) is `presented.logo`, unchanged by this backdrop-only
        // adoption — its origin is whatever is already recorded on `presentedLogoSource`, passed
        // straight through rather than recomputed.
        commit(item: presented.item, backdrop: image, logo: presented.logo, identity: identity,
               backdropSource: "late",
               logoSource: presented.logo != nil ? "cached" : "text",
               logoOrigin: presentedLogoSource,
               logoInk: presented.logoInk,   // beta.19-rc1 verdict (M5): carried, never re-sampled
               waitedMs: Int(Date().timeIntervalSince(startedAt) * 1000),
               // beta.19-rc1 verdict (I1): the late image is the resolve's own backdrop URL; the
               // logo's URL is carried like its bitmap.
               backdropURL: url, logoURL: presentedLogoURL)
    }

    /// FEAT-42 repair path: `logoPlan`'s metahub guess (step 4) 404'd for `target`. Kicks a real
    /// `TitleLogoStore` lookup, purely for the item's NEXT presentation (this one already
    /// committed, or is about to, with no logo) — never bundled with the pending/`.url` fetch
    /// itself, which must stay focused on THIS presentation's own budget. A no-op if a lookup for
    /// this item/scope is already resolved or in flight (`TitleLogoStore.lookupIfNeeded`'s own
    /// `results[key] == nil` guard).
    private func repairMetahubMiss(for target: MetaPreview) {
        TitleLogoStore.shared.lookupIfNeeded([target])
    }

    /// Pure predicate behind `adoptLateBackdrop` — see that method's doc comment for the finding
    /// and the full safety argument. Factored out the same way `isVisibleRepaint` was, so the
    /// no-double-commit guard can be pinned by a unit test with no `ArtworkStore` and no live view.
    ///
    /// beta.19-rc1 verdict (review r2, P3-2): `presentedIsSmallStandIn` (default false, every
    /// pre-existing caller) lets the late arrival replace the card-size stand-in of the same picture,
    /// the one bitmap it may replace. A poster stand-in is never marked, so it still blocks.
    nonisolated static func shouldAdoptLateBackdrop(targetIdentity: String?, presentedIdentity: String?,
                                        presentedBackdrop: UIImage?, presentedIsSmallStandIn: Bool = false,
                                        resolveTaskIsNil: Bool, identity: String) -> Bool {
        guard targetIdentity == identity else { return false }
        guard presentedIdentity == identity else { return false }
        guard presentedBackdrop == nil || presentedIsSmallStandIn else { return false }
        guard resolveTaskIsNil else { return false }
        return true
    }

    /// beta.19-rc1 verdict (review r3, P3 #1): how long one commit's backdrop swap occupies
    /// `HeroCrossfadeImage` (`crossfade(to:)`): the 0.3 s fade of the outgoing bitmap, then its
    /// release at 0.4 s. A second swap inside this span would drop that outgoing bitmap mid-fade.
    nonisolated static let commitCrossfadeSpan: TimeInterval = 0.4

    /// beta.19-rc1 verdict (review r3, P3 #1): how long the late replacement of the card-size
    /// stand-in still sleeps before its rest wait, `sinceCommit` seconds after the stand-in's commit:
    /// the rest of `commitCrossfadeSpan`, 0 once it is over. A negative or non-finite reading (no
    /// clock should give one) waits the whole span.
    nonisolated static func lateStandInFadeWait(sinceCommit: TimeInterval) -> TimeInterval {
        guard sinceCommit.isFinite, sinceCommit >= 0 else { return commitCrossfadeSpan }
        return max(0, commitCrossfadeSpan - sinceCommit)
    }

    /// `present item=<type:id> backdrop=<cached|fetched|poster|late|none> logo=<cached|fetched|text>
    /// waited=<ms> same=<0|1> frame=<w>x<h>|none`. `frame=` is BUG-95's append-only diagnostic —
    /// see `logPresent`. `backdrop=poster` is a TITLE hero whose primary backdrop missed or
    /// stalled and whose own poster stood in for it. `backdrop=late` (2026-09-08, append-only
    /// addition to the vocabulary) is `adoptLateBackdrop` painting a backdrop that arrived after
    /// the deadline already committed with none — see that method's doc comment; it can appear for
    /// either a title or a folder hero, though the finding that motivated it was folder-only.
    /// `same=1` is a re-present of the item already on screen that
    /// actually swaps its backdrop or logo bitmap, i.e. the repaint signature. A healthy
    /// cold-launch photo has none. A same-identity present that only refreshes TEXT (the allowed
    /// gap-fill) paints nothing and logs nothing, so it can never be misread as a repaint.
    /// Internal review r1 (P2): does a same-identity `present` change anything the viewer can
    /// READ? This is the whole `same=1` contract, factored out so it can be unit-tested without a
    /// live view (`HeroArtResolverVisibleRepaintTests`).
    ///
    /// The hero's text is exactly three things: the wordmark slot (`HeroLogo`, which renders
    /// `item.name` whenever no logo bitmap resolved), the meta line (`releaseInfo` then up to three
    /// `genres`), and the synopsis (`description_`). Each counts as a repaint only when the value
    /// ALREADY on screen was non-empty and has been replaced - a nil-or-empty value being filled in
    /// is the allowed silent gap-fill.
    ///
    /// Artwork is deliberately NOT a term. The same-identity branch never re-resolves it (a late
    /// wordmark for an already-committed item is dropped by design, BUG-90), so no bitmap can move
    /// here; and when the logo bitmap is nil the visible wordmark is `item.name`, which the name
    /// term already covers. Testing the item's logo URL instead would log `same=1` for a change
    /// that paints nothing - the same vacuousness the bitmap test had, pointed the other way.
    static func isVisibleRepaint(current: MetaPreview, target: MetaPreview) -> Bool {
        func replaced(_ before: String?, _ after: String?) -> Bool {
            guard let before, !before.isEmpty else { return false }
            return before != (after ?? "")
        }
        if replaced(current.name, target.name) { return true }
        if replaced(current.releaseInfo, target.releaseInfo) { return true }
        if replaced(current.description_, target.description_) { return true }
        // Genres are a LIST, and only the first three ever reach the meta line - a fourth genre
        // arriving changes nothing on screen and must not read as a repaint.
        let currentGenres = Array(current.genres.prefix(3))
        if !currentGenres.isEmpty && currentGenres != Array(target.genres.prefix(3)) { return true }
        return false
    }

    /// BUG-95 (beta.18): `frame=<w>x<h>|none` (append-only) is diagnostic —
    /// `HeroCrossfadeImage.lastReportedSize`, the container's own last-measured layout size, read
    /// here because the resolver has no view access of its own. Proof, photographable off the
    /// About pane's ring buffer, that the container's size no longer differs between a hero with
    /// no bitmap yet and one that just painted. `item=` already leads this line rather than
    /// trailing it (unlike `paint`, where Wave H had to insert new fields BEFORE it), so there is
    /// no "everything after item=" ordering to protect here; `frame=` is appended at the very end
    /// regardless, the same append-only discipline. `none` means no `HeroCrossfadeImage` has
    /// completed a layout pass yet this launch — expected on the very first `present` line, before
    /// SwiftUI's first layout.
    ///
    /// FEAT-42: `logoSrc=<addon|tmdb|metahub|none>` is appended AFTER `frame=` — the About pane's
    /// probe blob truncates lines in the middle, not at the end, so a field appended last is the
    /// one most likely to survive a photo of a long line. `none` covers both "no logo bitmap
    /// resolved" and "the plan named a source but its fetch missed" — see `commit`'s callers,
    /// which only ever pass a non-`.none` `logoOrigin` alongside a non-nil `logo` bitmap.
    ///
    /// beta.19-rc1 verdict (M5, BUG-138): `logoInk=<legible|dark|blank>` is appended LAST
    /// (append-only, after `logoSrc=`). `blank` is a logo bitmap that drew nothing readable and was
    /// dropped for the text wordmark (so it reads with `logo=text logoSrc=none`); `dark` a
    /// near-black wordmark drawn as a white silhouette. `legible` also stands for "no logo".
    ///
    /// beta.19-rc1 verdict (review r1, B P2-1): `backdrop=small` (a new VALUE, no new field): a title
    /// whose legacy-size backdrop missed the deadline committed the same picture at a card's size
    /// instead of its poster; the post-commit sharpen upgrades it (`[HomeHero] sharpen`).
    /// beta.19-rc1 verdict (review r2, P3-2): usually sooner, by that legacy decode itself: a
    /// `backdrop=late` line for the same item follows at the next rest (`adoptLateBackdrop`).
    private func logPresent(identity: String, backdrop: String, logo: String,
                            logoOrigin: HeroLogoSource, logoInk: HeroLogoInk, waitedMs: Int, same: Bool) {
        guard HomeHeroProbe.enabled else { return }
        let frame: String = HeroCrossfadeImage.lastReportedSize.map {
            String(format: "%.0fx%.0f", $0.width, $0.height)
        } ?? "none"
        HomeHeroProbe.log(String(format: "present item=%@ backdrop=%@ logo=%@ waited=%d same=%d frame=%@ logoSrc=%@ logoInk=%@",
                                 identity, backdrop, logo, waitedMs, same ? 1 : 0, frame, logoOrigin.rawValue,
                                 logoInk.rawValue))
    }
}

/// Round 3: the wait state of ONE `HeroArtResolver.present(_:isFolder:)` resolve. Sibling of
/// `HeadArtPrewarm` (`HomeHeroCommit.swift`) with the same contract and the same reason to exist:
/// the art budget is enforced by a continuation that the FIRST terminal event resumes, instead of
/// by a task group whose implicit "await every child" defeats the deadline. See the block comment
/// in `present(_:isFolder:)` for why the group form could not honour 400 ms.
///
/// It is a sibling rather than a reuse because `HeadArtPrewarm` only records WHETHER each piece
/// landed. The commit here needs the decoded bitmaps themselves, and it starts from the cached
/// values so a fetch that comes back empty leaves the cached image in place.
///
/// `@MainActor`, like the resolver that owns it, so the fetch tasks, the deadline task and the
/// cancellation handler all mutate it on one actor with no locking; global-actor isolation also
/// makes it implicitly `Sendable` for the capture in `withTaskCancellationHandler`.
///
/// Not `private`: `HeroPresentArtWaitTests` drives this state machine directly, which is the only
/// part of the resolve that can be exercised without a live view and a network.
@MainActor
final class HeroPresentArtWait {
    /// What the commit will paint. Seeded with whatever was already cached, and only ever
    /// overwritten by a fetch that actually produced an image.
    private(set) var backdrop: UIImage?
    private(set) var logo: UIImage?
    /// beta.19-rc1 verdict (M5, BUG-138): the URL a FETCHED `logo` came from (nil while `logo` is
    /// the seeded cached bitmap), so the commit can read that URL's ink memo — the `.pending` path
    /// resolves its URL inside its own task and the resolver would not otherwise know it.
    private(set) var logoURL: URL?
    /// True only when the budget expired first. Not consumed by the resolver today (the probe line
    /// reports `cached`/`fetched`/`none`/`poster` per piece, not a timeout token); kept because it
    /// is the one fact the commit cannot otherwise reconstruct, and it is what the unit test
    /// asserts on.
    private(set) var hitDeadline = false
    /// True when `backdrop` is the item's POSTER standing in for a primary that never landed. Read
    /// by the resolver for the probe line's `backdrop=poster` token; also the only way the commit
    /// can tell a poster apart from a primary that happened to be cached.
    private(set) var usedPosterFallback = false
    /// 2026-09-08 finding: a backdrop that resolves AFTER the wait already finished via
    /// `deadlineElapsed()` used to be dropped outright by `resolveBackdrop`'s `!finished` guard —
    /// exactly the deadline-hand-off image `present`'s resolve task needs one turn later to adopt
    /// via `adoptLateBackdrop`. Retained here, read there, once. Set only when the wait finished
    /// via the deadline (`hitDeadline`): a wait finished by `cancelWait()` belongs to a `present`
    /// call that has already been superseded, and must not retain anything for a resolver that has
    /// moved on to a different target.
    private(set) var lateBackdrop: UIImage?

    private var pendingBackdrop: Bool
    private var pendingLogo: Bool
    /// The poster stand-in for a TITLE hero whose primary backdrop misses. Seeded from the cache
    /// when the poster is already resident (the common case, since `heroBackdropPrefetchURLs`
    /// warms it alongside the primary) and otherwise filled by a fetch running concurrently with
    /// the primary's, inside the same deadline. `nil` for folder heroes, which must never fall
    /// back to their cover, which is the "background pops in then shrinks" bug (Wave H, hole H2).
    private var posterFallback: UIImage?
    /// True while the poster fetch above is still in flight.
    private var pendingPoster: Bool
    /// Set when the primary fetch came back empty. Only then may the poster be painted.
    private var primaryMissed = false
    /// Set when the primary fetch produced an image. A poster landing afterwards is discarded: a
    /// fallback never replaces a primary that made the budget.
    private var primaryLanded = false
    private var continuation: CheckedContinuation<Void, Never>?
    /// Set by the first terminal event. Later arrivals are no-ops, which is exactly the
    /// "a late logo for an already-presented item is dropped" rule, and `attach` resumes at once so
    /// a wait that finished before the continuation existed cannot hang.
    private var finished = false

    init(backdrop: UIImage?, logo: UIImage?, needsBackdrop: Bool, needsLogo: Bool,
         posterFallback: UIImage? = nil, needsPosterFallback: Bool = false) {
        self.backdrop = backdrop
        self.logo = logo
        pendingBackdrop = needsBackdrop
        pendingLogo = needsLogo
        self.posterFallback = posterFallback
        pendingPoster = needsPosterFallback
    }

    func attach(_ continuation: CheckedContinuation<Void, Never>) {
        if finished {
            continuation.resume()
        } else {
            self.continuation = continuation
        }
    }

    func resolveBackdrop(_ image: UIImage?) {
        guard !finished else {
            // The wait is already over. If it ended via the deadline, this image is exactly the
            // late arrival `adoptLateBackdrop` exists for — keep it for that one read. If it ended
            // via `cancelWait()` instead, this `present` call has been superseded; there is nothing
            // left waiting to adopt it, so nothing is retained.
            if hitDeadline, let image { lateBackdrop = image }
            return
        }
        pendingBackdrop = false
        if let image {
            backdrop = image
            primaryLanded = true
            // The primary made it, so there is nothing left to wait for and nothing the poster
            // could add. Whatever the poster fetch is doing still lands in `ArtworkStore` for the
            // card that owns it.
            pendingPoster = false
        } else {
            primaryMissed = true
            applyPosterFallback()
        }
        finishIfSettled()
    }

    /// The poster stand-in resolved (or failed). Only ever consulted once the primary has missed.
    func resolvePosterFallback(_ image: UIImage?) {
        guard !finished, !primaryLanded else { return }
        pendingPoster = false
        if let image { posterFallback = image }
        applyPosterFallback()
        finishIfSettled()
    }

    /// Paints the poster if the primary has already missed, one is available, and nothing is on the
    /// backdrop slot yet. A no-op in every other combination, so it is safe to call from either
    /// arrival order.
    private func applyPosterFallback() {
        guard primaryMissed, backdrop == nil, let posterFallback else { return }
        backdrop = posterFallback
        usedPosterFallback = true
        pendingPoster = false
    }

    func resolveLogo(_ image: UIImage?, url: URL? = nil) {
        guard !finished else { return }
        if let image {
            logo = image
            logoURL = url
        }
        pendingLogo = false
        finishIfSettled()
    }

    /// The budget expired. Whatever has not landed is not part of this commit; it stays in flight
    /// inside `ArtworkStore` so it lands in the cache for this item's next presentation.
    func deadlineElapsed() {
        guard !finished else { return }
        hitDeadline = true
        // A primary that is still in flight when the budget expires is "missing" for this commit
        // exactly as a primary that 404'd is, so the poster stands in rather than the hero going
        // out blank. A primary that lands afterwards is dropped, the same rule a late logo follows.
        if backdrop == nil, let posterFallback {
            backdrop = posterFallback
            usedPosterFallback = true
        }
        finish()
    }

    /// A newer `present` superseded this resolve. Stop waiting; the resolver's identity guard is
    /// what actually blocks the commit, this just stops holding the task open.
    func cancelWait() {
        guard !finished else { return }
        finish()
    }

    private func finishIfSettled() {
        guard !pendingBackdrop, !pendingLogo, !pendingPoster else { return }
        finish()
    }

    private func finish() {
        finished = true
        pendingBackdrop = false
        pendingLogo = false
        pendingPoster = false
        let waiter = continuation
        continuation = nil
        waiter?.resume()
    }
}

/// Horizontal "Continue Watching" row of in-progress titles with a progress bar. Tapping a card opens
/// the stream picker for that exact video (the in-progress episode for series), and playback resumes
/// from the saved position.
struct ContinueWatchingRow: View {
    let entries: [WatchProgressEntry]
    let onSelect: (WatchProgressEntry) -> Void
    let onRemove: (WatchProgressEntry) -> Void
    /// Hold-menu actions (Orivio item 3). The row only renders the menu; Home owns what each does.
    let onGoToDetails: (WatchProgressEntry) -> Void
    let onPlayManually: (WatchProgressEntry) -> Void
    let onStartOver: (WatchProgressEntry) -> Void
    let onMarkWatched: (WatchProgressEntry) -> Void
    /// Parent ids of series with Episode Shuffle on — those cards get a small shuffle badge.
    var shuffleParentIds: Set<String> = []
    /// Custom poster URL pattern for this screen (blank = none), observed by `HomeViewModel`.
    var posterPattern: String = ""
    /// UX-7: reports the focused card's entry (or nil) so Home can drive the hero from it.
    /// Defaulted — nil is a plain no-op. Gating and backdrop prefetch live in the callback
    /// (HomeView.reportRowFocus), not here.
    var onItemFocusChange: ((WatchProgressEntry?) -> Void)? = nil
    /// Focus inside the shelf disables the reorder snap-back (mirrors upstream's
    /// hasUserScrolledContinueWatching guard in their CW scroll stabilization).
    @FocusState private var focusedVideoId: String?
    /// Pinned-hero card reach (UX-7 extension, device rounds 4–5) — see `rowCardTopReach` /
    /// `rowCardBottomReach` in BrowseComponents for the mechanism. 0 (no-op) outside pinned Home.
    @Environment(\.rowCardTopReach) private var cardTopReach
    @Environment(\.rowCardBottomReach) private var cardBottomReach
    /// BUG-87/89 (rc11): see `EnvironmentValues.rowCardLinkFrameFloor`. 0 for every row but Home's
    /// last — and, since rc14 (BUG-122), this row too, which is a SHORT row (203pt landscape cards
    /// against the plan's poster-tall frame).
    @Environment(\.rowCardLinkFrameFloor) private var cardLinkFrameFloor
    @Environment(\.pinnedRowIsLast) private var isLastRow
    @Environment(\.posterStyle) private var posterStyle
    /// Home Stage & Strip (P1 §3.3): the strip's per-row focus memory. nil outside the strip, which
    /// leaves the remount restore below inert (Classic).
    @Environment(\.stripFocusMemory) private var stripFocusMemory

    /// rc14 (BUG-122): see `PinnedRowGeometry.shortRowLayoutCompensation`. The natural label is
    /// what `LandscapeCard` lays out inside the reaches — its fixed height plus the caption when
    /// titles are shown (`titleVisible` defaults to `posterStyle.showTitle` here).
    private var shortRowCompensation: CGFloat {
        let caption = posterStyle.showTitle ? PinnedRowTitle.cardLockupCaptionChrome : 0
        let natural = cardTopReach + Theme.Size.landscapeHeight + caption + cardBottomReach
        return PinnedRowGeometry.shortRowLayoutCompensation(floor: cardLinkFrameFloor,
                                                            naturalLabel: natural,
                                                            isLastRow: isLastRow)
    }

    /// Home Stage & Strip (P1 §3.3, remounted rows): the strip's `LazyVStack` may cull this row far
    /// from the current page and lose its horizontal offset, leaving the remembered card
    /// unrealized for `.defaultFocus`. On a (re)mount with a remembered card that is not the first,
    /// scroll it back into view on the next runloop with no animation (anchor nil: the minimal
    /// scroll, nothing moves when it is already visible). Inert outside the strip.
    private func restoreStripMemory(proxy: ScrollViewProxy) {
        guard let memory = stripFocusMemory, memory.drivesDefaultFocus,
              let id = memory.itemId(for: "continue-watching"),
              id != entries.first?.videoId,
              entries.contains(where: { $0.videoId == id }) else { return }
        DispatchQueue.main.async {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { proxy.scrollTo(id) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Pinned mode overlays the title inside the shelf's reach band instead (see
            // CatalogRowView's structural comment — out-of-bounds frames froze the focus
            // engine; all paddings must stay positive).
            if cardTopReach == 0 {
                Text("Continue Watching")
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.rowGap) {
                        // Keyed by videoId (NOT position): on reorder the cards move instead of
                        // swapping contents under the focused position — upstream's jump bug.
                        ForEach(entries, id: \.videoId) { entry in
                            let custom = customImageURL(entry)
                            Button { onSelect(entry) } label: {
                                LandscapeCard(
                                    title: entry.title,
                                    imageURL: custom ?? imageURL(entry),
                                    fallbackImageURL: custom == nil ? nil : imageURL(entry),
                                    progress: fraction(entry),
                                    overlayLeading: episodeCode(entry)
                                )
                                // Drawn over the artwork's top-right corner: an overlay never
                                // affects the card's layout size or focus behaviour.
                                .overlay(alignment: .topTrailing) {
                                    if shuffleParentIds.contains(entry.parentMetaId) {
                                        Image(systemName: "shuffle")
                                            .font(Theme.Font.caption.weight(.semibold))
                                            .foregroundStyle(Color.white.opacity(0.92))
                                            .padding(.horizontal, Theme.Spacing.xs)
                                            .padding(.vertical, Theme.Spacing.xxs)
                                            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                                            .padding(Theme.Spacing.sm)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .padding(.top, cardTopReach)
                                .padding(.bottom, cardBottomReach)
                                // BUG-87/89 (rc11): transparent floor on the REVEALED frame — 0 for
                                // every row but Home's last. `.top` so the artwork and caption do
                                // not move a point.
                                .frame(minHeight: cardLinkFrameFloor > 0 ? cardLinkFrameFloor : nil,
                                       alignment: .top)
                            }
                            .cardFocusButtonStyle()
                            .posterButtonShape()
                            .focused($focusedVideoId, equals: entry.videoId)
                            .contextMenu {
                                // Orivio item 3: the action list and its order come from
                                // `TitleHoldMenuPolicy` (Mark Episode Watched exists for episodes only).
                                ForEach(TitleHoldMenuPolicy.continueWatchingActions(isEpisode: isEpisode(entry)), id: \.self) { action in
                                    Button(role: action.isDestructive ? .destructive : nil) {
                                        perform(action, on: entry)
                                    } label: {
                                        Label(action.title, systemImage: action.systemImage)
                                    }
                                }
                            }
                            .id(entry.videoId)
                        }
                    }
                    // Always positive — the reach lives inside the buttons (see CatalogRowView).
                    .padding(.vertical, Theme.Spacing.lg)
                }
                .scrollClipDisabled()
                // BUG-118: see `RowEdgeEffectStyleModifier`.
                .rowEdgeEffectStyle()
                // BUG-37: rides down to the viewport's clip edge when the device rests short —
                // same one-line treatment as every other pinned row title (see
                // `pinnedRowTitleTracking` in BrowseComponents for the geometry and history).
                //
                // beta.19-rc1 verdict (review r1, B P2-3): AFTER `.rowEdgeEffectStyle()`, as
                // `CatalogRowView` and `CollectionRowView` attach theirs. Attached before it, the
                // title sat inside the Soft mask, and with Soft on (the default then) and its leading ramp
                // reaching 110 pt into the frame, a scrolled row drew "Continue Watching" at 0.61
                // alpha at x = 0. The overlay's frame is the same ScrollView frame either way (the
                // mask never changes layout), so `pinnedRowTitleTracking` sees the same geometry.
                .overlay(alignment: .topLeading) {
                    if cardTopReach > 0 {
                        Text("Continue Watching")
                            .font(Theme.Font.sectionTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .shadow(color: .black.opacity(0.7), radius: 8, y: 2)
                            // Wave 4 item 5: a fixed-height LandscapeCard shelf can state its
                            // artwork height directly — Theme.Size.landscapeHeight is
                            // LandscapeCard's own default `height` param, which this row never
                            // overrides. Cosmetic: only makes the probe's `cap=`/`intr=` readings
                            // truthful for this row (the cap itself stays PROBE-ONLY).
                            // Codex r7 P2: `isFocused` picks which clearance the belt judges this
                            // row by — only a FOCUSED row's cards are raised by the treatment.
                            .pinnedRowTitleTracking(rowKey: "continue-watching",
                                                    artworkHeight: Theme.Size.landscapeHeight,
                                                    isFocused: focusedVideoId != nil)
                            .padding(.top, Theme.Size.heroPinnedRowTitleInset)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: entries.first?.videoId) { _, newFirst in
                    // Content-driven reorder while the user is elsewhere: keep the shelf
                    // anchored to the first card instead of drifting mid-list.
                    guard focusedVideoId == nil, let newFirst else { return }
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) { proxy.scrollTo(newFirst, anchor: .leading) }
                }
                // Home Stage & Strip (P1 §3.3): see `restoreStripMemory`. Inert outside the strip.
                .onAppear { restoreStripMemory(proxy: proxy) }
            }
        }
        .focusSection()
        // rc14 (BUG-122): cancel the floor's layout growth — the buttons keep their tall frames
        // (that is the point), the row's reported height goes back to its natural one. AFTER
        // `.focusSection()` (review r1 P1: a focusable frame that reaches outside its own section
        // is the shape that froze directional resolution on device — see the structural note on
        // `CatalogRowView`), and before the settle tracker so it measures the natural row.
        .padding(.bottom, -shortRowCompensation)
        // Settle re-reveal (2026-08-30) — one line, same as every other pinned row; see
        // `pinnedRowSettleTracking` in BrowseComponents for the mechanism and its guarantees.
        .pinnedRowSettleTracking(rowKey: "continue-watching", isFocused: focusedVideoId != nil)
        // BUG-112 (Item A)
        .pinnedRowUpFallbackTarget(rowKey: "continue-watching",
                                   firstId: entries.first?.videoId,
                                   focus: $focusedVideoId)
        .onChange(of: focusedVideoId) { _, newId in
            onItemFocusChange?(newId.flatMap { id in entries.first { $0.videoId == id } })
        }
    }

    private func fraction(_ entry: WatchProgressEntry) -> Double? {
        // progressFraction covers percentage-only rows (Simkl/Trakt: durationMs == 0).
        entry.progressFraction > 0 ? Double(entry.progressFraction) : nil
    }

    /// Custom poster URL pattern (Continue Watching screen) for this entry's parent title, computed
    /// with the shared resolver because `WatchProgressEntry` carries no raw-URL fields. Landscape
    /// shape: a pattern without `{shape}` resolves nil here, so those cards render exactly as before.
    private func customImageURL(_ entry: WatchProgressEntry) -> String? {
        guard !posterPattern.isEmpty else { return nil }
        return CustomPosterUrls.shared.resolveWithPattern(
            pattern: posterPattern,
            contentId: entry.parentMetaId,
            contentType: entry.parentMetaType,
            shape: PosterShape.landscape
        )
    }

    private func imageURL(_ entry: WatchProgressEntry) -> String? {
        let bg: String? = entry.background
        if let bg, !bg.isEmpty { return bg }
        let poster: String? = entry.poster
        return poster
    }

    /// `S02E05` artwork badge for series entries (nil for movies — no badge). Same code shape as
    /// the Upcoming row so the two shelves read as one system.
    private func episodeCode(_ entry: WatchProgressEntry) -> String? {
        guard let season = entry.seasonNumber?.intValue, let episode = entry.episodeNumber?.intValue else { return nil }
        return String(format: "S%02dE%02d", season, episode)
    }

    private func isEpisode(_ entry: WatchProgressEntry) -> Bool {
        TitleHoldMenuPolicy.isEpisode(season: entry.seasonNumber?.intValue, episode: entry.episodeNumber?.intValue)
    }

    private func perform(_ action: TitleHoldMenuPolicy.CWAction, on entry: WatchProgressEntry) {
        switch action {
        case .playManually: onPlayManually(entry)
        case .goToDetails: onGoToDetails(entry)
        case .markEpisodeWatched: onMarkWatched(entry)
        case .startOver: onStartOver(entry)
        case .remove: onRemove(entry)
        }
    }
}

/// Identifiable wrapper so a progress entry can drive `.fullScreenCover(item:)` for direct resume.
struct ResumeTarget: Identifiable {
    let entry: WatchProgressEntry
    /// Hold menu "Play Manually": open the picker without auto-selecting a source.
    var forceManual: Bool = false
    /// Hold menu "Start Over": play from 0 instead of the saved position.
    var startFromBeginning: Bool = false
    var id: String { entry.videoId }
}

/// Full-bleed hero backdrop drawn behind the scrolling rows (Detail-style): fills the top region
/// to every edge — no corner radius, no inset — and runs under the floating glass tab bar.
///
/// UX-7: `item` now changes far more often than a carousel page turn — every row-poster focus
/// commit swaps it too — so the crossfade lives inside `HeroCrossfadeImage` and this view is
/// never re-identified. An `.id(item.id)`-driven transition here (the original approach) was
/// exactly the BUG-19 identity-churn class: gating a view's identity on focus produced 700–830ms
/// hangs on device once churn stopped being rare (occasional carousel auto-advance) and became
/// frequent (any row focus hop).
struct HomeHeroBackdrop: View {
    /// Wave H: the committed hero — item AND its already-resolved backdrop bitmap. This view no
    /// longer resolves anything itself; `HeroArtResolver` did that before the commit, so the
    /// artwork and the text in front of it can never belong to different items.
    let presentation: HeroPresentation
    /// The item the presentation carries. Everything below reads this rather than the presentation
    /// so the trailer lifecycle is untouched by Wave H.
    private var item: MetaPreview { presentation.item }
    /// Nuvio-style hero: the artwork becomes a right-anchored panel whose LEFT edge fades
    /// out through a gradient mask, so the info panel sits on pure flat background — none of
    /// the artwork ever renders behind the title/description (Christian's spec, 2026-07-30).
    var nuvioStyle: Bool = false
    /// FEAT-25: run the title's trailer in the backdrop, with no focus required. The gating lives
    /// entirely in `HomeView.heroTrailerAutoplayActive`; false here is byte-for-byte the backdrop
    /// this view has always drawn.
    var autoplaysTrailer: Bool = false
    /// FEAT-25: the SAME dwell → resolve → play state machine the inline catalog card runs
    /// (`InlineTrailerCard`), driven from this view's lifecycle instead of from focus. It brings
    /// the resolution cache, the single-player/single-extraction coordinator, the negative-result
    /// TTLs and the storm breaker with it — nothing about the pipeline is reimplemented here.
    /// Owned by `HomeView` (Codex beta.14 r2) so the carousel tick can poll the attempt phase;
    /// this view still drives its whole lifecycle via `syncTrailer()`.
    @ObservedObject var trailerModel: InlineTrailerCardModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// FEAT-25 (device pass 2026-08-21): the "Home is actually frontmost" gate. Neither a Detail
    /// push nor a tab switch fires `onDisappear` on this view (Home's subtree stays mounted in
    /// both), so the trailer kept playing — audibly — under Detail pages and in Settings.
    @Environment(\.tabBarVisibility) private var tabBarVisibility

    /// Cache/zoom identity of the title on screen — also the change signal the trailer restarts on.
    private var trailerKey: String { TrailerResolutionCache.key(type: item.type, id: item.id) }

    var body: some View {
        backdrop
            .onAppear {
                trailerModel.prefersReducedMotion = reduceMotion
                syncTrailer()
            }
            .onChange(of: autoplaysTrailer) { _, _ in syncTrailer() }
            .onChange(of: trailerKey) { _, _ in syncTrailer() }
            .onChange(of: scenePhase) { _, _ in syncTrailer() }
            .onChange(of: reduceMotion) { _, motion in trailerModel.prefersReducedMotion = motion }
            // FEAT-25: imperative on purpose — while covered, this subtree is hierarchy-resident
            // (the player keeps playing, hence the bug) but may not re-render, so an `onChange`
            // of a computed prop could defer teardown indefinitely. `onReceive` fires regardless.
            // `@Published` emits on willSet, so use the payload, not the property.
            .onReceive(tabBarVisibility.$homeSurfaceCovered) { covered in
                syncTrailer(homeCovered: covered)
            }
            .onDisappear { trailerModel.reset() }
    }

    /// Single funnel for every start/stop reason — hero content change, the setting or one of its
    /// gates flipping, backgrounding and coming back, and Home being covered by a Detail push or
    /// a tab switch (or uncovered again — returning re-arms the same 1s dwell, so the trailer
    /// starts fresh rather than resuming mid-scene). Always tears the current playback down
    /// first (`reset()` releases the player slot and clears the state machine's per-dwell memory),
    /// then re-arms only when there is a reason to. `focusChanged(true:)` is the inline card's own
    /// arming call: it starts the same 1s dwell before anything is resolved or requested.
    private func syncTrailer(homeCovered: Bool? = nil) {
        trailerModel.reset()
        guard autoplaysTrailer, scenePhase == .active,
              !(homeCovered ?? tabBarVisibility.homeSurfaceCovered) else { return }
        trailerModel.focusChanged(true, item: item)
    }

    private var backdrop: some View {
        Group {
            if nuvioStyle {
                heroSurface
                    .frame(width: Theme.Size.heroNuvioArtworkWidth, height: Theme.Size.heroBackdropHeight)
                    .clipped()
                    // The left ~30% of the image dissolves into the background color the rest
                    // of the screen is painted with — a smooth black→artwork transition, no
                    // hard edge and no art under the text.
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .black.opacity(0.35), location: 0.16),
                                .init(color: .black, location: 0.32),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                heroSurface
                    .frame(height: Theme.Size.heroBackdropHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    /// The artwork, with the trailer fading in over it once the state machine has something to
    /// play. The image is UNCONDITIONAL and never re-identified — the player is the only thing
    /// that comes and goes — so a trailer starting or ending can't remount the backdrop and
    /// reintroduce the BUG-19 identity churn this view was rebuilt to avoid. Nothing below is a
    /// placeholder: with no trailer (or the setting off) this is exactly the still backdrop, and
    /// the gap before one resolves is the still backdrop too. Never a spinner.
    private var heroSurface: some View {
        ZStack {
            // Wave H: image-driven, not URL-driven. The whole fetch-and-fallback ladder that used
            // to run here now runs in `HeroArtResolver` BEFORE the hero commits, so this view has
            // one job left — cross-fading one committed bitmap into the next in place, at fixed
            // geometry. The identity is the presentation's own (`"\(type):\(id)"`, unique for a
            // collection folder's synthetic id just as it is for a real title).
            HeroCrossfadeImage(image: presentation.backdrop, identity: presentation.identity)

            if let url = trailerModel.playingURL {
                TrailerHeroPlayer(
                    urlString: url,
                    onFailure: { report in trailerModel.playbackFailed(report) },
                    zoomKey: trailerKey,
                    loops: false,
                    onPlaybackEnded: { trailerModel.playbackFinished() },
                    surfaceTag: "home-hero"
                )
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: trailerModel.playingURL)
    }
}

/// BUG-42 (beta.13): release-safe hero commit probe — `defaults write com.nuvio.media.NuvioTV
/// debug.homeHeroProbe -bool YES`, greppable `[HomeHero]`. Same house pattern as
/// `HomeGeometryProbe`/`TrailerProbe` (deliberately not `#if DEBUG`: the reporter is on a release
/// sideload and the console is the only thing that comes back from a device pass). Two lines:
/// `publish` (from `HomeViewModel`, per hero-bearing state) and `paint` (from
/// `HeroCrossfadeImage.crossfade`, per image swap). A healthy cold launch shows exactly ONE
/// `paint first=1` and NO `publish … headChanged=1`.
enum HomeHeroProbe {
    /// BUG-42 (beta.13.5): the defaults knob stays for local/device-pass use, but the reporter is
    /// on a sideload with no way to `defaults write` — Settings → About now exposes the same knob
    /// as a toggle (`heroDiagnosticsKey`), and the probe lines are mirrored into a small persisted
    /// ring buffer the About pane renders, so a cold-launch capture is one TV photo away.
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.homeHeroProbe")
    nonisolated static let t0 = Date()
    // nonisolated (Codex round 1): the target defaults to MainActor isolation, and the
    // nonisolated `log` below reads this — pure Date math, safe from any executor.
    nonisolated static var sinceLaunchMs: Int { Int(Date().timeIntervalSince(t0) * 1000) }

    nonisolated static let linesKey = "debug.homeHeroProbe.lines"
    /// H-1A (beta.15): the buffer used to be a flat 24-line ring, front-evicted — so on a busy
    /// cold launch (addons syncing, rows filling in, hero enrichment landing) the LAUNCH HEAD —
    /// exactly the diagnostically valuable part: init, first publish, first paint — was the first
    /// thing evicted once logging ran past 24 lines, and a tester's photo of the About pane showed
    /// only recent noise with the actual double-paint evidence already gone. Now HEAD-PRESERVING:
    /// the first `headMaxLines` lines are captured once and never evicted; only the TAIL rolls,
    /// keeping the most recent `tailMaxLines`. A single elision marker line separates the two once
    /// eviction has actually started (never shown on a launch short enough that nothing was
    /// dropped). Max displayed lines: `headMaxLines` + 1 marker + `tailMaxLines` = 57.
    ///
    /// Wave H raised the head 16 → 24: the launch head now carries a `present` line per hero commit
    /// alongside the `publish`/`paint`/`commit` lines, and the photo contract the device pass reads
    /// (one publish before the first commit, `gate=`, zero `headChanged`/`same=1`) has to fit
    /// inside the frozen head or the evidence rolls out of the pane before the tester photographs
    /// it — the exact failure H-1A introduced the head-preserving buffer for.
    nonisolated static let headMaxLines = 24
    nonisolated static let tailMaxLines = 32
    nonisolated(unsafe) private static var headLines: [String] = []
    nonisolated(unsafe) private static var tailLines: [String] = []
    /// Lines dropped from the tail stream once `tailLines` is full. Stays 0 (no marker rendered)
    /// until eviction genuinely begins.
    nonisolated(unsafe) private static var elidedTailCount = 0
    nonisolated private static let bufferLock = NSLock()

    /// H-1A: monotonic per-process instance counter, guarded by `bufferLock` alongside the ring
    /// buffer it stamps lines for. `HomeViewModel`/`HeroCrossfadeImage` each mint one id at init
    /// and stamp it (`vm=<n>` / `item=<id>`) into every probe line they log, so a photographed
    /// pane can tell two overlapping instances apart instead of interleaving their lines under one
    /// identity — exactly the ambiguity a sync-driven theme remount (see `AppThemeModel`) produces.
    nonisolated(unsafe) private static var nextInstanceId = 0
    nonisolated static func newInstanceId() -> Int {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        nextInstanceId += 1
        return nextInstanceId
    }

    /// NSLogs `line` (the greppable `[HomeHero]` console contract is unchanged) and appends it to
    /// the persisted, head-preserving ring buffer. `headLines`/`tailLines` are fresh statics for
    /// this process, so the very first call of a launch already starts the buffer clean — no
    /// separate "did we reset yet" flag needed (the old flat-ring implementation carried one; it's
    /// moot once the head is captured once and frozen rather than continuously re-derived from
    /// whatever UserDefaults happened to hold from the previous launch).
    nonisolated static func log(_ line: String) {
        NSLog("[HomeHero] %@", line)
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let stamped = "\(sinceLaunchMs)ms \(line)"
        if headLines.count < headMaxLines {
            headLines.append(stamped)
        } else {
            tailLines.append(stamped)
            if tailLines.count > tailMaxLines {
                tailLines.removeFirst()
                elidedTailCount += 1
            }
        }
        var display = headLines
        if elidedTailCount > 0 {
            display.append("\u{2026} \(elidedTailCount) lines elided \u{2026}")
        }
        display.append(contentsOf: tailLines)
        UserDefaults.standard.set(display, forKey: linesKey)
    }
}

/// BUG-95 (beta.18, 2026-09-08): the tester still saw a collection folder's mosaic backdrop
/// "re-crop itself after it appears when the previous image had a different size" even after the
/// `Color.clear`/frame fix of `ecc00536` pinned `HeroCrossfadeImage`'s own container size. Root
/// cause: the leaves were SwiftUI `Image(uiImage:).resizable().scaledToFill()` — SwiftUI computes
/// that layer's aspect-fill geometry as part of its own layout pass, and when `crossfade(to:)`
/// swaps in a bitmap with a different aspect ratio than the outgoing one, the NEW layer's
/// aspect-fill size differs from the OLD layer's, even though the surrounding container's size is
/// now invariant. `.transaction { $0.animation = nil }` on each `Image` only strips animation from
/// that image's OWN modifiers (opacity, etc.) — it cannot stop SwiftUI from interpolating the
/// parent ZStack's placement of a child whose intrinsic-fill geometry just changed, because that
/// interpolation is driven by whatever transaction is active on the PARENT when the child's layout
/// inputs change, not by a transaction override written on the child itself. `ecc00536` fixed the
/// container-collapse jump; this is the layer-crop jump underneath it — the class of bug that fix
/// could not close on hardware (see u/mrStevenx3's rc5 report).
///
/// `HeroBitmapLayer` below replaces both `Image` leaves with a `UIViewRepresentable`-hosted
/// `UIImageView`. UIKit computes the aspect-fill crop at LAYOUT time, directly from the view's
/// `bounds` and the bitmap — there is no SwiftUI layout pass for it to participate in, so a bitmap
/// swap between two different aspect ratios can never be interpolated by any transaction, ambient
/// or explicit: `updateUIView` only ever swaps `image`, never touches `bounds`, and `bounds` itself
/// is driven solely by the (already-invariant, per `ecc00536`) container frame above it.
struct HeroBitmapLayer: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        if view.image !== image {
            view.image = image
        }
    }

    /// Take exactly the proposed size — never the bitmap's own intrinsic size — so SwiftUI's
    /// layout never has a reason to size this view off the image at all; the crop is entirely
    /// `UIImageView`'s job once `bounds` lands.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        let resolved = proposal.replacingUnspecifiedDimensions()
        return CGSize(width: resolved.width, height: resolved.height)
    }
}

/// UX-7 flash-free backdrop swapper: unlike `HomeHeroBackdrop`'s old approach, this view is NEVER
/// re-identified as `url` changes — see the BUG-19 note on `HomeHeroBackdrop`. Instead it holds up
/// to two decoded images itself and crossfades between them in place, so churn as fast as a row
/// focus hop never re-triggers view construction, layout, or a load-from-scratch flash.
struct HeroCrossfadeImage: View {
    let url: String?
    /// Second-chance artwork (the item's poster) for when `url` — typically a synthesized metahub
    /// background that may 404 — fails to fetch. Without it an IMDb item with no banner and a dead
    /// metahub entry would keep the previous title's backdrop (or blank on first load) even though
    /// a perfectly good poster exists (Codex review finding).
    let fallbackURL: String?
    /// H-1C (beta.15): the displayed item's stable identity (`"\(type):\(id)"`, constructed at the
    /// single call site in `HomeHeroBackdrop.heroSurface`) — landed in H-1A purely as a probe
    /// stamp (`item=<identity>` on every paint/suppression log line below), and load-bearing from
    /// H-1C onward, where it distinguishes a same-title URL upgrade (TMDB enrichment rewriting
    /// this title's banner) from a genuine title change (see `paintedIdentity`/
    /// `isSameTitleUpgrade` further down).
    let identity: String
    /// Wave H: the already-decoded bitmap to display, for the image-driven call site
    /// (`HomeHeroBackdrop`). nil in URL-driven mode, and nil here in image-driven mode means "this
    /// hero has no artwork" — the same terminal state `fadeToEmpty()` has always produced.
    private let directImage: UIImage?
    /// Which of the two modes this instance is in. A per-call-site CONSTANT (each call site uses
    /// exactly one initializer), so it can safely pick between the two task bodies without ever
    /// re-identifying the view mid-session.
    private let imageDriven: Bool
    @State private var current: UIImage?
    @State private var previous: UIImage?
    /// Drives the outgoing image's fade — animated 1 → 0 on every swap (see `crossfade(to:)`).
    @State private var previousOpacity: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Same trick as `HeroLogo.init`: seed `current` synchronously from the memory cache when the
    /// URL is already resident, so a cached backdrop is on screen from this view's very first
    /// frame — no placeholder flash as focus moves across a row.
    init(url: String?, fallbackURL: String? = nil, identity: String) {
        self.url = url
        self.fallbackURL = fallbackURL
        self.identity = identity
        self.directImage = nil
        self.imageDriven = false
        let resolved: URL? = {
            guard let url, !url.isEmpty else { return nil }
            return URL(string: url)
        }()
        let seeded = ArtworkStore.cached(resolved)
        _current = State(initialValue: seeded)
        // Codex wave-3 (P2): when init seeds `current`, the first task's cachedPrimary hit is the
        // SAME UIImage instance, so `crossfade`'s same-image guard returns before recording
        // `paintedIdentity` — a later same-title enrichment would then be misclassified as a title
        // change and repaint the fallback poster. Seed the painted state here alongside the image.
        _paintedIdentity = State(initialValue: seeded != nil ? identity : nil)
        _paintedFallbackURL = State(initialValue: seeded != nil ? fallbackURL : nil)
    }

    /// Wave H: image-driven mode. The caller has already resolved the artwork (see
    /// `HeroArtResolver`), so there is no ladder, no deadline and no fallback here — one bitmap in,
    /// one cross-fade out. The whole point is that a hero's text, logo and backdrop change in the
    /// same transaction; a view that fetched its own image could never guarantee that.
    init(image: UIImage?, identity: String) {
        self.url = nil
        self.fallbackURL = nil
        self.identity = identity
        self.directImage = image
        self.imageDriven = true
        _current = State(initialValue: image)
        _paintedIdentity = State(initialValue: image != nil ? identity : nil)
        _paintedFallbackURL = State(initialValue: nil)
    }

    /// BUG-42 probe: an init-seeded first frame IS the first paint (no `crossfade` runs for it).
    /// Logged from the task, not `init` — SwiftUI may re-run `init` on parent updates while keeping
    /// the `@State`, so only the first task on a view that has painted nothing yet counts.
    @State private var paintCount = 0
    @State private var didLogSeededPaint = false
    /// H-1C (beta.15): which item's identity the currently-committed `current` image belongs to —
    /// set in `crossfade(to:)`, cleared in `fadeToEmpty()`. This view is never re-identified (see
    /// the type doc), so it lives across many different items over time; comparing a task run's
    /// `identity` against this tells a same-title URL upgrade (TMDB enrichment rewriting THIS
    /// title's banner mid-display) apart from a genuine title change.
    @State private var paintedIdentity: String?
    /// Codex wave-3 (P2): the fallback URL that was current when `paintedIdentity` was recorded.
    /// A same-title task run whose fallback URL CHANGED (e.g. a CW→catalog re-adoption swapping
    /// the poster while the primary keeps failing) is not the enrichment-repaint shape H-1C
    /// suppresses — the new poster must still commit through the existing ladder, or a failing
    /// primary pins the stale poster indefinitely.
    @State private var paintedFallbackURL: String?

    /// BUG-95 (beta.18) diagnostic only: the container's LAST rendered size, reported by the
    /// `onGeometryChange` in `body` below. `HeroArtResolver.logPresent` has no view access of its
    /// own, so it reads this static to append `frame=<w>x<h>` to the `present` probe line — proof,
    /// photographable off the About pane's ring buffer, that this view's size no longer differs
    /// between a hero with no bitmap yet and one that just painted (see the fix note on `body`).
    /// `@MainActor` because every reader/writer (this view, `HeroArtResolver`) already runs there;
    /// never read by anything that decides what to draw.
    @MainActor static var lastReportedSize: CGSize?

    var body: some View {
        GeometryReader { geo in
        ZStack {
            // BUG-95 (beta.18): folder backdrop grew into place — a folder hero (`poster: nil`,
            // Wave H's `HeroArtResolver`) commits with `backdrop == nil` on its FIRST paint while
            // the fetch is still in flight, so `current`/`previous` were both nil and this ZStack
            // had NO children at all. A childless ZStack ignores whatever size its parent proposes
            // (`HomeHeroBackdrop`'s fixed `.frame(width: heroNuvioArtworkWidth, height:
            // heroBackdropHeight)`) and collapses to nothing; the first bitmap to land then gave it
            // its first real child and its size jumped from that collapsed point straight to the
            // full frame — and because `HeroArtResolver.commit` committed that bitmap inside a
            // `withAnimation`, SwiftUI interpolated the jump, so `.scaledToFill()` computed its
            // crop against a box that started tiny and grew over ~0.3s: exactly the tester's video
            // (blank panel → logo → heavily-cropped mosaic → settles less cropped ~35 frames
            // later). `Color.clear` is a shape-backed view — it always reports the FULL proposed
            // size whether or not a bitmap child exists alongside it — so this ZStack's own size is
            // now CONSTANT across every state the crossfade passes through, with nothing left for
            // any transaction (ambient or explicit) to animate. `.clipped()` below is
            // belt-and-braces: once the box can no longer collapse, a `.scaledToFill()` image can
            // never overflow it either.
            Color.clear
            // Content-mode/frame/clipping are the caller's job (parity with what
            // CachedAsyncImage used to provide at these call sites). Both leaves below are
            // `HeroBitmapLayer` (UIKit-backed), not SwiftUI `Image` — see that type's doc comment
            // above `HeroCrossfadeImage` for why: a UIImageView computes its aspect-fill crop at
            // UIKit layout time from its own bounds, so no SwiftUI transaction can ever interpolate
            // it when the bitmap's aspect ratio changes mid-crossfade.
            if let current {
                HeroBitmapLayer(image: current)
                    // BUG-95 belt-and-braces: this layer has no animation of its own to protect
                    // (unlike `previous` below), so pin it to the ambient transaction unconditionally
                    // — a future caller-side `withAnimation` (e.g. `HeroArtResolver.commit`, which
                    // still wraps its commit for reasons explained on that function) can no longer
                    // interpolate anything about this image, geometry included, by accident. Belt
                    // and braces only: `HeroBitmapLayer` itself is already immune (see its doc).
                    .transaction { $0.animation = nil }
            }
            // The OUTGOING image sits on top and fades out to reveal the new one beneath —
            // stacked the other way (opaque newcomer above) the animated removal is invisible
            // and every swap reads as a hard cut.
            if let previous {
                HeroBitmapLayer(image: previous)
                    // BUG-95 belt-and-braces, same as `current` above — applied BEFORE `.opacity`
                    // in the chain, so it only pins the image content itself; the `.opacity`
                    // modifier stacked on top of it is deliberately left OUTSIDE this override and
                    // keeps animating exactly as `crossfade(to:)`/`fadeToEmpty()`'s own explicit
                    // `withAnimation` calls below intend.
                    .transaction { $0.animation = nil }
                    .opacity(previousOpacity)
            }
        }
        // BUG-95 gate run (beta.18): `Color.clear` alone was not enough — the simulator layout probe
        // showed a filled container at 1250x1250 for a square bitmap, because `.scaledToFill()`
        // reports a size LARGER than the proposal and a ZStack sizes to the union of its children.
        // The GeometryReader takes exactly the proposed size no matter what its children want,
        // and this frame pins the stack to it; the images are cropped inside, never resized by.
        .frame(width: geo.size.width, height: geo.size.height)
        .clipped()
        // BUG-95 diagnostic only (see `lastReportedSize`'s own doc) — never consulted by any
        // drawing or state-machine decision in this file.
        .onGeometryChange(for: CGSize.self, of: { proxy in
            proxy.size
        }, action: { newSize in
            HeroCrossfadeImage.lastReportedSize = newSize
        })
        // Keyed on BOTH urls: between same-title previews the primary can stay identical while
        // only the fallback poster changes (CW adaptation without a poster → catalog card with
        // one) — keyed on the primary alone, a terminally-failed primary never retried the newly
        // available fallback.
        // Codex wave-3 r2 (P2): `identity` is part of the key — two consecutive items resolving to
        // the SAME url/fallback pair (shared artwork) must still rerun the task, or
        // `paintedIdentity` stays owned by the previous item and a later enrichment of the new
        // item bypasses the same-title fallback suppression.
        .task(id: taskKey) {
            // Wave H: image-driven mode has no ladder to run — commit what the resolver handed us.
            if imageDriven {
                applyDirectImage()
                return
            }
            // BUG-42: is this the hero's very first paint (nothing on screen yet)? Later swaps keep
            // the "show the cached poster now, upgrade later" rule below — it exists so a stalled
            // metahub fetch can't pin the PREVIOUS title's art. On first paint there is no previous
            // art to pin, and the poster→backdrop crossfade IS the "one cover, then another loads
            // over it" the reporter filmed. So on first paint the poster waits for the primary up
            // to `firstPaintFallbackDeadline` before it is allowed to show.
            let firstPaint = current == nil && previous == nil
            // H-1C: the SAME title is already on screen with correct art, and this task run is
            // only here because enrichment (or any other source) rewrote a URL for that same
            // title — the exact shape that produced the "poster paints over already-correct
            // backdrop" bug. Keyed STRICTLY on identity, never on "did the URL change": a genuine
            // title change must still run the full stale-art-protection ladder below unchanged —
            // keying on URL instead would reintroduce the mismatched-art bug that ladder prevents.
            // `current != nil` also rules this out on true first paint (where there is nothing to
            // protect yet), matching `firstPaint`'s own current==nil check.
            let isSameTitleUpgrade = (identity == paintedIdentity) && current != nil
            // Codex wave-3 (P2): fallback suppression additionally requires the fallback URL to be
            // UNCHANGED since the painted state — see `paintedFallbackURL`. The terminal
            // keep-good-art guard at the bottom stays keyed on `isSameTitleUpgrade` alone.
            let suppressFallback = isSameTitleUpgrade && fallbackURL == paintedFallbackURL
            if !firstPaint, paintCount == 0, !didLogSeededPaint, HomeHeroProbe.enabled {
                didLogSeededPaint = true
                // Wave H: `url=`/`same=` for parity with `crossfade`'s line; `same=0` because a
                // seeded first paint has nothing behind it (see the image-driven twin).
                HomeHeroProbe.log(String(format: "paint kind=seededPrimary first=1 sinceLaunch=%dms hadArt=0 url=%@ same=0 item=%@", HomeHeroProbe.sinceLaunchMs, paintURLKind("cachedPrimary"), identity))
            }
            guard let url, !url.isEmpty, let resolvedURL = URL(string: url) else {
                // This title genuinely has no artwork: fade down to the flat background rather
                // than keep presenting the PREVIOUS title's backdrop under the new title's text.
                fadeToEmpty()
                return
            }
            if let hit = ArtworkStore.cached(resolvedURL) {
                crossfade(to: hit, kind: "cachedPrimary", first: firstPaint)
                return
            }
            let resolvedFallback: URL? = {
                guard let fallbackURL, !fallbackURL.isEmpty, fallbackURL != url else { return nil }
                return URL(string: fallbackURL)
            }()
            // Primary is a cache miss, but the fallback poster may already be resident (it's
            // usually the card image on screen): show it NOW as this title's provisional art,
            // then upgrade when the primary lands. Without this, a slow/unreachable metahub
            // fetch pins the PREVIOUS title's backdrop for a whole URLSession timeout while a
            // perfectly good cached poster sits hidden.
            var showedArt = false
            // BUG-42: on first paint the resident poster is held back (see above); it becomes the
            // deadline's fallback instead of the immediate paint.
            var heldFallback: UIImage? = nil
            if let resolvedFallback, let fallbackHit = ArtworkStore.cached(resolvedFallback) {
                if firstPaint {
                    heldFallback = fallbackHit
                } else if suppressFallback {
                    // H-1C: never repaint the poster over this same title's already-correct art —
                    // only `primary`/`cachedPrimary` may commit while an upgrade is in flight.
                    if HomeHeroProbe.enabled {
                        HomeHeroProbe.log(String(format: "paint suppressed kind=sameTitleFallback sinceLaunch=%dms item=%@", HomeHeroProbe.sinceLaunchMs, identity))
                    }
                } else {
                    crossfade(to: fallbackHit, kind: "fallbackCached", first: false)
                    showedArt = true
                }
            }
            // Race BOTH candidates rather than awaiting the primary serially — a stalled primary
            // must not pin stale/blank art for a whole URLSession timeout while a fetchable
            // poster exists. The fallback promotes itself only until the primary lands; a
            // late-arriving primary still upgrades the hero. Old art stays on screen mid-flight
            // (never blank), and `.task(id:)` cancellation stops a slow fetch for a title the
            // user already focused past from landing over the correct, newer image. No
            // `cancelAll()` on the primary's win: `ArtworkStore` coalesces in-flight fetches, so
            // the drained fallback just parks in cache.
            var primaryLanded = false
            // BUG-42: how long a FETCHED poster waits for the real backdrop before it is allowed
            // to paint. First paint: 600 ms from task start — long enough for a warm CDN hit,
            // short enough that a dead metahub entry never leaves the hero blank past the rows
            // (BUG-26 launch timing). Later swaps: 150 ms from the moment the fetched poster
            // ARRIVES (not from task start — on a slow network both fetches outlive a start-anchored
            // window and the flash comes back; Codex gate 8): the two fetches routinely complete
            // 1–4 ms apart (sim log 2026-08-18), and without a grace the poster painted, then the
            // backdrop painted over it a frame later — the reporter's "one cover then another" on
            // every hero move. A CACHED poster on a later swap still paints immediately
            // (stale-art protection).
            let firstPaintDeadline: UInt64 = 600_000_000
            let laterSwapGrace: UInt64 = 150_000_000
            enum Arrival { case primary(UIImage?), fallback(UIImage?), deadline }
            await withTaskGroup(of: Arrival.self) { group in
                group.addTask { .primary(try? await ArtworkStore.fetch(resolvedURL)) }
                if let resolvedFallback {
                    group.addTask { .fallback(try? await ArtworkStore.fetch(resolvedFallback)) }
                }
                if firstPaint {
                    group.addTask {
                        try? await Task.sleep(nanoseconds: firstPaintDeadline)
                        return .deadline
                    }
                }
                var deadlinePassed = false
                var graceArmed = firstPaint
                // BUG-42: once the FIRST paint has been committed with the poster (deadline hit),
                // a late backdrop must not paint over it — that IS the double commit. The item's
                // next visit finds the backdrop cached and paints it once, from the start.
                var firstPaintCommittedWithFallback = false
                for await arrival in group {
                    guard !Task.isCancelled else { return }
                    switch arrival {
                    case let .primary(image):
                        guard let image else { continue }
                        showedArt = true
                        primaryLanded = true
                        if firstPaintCommittedWithFallback {
                            if HomeHeroProbe.enabled {
                                HomeHeroProbe.log(String(format: "paint suppressed kind=primaryAfterFirstPaintFallback sinceLaunch=%dms item=%@", HomeHeroProbe.sinceLaunchMs, identity))
                            }
                            continue
                        }
                        crossfade(to: image, kind: "primary", first: firstPaint)
                    case let .fallback(image):
                        guard let image else { continue }
                        if primaryLanded { continue }
                        if deadlinePassed {
                            if suppressFallback {
                                // H-1C: same suppression as the immediate branch above — the
                                // fetched poster must not repaint over this same title's art.
                                if HomeHeroProbe.enabled {
                                    HomeHeroProbe.log(String(format: "paint suppressed kind=sameTitleFallback sinceLaunch=%dms item=%@", HomeHeroProbe.sinceLaunchMs, identity))
                                }
                            } else {
                                showedArt = true
                                if firstPaint { firstPaintCommittedWithFallback = true }
                                crossfade(to: image, kind: "fallbackFetched", first: firstPaint)
                            }
                        } else {
                            heldFallback = image
                            if !graceArmed {
                                graceArmed = true
                                group.addTask {
                                    try? await Task.sleep(nanoseconds: laterSwapGrace)
                                    return .deadline
                                }
                            }
                        }
                    case .deadline:
                        deadlinePassed = true
                        if !primaryLanded, let held = heldFallback {
                            if suppressFallback {
                                // H-1C: same suppression again — the held poster must not repaint
                                // over this same title's art either.
                                if HomeHeroProbe.enabled {
                                    HomeHeroProbe.log(String(format: "paint suppressed kind=sameTitleFallback sinceLaunch=%dms item=%@", HomeHeroProbe.sinceLaunchMs, identity))
                                }
                            } else {
                                showedArt = true
                                if firstPaint { firstPaintCommittedWithFallback = true }
                                crossfade(to: held, kind: "fallbackHeld", first: firstPaint)
                            }
                        }
                    }
                }
            }
            // Every source failed terminally and nothing provisional made it up: same rule as
            // the no-URL case — stale art under a mismatched title is worse than the flat
            // background.
            guard !Task.isCancelled, !showedArt else { return }
            if isSameTitleUpgrade {
                // H-1C: the SAME title is already on screen with good art — the whole point of
                // suppressing the fallback repaints above is defeated if a failed upgrade then
                // fades that good art to the flat background anyway. Keep it. A genuine title
                // change (isSameTitleUpgrade false) still falls through to fadeToEmpty() below,
                // unchanged.
                if HomeHeroProbe.enabled {
                    HomeHeroProbe.log(String(format: "paint suppressed kind=sameTitleFadeToEmpty sinceLaunch=%dms item=%@", HomeHeroProbe.sinceLaunchMs, identity))
                }
                return
            }
            fadeToEmpty()
        }
        }
    }

    /// The `.task(id:)` key. URL-driven keeps its exact historical spelling (identity + both URLs
    /// — see the comment at the call site). Image-driven keys on the bitmap's own object identity,
    /// which is what actually changes there; `ArtworkStore` vends one decoded instance per URL, so
    /// this is stable across re-renders and changes exactly when the artwork does.
    private var taskKey: String {
        guard imageDriven else { return "\(identity)|\(url ?? "")|\(fallbackURL ?? "")" }
        let stamp = directImage.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue)) } ?? "nil"
        return "image|\(identity)|\(stamp)"
    }

    /// Wave H: commit the caller-resolved bitmap. Same bookkeeping as the URL ladder's terminal
    /// paints — `crossfade` owns the probe line, the `paintedIdentity` state and the fade — so the
    /// two modes report identically.
    private func applyDirectImage() {
        let firstPaint = current == nil && previous == nil
        if !firstPaint, paintCount == 0, !didLogSeededPaint, HomeHeroProbe.enabled {
            didLogSeededPaint = true
            // `same=0` on purpose: this line is the FIRST paint of this view instance (init seeded
            // it from the presentation), so there is nothing it could be repainting over, even
            // though `paintedIdentity` was seeded alongside it.
            HomeHeroProbe.log(String(format: "paint kind=seededPrimary first=1 sinceLaunch=%dms hadArt=0 url=image same=0 item=%@", HomeHeroProbe.sinceLaunchMs, identity))
        }
        guard let directImage else {
            fadeToEmpty()
            return
        }
        crossfade(to: directImage, kind: "image", first: firstPaint)
    }

    /// Which source the painted bitmap came from, for the probe's `url=` field: `banner` (the
    /// item's own backdrop), `metahub` (the synthesized CDN backdrop), `poster` (the fallback
    /// ladder), `image` (Wave H's resolver-supplied bitmap), `none` (no primary URL at all).
    private func paintURLKind(_ kind: String) -> String {
        if imageDriven { return "image" }
        if kind.hasPrefix("fallback") { return "poster" }
        guard let url, !url.isEmpty else { return "none" }
        return url.contains("images.metahub.space") ? "metahub" : "banner"
    }

    /// The no-artwork terminal state: fade the last image out to the flat background (scrim and
    /// background color remain — the same look a titles-without-art hero always had).
    private func fadeToEmpty() {
        guard current != nil || previous != nil else { return }
        previous = current
        current = nil
        // H-1C: nothing is committed any more — the next task run must not treat whatever item
        // this was as a same-title upgrade just because its identity string is still sitting here.
        paintedIdentity = nil
        paintedFallbackURL = nil
        if reduceMotion || previous == nil {
            previous = nil
            previousOpacity = 0
            return
        }
        previousOpacity = 1
        withAnimation(.easeInOut(duration: 0.3)) {
            previousOpacity = 0
        }
        let fading = previous
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if previous === fading { previous = nil }
        }
    }

    /// `first` = this task started with nothing on screen (the hero's first paint); `hadArt` on the
    /// log line says whether THIS swap replaced an image (a second commit) or filled a blank.
    private func crossfade(to image: UIImage, kind: String = "swap", first: Bool = false) {
        guard image !== current else {
            // Codex wave-3 r2 (P2): the image is already on screen, but THIS commit may belong to
            // a different item that resolved to the same bitmap (identity joined the task key
            // above) — refresh the painted ownership so the suppression state tracks the item
            // actually being displayed, not the one that first loaded the pixels.
            paintedIdentity = identity
            paintedFallbackURL = fallbackURL
            return
        }
        paintCount += 1
        if HomeHeroProbe.enabled, imageDriven, current != nil, identity == paintedIdentity,
           HeroSharpen.isAdopted(image) {
            // beta.19-rc1 verdict (I1, BUG-134): the resolver's post-commit sharpen, a sharper
            // version of the picture already on screen. Logged as its own console line, not as
            // `paint … same=1`: that token is the repaint signature the photo contract forbids
            // (test31, test62), and this is the one same-item repaint that is intended.
            HeroSharpen.log("paint item=\(identity)")
        } else if HomeHeroProbe.enabled {
            // Wave H adds `url=` and `same=`. Both sit BEFORE `item=`, which stays last: the
            // harness parses the item id as "everything after `item=`" (NuvioTVUITests test31), so
            // appending past it would silently make that oracle unparseable. No existing field is
            // renamed or reordered relative to the others.
            // `same=1` means this paint replaced art that was already this same item's — a repaint,
            // which after Wave H should only ever be a genuine re-resolve, never a raw-then-
            // enriched swap.
            let same = identity == paintedIdentity ? 1 : 0
            HomeHeroProbe.log(String(format: "paint kind=%@ first=%d sinceLaunch=%dms hadArt=%d url=%@ same=%d item=%@", kind, first ? 1 : 0, HomeHeroProbe.sinceLaunchMs, current == nil ? 0 : 1, paintURLKind(kind), same, identity))
        }
        previous = current
        current = image
        // H-1C: record which item this committed image belongs to — the same-title-upgrade check
        // near the top of the `.task` compares its `identity` against this on the NEXT task run
        // for this (persistent, never-re-identified) view instance.
        paintedIdentity = identity
        paintedFallbackURL = fallbackURL
        if reduceMotion || previous == nil {
            previous = nil
            previousOpacity = 0
            return
        }
        // Fade the old image (now stacked on top) out over the new one, then release the decoded
        // bitmap once it's invisible — unless another swap has already taken over the slot.
        previousOpacity = 1
        withAnimation(.easeInOut(duration: 0.3)) {
            previousOpacity = 0
        }
        let fading = previous
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if previous === fading { previous = nil }
        }
    }
}

/// Gradient scrims over the hero backdrop: a subtle top darkening under the tab bar, and a bottom
/// fade to the app background so the backdrop blends into the rows region below.
struct HomeHeroScrim: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.55), location: 0.0),
                .init(color: .black.opacity(0.15), location: 0.18),
                .init(color: .clear, location: 0.42),
                .init(color: Theme.Palette.background.opacity(0.85), location: 0.82),
                .init(color: Theme.Palette.background, location: 1.0),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: Theme.Size.heroBackdropHeight)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// One page of the hero carousel — a single focusable target that opens the detail screen.
/// Two layouts (UX-2 hero redesign — the tester's "hero info on the right" meant the ARTWORK
/// on the right, clarified by Christian's reference photos 2026-07-30):
/// - **Classic** (default): logo/meta/synopsis on the lower left — the original layout.
/// - **Nuvio-style** (Settings → Home Screen → "Nuvio-Style Hero"): title/description in a
///   fixed-width panel on the LEFT, raised toward the top of the backdrop, while the artwork
///   reads on the right behind `HomeHeroLeadingScrim` — upstream's modern-home look.
/// Both obey the fixed-slot rule: every slot has a FIXED height/width, so all pages are
/// layout-identical and advancing the carousel can never reflow anything around it. The same rule
/// is what lets a focus takeover (UX-7) — and FEAT-15's focus panel, where every repaint is a
/// takeover — swap titles without moving the rows underneath.
///
/// Accessibility note for the CTA-less form (`showsCTA: false`): the info block keeps its combined
/// accessibility element, but with no focusable descendant tvOS VoiceOver has no way to land on
/// it. That is not a regression — Show Hero off previously rendered no hero region at all — but it
/// does mean the synopsis is sighted-only in that mode. Restoring it needs a focusable element,
/// which is exactly what the mode removes on purpose; a non-competing route (e.g. folding the
/// synopsis into the focused card's accessibility value) would belong in the row components.
struct HomeHeroForeground: View {
    /// Wave H: the committed hero — the item AND its resolved logo bitmap. Taking the logo as a
    /// value instead of letting `HeroLogo` fetch its own is what removes BUG-86 phenomenon B /
    /// BUG-90: the wordmark and the title text can no longer be drawn superimposed, because there
    /// is no longer a moment where one has arrived and the other has not.
    ///
    /// beta.19-rc1 verdict (M5, BUG-138): the presentation whose TEXT is on screen —
    /// `HeroTextLayer`'s `TextSwapModel.shown`, which lags the resolver's committed hero by one
    /// fade-out (0.12 s) so the old and the new text are never drawn together. The CTA follows it.
    let textPresentation: HeroPresentation
    /// The info block's opacity, applied OUTSIDE its `.id` through `textAnimation` (see
    /// `TextSwapModel`'s type doc). 1 and nil for a host with no swap model.
    var textOpacity: Double = 1
    var textAnimation: Animation? = nil
    /// The item the presentation carries; every layout below reads this, unchanged.
    private var item: MetaPreview { textPresentation.item }
    /// Bound to the CTA button — the hero page's ONLY focusable element. The info block above
    /// it is static content (Christian's spec 2026-07-30: the title is no longer selectable;
    /// a "Go to Movie"/"Go to Show" button below the description carries focus instead).
    var heroFocused: FocusState<Bool>.Binding
    /// Compact slots for the PINNED hero (device round 6): smaller logo slot, 2-line synopsis,
    /// tighter vertical padding — the pinned split must leave the rows viewport large enough
    /// for a reach-extended focus frame plus the engine's reveal margin. Classic and full
    /// Nuvio (never pinned) always pass false and are layout-identical to before.
    var compact: Bool = false
    /// FEAT-15: false in the Show-Hero-off focus panel, which has no carousel and therefore no
    /// reason to own a focusable element (see `HomeView.heroCarousel`). The CTA's fixed slot is
    /// not left empty — `synopsisSlotHeight` absorbs it — so the panel's total height, and with it
    /// the pinned rows viewport, is unchanged in both modes.
    var showsCTA: Bool = true
    /// FEAT-15: forces the Nuvio (leading text column / trailing artwork) layout regardless of the
    /// stored `hero_nuvio_style` preference. The focus panel always uses it: it is the layout the
    /// request is modelled on, the pinned geometry has only ever been device-tuned for it, and its
    /// Settings row is hidden while Show Hero is off.
    var forceNuvioLayout: Bool = false
    /// BUG-38 round three: set when `item` is a collection folder's preview — the CTA then opens
    /// the folder page instead of a Detail route for an id no addon can resolve.
    var folderRoute: FolderRoute? = nil
    /// Wave 10: how many points the PINNED hero is yielding to the rows below it, so the focused
    /// row fits at the canonical rest. Spent on the two elastic slots rather than clipped off the
    /// frame — the logo slot first, then the synopsis — because a hard-clipped hero was the
    /// alternative the product review rejected. 0 everywhere except pinned mode at a Poster Size
    /// that needs it (Large today; Small/Medium compute 0 and are bit-identical to Wave 9).
    var compression: CGFloat = 0
    @AppStorage("hero_nuvio_style") private var heroNuvioStyle = false

    /// The compression split across the two elastic slots, each bounded by its own floor.
    ///
    /// FEAT-29 (Steven's beta.17 report): SYNOPSIS gives first now, logo takes the remainder — the
    /// reverse of Wave 10's original order. A collection FOLDER hero has no synopsis text to
    /// protect (`HomeView.folderHeroPreview` always sends `description: nil`), so its give ceiling
    /// is the WHOLE synopsis slot (`heroSynopsisSlotHeightPinned`, 72 — a genuine 0 floor) rather
    /// than the floor-bounded `heroSynopsisSlotPinnedGive` (36) title heroes use; at Large,
    /// `min(68.3, 72) == 68.3` covers the whole compression and the folder's logo slot gives up
    /// nothing (matches the FEAT-29 design note: "0 at Large since 68.3 ≤ 72"). A TITLE hero keeps
    /// its floor-bounded synopsis ceiling (36) and its own logo-give ceiling
    /// (`heroLogoSlotPinnedGive`, 32) — at Large the two sum to the same 68pt Wave 10 always gave
    /// (36 + 32), so nothing changes there; the swapped order only changes which slot gives first
    /// at INTERMEDIATE compressions (a synced custom Poster Size between Medium and Large), where
    /// the logo now stays at its full 110pt until the synopsis alone has given all 36 of its own
    /// pt — the same regression class this fix closes for folder heroes, closed here too.
    ///
    /// BUG-87 (beta.18): the ceiling is stated against the slot this hero form ACTUALLY has. In
    /// FEAT-15's panel (`showsCTA == false`) the synopsis has already absorbed the CTA slot and the
    /// `md` above it — 144pt, not 72 — so its give against the same one-line floor is 108, and a
    /// folder hero's is the whole 144. Charging the carousel's 36/72 there capped the give 72pt
    /// short of what the panel can really yield, which is why Steven's shape could not be made to
    /// fit: the FRAME would have shrunk past what the CONTENT gave up, the exact overflow
    /// `Theme.Size.heroPinnedCompressionCap` exists to prevent. Carousel numbers are unchanged.
    ///
    /// rc2 (2026-09-06): the split itself now lives in `PinnedRowGeometry.HeroSlotGive`, which is a
    /// pure value function and therefore unit-tested rather than reasoned about here — these two
    /// properties are thin wrappers over it. The behaviour change it carries is for the PANEL form
    /// only: it no longer drains the panel's whole 108pt of synopsis give before touching the logo.
    /// It spends the carousel's own 36 first, then the logo's 32, and only reaches the extra 72 the
    /// panel absorbed from the CTA for compressions past those two plus the frame's 2pt of slack.
    /// At the tester's 68.33 that is synopsis 36 + logo 32 ⇒ a 108pt synopsis slot ⇒ **3 lines**,
    /// the beta.17 reading he asked to keep, where the drain-synopsis-first order gave 2. Carousel
    /// and collection-folder heroes are numerically unchanged at every compression.
    /// rc14 (BUG-119, review r1 P3): the folder-hero split (synopsis slot drained first, logo
    /// unbounded) only applies where the folder hero is DRAWN as the merged logo-only box — the
    /// carousel. The panel renders a folder through the three-slot column with real text in the
    /// synopsis slot now, so it takes the title hero's floors.
    private var splitsAsFolderHero: Bool { isCollectionHero(item) && showsCTA }

    private var synopsisSlotGive: CGFloat {
        PinnedRowGeometry.HeroSlotGive.split(compression: compression,
                                             showsCTA: showsCTA,
                                             folderHero: splitsAsFolderHero).synopsis
    }
    private var logoSlotGive: CGFloat {
        PinnedRowGeometry.HeroSlotGive.split(compression: compression,
                                             showsCTA: showsCTA,
                                             folderHero: splitsAsFolderHero).logo
    }

    /// The compact (pinned) logo slot's height after `logoSlotGive`, or the classic fixed slot
    /// outside pinned mode. Shared by the title-hero column (`nuvioLayout`'s non-folder branch)
    /// and the folder-hero merged box's total-height arithmetic (both need the SAME number the
    /// three-slot layout would have used, so the panel's total height never changes — see that
    /// layout's comment).
    private var logoSlotHeight: CGFloat {
        compact ? Theme.Size.heroLogoSlotHeightPinned - logoSlotGive : Theme.Size.heroLogoSlotHeight
    }

    private var usesNuvioLayout: Bool { forceNuvioLayout || heroNuvioStyle }

    /// rc14: the pinned hero's slot gap (12) — see `Theme.Size.heroPinnedSlotGap`. Classic keeps
    /// `Spacing.md`.
    private var slotGap: CGFloat { compact ? Theme.Size.heroPinnedSlotGap : Theme.Spacing.md }

    var body: some View {
        VStack(alignment: .leading, spacing: slotGap) {
            // Wave H: the info block is ONE unit — logo, meta line and synopsis change together,
            // never one item's text against another's logo.
            //
            // beta.19-rc1 verdict (M5, BUG-138): it no longer CROSS-fades. Under Wave H the block
            // was `.transition(.opacity)` inside the resolver's 0.3 s commit transaction, so the old
            // and the new block were both on screen for 0.3 s (Steven's doubled title). Now
            // `HeroTextLayer`'s `TextSwapModel` fades the old text OUT, swaps it while invisible and
            // fades the new text IN: the swap is a hard cut (`.transition(.identity)`, in an
            // animation-free transaction) and only the opacity, applied OUTSIDE the `.id`, animates
            // (`textAnimation`'s scoped curve). `hero_info` names the block for the UI legs (all
            // builds); in DEBUG, `HeroInfoLiveCounter` counts live blocks from INSIDE the `.id`
            // (`debug_heroText … maxLive=`, test89: a second live block reads 2).
            //
            // Two deliberate details kept from Wave H. The `.id` is on this block and NOT on the CTA
            // below it: the CTA is the hero's only focusable element, and re-identifying a focused
            // view hands the tvOS focus engine a removal it did not ask for (the CTA is not faded
            // either). And the block stays wrapped in a ZStack rather than sitting directly in the
            // VStack: should two copies ever be alive at once again, as VStack children they would
            // stack VERTICALLY — the hero would grow by its own height and shove every row down, the
            // moving-block input BUG-87's corrector then chases. Overlaid in a ZStack they occupy the
            // same fixed-height slot and nothing reflows.
            ZStack(alignment: .topLeading) {
                Group {
                    if usesNuvioLayout {
                        nuvioLayout
                    } else {
                        classicLayout
                    }
                }
                .accessibilityElement(children: .combine)
                #if DEBUG
                .onAppear { HeroInfoLiveCounter.appear() }
                .onDisappear { HeroInfoLiveCounter.disappear() }
                #endif
                .id(textPresentation.identity)
                .transition(.identity)
                .animation(textAnimation) { $0.opacity(textOpacity) }
                .accessibilityIdentifier("hero_info")
            }
            #if DEBUG
            .overlay(alignment: .topLeading) {
                // 2026-09-10 diagnostic (invisible, harness-readable): the measured-line-height
                // inputs to `synopsisLineLimit` (BUG "1–2 lines" — see that property's doc). `synL`
                // is the resolved line limit, `synLH` the measured `Theme.Font.bodyLineHeight`
                // feeding it (rounded for a stable harness read), `synSlot` the synopsis slot
                // height it applies to. No probe existed inside `HomeHeroForeground` before this —
                // added here rather than threading these private computed properties out to
                // `HomeView`'s `debug_env`/`debug_hero` probes, which live in a different struct
                // and cannot see them.
                //
                // P2 fix: this was previously a plain VStack child below the hero ZStack, so its
                // own text height plus the VStack's `spacing` shifted the CTA down and grew the
                // hero's measured content height in DEBUG builds — changing the very geometry it
                // was added to observe. Attached as an `.overlay` on the ZStack instead, it draws
                // on top without being sized into the VStack's layout.
                Text("debug_hero_synopsis synL=\(synopsisLineLimit) synLH=\(Int(Theme.Font.synopsisLineHeight.rounded())) synSlot=\(Int(synopsisSlotHeight.rounded()))")
                    .font(.system(size: 8))
                    .opacity(0.011)
                    .accessibilityIdentifier("debug_hero_synopsis")
                    .allowsHitTesting(false)
            }
            #endif

            // The CTA sits below the description and above the page dots (which render
            // outside the TabView). D-pad left/right still pages the carousel while this
            // button holds focus — it is the page's focus anchor.
            if showsCTA {
                Group {
                    if let folderRoute {
                        NavigationLink(value: folderRoute) {
                            Text(ctaTitle)
                                .font(Theme.Font.body)
                        }
                    } else {
                        NavigationLink(value: TitleRoute(preview: item)) {
                            Text(ctaTitle)
                                .font(Theme.Font.body)
                        }
                    }
                }
                .buttonStyle(.glass)
                .focused(heroFocused)
                .frame(height: Theme.Size.heroButtonSlotHeight, alignment: .center)
                .accessibilityLabel("\(ctaTitle): \(item.name)")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        // rc14: pinned vertical padding 16 → 12 (`heroPinnedVerticalPad`) — part of the chrome
        // shave that hands `HeroSlotGive.split` 22pt of free slack. Classic keeps `lg`.
        .padding(.vertical, compact ? Theme.Size.heroPinnedVerticalPad : Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fixed synopsis slot. FEAT-15: with no CTA the panel would otherwise centre itself inside
    /// the hero region's fixed frame and leave a dead band where the button used to be, so the
    /// synopsis absorbs the CTA slot AND the gap that preceded it — same arithmetic on the
    /// same existing tokens, no new Theme constant, and the summed panel height comes out
    /// IDENTICAL, which is what keeps the pinned rows viewport (and every `heroPinned*` reach
    /// constant tuned against it) untouched. rc14 numbers (chrome shave: 12pt pads, 12pt gaps):
    ///     carousel form  24 padding + 110 logo + 12 + 32 meta + 12 + 72 synopsis + 12 + 56 CTA = 330
    ///     panel form     24 padding + 110 logo + 12 + 32 meta + 12 + 140 synopsis            = 330
    /// both inside the 352pt `heroCarouselHeightPinned` frame the caller pins; the 22 left over is
    /// `heroPinnedFrameSlack`, which the split spends first. The line limit grows with the slot:
    /// 140pt fits four `Theme.Font.synopsis` lines, so the panel FEAT-15 asks for shows twice the
    /// description the pinned carousel could.
    ///
    /// BUG-87 (beta.18): the compact branch resolves the panel's slot from
    /// `heroSynopsisSlotHeightPinnedPanel` (which IS `72 + 56 + 16`) before subtracting the give,
    /// instead of subtracting the give from 72 and adding the CTA terms back afterwards. Same
    /// number in every configuration that shipped; it stops being the same one once the give can
    /// exceed 72, which is what the panel's real ceiling now allows.
    private var synopsisSlotHeight: CGFloat {
        guard compact else {
            let base = Theme.Size.heroSynopsisSlotHeightNuvio
            return showsCTA ? base : base + Theme.Size.heroButtonSlotHeight + Theme.Spacing.md
        }
        let slot = showsCTA ? Theme.Size.heroSynopsisSlotHeightPinned
                            : Theme.Size.heroSynopsisSlotHeightPinnedPanel
        return slot - synopsisSlotGive
    }

    /// Lines the synopsis may use, tracking `synopsisSlotHeight` above.
    ///
    /// Wave 10: a compressed synopsis slot must drop a line with it, or the text clips inside its
    /// own frame instead of shortening.
    ///
    /// BUG-87 (beta.18): DERIVED from the resolved slot rather than from a give>0 flag. The pinned
    /// slot is exactly two 36pt lines, so the line height is the constant divided by two and the
    /// limit is however many whole lines the slot still holds. That reproduces every number the
    /// flag produced — carousel 72 → 2, carousel compressed 36 → 1, panel 144 → 4, panel at Wave
    /// 10's Large give (108) → 3 — and keeps holding once the panel's give can take the slot below
    /// 72, where the flag would have claimed three lines in a one-line box.
    ///
    /// 2026-09-10: the `/ 2` above assumed a 36pt line, which is not `Theme.Font.body`'s real
    /// rendered line height — the system face is ≈35pt and Open Sans (FEAT-31) is ≈39.5pt at the
    /// same size. That mismatch undercounted Open Sans (a 108pt slot drew 2 lines while this
    /// counted 3 — the tester's report) and, after this batch's Large reach change puts the
    /// No-Zoom panel slot at 107.67, overcounts the system face too (36 rounds it down to 2 when
    /// the real ~35pt line fits 3). Measured via `Theme.Font.bodyLineHeight` instead of assumed.
    private var synopsisLineLimit: Int {
        guard compact else { return showsCTA ? 3 : 5 }
        // Measured, not assumed — see `Theme.Font.synopsisLineHeight` (rc14: the synopsis is set
        // in `Theme.Font.synopsis`, one text style below `body`, so its own metric is the one that
        // counts). A slot that is short of a whole line by less than `lineTolerance` still gets
        // the line: the synopsis `Text` sits in a fixed-height frame, so an overhang that small is
        // clipped by the frame and never seen, whereas rounding it away costs a whole visible line
        // (the 107.67-vs-108 case).
        let lineHeight = Theme.Font.synopsisLineHeight
        let lineTolerance: CGFloat = 1
        guard lineHeight > 0 else { return 1 }
        return max(1, Int(((synopsisSlotHeight + lineTolerance) / lineHeight).rounded(.down)))
    }

    /// "movie" is the only meta type that reads as a film; series/tv both read as shows.
    private var ctaTitle: String {
        if folderRoute != nil { return String(localized: "Open Folder") }
        return item.type == "movie"
            ? String(localized: "Go to Movie")
            : String(localized: "Go to Show")
    }

    /// Nuvio-style: fixed-width text column on the left (logo, meta, 3-line synopsis) — the
    /// artwork owns the rest of the frame to the right.
    ///
    /// FEAT-29: a collection FOLDER hero (`isCollectionHero(item)`) renders a single MERGED box
    /// instead — `folderHeroPreview` always sends `description: nil, genres: []`, so the
    /// three-slot column used to draw an empty meta line and an empty synopsis under a wordmark
    /// that Wave 10's (pre-fix) give order shrank first. One generously-sized, vertically centred
    /// `HeroLogo` reads as the reference footage instead (`zoom-nuvio-collection-t96.png`). The
    /// box's total height is `logoSlotHeight + md + heroMetaSlotHeight + md + synopsisSlotHeight`
    /// — the EXACT sum the three-slot VStack below would have consumed (two `Spacing.md` gaps
    /// between three children, `.frame(height:)` on each) — so the outer `heroCarouselHeightPinned
    /// - compression` frame this whole view sits inside never changes and rows below cannot
    /// reflow; only what is drawn inside the box differs.
    private var nuvioLayout: some View {
        Group {
            if isCollectionHero(item) && showsCTA {
                HeroLogo(item: item, image: textPresentation.logo,
                         maxHeight: Theme.Size.heroFolderLogoHeightOverride
                            ?? Theme.Size.heroFolderLogoSlotHeight,
                         ink: textPresentation.logoInk)
                    .frame(height: logoSlotHeight + slotGap + Theme.Size.heroMetaSlotHeight
                                   + slotGap + synopsisSlotHeight,
                           alignment: .leading)
            } else {
                // rc14 (BUG-119, Steven 2026-09-13 + rc13 verdict): in the CTA-less PANEL form a
                // focused collection folder keeps the three-slot column — wordmark, then the
                // folder's collection name as the meta line and a one-line description in the
                // synopsis slot — instead of the carousel's merged logo-only box. "I can still see
                // the top row, and there's no title or description in this mode": the panel's job
                // is to describe the focused tile, and a folder has a name even when it has no
                // synopsis. The merged box stays for the carousel (FEAT-29's reference footage).
                VStack(alignment: .leading, spacing: slotGap) {
                    HeroLogo(item: item, image: textPresentation.logo, ink: textPresentation.logoInk)
                        .frame(height: logoSlotHeight, alignment: .bottomLeading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(metaLine)
                        .font(Theme.Font.metaStrong)
                        .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                        .lineLimit(1)
                        .frame(height: Theme.Size.heroMetaSlotHeight, alignment: .leading)

                    Text(synopsis)
                        .font(Theme.Font.synopsis)
                        .foregroundStyle(Theme.Palette.textPrimary.opacity(0.85))
                        .lineLimit(synopsisLineLimit)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: synopsisSlotHeight, alignment: .topLeading)
                        // Wave H: a description that arrives after its hero was committed (the
                        // one gap-fill the commit protocol still allows) lands with NO motion. The
                        // slot's height is fixed either way, so there is nothing to animate but
                        // the text itself, and animating that is the "empty synopsis, then it
                        // pops in" the tester filmed.
                        .animation(nil, value: synopsis)
                }
            }
        }
        .frame(width: Theme.Size.heroInfoPanelWidth, alignment: .leading)
    }

    /// The original bottom-left layout. FEAT-29: gets the same folder-hero merged-box treatment as
    /// `nuvioLayout` — it already has its own logo slot to merge into, and `compression` is always
    /// 0 in classic (the in-scroll hero, `heroCarousel`'s `compact: false` call site), so the box
    /// total is the fixed sum below rather than `logoSlotHeight`/`synopsisSlotHeight`'s compact
    /// arithmetic.
    private var classicLayout: some View {
        Group {
            if isCollectionHero(item) {
                HeroLogo(item: item, image: textPresentation.logo,
                         maxHeight: Theme.Size.heroFolderLogoHeightOverride
                            ?? Theme.Size.heroFolderLogoSlotHeight,
                         ink: textPresentation.logoInk)
                    .frame(height: Theme.Size.heroLogoSlotHeight + Theme.Spacing.md
                                   + Theme.Size.heroMetaSlotHeight + Theme.Spacing.md
                                   + Theme.Size.heroSynopsisSlotHeight,
                           alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HeroLogo(item: item, image: textPresentation.logo, ink: textPresentation.logoInk)
                        .frame(height: Theme.Size.heroLogoSlotHeight, alignment: .bottomLeading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(metaLine)
                        .font(Theme.Font.metaStrong)
                        .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                        .lineLimit(1)
                        .frame(height: Theme.Size.heroMetaSlotHeight, alignment: .leading)

                    Text(synopsis)
                        .font(Theme.Font.synopsis)
                        .foregroundStyle(Theme.Palette.textPrimary.opacity(0.85))
                        .lineLimit(2)
                        .frame(maxWidth: 1000, alignment: .leading)
                        .frame(height: Theme.Size.heroSynopsisSlotHeight, alignment: .topLeading)
                        // Wave H: see the same line in `nuvioLayout` — a late description must
                        // not animate.
                        .animation(nil, value: synopsis)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var synopsis: String {
        let description: String? = item.description_
        return description ?? ""
    }

    private var metaLine: String {
        var parts: [String] = []
        let release: String? = item.releaseInfo
        if let release, !release.isEmpty { parts.append(release) }
        let genres = item.genres.prefix(3)
        if !genres.isEmpty { parts.append(genres.joined(separator: " \u{00B7} ")) }
        return parts.joined(separator: "  \u{00B7}  ")
    }
}

/// beta.19-rc1 verdict (M5, BUG-138): the hero's text layer. Owns and OBSERVES the text swap model
/// (`HeroTextSwapModel`, `.classic` timing), so a hero change re-renders this layer and
/// `HomeHeroForeground`, never `HomeView`'s body, which holds no swap model and observes nothing
/// new (critique #11).
///
/// The resolver's committed `presentation` still drives the artwork (`HomeHeroBackdrop`, unchanged)
/// the instant it commits; the TEXT follows one fade-out later: old text out over 0.12 s, swapped
/// while invisible, new text in over 0.12 s. A same-identity update (a late synopsis, spec B's
/// post-commit sharpen) is a silent gap-fill. The CTA follows the visible text, so it never opens
/// a title whose name is not on screen.
///
/// Lives in this file, not `HeroTextSwap.swift`, because `HomeHeroForeground`'s memberwise init is
/// file-private (it has a private `@AppStorage`).
struct HeroTextLayer: View {
    /// The resolver's committed hero (`HeroArtResolver.presented`).
    let presentation: HeroPresentation
    var heroFocused: FocusState<Bool>.Binding
    var compact: Bool
    var showsCTA: Bool
    var forceNuvioLayout: Bool
    var compression: CGFloat
    /// `HomeView.heroFolderRoutes`: looked up for the VISIBLE text's item, so a folder CTA opens the
    /// folder whose name is on screen.
    var folderRoutes: [String: FolderRoute]

    @StateObject private var textSwap = HeroTextSwapModel(timing: .classic, identity: { $0.identity })
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let text = textSwap.shown ?? presentation
        HomeHeroForeground(textPresentation: text,
                           textOpacity: textSwap.textOpacity,
                           textAnimation: textSwap.opacityAnimation,
                           heroFocused: heroFocused,
                           compact: compact,
                           showsCTA: showsCTA,
                           forceNuvioLayout: forceNuvioLayout,
                           folderRoute: isCollectionHero(text.item) ? folderRoutes[text.item.id] : nil,
                           compression: compression)
            .onAppear { textSwap.seed(presentation) }
            .onChange(of: presentation) { _, next in
                textSwap.receive(next, reduceMotion: reduceMotion)
            }
            #if DEBUG
            .overlay(alignment: .topLeading) {
                // Invisible, harness-readable (test89): the swap's live state plus the live info
                // block high-water mark. Append-only: `phase= shown= pending= swaps= maxLive=`.
                // `maxLive=1` is the "never two titles at once" oracle; a block that lingers next to
                // its successor reads 2 (see `HeroInfoLiveCounter`).
                Text("debug_heroText \(textSwap.debugLine) maxLive=\(HeroInfoLiveCounter.max)")
                    .font(.system(size: 8))
                    .opacity(0.011)
                    .accessibilityIdentifier("debug_heroText")
                    .allowsHitTesting(false)
            }
            #endif
    }
}

#if DEBUG
/// beta.19-rc1 verdict (M3/R2, BUG-133): the inline trailer event log (`InlineTrailerDebugLog`,
/// written by `InlineTrailerCardModel`) as an invisible, harness-readable label. A LEAF view that
/// observes the log itself, so an event re-renders this label and never `HomeView`'s body
/// (critique #11).
///
/// Spelling: `debug_trailerMorph <last event> aborts=N`. The event is the log's own line
/// (`event=gate|reveal|wide|shrink|dissolve|abort|defer|play|mute host=card|hero key=…`); `aborts=`
/// is appended after it (`abortCount` moves in the same `note` that publishes `last`).
struct TrailerMorphDebugLabel: View {
    @ObservedObject private var log = InlineTrailerDebugLog.shared

    var body: some View {
        Text("debug_trailerMorph \(log.last) aborts=\(log.abortCount)")
            .font(.system(size: 8))
            .opacity(0.011)
            .accessibilityIdentifier("debug_trailerMorph")
            .allowsHitTesting(false)
    }
}

/// beta.19-rc1 verdict (B2, BUG-131): the trailer listener lifecycle (`TrailerListenerDebug`,
/// mirrored from every `[TrailerRepack] listener …` line) as an invisible, harness-readable label.
/// A LEAF view, like `TrailerMorphDebugLabel`.
///
/// Spelling: `debug_trailerListener <last> rebuilds=N recent=<newest six, " | "-joined>`. `last` is
/// overwritten by the `start`/`ready` lines a moment after a rebuild, so an oracle for "a rebuild
/// happened" (test91: `rebuild reason=active`) reads `rebuilds=` or `recent=`, never `last`.
/// `rebuilds` moves in the same `note` that publishes `last`/`recent`.
struct TrailerListenerDebugLabel: View {
    @ObservedObject private var listener = TrailerListenerDebug.shared

    var body: some View {
        Text("debug_trailerListener \(listener.last) rebuilds=\(listener.rebuilds) recent=\(listener.recent)")
            .font(.system(size: 8))
            .opacity(0.011)
            .accessibilityIdentifier("debug_trailerListener")
            .allowsHitTesting(false)
    }
}
#endif

/// BUG-38 round three: the `MetaPreview.type` a collection folder's hero preview carries, and
/// the scheme its synthetic id starts with. Both are namespaced so no addon catalog item can
/// satisfy `isCollectionHero` by accident (Codex round 1: Stremio manifests may declare ANY
/// media type — "collection" included — and a real title misclassified here would lose its hero
/// trailer and enrichment). The predicate requires BOTH the dotted type and the id scheme; a
/// catalog would have to ship that exact pair, which nothing does.
let collectionHeroType = "nuvio.folder"
let collectionHeroIdScheme = "nuvio-folder://"

func isCollectionHero(_ item: MetaPreview) -> Bool {
    item.type == collectionHeroType && item.id.hasPrefix(collectionHeroIdScheme)
}

/// Resolves the logo artwork URL for a hero item. Catalog previews (Cinemeta rows especially)
/// usually omit `logo` even when logo art exists, so for IMDb-id items fall back to metahub —
/// the same CDN Cinemeta's own full meta points at. A miss there just 404s and `HeroLogo`
/// shows its text wordmark, so the synthesized URL is strictly additive (BUG-17).
func heroLogoURL(for item: MetaPreview) -> URL? {
    heroLogoURL(logo: item.logo, id: item.id)
}

/// Same chain for a Continue Watching entry, so the CW row's prefetch warms the logo the hero will
/// actually wait on (`background`/`parentMetaId` play the banner/id roles, exactly as they do for
/// `heroBackdropURL(for:)`).
func heroLogoURL(for entry: WatchProgressEntry) -> URL? {
    heroLogoURL(logo: nil, id: entry.parentMetaId)
}

private func heroLogoURL(logo: String?, id: String) -> URL? {
    if let logo, !logo.isEmpty { return URL(string: logo) }
    let imdbId = id.split(separator: ":").first.map(String.init) ?? id
    guard imdbId.hasPrefix("tt") else { return nil }
    return URL(string: "https://images.metahub.space/logo/medium/\(imdbId)/img")
}

/// Resolves the backdrop artwork URL for a hero item — a carousel page, or (UX-7) a row poster
/// that has taken over the hero. `banner` covers the common case; IMDb-id items without one fall
/// back to metahub's background art (the same CDN `heroLogoURL` leans on above) before finally
/// falling back to poster art. Every step is strictly additive — a miss just moves to the next
/// source, never a hard failure.
func heroBackdropURL(for item: MetaPreview) -> String? {
    heroBackdropURL(banner: item.banner, id: item.id, poster: item.poster)
}

/// Same chain for a Continue Watching entry (`background` plays the banner role, the parent meta
/// id carries the IMDb id) — the CW row's prefetch must warm the URL the hero will actually
/// render, not a poster the metahub branch would shadow.
func heroBackdropURL(for entry: WatchProgressEntry) -> String? {
    heroBackdropURL(banner: entry.background, id: entry.parentMetaId, poster: entry.poster)
}

private func heroBackdropURL(banner: String?, id: String, poster: String?) -> String? {
    if let banner, !banner.isEmpty { return banner }
    let imdbId = id.split(separator: ":").first.map(String.init) ?? id
    if imdbId.hasPrefix("tt") {
        return "https://images.metahub.space/background/medium/\(imdbId)/img"
    }
    return (poster?.isEmpty == false) ? poster : nil
}

/// Prefetch wants BOTH candidates the hero can render — the resolved primary AND the poster
/// `HeroArtResolver` falls back to when the primary (typically a synthesized metahub URL) 404s or
/// stalls. Warming only the primary made exactly the fallback scenario the cold, flashing one, and
/// keeping the poster warm here is what makes the resolver's fallback usually free: it commits the
/// cached poster the instant the primary misses instead of spending its budget fetching one.
/// Cheap in practice: row posters are the card images already on screen, so `ArtworkStore`'s
/// cache check absorbs the duplicates.
/// Wave H: the LOGO is in here too. The hero now commits only once both its backdrop and its logo
/// have resolved (or a deadline passed), so a cold logo is a delayed hero — and every row-focus
/// prefetch warms both for the whole row rather than leaving the logo to be fetched at paint time.
func heroBackdropPrefetchURLs(for item: MetaPreview) -> [String] {
    var urls: [String] = []
    if let primary = heroBackdropURL(for: item) { urls.append(primary) }
    if let poster = item.poster, !poster.isEmpty, !urls.contains(poster) { urls.append(poster) }
    if let logo = heroLogoURL(for: item)?.absoluteString, !urls.contains(logo) { urls.append(logo) }
    return urls
}

/// beta.19-rc1 verdict (review r2, P3-1): `heroBackdropPrefetchURLs(for:)` as typed prefetch items
/// for the hero carousel's warm-up (`prefetchHeroArt`): the title logo at
/// `HeroSharpen.heroLogoRequest`, the request `HeroArtResolver.present` looks it up and fetches it
/// with (so the hero's own fetch joins this one while it is in flight instead of downloading the file
/// a second time), the backdrop and the poster at `.legacy` as before. The row-focus prefetches keep
/// the plain URL list: they run before the hero presents a row's item, and a slot-sized fetch joins
/// the larger legacy work still in flight (`ArtworkStore.inflightKeys`).
func heroArtPrefetchItems(for item: MetaPreview) -> [ArtworkPrefetchItem] {
    let logo = heroLogoURL(for: item)?.absoluteString
    let backdrop = heroBackdropURL(for: item)
    let logoRequest = HeroSharpen.heroLogoRequest
    return heroBackdropPrefetchURLs(for: item).compactMap { string in
        guard let url = URL(string: string) else { return nil }
        // A logo URL that is also the backdrop or the poster keeps the legacy decode those need.
        let logoOnly = string == logo && string != backdrop && string != item.poster
        return ArtworkPrefetchItem(url: url, decode: logoOnly ? logoRequest : .legacy)
    }
}

/// Continue Watching flavor of `heroBackdropPrefetchURLs(for:)`.
func heroBackdropPrefetchURLs(for entry: WatchProgressEntry) -> [String] {
    var urls: [String] = []
    if let primary = heroBackdropURL(for: entry) { urls.append(primary) }
    if let poster = entry.poster, !poster.isEmpty, !urls.contains(poster) { urls.append(poster) }
    if let logo = heroLogoURL(for: entry)?.absoluteString, !urls.contains(logo) { urls.append(logo) }
    return urls
}

/// The hero page's logo artwork, with the title text as its stand-in when the item has no logo (or
/// its logo did not resolve before the hero's commit deadline).
///
/// Wave H: STATELESS. It used to own a `.task` that fetched the logo and swapped Text→Image under
/// its own `withAnimation(.easeIn(0.25))` — with SwiftUI's default cross-dissolve that draws the
/// title text and the wordmark superimposed for the length of the fade, which is exactly what the
/// tester filmed on every hero change (BUG-86 phenomenon B, and BUG-90). There is nothing to fetch
/// here now: `HeroArtResolver` resolves the logo BEFORE the hero commits and hands it down as a
/// value, so text and image are two branches of one atomic state, never two overlapping paints.
///
/// `.id(item.id)` + `.transition(.identity)` make the branch swap a hard cut rather than a fade —
/// the fade belongs to the whole info block one level up (`HomeHeroForeground`), which fades the
/// OLD hero's text out and then the NEW hero's in (beta.19-rc1 verdict M5, `TextSwapModel`), never
/// one item's text against its own logo.
///
/// beta.19-rc1 verdict (M5, BUG-138): `ink` is the resolver's verdict on the bitmap
/// (`HeroLogoInk`). A near-black, low-chroma wordmark (`.dark`) would vanish on the dark hero, so it
/// is drawn as a template in the primary text colour (a white silhouette); everything else
/// (`.legible`, including red, blue and every brand colour) is drawn exactly as before. `.blank`
/// never reaches here with a bitmap: the resolver commits it as no logo, so the text stand-in shows.
struct HeroLogo: View {
    let item: MetaPreview
    /// The resolved wordmark, or nil for the text stand-in. Supplied by the caller — see the type
    /// doc for why this view may not fetch it itself.
    let image: UIImage?
    /// FEAT-29: caps how tall the wordmark (or its text stand-in's own font metrics — unaffected,
    /// this only bounds the `Image` branch) may render. Defaults to the classic title-hero cap
    /// (`heroLogoSlotHeight`), unchanged for every existing call site. The folder-hero merged box
    /// (`HomeHeroForeground.nuvioLayout`/`.classicLayout`) passes `heroFolderLogoSlotHeight`
    /// instead, so a collection wordmark reads at the reference size regardless of what the
    /// shared title-hero logo slot is doing under Wave 10 compression.
    var maxHeight: CGFloat = Theme.Size.heroLogoSlotHeight
    /// beta.19-rc1 verdict (M5): see the type doc.
    var ink: HeroLogoInk = .legible

    var body: some View {
        Group {
            if let image {
                logoImage(image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // Tints only the `.template` rendering (`.dark`); the `.original` bitmap
                    // ignores the foreground style, so `.legible` draws exactly as before.
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(
                        maxWidth: Theme.Size.heroLogoMaxWidth,
                        maxHeight: maxHeight,
                        alignment: .bottomLeading
                    )
            } else {
                Text(item.name)
                    .font(Theme.Font.hero)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
            }
        }
        .id(item.id)
        .transition(.identity)
    }

    /// `.template` for a `.dark` wordmark (the silhouette), `.original` otherwise — explicit, so
    /// the foreground style above can never tint a brand-coloured logo.
    private func logoImage(_ image: UIImage) -> Image {
        Image(uiImage: image).renderingMode(ink == .dark ? .template : .original)
    }
}

/// Page-position dots for the hero carousel. Rendered once, outside the sliding pages, so they
/// stay put while the carousel animates.
struct HeroPageDots: View {
    let count: Int
    let index: Int

    /// Capsule height of each dot.
    nonisolated static let dotHeight: CGFloat = 10
    /// The laid-out height of this view: a dot plus the vertical padding. Read by
    /// `Theme.Size.heroPinnedRowsViewportBudget(showsCTA:)`, whose panel-form budget is taller by
    /// exactly this plus the header's `Spacing.sm` (2026-09-30), so the two cannot drift.
    nonisolated static let height: CGFloat = dotHeight + 2 * Theme.Spacing.xs

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index
                          ? Theme.Palette.textPrimary
                          : Theme.Palette.textSecondary.opacity(0.45))
                    .frame(width: i == index ? 34 : 10, height: Self.dotHeight)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .glassEffect(.regular, in: .capsule)
        .animation(.easeInOut(duration: 0.3), value: index)
        .accessibilityHidden(true)
    }
}

/// rc14 (BUG-112 residue): the Up-input bookkeeping `HomeView.revealTopAfterUpIntoHero` reads —
/// a reference box so the window-level swipe catcher can stamp it without a Home body re-evaluation
/// (review r1 P3). `MainActor` like everything that touches it.
@MainActor
final class HomeRowInputBox {
    /// beta.18 verdict (BUG-126): the row-focus ownership state, moved here from `@State` so a row
    /// hop does not re-evaluate Home's body (see `RowStepAB.handlerOnlyRowStateOffBody`). Handlers
    /// only; nothing renders these.
    var focusedRowKey: String?
    /// `systemUptime` of the last change of `focusedRowKey` to a different row.
    var lastRowFocusChangeAt: TimeInterval?
    /// When the last Up INPUT arrived — a press via `handleRowsMove`/`handleHeroUp`, a swipe via the
    /// catcher's `onAnySwipeUp` — consumed or not. `-1` = never.
    var lastUpInputAt: TimeInterval = -1
    /// When a row last released focus (`handleRowFocusOwnership`'s `owns: false` branch).
    var lastRowReleasedAt: TimeInterval?
    /// Voids a pending deferred re-check when a newer hero focus gain or a reveal supersedes it.
    var revealGeneration = 0
    /// review r1 (P3-3): `systemUptime` of the last up-into-hero reveal scroll; latch for the
    /// `alreadyRevealing` decline.
    var lastRevealAt: TimeInterval?
}
