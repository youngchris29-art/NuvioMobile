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

    /// Tab-bar clip round 6: true while the scroll rests in the "walked back up but short of the
    /// true top" window (4–150pt). The hero-refocus completion scroll below only fires here.
    @State private var topCompletionEligible = false

    private var heroItems: [MetaPreview] { Array(model.heroItems.prefix(8)) }
    private var currentHero: MetaPreview? {
        guard !heroItems.isEmpty else { return nil }
        return heroItems[min(heroIndex, heroItems.count - 1)]
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
                Text("debug_hero idx=\(heroIndex) foc=\(heroFocused ? 1 : 0) n=\(heroItems.count)")
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
                if let hero = currentHero {
                    Group {
                        // Nuvio-style: right-anchored artwork whose left edge fades to the
                        // flat background — the info panel never sits over the art.
                        HomeHeroBackdrop(item: hero, nuvioStyle: heroNuvioStyle)
                        HomeHeroScrim()
                    }
                    .opacity(heroPosterFocusOnly ? (heroFocused ? 1 : 0) : 1)
                    .animation(.easeInOut(duration: 0.4), value: heroFocused)
                    // Purely decorative background art — the same title/synopsis is exposed by
                    // the focusable HomeHeroForeground button in front of it, so VoiceOver
                    // shouldn't stop on this layer too.
                    .accessibilityHidden(true)
                }

                ScrollViewReader { scrollProxy in
                ScrollView(.vertical) {
                    // Lazy so row construction (and each row's poster loads) is deferred to
                    // scroll position — an eager VStack builds every catalog row up front,
                    // which on catalog-heavy accounts stalls the main thread past the
                    // watchdog and bursts artwork decodes past jetsam (BUG-11).
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.sectionGap) {
                        if !heroItems.isEmpty {
                            // Nuvio-style raises the info panel toward the top of the backdrop
                            // (reference: upstream's modern home) — classic keeps it on the
                            // lower third, Detail-style.
                            heroCarousel
                                .padding(.top, heroNuvioStyle
                                    ? Theme.Size.heroForegroundTopPadNuvio
                                    : Theme.Size.heroForegroundTopPad)
                        }

                        if model.rows.isEmpty {
                            placeholder
                        }

                        if !model.continueWatching.isEmpty {
                            ContinueWatchingRow(
                                entries: model.continueWatching,
                                onSelect: { resume = ResumeTarget(entry: $0) },
                                onRemove: { WatchProgressRepository.shared.clearProgress(videoId: $0.videoId, parentMetaId: $0.parentMetaId) }
                            )
                        }

                        // Catalog sections and collection folder-tile rows, interleaved per the
                        // user's Home Rows settings order.
                        ForEach(model.rows) { row in
                            switch row {
                            case .catalog(let section):
                                CatalogRowView(section: section, previewLimit: CatalogRowView.homePreviewLimit)
                            case .collection(let collection):
                                CollectionRowView(collection: collection)
                            }
                        }
                    }
                    .padding(Theme.Spacing.screen)
                    // Menu-to-top scroll anchor (BUG-27). On the LazyVStack itself, not the
                    // hero — the anchor must exist even while the hero row is lazily culled.
                    .id("home_top")
                }
                .scrollClipDisabled()
                .reportsScrollToTabBar(isScrolledDown: $isScrolledDown)
                // BUG-27: from down the page, Menu jumps back to the top and hands focus to
                // the hero CTA — one press instead of dozens of Ups, and from there a single
                // Up reaches the (now visible again) tab bar. The handler is nil at the top
                // so Menu keeps its default root behavior there; it only attaches when the
                // hero exists, because jumping without a focus anchor would let the focus
                // engine drag the scroll right back down to the still-focused row.
                .onExitCommand(perform: (isScrolledDown && !heroItems.isEmpty) ? {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        scrollProxy.scrollTo("home_top", anchor: .top)
                    }
                    // Focus can only land on the hero CTA once the lazy top region is built;
                    // hand it over just after the scroll animation settles.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        heroFocused = true
                    }
                } : nil)
                // Tab-bar clip, rounds 5–6 — the actual mechanism (device-diagnosed): focus-driven
                // scrolling stops wherever the focused item fits, SHORT of the true top edge, and
                // the tvOS 26 system bar's scroll-linked expansion sticks mid-way (clipped at the
                // screen top until focus moves inside the bar). Menu-to-top never clipped because
                // it scrolls to the real top — so when focus WALKS back onto the hero, finish the
                // job the same way. Round 6: gated to the residual window (near the top but not AT
                // it) — round 5 fired this unconditionally, and the scroll animation it started on
                // every at-top focus return contended with downward focus scrolling, wedging Down
                // navigation at the hero.
                .onScrollGeometryChange(for: Bool.self, of: { geo in
                    let y = geo.contentOffset.y - geo.contentInsets.top
                    return y > 4 && y < 150
                }, action: { _, inWindow in
                    topCompletionEligible = inWindow
                })
                .onChange(of: heroFocused) { _, focused in
                    guard focused, topCompletionEligible else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scrollProxy.scrollTo("home_top", anchor: .top)
                    }
                }
                }
            }
            .onReceive(heroTimer) { _ in
                // Reduce Motion: pause auto-advance entirely rather than rebasing the TabView
                // selection without animation — that desyncs tvOS's paged TabView (see the
                // comment below), so the only safe accommodation is to stop advancing and let
                // the carousel sit still until the user pages manually (still animated).
                guard !reduceMotion else { return }
                guard heroItems.count > 1, !heroFocused,
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
        }
        .onDisappear { model.stop() }
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
                if let hero = currentHero {
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
                // Both layouts keep the info panel on the left, so the dots stay leading.
                HeroPageDots(count: heroItems.count, index: min(heroIndex, heroItems.count - 1))
                    .padding(.leading, Theme.Spacing.lg)
            }
        }
    }

    /// Warm the artwork caches for every hero page (backdrop + logo) as soon as the items are
    /// known, so manual paging and the auto-advance crossfade never flash a placeholder.
    private func prefetchHeroArt() {
        var urls: [URL] = []
        for item in heroItems {
            let banner: String? = item.banner
            let poster: String? = item.poster
            let backdrop = (banner?.isEmpty == false) ? banner : poster
            if let backdrop, !backdrop.isEmpty, let url = URL(string: backdrop) { urls.append(url) }
            if let url = heroLogoURL(for: item) { urls.append(url) }
        }
        ArtworkStore.prefetch(urls)
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

/// Horizontal "Continue Watching" row of in-progress titles with a progress bar. Tapping a card opens
/// the stream picker for that exact video (the in-progress episode for series), and playback resumes
/// from the saved position.
struct ContinueWatchingRow: View {
    let entries: [WatchProgressEntry]
    let onSelect: (WatchProgressEntry) -> Void
    let onRemove: (WatchProgressEntry) -> Void
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
/// to every edge — no corner radius, no inset — and runs under the floating glass tab bar. The
/// image crossfades when the parent advances `item`.
struct HomeHeroBackdrop: View {
    let item: MetaPreview
    /// Nuvio-style hero: the artwork becomes a right-anchored panel whose LEFT edge fades
    /// out through a gradient mask, so the info panel sits on pure flat background — none of
    /// the artwork ever renders behind the title/description (Christian's spec, 2026-07-30).
    var nuvioStyle: Bool = false

    var body: some View {
        Group {
            if nuvioStyle {
                CachedAsyncImage(string: backdropURL)
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
                CachedAsyncImage(string: backdropURL)
                    .frame(height: Theme.Size.heroBackdropHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .id(item.id)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.6), value: item.id)
    }

    private var backdropURL: String? {
        let banner: String? = item.banner
        if let banner, !banner.isEmpty { return banner }
        let poster: String? = item.poster
        return poster
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
