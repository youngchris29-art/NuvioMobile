import SwiftUI
import UIKit
import SharedCore

/// Pinned-hero card reach (UX-7 extension, device round 4 of the pinned pass, 2026-08-03).
///
/// On tvOS there is no free momentum scrolling — Siri Remote swipes drive the FOCUS engine and
/// every vertical rest comes from its scroll-to-reveal, which aligns to the focused CARD's
/// frame. Real hardware rests that reveal systematically short (the BUG-30 residual class), so
/// in Home's pinned-hero mode — where the rows viewport hard-clips at the hero boundary — any
/// content ABOVE the focused card's frame (the row's section title, the top band) can end up
/// cut. Rounds 2–3 proved padding OUTSIDE the card frame can never fix this: the reveal simply
/// doesn't include it.
///
/// The fix: rows extend each focusable card's frame UPWARD by this many transparent points
/// (inside the button label, compensated by the row's paddings so nothing moves visually). The
/// reveal target then physically includes the title band — the engine cannot rest a row with
/// its title or art cut. 0 (the default) everywhere except Home's pinned mode, where HomeView
/// sets `Theme.Size.heroPinnedRowTopPad`; at 0 every consuming expression collapses to the
/// original layout, keeping classic byte-identical.
private struct RowCardTopReachKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// Downward twin of `rowCardTopReach` (device round 5): scrolling DOWN, the reveal rests short
/// in the mirror direction — the focused card's frame BOTTOM (caption included) lands below the
/// fold and the art's bottom edge is cut. Extending the frame downward by this many transparent
/// points absorbs that shortfall the same way the top reach absorbs the upward one.
private struct RowCardBottomReachKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var rowCardTopReach: CGFloat {
        get { self[RowCardTopReachKey.self] }
        set { self[RowCardTopReachKey.self] = newValue }
    }
    var rowCardBottomReach: CGFloat {
        get { self[RowCardBottomReachKey.self] }
        set { self[RowCardBottomReachKey.self] = newValue }
    }
}

/// Swift-side navigation value. Kotlin data classes don't conform to Swift `Hashable`, so we wrap the
/// `MetaPreview` and hash on its stable identity (type + id) while still carrying all its fields for
/// the destination's initial render. Shared by Home, Search, and detail "more like this".
struct TitleRoute: Hashable {
    let preview: MetaPreview

    static func == (lhs: TitleRoute, rhs: TitleRoute) -> Bool {
        lhs.preview.id == rhs.preview.id && lhs.preview.type == rhs.preview.type
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(preview.id)
        hasher.combine(preview.type)
    }
}

/// Navigation value for the full-grid "See All" screen. `CatalogTarget` is a Kotlin sealed interface
/// and can't be a `NavigationStack` value directly, so we wrap it — hashing on the section's stable
/// `key` while carrying the title + target for the destination (same approach as `TitleRoute`).
struct CatalogRoute: Hashable {
    let key: String
    let title: String
    let target: any CatalogTarget

    init(section: HomeCatalogSection) {
        self.key = section.key
        self.title = section.title
        self.target = section.target
    }

    static func == (lhs: CatalogRoute, rhs: CatalogRoute) -> Bool { lhs.key == rhs.key }

    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// Navigation value for a cast/crew member's detail page (TMDB person id + name for the initial
/// render). Only produced when a `MetaPerson` has a `tmdbId`. Hashes on the id.
struct PersonRoute: Hashable {
    let id: Int
    let name: String

    static func == (lhs: PersonRoute, rhs: PersonRoute) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Navigation value for a studio/network browse page (TMDB discover-by-company/network). Only
/// produced when a `MetaCompany` has a `tmdbId`. `isNetwork` picks the TMDB entity kind (networks
/// come from `meta.networks`, studios from `meta.productionCompanies`); `sourceType` is the origin
/// title's type ("movie"/"series"), which orders the rails. Hashes on kind + id.
struct EntityRoute: Hashable {
    let id: Int
    let name: String
    let isNetwork: Bool
    let sourceType: String

