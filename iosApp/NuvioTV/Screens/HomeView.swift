import Combine
import SwiftUI
import UIKit
import SharedCore

/// First real content screen for tvOS: a focus-navigable grid of catalog rows, fed entirely by the
/// shared Kotlin `HomeRepository`. Tapping a poster pushes the detail screen.
struct HomeView: View {
    @StateObject private var model = HomeViewModel()
    @State private var resume: ResumeTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    /// BUG-25 audit hook (kept): exposes the poster/depth environment Home actually renders
    /// with, as an invisible accessibility element the NuvioTVUITests harness reads
    /// (test10RenderCheck). DEBUG-only; costs nothing in release builds.
    @Environment(\.posterStyle) private var debugPosterStyle
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
    /// FEAT-15: the live "Show Hero" setting. `HomeCatalogSettingsRepository.snapshot()` rebuilds
    /// the entire preference map on every call, so it cannot be read from `body` at render
    /// frequency the way `reportRowFocus` used to read it per focus event — this watches the same
    /// flow SettingsViewModel does and republishes the single field Home renders from.
    @StateObject private var heroSettings = HomeHeroSettingsObserver()

    // Hero carousel state, hoisted here so the full-bleed backdrop (behind the scroll) and the
    // focusable paged carousel (inside the scroll) share the same index. The carousel is a paged
    // TabView: D-pad left/right (and touch-surface swipes) page manually while the hero is
    // focused — the same interaction as the Apple TV+ feature carousel — and a timer advances it
    // while focus is elsewhere.
    @State private var heroIndex = 0
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
    private let homeScrollEdgeHard = UserDefaults.standard.bool(forKey: "debug.homeScrollEdgeHard")

    /// UX-7: always-on focus-follows-backdrop. Owns the row-focused item (if any) that should
    /// take over the hero from the carousel.
    @StateObject private var focusModel = HomeHeroFocusModel()
    /// UX-7: rows whose backdrops have already been prefetch-warmed (keyed by report source),
    /// so each row pays the warm-up exactly once per Home lifetime.
    @State private var prefetchedBackdropRows = Set<String>()

    private var heroItems: [MetaPreview] { Array(model.heroItems.prefix(8)) }
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
    /// Codex review: gated on `heroPanelSeed` rather than `hasFocusableRows` — a collection-only
    /// Home has focusable rows but nothing the panel can ever represent (`CollectionRowView`
    /// never reports a `MetaPreview`), and mounting it there reserved a permanently blank band.
    /// With no seed the layout degenerates to pure rows, which is also the only way a "rows
    /// only, no hero region" configuration remains reachable. Still a content/load-boundary
    /// value, never per-focus.
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
        for row in model.rows {
            if case .catalog(let section) = row, let first = section.items.first { return first }
        }
        if let firstEntry = model.continueWatching.first { return previewFromEntry(firstEntry) }
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
        if heroCarouselActive { return focusModel.focusedItem ?? currentHero }
        if focusHeroActive { return focusModel.focusedItem ?? heroRestingItem }
        return nil
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
    private var heroTrailerAutoplayActive: Bool {
        guard heroTrailerAutoplay, UIAccessibility.isVideoAutoplayEnabled else { return false }
        let heroEngaged = heroFocused || focusModel.focusedItem != nil
        if heroPosterFocusOnly && heroCarouselActive && !heroEngaged { return false }
        if inlineTrailersEnabled && focusModel.focusedItem != nil { return false }
        return true
    }

