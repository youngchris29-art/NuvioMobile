import Combine
import SwiftUI
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
    @AppStorage("hero_poster_focus_only") private var heroPosterFocusOnly = false
    /// UX-2 hero redesign, v2 (opt-in): Nuvio-style hero — title/description on the LEFT,
    /// the backdrop artwork reading on the RIGHT behind a leading scrim, info panel raised
    /// toward the top (Christian's reference photos, 2026-07-30). Default stays the classic
    /// lower-left layout. Mirrored by HomeHeroForeground and the Home Screen settings pane.
    @AppStorage("hero_nuvio_style") private var heroNuvioStyle = false

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
    private let homeScrollProbeEnabled = UserDefaults.standard.bool(forKey: "debug.homeScrollProbe")

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
    /// UX-7: the item the hero should actually display — a row-focused poster wins over the
    /// carousel's own current page while one is committed. Gated on `heroItems` HERE, at display
    /// time, not at report time: rows report unconditionally, so a card focused while the hero
    /// fan-out is still loading takes over the moment `heroItems` arrives (no re-report exists at
    /// that boundary — `@FocusState` hasn't changed), and Show Hero OFF stays a pure display
    /// decision (`heroItems` empty ⇒ no hero region at all).
    private var displayHero: MetaPreview? {
        heroItems.isEmpty ? nil : (focusModel.focusedItem ?? currentHero)
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
                Text("debug_hero idx=\(heroIndex) foc=\(heroFocused ? 1 : 0) n=\(heroItems.count) src=\(focusModel.focusedItem == nil ? "c" : "f") fitem=\(focusModel.focusedItem?.id ?? "-") pin=\(heroNuvioStyle ? 1 : 0)")
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
                        HomeHeroBackdrop(item: hero, nuvioStyle: heroNuvioStyle)
                        HomeHeroScrim()
                    }
                    // UX-7: a row-focused poster (focusModel.focusedItem != nil) always shows
                    // its artwork — heroPosterFocusOnly only gates the carousel's own idle fade.
                    .opacity(heroPosterFocusOnly ? ((heroFocused || focusModel.focusedItem != nil) ? 1 : 0) : 1)
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
                // `pinned` is passed as `heroNuvioStyle && !heroItems.isEmpty`, NOT the bare
                // setting: with Show Hero off (or before the fan-out loads), Nuvio mode renders
                // rows-only and they must keep the CLASSIC geometry — full 60pt overscan top
                // inset and lift-friendly disabled clipping — instead of the compact insets that
                // only make sense under a mounted header. This is a value change (paddings,
                // clip flag, the in-scroll hero condition), not a structural one, so flipping at
                // the load boundary re-identifies nothing.
                // ScrollViewReader + the Menu handler sit ABOVE the mode split: in pinned mode
                // the hero CTA is a SIBLING of the rows ScrollView, so a handler attached to the
                // ScrollView alone would not cover it — a Menu press with focus on the CTA while
                // `isScrolledDown` hadn't cleared yet (e.g. a reflexive double-Menu during the
                // jump-to-top animation) would bubble to the tab root and suspend the app. One
                // handler on the common ancestor covers rows and CTA in both modes; scrollTo
                // resolves the "home_top" anchor through the descendant ScrollView.
                ScrollViewReader { scrollProxy in
                    Group {
                        if heroNuvioStyle {
                            VStack(spacing: 0) {
                                if !heroItems.isEmpty {
                                    pinnedHeroHeader
                                }
                                rowsScroll(pinned: !heroItems.isEmpty)
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
                }
            }
            .onReceive(heroTimer) { _ in
                // Reduce Motion: pause auto-advance entirely rather than rebasing the TabView
                // selection without animation — that desyncs tvOS's paged TabView (see the
                // comment below), so the only safe accommodation is to stop advancing and let
                // the carousel sit still until the user pages manually (still animated).
                guard !reduceMotion else { return }
                // UX-7: a row-focused poster owns the hero right now — the carousel must not
                // advance underneath it.
                guard heroItems.count > 1, !heroFocused, focusModel.focusedItem == nil,
                      Date().timeIntervalSince(lastHeroChange) >= 7 else { return }
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
                    episode: target.entry.episodeNumber?.value
                )
            }
        }
        .onAppear {
            #if DEBUG
            LaunchTrace.mark("home_appear")  // BUG-26: profile gate passed, Home mounting
            #endif
            model.start()
            prefetchHeroArt()
            // UX-7: when a row-focused poster reverts (grace period elapsed, or the CTA
            // reclaimed the hero), re-stamp the carousel's "last change" clock — otherwise the
            // auto-advance timer's next tick would immediately yank the page the instant focus
            // moves away, before the user even sees the carousel resume.
            focusModel.onRevert = { lastHeroChange = Date() }
        }
        .onDisappear { model.stop() }
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
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.sectionGap) {
                if !heroItems.isEmpty && !pinned {
                    // Classic only: the hero scrolls away with the rows, its info panel
                    // sitting on the lower third of the backdrop, Detail-style.
                    // Pinned (Nuvio-style) doesn't render a hero here at all — it sits
                    // ABOVE this ScrollView as the fixed top of the VStack split (see
                    // `pinnedHeroHeader`), which owns its own compacted paddings.
                    heroCarousel
                        .padding(.top, Theme.Size.heroForegroundTopPad)
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

                // Catalog sections and collection folder-tile rows, interleaved per the
                // user's Home Rows settings order.
                ForEach(model.rows) { row in
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
                    case .collection(let collection):
                        CollectionRowView(collection: collection)
                    }
                }
            }
            .padding(rowsInsets(pinned: pinned))
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
        .reportsScrollToTabBar(isScrolledDown: $isScrolledDown)
        // BUG-30 device-verify probe (instrumentation only, behavior-neutral): logs raw
        // contentOffset/contentInsets on every change so `log show` after a D-pad walk-up
        // shows where focus-driven scrolling rests vs. the true top. Off by default; the
        // modifier is only attached when the knob is set, so disabled testers pay nothing.
        //   defaults write com.nuvio.media.NuvioTV debug.homeScrollProbe -bool YES
        .modifier(HomeScrollProbeModifier(enabled: homeScrollProbeEnabled))
        // The BUG-27 Menu handler is NOT here: it lives on the common ancestor in `body`,
        // because in pinned mode the hero CTA is a sibling of this ScrollView and a handler
        // attached here would not cover it (Menu on the CTA would suspend the app).
    }

    /// The paged hero carousel plus its (static) page dots. Fixed height everywhere: paging or
    /// auto-advancing swaps content inside a constant frame, so the rows below never move.
    private var heroCarousel: some View {
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
                    HomeHeroForeground(item: hero, heroFocused: $heroFocused)
                }
            }
            .frame(height: Theme.Size.heroCarouselHeight)
            .focusSection()
            .onMoveCommand { direction in
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
            }

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
    /// Paddings are the COMPACTED pinned set (`heroPinnedTopPad` / `heroPinnedRowsGap`), not the
    /// in-scroll ones: pinned mode shares one screen between hero and rows, so the hero has to
    /// give the rows viewport ~450pt to fit a poster row. See the height budget on those tokens.
    private var pinnedHeroHeader: some View {
        heroCarousel
            .padding(.top, Theme.Size.heroPinnedTopPad)
            .padding(.horizontal, Theme.Spacing.screen)
            .padding(.bottom, Theme.Size.heroPinnedRowsGap)
    }

    /// Content insets for the rows `LazyVStack`. Classic keeps the uniform overscan-safe
    /// `Theme.Spacing.screen` on all four edges, byte-for-byte what it always had. Pinned trims
    /// only the TOP: `pinnedHeroHeader` already supplied the gap above the rows
    /// (`heroPinnedRowsGap`), and a second 60pt there would push row 1 out of the compacted
    /// viewport. The horizontal/bottom insets stay at 60 — with clipping ENABLED in pinned mode
    /// they are also what keeps a focused card's lift inside the clip.
    private func rowsInsets(pinned: Bool) -> EdgeInsets {
        pinned
            ? EdgeInsets(top: Theme.Spacing.sm, leading: Theme.Spacing.screen,
                         bottom: Theme.Spacing.screen, trailing: Theme.Spacing.screen)
            : EdgeInsets(top: Theme.Spacing.screen, leading: Theme.Spacing.screen,
                         bottom: Theme.Spacing.screen, trailing: Theme.Spacing.screen)
    }

    /// Warm the artwork caches for every hero page (backdrop + logo) as soon as the items are
    /// known, so manual paging and the auto-advance crossfade never flash a placeholder.
    private func prefetchHeroArt() {
        var urls: [URL] = []
        for item in heroItems {
            // Both render candidates (primary + poster fallback), same chain the backdrop
            // actually uses — see heroBackdropPrefetchURLs.
            urls.append(contentsOf: heroBackdropPrefetchURLs(for: item).compactMap(URL.init(string:)))
            if let url = heroLogoURL(for: item) { urls.append(url) }
        }
        ArtworkStore.prefetch(urls)
    }

    /// UX-7: single funnel for every row's focus report. Three layers of gating history live
    /// here, each learned the hard way:
    ///  - The Show Hero SETTING gates all work (reports, enrichment, backdrop prefetch) — with
    ///    the hero deliberately off, browsing must not generate artwork/metadata traffic for a
    ///    feature that cannot render (Codex review finding). Read LIVE from the settings repo on
    ///    every event, never captured at row construction.
    ///  - The temporary loading state (`heroItems` still empty during the fan-out) does NOT gate
    ///    reports — `displayHero` gates at display time instead, so a card focused before the
    ///    fan-out lands takes over the moment `heroItems` arrives (no re-report exists at that
    ///    boundary, and a construction-time gate got cached dead by the LazyVStack).
    ///  - Backdrop prefetch warms once per row, on its first non-nil report, through the same
    ///    `heroBackdropURL` chain the hero renders.
    private func reportRowFocus(_ item: MetaPreview?, source: String, prefetch: () -> [String]) {
        guard HomeCatalogSettingsRepository.shared.snapshot().heroEnabled else {
            // Also drop any claim made while the hero WAS enabled: re-enabling later must not
            // resurrect a title whose card focus long since moved on (no @FocusState change
            // fires at that boundary, so a cached claim would win). Idempotent when idle.
            focusModel.cancelAndRevert()
            return
        }
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
fileprivate struct HomeScrollProbeModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        // `enabled == false` returns bare `content` — onScrollGeometryChange is never attached to
        // the view tree, so there's no closure evaluation, no comparison, and no log output.
        if enabled {
            content.onScrollGeometryChange(for: String.self, of: { geo in
                "y=\(Int(geo.contentOffset.y)) inset=\(Int(geo.contentInsets.top))"
            }, action: { _, v in
                NSLog("[HomeScrollProbe] %@", v)
            })
        } else {
            content
        }
    }
}