    static func == (lhs: EntityRoute, rhs: EntityRoute) -> Bool {
        lhs.id == rhs.id && lhs.isNetwork == rhs.isNetwork
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(isNetwork)
    }
}

/// One horizontal catalog (e.g. "Popular Movies", or a search-result group) as a focus-scrollable row
/// of poster cards.
///
/// By default each card is a `NavigationLink` to the title's detail screen (used on Home). Pass
/// `onSelect` to instead handle taps manually — Search uses this to dismiss the keyboard before
/// navigating.
struct CatalogRowView: View {
    /// BUG-13: the Home fetch trims each row to `HOME_CATALOG_PREVIEW_FETCH_LIMIT` items
    /// (HomeRepository.kt) while `availableItemCount` keeps the addon's real first-page count. Rows
    /// built that way must pass this limit so the "See All" gate can spot a truncated catalog.
    static let homePreviewLimit = 18

    let section: HomeCatalogSection
    /// Number of items the producing repository kept for this row, or `nil` when the row already
    /// renders everything it fetched (Search) — then only `hasMore` can open the full grid.
    var previewLimit: Int? = nil
    var onSelect: ((MetaPreview) -> Void)? = nil
    /// UX-7: reports the focused card's item (or nil) so Home can drive the hero from it.
    /// Defaulted and appended last — Search's call site (`CatalogRowView(section:)`) and Home's
    /// (`section:previewLimit:`) both compile unchanged. Gating and backdrop prefetch live in
    /// the callback (HomeView.reportRowFocus), not here.
    var onItemFocusChange: ((MetaPreview?) -> Void)? = nil

    /// Inline trailer previews on focus dwell (see `InlineTrailerCard`). Device-local on purpose —
    /// whether a living-room Apple TV should autoplay trailers is a per-device call, not a synced
    /// account preference. Off by default (opt-in); Settings → Home Screen owns the toggle UI.
    @AppStorage("inline_trailers_enabled") private var inlineTrailersEnabled = false

    /// Which card holds focus. Needed here (rather than inside the card) because tvOS delivers
    /// remote commands to the *focused view chain* — the `Button`/`NavigationLink` below, never its
    /// label — so the play/pause mute toggle has to be attached at this level and gated on "this is
    /// the focused item, and it is the one playing".
    @FocusState private var focusedItemId: String?

    /// Which card currently owns the single inline `AVPlayer`, published by the shared coordinator.
    @ObservedObject private var trailerCoordinator = InlineTrailerCoordinator.shared

    /// BUG-29: an inline-trailer expansion widens its card in place without moving focus, so tvOS's
    /// automatic focus-driven scroll never fires — the row has to scroll itself, and Reduce Motion
    /// governs whether that scroll animates (see `expansionChanged(for:expanded:proxy:)`).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// tvOS Accessibility ▸ Motion ▸ Auto-Play Video Previews. When the user has turned previews off
    /// system-wide, the row must render exactly as it did before this feature existed.
    private var inlineTrailersActive: Bool {
        inlineTrailersEnabled && UIAccessibility.isVideoAutoplayEnabled
    }

    /// BUG-13: an addon whose manifest declares no `skip` extra always reports `hasMore == false`,
    /// even when its single response carried far more titles than the row kept — gating on `hasMore`
    /// alone made those catalogs a dead end. Mirrors composeApp's Home gate, which uses the same
    /// shared `canOpenCatalog(previewLimit:)` (HomeModels.kt: availableItemCount > previewLimit || hasMore).
    private var canOpenFullCatalog: Bool {
        guard let previewLimit else { return section.hasMore }
        return section.canOpenCatalog(previewLimit: Int32(previewLimit))
    }