    /// FEAT-25: whether the hero's OWN trailer holds the shared player slot right now. Polled by
    /// the carousel's auto-advance tick; never observed (see the call site).
    private var heroTrailerPlaying: Bool {
        guard heroTrailerAutoplayActive, let hero = displayHero else { return false }
        return InlineTrailerCoordinator.shared.playingKey == TrailerResolutionCache.key(type: hero.type, id: hero.id)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.Palette.background.ignoresSafeArea()

                #if DEBUG
                // BUG-25 diagnostic (invisible, harness-readable): the env values Home renders with.
                Text("debug_env cr=\(Int(debugPosterStyle.cornerRadius)) w=\(Int(debugPosterStyle.width)) depth=\(debugCardDepth.enabled ? 1 : 0) edge=\(debugCardDepth.edgeStrength)")
                    .font(.system(size: 8))
                    .opacity(0.011)
                    .accessibilityIdentifier("debug_env")
                // BUG-23 diagnostic (invisible, harness-readable): the hero carousel's live
                // selection + focus state, so the UITest can watch exactly what a left press
                // does to the index (one-press page? two? snap-back?).
                Text("debug_hero idx=\(heroIndex) foc=\(heroFocused ? 1 : 0) n=\(heroItems.count) src=\(focusModel.focusedItem == nil ? "c" : "f") fitem=\(focusModel.focusedItem?.id ?? "-") pin=\(heroNuvioStyle ? 1 : 0) mode=\(heroCarouselActive ? "carousel" : (focusHeroActive ? "focus" : "none"))")
                    .font(.system(size: 8))
                    .opacity(0.011)
                    .accessibilityIdentifier("debug_hero")
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
                if let hero = displayHero {
                    Group {
                        // Nuvio-style: right-anchored artwork whose left edge fades to the
                        // flat background — the info panel never sits over the art.
                        // FEAT-15: the focus panel always uses that treatment (see heroNuvioStyle).
                        HomeHeroBackdrop(
                            item: hero,
                            nuvioStyle: heroNuvioStyle || focusHeroActive,
                            autoplaysTrailer: heroTrailerAutoplayActive
                        )
                        HomeHeroScrim()
                    }
                    // UX-7: a row-focused poster (focusModel.focusedItem != nil) always shows
                    // its artwork — heroPosterFocusOnly only gates the carousel's own idle fade.
                    // FEAT-15: and only the CAROUSEL's. In focus-panel mode the toggle is inert —
                    // hiding the artwork "while browsing" there would hide it always, since
                    // browsing is the only thing that mode ever shows (see heroPosterFocusOnly).
                    .opacity(heroPosterFocusOnly && heroCarouselActive
                             ? ((heroFocused || focusModel.focusedItem != nil) ? 1 : 0) : 1)
                    .animation(.easeInOut(duration: 0.4), value: heroFocused || focusModel.focusedItem != nil)
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
                ScrollViewReader { scrollProxy in
                    Group {
                        if heroContainerPinned {
                            VStack(spacing: 0) {
                                if heroHeaderVisible {
                                    pinnedHeroHeader
                                }
                                rowsScroll(pinned: heroHeaderVisible)
                            }
                        } else {
                            rowsScroll(pinned: false)
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
                    } : nil)
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
                    // Round 7 (2026-08-05) deliberately does NOT touch this site: instead of
                    // correcting the scroll after the fact, it removes the reason the scroll
                    // stops short — the classic hero now carries its top padding as a
                    // transparent frame reach, so the topmost revealable frame IS the content
                    // top (see `heroCarousel(compact:topReach:)` and `rowsInsets`). That is a
                    // geometry change on the way UP, invisible to Menu-to-top, which already
                    // scrolls to "home_top" explicitly and is unaffected either way. Unverified
                    // until a device walk says the probe's `residual` dropped from 67 toward 0.
                }
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
                // FEAT-25: a hero trailer that is actually playing owns the page. Advancing under
                // it would cut every trailer off around the 8s mark and restart the whole
                // resolve pipeline for the next title, which is most of the time the feature has
                // to work with. Read straight off the coordinator rather than observing it — an
                // `@ObservedObject` here would re-render Home on every claim/release anywhere in
                // the app, which is precisely the churn class BUG-19 was about. Playback is
                // single-pass (`loops: false`), so the page resumes advancing the moment the
                // trailer ends.
                guard !heroTrailerPlaying else { return }
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
            }
            .onChange(of: heroItems.count) { _, newCount in
                if heroIndex >= newCount { heroIndex = 0 }
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
                    synopsis: { let d: String? = target.entry.pauseDescription; return (d ?? "").isEmpty ? nil : d }()
                )
            }
        }
        .onAppear {
            #if DEBUG
            LaunchTrace.mark("home_appear")  // BUG-26: profile gate passed, Home mounting
            #endif
            model.start()
            if upcomingRowEnabled { model.startUpcoming() }
            heroSettings.start()
            prefetchHeroArt()
            // UX-7: when a row-focused poster reverts (grace period elapsed, or the CTA
            // reclaimed the hero), re-stamp the carousel's "last change" clock — otherwise the
            // auto-advance timer's next tick would immediately yank the page the instant focus
            // moves away, before the user even sees the carousel resume.
            focusModel.onRevert = { lastHeroChange = Date() }
        }
        .onDisappear {
            model.stop()
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
    /// Clipping: classic keeps `.scrollClipDisabled()` so focused cards may lift past the scroll
    /// bounds. Pinned deliberately keeps DEFAULT clipping — that hard edge just under the pinned
    /// hero is what hides rows scrolled past the viewport top (it replaces the fade mask the sim
    /// pass falsified). The focus lift stays inside the clip because the content insets below
    /// keep every card away from the viewport edges.
    @ViewBuilder
    private func rowsScroll(pinned: Bool) -> some View {
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
                        // UX-7 (see reportRowFocus for the gating rationale).
                        onItemFocusChange: { entry in
                            reportRowFocus(entry.map(previewFromEntry), source: "continue-watching",
                                           prefetch: { model.continueWatching.prefix(8).flatMap { heroBackdropPrefetchURLs(for: $0) } })
                        }
                    )
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
                                                   prefetch: { section.items.prefix(8).flatMap { heroBackdropPrefetchURLs(for: $0) } })
                                }
                            )
                            // BUG-35 (beta.12): localize this row's leading items when it scrolls
                            // into view. LazyVStack fires onAppear per row as it mounts; the shared
                            // repo dedups per item+language for the session, so re-appearing rows
                            // cost nothing (see HomeRepository.requestRowEnrichment).
                            .onAppear { model.rowAppeared(sectionKey: section.key) }
                        case .collection(let collection):
                            CollectionRowView(collection: collection)
                        }
                    }
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
            .environment(\.rowCardTopReach, pinned ? Theme.Size.heroPinnedRowTopPad : 0)
            .environment(\.rowCardBottomReach, pinned ? Theme.Size.heroPinnedRowBottomReach : 0)
            // BUG-30: `heroInScroll` moves the classic top inset into the hero's own reach (see
            // the hero branch above). Every other configuration keeps its inset unchanged.
            .padding(rowsInsets(pinned: pinned, heroInScroll: !heroItems.isEmpty && !pinned))
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
        // BUG-30 A/B knob (see `homeScrollEdgeHard`). Not attached unless the knob is set, so
        // the shipped tree is unchanged.
        .modifier(HomeScrollEdgeStyleModifier(hard: homeScrollEdgeHard))
        // The BUG-27 Menu handler is NOT here: it lives on the common ancestor in `body`,
        // because in pinned mode the hero CTA is a sibling of this ScrollView and a handler
        // attached here would not cover it (Menu on the CTA would suspend the app).
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
    private func heroCarousel(compact: Bool, topReach: CGFloat = 0) -> some View {
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
                if let hero = displayHero {
                    HomeHeroForeground(item: hero, heroFocused: $heroFocused, compact: compact,
                                       showsCTA: heroCarouselActive,
                                       forceNuvioLayout: focusHeroActive)
                }
            }
            // Compact (pinned) trims ~100pt so the rows viewport below can fit a reach-
            // extended focus frame plus the engine's reveal margin — see the Theme comment
            // on heroCarouselHeightPinned (device round 6). FEAT-15's panel keeps the SAME
            // fixed height as the pinned carousel — the freed CTA slot is redistributed to the
            // synopsis INSIDE the panel (see HomeHeroForeground), never given back to the rows,
            // so the pinned geometry the `heroPinned*` reach constants were tuned against
            // (device rounds 4–7) is identical in both modes.
            .frame(height: compact ? Theme.Size.heroCarouselHeightPinned
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

            if heroItems.count > 1 {
                // Both layouts keep the info panel on the left, so the dots stay leading. Never
                // conditionally removed while a row poster owns the hero (UX-7) — faded out via
                // opacity instead, so the carousel's layout never reflows around them.
                HeroPageDots(count: heroItems.count, index: min(heroIndex, heroItems.count - 1))
                    .padding(.leading, Theme.Spacing.lg)
                    .opacity(focusModel.focusedItem == nil ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: focusModel.focusedItem == nil)
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
    private var pinnedHeroHeader: some View {
        heroCarousel(compact: true)
            .padding(.top, Theme.Size.heroPinnedTopPad)
            .padding(.horizontal, Theme.Spacing.screen)
            .padding(.bottom, Theme.Size.heroPinnedRowsGap)
    }

    /// Content insets for the rows `LazyVStack`. Classic keeps the uniform overscan-safe
    /// `Theme.Spacing.screen` on all four edges, byte-for-byte what it always had. Pinned uses
    /// `heroPinnedRowsHeadroom` (80) on top: NOT spacing — it is the buffer that absorbs the
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
                              bottom: Theme.Spacing.screen, trailing: Theme.Spacing.screen)
        }
        return EdgeInsets(top: heroInScroll ? 0 : Theme.Spacing.screen,
                          leading: Theme.Spacing.screen,
                          bottom: Theme.Spacing.screen, trailing: Theme.Spacing.screen)
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
        var urls: [URL] = []
        // Both render candidates (primary + poster fallback), same chain the backdrop
        // actually uses — see heroBackdropPrefetchURLs.
        for item in heroItems {
            urls.append(contentsOf: heroBackdropPrefetchURLs(for: item).compactMap(URL.init(string:)))
            if let url = heroLogoURL(for: item) { urls.append(url) }
        }
        if let resting = heroRestingItem {
            urls.append(contentsOf: heroBackdropPrefetchURLs(for: resting).compactMap(URL.init(string:)))
            if let url = heroLogoURL(for: resting) { urls.append(url) }
        }
        ArtworkStore.prefetch(urls)
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
    ///
    /// Note the removed `cancelAndRevert()` had a second job — dropping a claim made while the
    /// hero was enabled so that re-enabling later could not resurrect a stale title. That job is
    /// obsolete for the same reason: the claim is never orphaned now, because both settings states
    /// display it. Toggling Show Hero mid-browse simply moves the committed title from the
    /// carousel's hero to the focus panel and back.
    private func reportRowFocus(_ item: MetaPreview?, source: String, prefetch: () -> [String]) {
        if item != nil, prefetchedBackdropRows.insert(source).inserted {
            ArtworkStore.prefetch(prefetch().compactMap(URL.init(string:)))
        }
        focusModel.reportFocus(item, from: source)
    }

    /// UX-7: adapts a Continue Watching entry to the hero's `MetaPreview` shape so a focused CW
    /// card can drive the hero the same way a catalog poster does. Kotlin default args aren't
    /// exported to Swift, so every `MetaPreview` field has to be supplied explicitly — the fields
    /// CW doesn't carry (rating, popularity, etc.) go in as nil/empty rather than guessed.
    private func previewFromEntry(_ entry: WatchProgressEntry) -> MetaPreview {
        MetaPreview(
            id: entry.parentMetaId,
            type: entry.parentMetaType,
            name: entry.title,
            poster: entry.poster,
            banner: entry.background,
            logo: nil,
            posterShape: .poster,
            description: nil,
            releaseInfo: nil,
            rawReleaseDate: nil,
            popularity: nil,
            voteCount: nil,
            imdbRating: nil,
            genres: []
        )
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

    /// Called on every focus change a row reports — `nil` when nothing in that row holds focus.
    /// `source` is a stable identity for the reporting row (`section.key`, "continue-watching").
    func reportFocus(_ item: MetaPreview?, from source: String) {
        // A nil from a row that doesn't own the current claim is the trailing edge of a
        // cross-row hop; the row that DOES own the claim already spoke for itself.
        if item == nil, let claimSource, claimSource != source { return }
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
            if item == nil { claimSource = nil }
            // Same title ≠ same preview: one id can be represented by different previews across
            // rows (a Continue Watching adaptation carries no description; a catalog card does).
            // Adopt the newly focused card's content immediately — the title is already
            // committed, so there's no dwell to honor — and leave a byte-identical re-report as
            // the pure no-op it should be (Codex review finding).
            if let item, focusedItem?.isEqual(item) != true {
                focusedItem = item
                enrichIfNeeded(item)
            }
            return
        }

        generation &+= 1
        let generationAtStart = generation
        pendingTask?.cancel()

        if let item {
            pendingTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.commitDelay * 1_000_000_000))
                guard !Task.isCancelled, let self, self.generation == generationAtStart else { return }
                self.focusedItem = item
                self.enrichIfNeeded(item)
            }
        } else {
            pendingTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.revertGrace * 1_000_000_000))
                guard !Task.isCancelled, let self, self.generation == generationAtStart else { return }
                self.focusedItem = nil
                self.claimSource = nil
                self.onRevert?()
            }
        }
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
        guard nonBlank(item.description_) == nil || nonBlank(item.banner) == nil else { return }
        let settings = TmdbSettingsRepository.shared.snapshot()
        guard settings.enabled, settings.hasApiKey,
              settings.useArtwork || settings.useBasicInfo else { return }
        // suspend fun → Swift completion; result may arrive off the main thread, so hop back
        // (same convention as PersonDetailViewModel.start()).
        TmdbMetadataService.shared.fetchPreviewEnrichment(
            type: item.type, id: item.id, settings: settings
        ) { [weak self] enrichment, _ in
            DispatchQueue.main.async {
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
                self.focusedItem = MetaPreview(
                    id: base.id,
                    type: base.type,
                    // BUG-42: the committed title is left alone. Carousel parity no longer needs an
                    // override here — a row item the hero also carries is localized by the SHARED
                    // publish, so both copies already agree — and swapping a title the viewer is
                    // reading is the exact double commit this fix removes (see the doc comment).
                    name: base.name,
                    poster: base.poster,
                    banner: self.nonBlank(base.banner) ?? (useArtwork ? enrichment.backdrop : nil),
                    logo: self.nonBlank(base.logo) ?? (useArtwork ? enrichment.logo : nil),
                    posterShape: base.posterShape,
                    description: self.nonBlank(base.description_) ?? (useBasicInfo ? enrichment.description_ : nil),
                    releaseInfo: base.releaseInfo,
                    rawReleaseDate: base.rawReleaseDate,
                    popularity: base.popularity,
                    voteCount: base.voteCount,
                    imdbRating: base.imdbRating,
                    genres: base.genres.isEmpty && useBasicInfo ? enrichment.genres : base.genres
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
        claimSource = nil
        let wasCommitted = focusedItem != nil
        focusedItem = nil
        if wasCommitted { onRevert?() }
    }
}

/// Horizontal "Continue Watching" row of in-progress titles with a progress bar. Tapping a card opens
/// the stream picker for that exact video (the in-progress episode for series), and playback resumes
/// from the saved position.
struct ContinueWatchingRow: View {
    let entries: [WatchProgressEntry]
    let onSelect: (WatchProgressEntry) -> Void
    let onRemove: (WatchProgressEntry) -> Void
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
                            Button { onSelect(entry) } label: {
                                LandscapeCard(
                                    title: entry.title,
                                    imageURL: imageURL(entry),
                                    progress: fraction(entry),
                                    overlayLeading: episodeCode(entry)
                                )
                                .padding(.top, cardTopReach)
                                .padding(.bottom, cardBottomReach)
                            }
                            .buttonStyle(.borderless)
                            .posterButtonShape()
                            .focused($focusedVideoId, equals: entry.videoId)
                            .contextMenu {
                                Button(role: .destructive) {
                                    onRemove(entry)
                                } label: {
                                    Label("Remove from Continue Watching", systemImage: "trash")
                                }
                            }
                            .id(entry.videoId)
                        }
                    }
                    // Always positive — the reach lives inside the buttons (see CatalogRowView).
                    .padding(.vertical, Theme.Spacing.lg)
                }
                // BUG-37: rides down to the viewport's clip edge when the device rests short —
                // same one-line treatment as every other pinned row title (see
                // `pinnedRowTitleTracking` in BrowseComponents for the geometry and history).
                .overlay(alignment: .topLeading) {
                    if cardTopReach > 0 {
                        Text("Continue Watching")
                            .font(Theme.Font.sectionTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .shadow(color: .black.opacity(0.7), radius: 8, y: 2)
                            .pinnedRowTitleTracking(rowKey: "continue-watching")
                            .padding(.top, Theme.Size.heroPinnedRowTitleInset)
                            .allowsHitTesting(false)
                    }
                }
                .scrollClipDisabled()
                .onChange(of: entries.first?.videoId) { _, newFirst in
                    // Content-driven reorder while the user is elsewhere: keep the shelf
                    // anchored to the first card instead of drifting mid-list.
                    guard focusedVideoId == nil, let newFirst else { return }
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) { proxy.scrollTo(newFirst, anchor: .leading) }
                }
            }
        }
        .focusSection()
        .onChange(of: focusedVideoId) { _, newId in
            onItemFocusChange?(newId.flatMap { id in entries.first { $0.videoId == id } })
        }
    }

    private func fraction(_ entry: WatchProgressEntry) -> Double? {
        entry.durationMs > 0 ? Double(entry.lastPositionMs) / Double(entry.durationMs) : nil
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
}

