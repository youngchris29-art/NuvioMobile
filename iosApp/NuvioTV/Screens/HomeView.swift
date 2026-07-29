import Combine
import SwiftUI
import SharedCore

/// First real content screen for tvOS: a focus-navigable grid of catalog rows, fed entirely by the
/// shared Kotlin `HomeRepository`. Tapping a poster pushes the detail screen.
struct HomeView: View {
    @StateObject private var model = HomeViewModel()
    @State private var resume: ResumeTarget?

    /// Whether the hero backdrop artwork only renders while the hero carousel is focused (the
    /// original behavior). A beta tester read the focus-gated fade as a bug ("hero posts don't
    /// work") since the artwork is invisible until you navigate down to it, so the default is now
    /// false — artwork always visible — with this Settings toggle to restore the old fade for
    /// anyone who preferred it. UserDefaults-backed and local-only (not synced): it's a per-device
    /// display preference, not account state, so no shared/Kotlin settings plumbing is needed.
    @AppStorage("hero_poster_focus_only") private var heroPosterFocusOnly = false

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

    private var heroItems: [MetaPreview] { Array(model.heroItems.prefix(8)) }
    private var currentHero: MetaPreview? {
        guard !heroItems.isEmpty else { return nil }
        return heroItems[min(heroIndex, heroItems.count - 1)]
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.Palette.background.ignoresSafeArea()

                // Full-bleed hero backdrop runs to every edge (and under the floating glass tab
                // bar); the rows scroll over it, Detail-style.
                // Default: always show the artwork, so it's visible the moment Home appears
                // (see heroPosterFocusOnly doc comment above). With the Settings toggle on,
                // fall back to the original behavior — only show it while the hero itself is
                // highlighted, fading to the flat dark background once focus moves down into
                // Continue Watching / the catalogs.
                if let hero = currentHero {
                    Group {
                        HomeHeroBackdrop(item: hero)
                        HomeHeroScrim()
                    }
                    .opacity(heroPosterFocusOnly ? (heroFocused ? 1 : 0) : 1)
                    .animation(.easeInOut(duration: 0.4), value: heroFocused)
                }

                ScrollView(.vertical) {
                    // Lazy so row construction (and each row's poster loads) is deferred to
                    // scroll position — an eager VStack builds every catalog row up front,
                    // which on catalog-heavy accounts stalls the main thread past the
                    // watchdog and bursts artwork decodes past jetsam (BUG-11).
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.sectionGap) {
                        if !heroItems.isEmpty {
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
                }
                .scrollClipDisabled()
                .reportsScrollToTabBar()
            }
            .onReceive(heroTimer) { _ in
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
            model.start()
            prefetchHeroArt()
        }
        .onDisappear { model.stop() }
    }

    /// The paged hero carousel plus its (static) page dots. Fixed height everywhere: paging or
    /// auto-advancing swaps content inside a constant frame, so the rows below never move.
    private var heroCarousel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            TabView(selection: $heroIndex) {
                ForEach(Array(heroItems.enumerated()), id: \.offset) { index, item in
                    HomeHeroForeground(item: item)
                        .focused($heroFocused)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: Theme.Size.heroCarouselHeight)
            .focusSection()

            if heroItems.count > 1 {
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
                            .buttonStyle(.poster)
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

    var body: some View {
        CachedAsyncImage(string: backdropURL)
            .frame(height: Theme.Size.heroBackdropHeight)
            .frame(maxWidth: .infinity)
            .clipped()
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

/// One page of the hero carousel: logo/title, metadata and a short synopsis — a single focusable
/// target that opens the detail screen. Every slot has a FIXED height (logo box, one meta line,
/// two synopsis lines), so all pages are layout-identical and advancing the carousel can never
/// reflow anything around it.
struct HomeHeroForeground: View {
    let item: MetaPreview

    var body: some View {
        NavigationLink(value: TitleRoute(preview: item)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HeroLogo(item: item)
                    .frame(height: Theme.Size.heroLogoSlotHeight, alignment: .bottomLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(HeroFocusUnderline())

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
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Full-bleed carousel page: a ring or scale would clip at the page edges, so hero
            // focus is just a soft glow + content brightening (see HeroFocusGlow).
            .modifier(HeroFocusGlow())
        }
        .buttonStyle(.poster)
        .accessibilityLabel(item.name)
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

/// Subtle focus treatment for the hero carousel page: brightens the content and adds a soft white
/// glow when focused. Deliberately no ring, platter, or scale — the hero spans the full carousel
/// page, so any of those would clip at its edges.
private struct HeroFocusGlow: ViewModifier {
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .opacity(isFocused ? 1 : 0.88)
            .shadow(color: .white.opacity(isFocused ? 0.22 : 0), radius: 20)
            .animation(.easeOut(duration: 0.2), value: isFocused)
    }
}

/// Accent underline that slides in beneath the hero logo when the hero is focused. Drawn as an
/// overlay hanging just below the fixed logo slot, so it never changes the carousel's layout.
private struct HeroFocusUnderline: ViewModifier {
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomLeading) {
            Capsule()
                .fill(Theme.Palette.accentFocus)
                .frame(width: isFocused ? 160 : 0, height: 5)
                .offset(y: 14)
                .opacity(isFocused ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: isFocused)
        }
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