    /// Pinned-hero card reach (UX-7 extension, device rounds 4–5) — see `rowCardTopReach` /
    /// `rowCardBottomReach` for the mechanism. 0 (no-op) everywhere except Home's pinned mode.
    @Environment(\.rowCardTopReach) private var cardTopReach
    @Environment(\.rowCardBottomReach) private var cardBottomReach

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Classic keeps the title as a plain sibling above the shelf. PINNED mode instead
            // overlays the title INSIDE the shelf's top reach band (below) so the focused
            // cards' frames — which the focus engine's scroll-to-reveal aligns — physically
            // contain the title's region. Earlier attempts reached the card frames upward
            // with NEGATIVE compensating paddings; once the reach exceeded the row's own
            // bounds the focused item sat outside its .focusSection() geometry and the
            // engine's directional resolution FROZE outright (sim-reproduced, device rounds
            // 5–7). All-positive paddings keep every frame inside the row.
            //
            // The "See All" affordance is a trailing CARD inside the shelf (device round 5,
            // Christian's call): the old header pill was a focusable stop BETWEEN rows, so
            // vertical focus travel could land on it and reveals would align its tiny frame —
            // degenerate rest positions (sliver rows, floating pill, art cut at the fold).
            if cardTopReach == 0 {
                Text(section.title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.rowGap) {
                        ForEach(section.items, id: \.id) { item in
                            Group {
                                if let onSelect {
                                    Button { onSelect(item) } label: {
                                        card(for: item, proxy: proxy)
                                            .padding(.top, cardTopReach)
                                            .padding(.bottom, cardBottomReach)
                                    }
                                        .buttonStyle(.borderless)
                                        .posterButtonShape()
                                } else {
                                    NavigationLink(value: TitleRoute(preview: item)) {
                                        card(for: item, proxy: proxy)
                                            .padding(.top, cardTopReach)
                                            .padding(.bottom, cardBottomReach)
                                    }
                                    .buttonStyle(.borderless)
                                    .posterButtonShape()
                                }
                            }
                            .focused($focusedItemId, equals: item.id)
                            // Mirrors Detail's hero trailer: the card's mute glyph isn't reachable by
                            // the focus engine, so play/pause is the toggle. Nil unless *this* focused
                            // card is the one playing — an unconditional handler would swallow
                            // play/pause from everything else that wants it (Home's hero).
                            .onPlayPauseCommand(perform: muteToggle(for: item))
                            .id(item.id)
                        }

                        // Trailing "See All" card (see the header comment). Same gate as the
                        // pill had; same route.
                        if canOpenFullCatalog {
                            NavigationLink(value: CatalogRoute(section: section)) {
                                SeeAllCard()
                                    .padding(.top, cardTopReach)
                                    .padding(.bottom, cardBottomReach)
                            }
                            .buttonStyle(.borderless)
                            .posterButtonShape()
                        }
                    }
                    // ALWAYS positive — the reach lives inside the buttons' labels, the row's
                    // frame contains it whole, and nothing pokes outside the focus section.
                    .padding(.vertical, Theme.Spacing.lg)
                }
                .scrollClipDisabled()
                // Pinned: the title floats over the (transparent) reach band at the shelf's
                // top-leading corner — visually where it always was, but INSIDE the region
                // the focused cards' frames cover, so every reveal shows it.
                .overlay(alignment: .topLeading) {
                    if cardTopReach > 0 {
                        Text(section.title)
                            .font(Theme.Font.sectionTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .padding(.top, Theme.Size.heroPinnedRowTitleInset)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .focusSection()
        .onChange(of: focusedItemId) { _, newId in
            onItemFocusChange?(newId.flatMap { id in section.items.first { $0.id == id } })
        }
    }

    /// Portrait poster by default; a 16:9 landscape card when the user enables landscape catalog
    /// rows — both rendered by `InlineTrailerCard`, which also grows the muted trailer preview once
    /// focus rests on the card. With inline trailers off it is a straight pass-through to the same
    /// two cards, so the row is unchanged.
    private func card(for item: MetaPreview, proxy: ScrollViewProxy) -> some View {
        InlineTrailerCard(item: item, enabled: inlineTrailersActive) { expanded in
            expansionChanged(itemId: item.id, expanded: expanded, proxy: proxy)
        }
    }

    /// BUG-29: an inline-trailer expansion morphs the focused card wider **to the right** in place —
    /// focus never moves (it's still the same button), so tvOS never issues its usual focus-driven
    /// scroll, and a card near a row's trailing edge grows straight off the visible strip. Ask the
    /// `ScrollView` to bring the card back into view ourselves whenever it expands; a `nil` anchor
    /// asks for the *minimal* scroll needed, so a card that already fits doesn't jump. Collapsing
    /// needs no help — the row only ever overflows while a card is wide, never while it's back to
    /// poster width.
    ///
    /// Deferred by one runloop hop so the scroll targets the tile's *expanded* geometry: `expanded`
    /// flips the instant the morph starts (`InlineTrailerCardModel.setPhase`), not when it finishes,
    /// so scrolling in the same tick would still measure the old, narrower frame. The morph itself
    /// runs 0.35s (`InlineTrailerCardModel.morphAnimation`), so the deferred scroll still lands well
    /// inside it and the two animate together visually.
    private func expansionChanged(itemId: String, expanded: Bool, proxy: ScrollViewProxy) {
        guard expanded else { return }
        // Device finding (BUG-29 round 2): a nil-anchor scrollTo at morph START is a no-op —
        // the tile's pre-growth frame is still fully visible at that moment, so "minimal
        // scroll" resolves to nothing and the tile then grows off the trailing edge anyway.
        // Two-part fix: the LAST item deterministically needs its trailing edge pinned to the
        // viewport (no geometry read needed), and every other item gets a correction pass
        // AFTER the 0.35s morph settles, when scrollTo finally sees the expanded frame.
        let anchor: UnitPoint? = itemId == section.items.last?.id ? .trailing : nil
        Task { @MainActor in
            scrollToExpanded(itemId, anchor: anchor, proxy: proxy)
            try? await Task.sleep(nanoseconds: 450_000_000)
            scrollToExpanded(itemId, anchor: anchor, proxy: proxy)
        }
    }

    private func scrollToExpanded(_ itemId: String, anchor: UnitPoint?, proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(itemId, anchor: anchor)
        } else {
            withAnimation(InlineTrailerCardModel.morphAnimation) {
                proxy.scrollTo(itemId, anchor: anchor)
            }
        }
    }

    /// Play/pause handler for `item`'s focusable button, or `nil` when this card isn't the focused,
    /// currently-playing one — `.onPlayPauseCommand(perform: nil)` leaves the command to whoever
    /// else is listening instead of consuming it.
    private func muteToggle(for item: MetaPreview) -> (() -> Void)? {
        guard focusedItemId == item.id,
              trailerCoordinator.playingKey == TrailerResolutionCache.key(type: item.type, id: item.id)
        else { return nil }
        return { HeroTrailerAudioState.shared.toggleMuted() }
    }
}

/// The trailing "See All" tile at the end of a catalog row (device round 5 of the pinned-hero
/// pass — replaces the focusable header pill; see CatalogRowView's header comment for why).
/// Shaped like the row's RESTING cards — portrait per the user's Poster Style, or 16:9 landscape
/// when landscape catalog rows are on — so the shelf reads as one continuous strip and vertical
/// focus travel always lands on card-sized frames. When captions are visible, an empty caption
/// slot keeps the tile's art aligned with its neighbors' art. Standard system lift
/// (`.hoverEffect(.highlight)`); in FEAT-14 ring mode the tile deliberately keeps the system
/// treatment — the accent ring marks CONTENT cards, and a utility tile reads fine without it.
struct SeeAllCard: View {
    @Environment(\.posterStyle) private var style

    private var tileWidth: CGFloat {
        style.landscapeCatalogRows ? Theme.Size.landscapeWidth : style.width
    }
    private var tileHeight: CGFloat {
        style.landscapeCatalogRows ? Theme.Size.landscapeHeight : style.height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text("See All")
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .frame(width: tileWidth, height: tileHeight)
            .background(
                Theme.Palette.surfaceElevated,
                in: RoundedRectangle(cornerRadius: style.cornerRadius)
            )
            .nuvioCardDepth(RoundedRectangle(cornerRadius: style.cornerRadius), surface: .posters)
            .hoverEffect(.highlight)

            if style.showTitle {
                // Empty caption slot: neighbors are art + caption, so without this the
                // LazyHStack's center alignment would float the tile relative to their art.
                Text(verbatim: " ")
                    .font(Theme.Font.cardTitle)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
        }
    }
}

/// A single poster tile, now backed by the shared `PosterCard` design-system component
/// (cached artwork, shimmer, brand focus ring, focus-aware title).
struct PosterCardView: View {
    let item: MetaPreview

    var body: some View {
        PosterCard(title: item.name, imageURL: item.poster)
    }
}