/// Identifiable wrapper so a progress entry can drive `.fullScreenCover(item:)` for direct resume.
struct ResumeTarget: Identifiable {
    let entry: WatchProgressEntry
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
    let item: MetaPreview
    /// Nuvio-style hero: the artwork becomes a right-anchored panel whose LEFT edge fades
    /// out through a gradient mask, so the info panel sits on pure flat background — none of
    /// the artwork ever renders behind the title/description (Christian's spec, 2026-07-30).
    var nuvioStyle: Bool = false
    /// FEAT-25: run the title's trailer in the backdrop, with no focus required. The gating lives
    /// entirely in `HomeView.heroTrailerAutoplayActive`; false here is byte-for-byte the backdrop
    /// this view has always drawn.
    var autoplaysTrailer: Bool = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// FEAT-25: the SAME dwell → resolve → play state machine the inline catalog card runs
    /// (`InlineTrailerCard`), driven from this view's lifecycle instead of from focus. It brings
    /// the resolution cache, the single-player/single-extraction coordinator, the negative-result
    /// TTLs and the storm breaker with it — nothing about the pipeline is reimplemented here.
    @StateObject private var trailerModel = InlineTrailerCardModel()

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
            .onDisappear { trailerModel.reset() }
    }

    /// Single funnel for every start/stop reason — hero content change, the setting or one of its
    /// gates flipping, backgrounding, and coming back. Always tears the current playback down
    /// first (`reset()` releases the player slot and clears the state machine's per-dwell memory),
    /// then re-arms only when there is a reason to. `focusChanged(true:)` is the inline card's own
    /// arming call: it starts the same 1s dwell before anything is resolved or requested.
    private func syncTrailer() {
        trailerModel.reset()
        guard autoplaysTrailer, scenePhase == .active else { return }
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
            HeroCrossfadeImage(url: heroBackdropURL(for: item), fallbackURL: item.poster)

            if let url = trailerModel.playingURL {
                TrailerHeroPlayer(
                    urlString: url,
                    onFailure: { report in trailerModel.playbackFailed(report) },
                    zoomKey: trailerKey,
                    loops: false,
                    onPlaybackEnded: { trailerModel.playbackFinished() }
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
    nonisolated static let maxLines = 24
    nonisolated(unsafe) private static var didResetThisLaunch = false
    nonisolated private static let bufferLock = NSLock()

    /// NSLogs `line` (the greppable `[HomeHero]` console contract is unchanged) and appends it to
    /// the persisted ring buffer. The buffer resets on the first record of each launch, so the
    /// About pane always shows exactly the current launch's lines — the cold-launch capture
    /// BUG-42 has been waiting for.
    nonisolated static func log(_ line: String) {
        NSLog("[HomeHero] %@", line)
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let defaults = UserDefaults.standard
        var lines = didResetThisLaunch ? (defaults.stringArray(forKey: linesKey) ?? []) : []
        didResetThisLaunch = true
        lines.append("\(sinceLaunchMs)ms \(line)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        defaults.set(lines, forKey: linesKey)
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
    @State private var current: UIImage?
    @State private var previous: UIImage?
    /// Drives the outgoing image's fade — animated 1 → 0 on every swap (see `crossfade(to:)`).
    @State private var previousOpacity: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Same trick as `HeroLogo.init`: seed `current` synchronously from the memory cache when the
    /// URL is already resident, so a cached backdrop is on screen from this view's very first
    /// frame — no placeholder flash as focus moves across a row.
    init(url: String?, fallbackURL: String? = nil) {
        self.url = url
        self.fallbackURL = fallbackURL
        let resolved: URL? = {
            guard let url, !url.isEmpty else { return nil }
            return URL(string: url)
        }()
        _current = State(initialValue: ArtworkStore.cached(resolved))
    }

    /// BUG-42 probe: an init-seeded first frame IS the first paint (no `crossfade` runs for it).
    /// Logged from the task, not `init` — SwiftUI may re-run `init` on parent updates while keeping
    /// the `@State`, so only the first task on a view that has painted nothing yet counts.
    @State private var paintCount = 0
    @State private var didLogSeededPaint = false

    var body: some View {
        ZStack {
            // Content-mode/frame/clipping are the caller's job (parity with what
            // CachedAsyncImage used to provide at these call sites).
            if let current {
                Image(uiImage: current)
                    .resizable()
                    .scaledToFill()
            }
            // The OUTGOING image sits on top and fades out to reveal the new one beneath —
            // stacked the other way (opaque newcomer above) the animated removal is invisible
            // and every swap reads as a hard cut.
            if let previous {
                Image(uiImage: previous)
                    .resizable()
                    .scaledToFill()
                    .opacity(previousOpacity)
            }
        }
        // Keyed on BOTH urls: between same-title previews the primary can stay identical while
        // only the fallback poster changes (CW adaptation without a poster → catalog card with
        // one) — keyed on the primary alone, a terminally-failed primary never retried the newly
        // available fallback.
        .task(id: "\(url ?? "")|\(fallbackURL ?? "")") {
            // BUG-42: is this the hero's very first paint (nothing on screen yet)? Later swaps keep
            // the "show the cached poster now, upgrade later" rule below — it exists so a stalled
            // metahub fetch can't pin the PREVIOUS title's art. On first paint there is no previous
            // art to pin, and the poster→backdrop crossfade IS the "one cover, then another loads
            // over it" the reporter filmed. So on first paint the poster waits for the primary up
            // to `firstPaintFallbackDeadline` before it is allowed to show.
            let firstPaint = current == nil && previous == nil
            if !firstPaint, paintCount == 0, !didLogSeededPaint, HomeHeroProbe.enabled {
                didLogSeededPaint = true
                HomeHeroProbe.log(String(format: "paint kind=seededPrimary first=1 sinceLaunch=%dms hadArt=0", HomeHeroProbe.sinceLaunchMs))
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
                                HomeHeroProbe.log(String(format: "paint suppressed kind=primaryAfterFirstPaintFallback sinceLaunch=%dms", HomeHeroProbe.sinceLaunchMs))
                            }
                            continue
                        }
                        crossfade(to: image, kind: "primary", first: firstPaint)
                    case let .fallback(image):
                        guard let image else { continue }
                        if primaryLanded { continue }
                        if deadlinePassed {
                            showedArt = true
                            if firstPaint { firstPaintCommittedWithFallback = true }
                            crossfade(to: image, kind: "fallbackFetched", first: firstPaint)
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
                            showedArt = true
                            if firstPaint { firstPaintCommittedWithFallback = true }
                            crossfade(to: held, kind: "fallbackHeld", first: firstPaint)
                        }
                    }
                }
            }
            // Every source failed terminally and nothing provisional made it up: same rule as
            // the no-URL case — stale art under a mismatched title is worse than the flat
            // background.
            guard !Task.isCancelled, !showedArt else { return }
            fadeToEmpty()
        }
    }

    /// The no-artwork terminal state: fade the last image out to the flat background (scrim and
    /// background color remain — the same look a titles-without-art hero always had).
    private func fadeToEmpty() {
        guard current != nil || previous != nil else { return }
        previous = current
        current = nil
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
        guard image !== current else { return }
        paintCount += 1
        if HomeHeroProbe.enabled {
            HomeHeroProbe.log(String(format: "paint kind=%@ first=%d sinceLaunch=%dms hadArt=%d", kind, first ? 1 : 0, HomeHeroProbe.sinceLaunchMs, current == nil ? 0 : 1))
        }
        previous = current
        current = image
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
    let item: MetaPreview
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
    @AppStorage("hero_nuvio_style") private var heroNuvioStyle = false

    private var usesNuvioLayout: Bool { forceNuvioLayout || heroNuvioStyle }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Group {
                if usesNuvioLayout {
                    nuvioLayout
                } else {
                    classicLayout
                }
            }
            .accessibilityElement(children: .combine)

            // The CTA sits below the description and above the page dots (which render
            // outside the TabView). D-pad left/right still pages the carousel while this
            // button holds focus — it is the page's focus anchor.
            if showsCTA {
                NavigationLink(value: TitleRoute(preview: item)) {
                    Text(ctaTitle)
                        .font(Theme.Font.body)
                }
                .buttonStyle(.glass)
                .focused(heroFocused)
                .frame(height: Theme.Size.heroButtonSlotHeight, alignment: .center)
                .accessibilityLabel("\(ctaTitle): \(item.name)")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, compact ? Theme.Spacing.md : Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fixed synopsis slot. FEAT-15: with no CTA the panel would otherwise centre itself inside
    /// the hero region's fixed frame and leave a dead band where the button used to be, so the
    /// synopsis absorbs the CTA slot AND the `md` gap that preceded it — same arithmetic on the
    /// same existing tokens, no new Theme constant, and the summed panel height comes out
    /// IDENTICAL, which is what keeps the pinned rows viewport (and every `heroPinned*` reach
    /// constant tuned against it) untouched:
    ///     carousel form  32 padding + 110 logo + 16 + 32 meta + 16 + 72 synopsis + 16 + 56 CTA = 350
    ///     panel form     32 padding + 110 logo + 16 + 32 meta + 16 + 144 synopsis            = 350
    /// both inside the 352pt `heroCarouselHeightPinned` frame the caller pins. The line limit
    /// grows with the slot: 144pt fits four 29pt body lines, so the panel FEAT-15 asks for shows
    /// twice the description the pinned carousel could.
    private var synopsisSlotHeight: CGFloat {
        let base = compact ? Theme.Size.heroSynopsisSlotHeightPinned
                           : Theme.Size.heroSynopsisSlotHeightNuvio
        guard !showsCTA else { return base }
        return base + Theme.Size.heroButtonSlotHeight + Theme.Spacing.md
    }

    /// Lines the synopsis may use, tracking `synopsisSlotHeight` above.
    private var synopsisLineLimit: Int {
        let base = compact ? 2 : 3
        return showsCTA ? base : base + 2
    }

    /// "movie" is the only meta type that reads as a film; series/tv both read as shows.
    private var ctaTitle: String {
        item.type == "movie"
            ? String(localized: "Go to Movie")
            : String(localized: "Go to Show")
    }

    /// Nuvio-style: fixed-width text column on the left (logo, meta, 3-line synopsis) — the
    /// artwork owns the rest of the frame to the right.
    private var nuvioLayout: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HeroLogo(item: item)
                .frame(height: compact ? Theme.Size.heroLogoSlotHeightPinned
                                       : Theme.Size.heroLogoSlotHeight,
                       alignment: .bottomLeading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(metaLine)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                .lineLimit(1)
                .frame(height: Theme.Size.heroMetaSlotHeight, alignment: .leading)

            Text(synopsis)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textPrimary.opacity(0.85))
                .lineLimit(synopsisLineLimit)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: synopsisSlotHeight, alignment: .topLeading)
        }
        .frame(width: Theme.Size.heroInfoPanelWidth, alignment: .leading)
    }

    /// The original bottom-left layout, unchanged.
    private var classicLayout: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HeroLogo(item: item)
                .frame(height: Theme.Size.heroLogoSlotHeight, alignment: .bottomLeading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(metaLine)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                .lineLimit(1)
                .frame(height: Theme.Size.heroMetaSlotHeight, alignment: .leading)

            Text(synopsis)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textPrimary.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(height: Theme.Size.heroSynopsisSlotHeight, alignment: .topLeading)
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



/// Resolves the logo artwork URL for a hero item. Catalog previews (Cinemeta rows especially)
/// usually omit `logo` even when logo art exists, so for IMDb-id items fall back to metahub —
/// the same CDN Cinemeta's own full meta points at. A miss there just 404s and `HeroLogo`
/// shows its text wordmark, so the synthesized URL is strictly additive (BUG-17).
func heroLogoURL(for item: MetaPreview) -> URL? {
    let logo: String? = item.logo
    if let logo, !logo.isEmpty { return URL(string: logo) }
    let imdbId = item.id.split(separator: ":").first.map(String.init) ?? item.id
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
/// `HeroCrossfadeImage` falls back to when the primary (typically a synthesized metahub URL)
/// 404s. Warming only the primary made exactly the fallback scenario the cold, flashing one.
/// Cheap in practice: row posters are the card images already on screen, so `ArtworkStore`'s
/// cache check absorbs the duplicates.
func heroBackdropPrefetchURLs(for item: MetaPreview) -> [String] {
    var urls: [String] = []
    if let primary = heroBackdropURL(for: item) { urls.append(primary) }
    if let poster = item.poster, !poster.isEmpty, !urls.contains(poster) { urls.append(poster) }
    return urls
}

/// Continue Watching flavor of `heroBackdropPrefetchURLs(for:)`.
func heroBackdropPrefetchURLs(for entry: WatchProgressEntry) -> [String] {
    var urls: [String] = []
    if let primary = heroBackdropURL(for: entry) { urls.append(primary) }
    if let poster = entry.poster, !poster.isEmpty, !urls.contains(poster) { urls.append(poster) }
    return urls
}

/// The hero page's logo artwork, with the title text as its stand-in (no logo URL, load failure,
/// or not fetched yet). Seeds from the shared artwork memory cache synchronously, so a cached
/// logo is on screen from the page's very first frame — no placeholder flash as pages cycle.
struct HeroLogo: View {
    let item: MetaPreview
    private let url: URL?
    @State private var image: UIImage?

    init(item: MetaPreview) {
        self.item = item
        self.url = heroLogoURL(for: item)
        _image = State(initialValue: ArtworkStore.cached(url))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        maxWidth: Theme.Size.heroLogoMaxWidth,
                        maxHeight: Theme.Size.heroLogoSlotHeight,
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
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = ArtworkStore.cached(url) {
                image = hit
                return
            }
            image = nil
            if let fetched = try? await ArtworkStore.fetch(url) {
                withAnimation(.easeIn(duration: 0.25)) { image = fetched }
            }
        }
    }
}

/// Page-position dots for the hero carousel. Rendered once, outside the sliding pages, so they
/// stay put while the carousel animates.
struct HeroPageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index
                          ? Theme.Palette.textPrimary
                          : Theme.Palette.textSecondary.opacity(0.45))
                    .frame(width: i == index ? 34 : 10, height: 10)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .glassEffect(.regular, in: .capsule)
        .animation(.easeInOut(duration: 0.3), value: index)
        .accessibilityHidden(true)
    }
}