/// UX-7: drives the always-on "focus-follows-backdrop" hero. When focus rests on a poster in a
/// Home catalog row or Continue Watching, the hero adopts that title's artwork/text live; when
/// focus moves to the hero CTA or off every row, the carousel resumes.
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
                // Field gating mirrors the shared hero path (HomeRepository.withHeroEnrichment):
                // artwork fields only under useArtwork, text fields only under useBasicInfo — a
                // focused-row hero must not bypass the user's TMDB category preferences.
                let useArtwork = settings.useArtwork
                let useBasicInfo = settings.useBasicInfo
                self.focusedItem = MetaPreview(
                    id: base.id,
                    type: base.type,
                    // Carousel parity (withHeroEnrichment): the TMDB localized title wins under
                    // Basic Info, so focusing a card never swaps a localized carousel title back
                    // to the addon's fallback name.
                    name: (useBasicInfo ? self.nonBlank(enrichment.localizedTitle) : nil) ?? base.name,
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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Continue Watching")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)

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
                                    progress: fraction(entry)
                                )
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
                    .padding(.vertical, Theme.Spacing.lg)
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

    var body: some View {
        Group {
            if nuvioStyle {
                HeroCrossfadeImage(url: heroBackdropURL(for: item), fallbackURL: item.poster)
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
                HeroCrossfadeImage(url: heroBackdropURL(for: item), fallbackURL: item.poster)
                    .frame(height: Theme.Size.heroBackdropHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
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
            guard let url, !url.isEmpty, let resolvedURL = URL(string: url) else {
                // This title genuinely has no artwork: fade down to the flat background rather
                // than keep presenting the PREVIOUS title's backdrop under the new title's text.
                fadeToEmpty()
                return
            }
            if let hit = ArtworkStore.cached(resolvedURL) {
                crossfade(to: hit)
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
            if let resolvedFallback, let fallbackHit = ArtworkStore.cached(resolvedFallback) {
                crossfade(to: fallbackHit)
                showedArt = true
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
            await withTaskGroup(of: (Bool, UIImage?).self) { group in
                group.addTask { (true, try? await ArtworkStore.fetch(resolvedURL)) }
                if let resolvedFallback {
                    group.addTask { (false, try? await ArtworkStore.fetch(resolvedFallback)) }
                }
                for await (isPrimary, image) in group {
                    guard !Task.isCancelled else { return }
                    guard let image else { continue }
                    showedArt = true
                    if isPrimary {
                        primaryLanded = true
                        crossfade(to: image)
                    } else if !primaryLanded {
                        crossfade(to: image)
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

    private func crossfade(to image: UIImage) {
        guard image !== current else { return }
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
/// layout-identical and advancing the carousel can never reflow anything around it.
struct HomeHeroForeground: View {
    let item: MetaPreview
    /// Bound to the CTA button — the hero page's ONLY focusable element. The info block above
    /// it is static content (Christian's spec 2026-07-30: the title is no longer selectable;
    /// a "Go to Movie"/"Go to Show" button below the description carries focus instead).
    var heroFocused: FocusState<Bool>.Binding
    @AppStorage("hero_nuvio_style") private var heroNuvioStyle = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Group {
                if heroNuvioStyle {
                    nuvioLayout
                } else {
                    classicLayout
                }
            }
            .accessibilityElement(children: .combine)

            // The CTA sits below the description and above the page dots (which render
            // outside the TabView). D-pad left/right still pages the carousel while this
            // button holds focus — it is the page's focus anchor.
            NavigationLink(value: TitleRoute(preview: item)) {
                Text(ctaTitle)
                    .font(Theme.Font.body)
            }
            .buttonStyle(.glass)
            .focused(heroFocused)
            .frame(height: Theme.Size.heroButtonSlotHeight, alignment: .center)
            .accessibilityLabel("\(ctaTitle): \(item.name)")
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Theme.Size.heroSynopsisSlotHeightNuvio, alignment: .topLeading)
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
