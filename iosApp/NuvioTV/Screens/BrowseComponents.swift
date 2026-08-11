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

// MARK: - Home geometry probes (BUG-30 / BUG-37)

/// Runtime knob shared by every Home geometry probe — all of them log with the `[HomeScrollProbe]`
/// prefix, so one device walk produces one greppable stream:
///
///     defaults write com.nuvio.media.NuvioTV debug.homeScrollProbe -bool YES
///
/// Read ONCE at launch: a disabled probe costs a single Bool for the whole session, because every
/// probe is a modifier that simply isn't attached when this is false (see `pinnedRowTitleTracking`
/// here and `HomeScrollProbeModifier` in HomeView).
///
/// Deliberately NOT `#if DEBUG`, matching the existing BUG-30 probe it now backs: there is no
/// automated input path to the physical Apple TV, so every device pass is a manual walk that may
/// well be a release-configuration sideload, and the console is the only diagnostic that comes
/// back (same precedent as `ProfilesViewModel.select(_:)`).
enum HomeGeometryProbe {
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.homeScrollProbe")
}

// MARK: - Pinned row title tracking (BUG-37)

/// Keeps a PINNED row's overlaid section title inside the rows viewport at every rest position the
/// DEVICE produces, not just the exact ones the simulator produces.
///
/// Why round 8's compromise wasn't enough. The title is overlaid `heroPinnedRowTitleInset` (48)
/// below the SHELF's top; the focusable card frame the engine's scroll-to-reveal aligns starts
/// `Spacing.lg` (24) below that same shelf top, inside the shelf's own padding. So the static
/// margin between "the engine rested the card frame's top at the viewport edge" and "the title's
/// top" is 48 − 24 = 24pt — round 8 read the inset against the shelf and recorded it as ~48. The
/// device's measured rest error is 40–67pt short (`[HomeScrollProbe]`, 1,603 samples, 2026-08-02:
/// rest y=-90 vs true top -157), so the title clears on the sim and is cut on hardware.
///
/// Why NOT card-anchoring the title (moving it inside the button's label), which is the obvious
/// "it moves with the card" fix. It buys nothing here: the shelf never scrolls vertically, so the
/// title and the cards are already rigid with respect to each other — re-anchoring changes which
/// edge the inset is measured from, not the geometry. The band above the art is 96pt whichever
/// anchor you pick, the title is ~40pt, so the best static margin either way is ~32pt, still under
/// the envelope. And it would spend the structural invariants rounds 5–7 paid for: label content
/// has to be compensated by paddings that stay POSITIVE (negative compensation put focusable
/// frames outside their `.focusSection()` and froze directional resolution), a per-card overlay
/// would draw the title once per card, and any extra band means a reach above 72 — the sim
/// bisected 100 as where focus resolution dies.
///
/// What happens instead: the title stays exactly where round 8 put it at a true rest, and slides
/// DOWN by however much the viewport's top edge has eaten into it, clamped to
/// `heroPinnedRowTitleMaxSlide`. Render-time only — `visualEffect` runs at draw time, so there is
/// no layout pass, no `@State` write, and no view identity involved (the BUG-19 rule is untouched;
/// nothing here can churn identity per scroll frame). At 0pt of rest error nothing moves and the
/// look is byte-identical to beta.10; across the whole 0–67pt envelope the title parks against the
/// clip edge instead of disappearing behind it; past the clamp (a row scrolled well above the
/// focused one) it releases and scrolls away like any other content, i.e. it behaves as a sticky
/// header for exactly as long as its row is still on screen.
///
/// Contract note for `CollectionRowView` (CollectionsUI.swift, same overlay pattern via the same
/// environment values): the contract is UNCHANGED — the title is still an overlay on the shelf at
/// the same inset — so that row keeps working untouched, it simply keeps the round-8 behavior. The
/// follow-up is one line: add `.pinnedRowTitleTracking(rowKey: collection.id)` to its overlaid
/// `Text` immediately before the existing `.padding(.top, Theme.Size.heroPinnedRowTitleInset)`.
enum PinnedRowTitle {
    /// Name Home attaches to its rows ScrollView (`rowsScroll`) purely as a resolution fallback
    /// for `visibleBounds` below. Also the name `CollectionRowView`'s follow-up inherits for free.
    nonisolated static let rowsScrollSpace = "home_rows_scroll"

    /// The rows viewport's rect, converted into the TITLE's local space — so `minY > 0` reads
    /// directly as "the viewport's top edge is this far BELOW the title's top", i.e. exactly this
    /// much of the title is currently clipped away.
    ///
    /// Primary lookup is the enclosing VERTICAL scroll view (the row's own shelf is horizontal, so
    /// the axis filter skips it). The named fallback covers the case where that filter doesn't
    /// resolve through the nested shelf: a miss on both is fail-safe (no slide = exactly today's
    /// behavior) but silent, so the probe logs nothing for titles — which is itself the signal
    /// that the lookup, not the geometry, is what needs looking at.
    nonisolated static func visibleBounds(_ proxy: GeometryProxy) -> CGRect? {
        proxy.bounds(of: .scrollView(axis: .vertical)) ?? proxy.bounds(of: .named(rowsScrollSpace))
    }

    /// How far the title must ride DOWN to stay fully inside the rows viewport, clamped.
    /// `proxy` must be the TITLE's own geometry (local origin = the title's top-left).
    nonisolated static func slide(_ proxy: GeometryProxy) -> CGFloat {
        guard let visible = visibleBounds(proxy) else { return 0 }
        return min(max(visible.minY, 0), Theme.Size.heroPinnedRowTitleMaxSlide)
    }

    /// Signed clearance between the title's top and the viewport's top edge BEFORE sliding —
    /// negative means the rest fell short far enough to cut the title (BUG-37 reproducing).
    /// Probe-only.
    nonisolated static func rawMargin(_ proxy: GeometryProxy) -> CGFloat? {
        visibleBounds(proxy).map { -$0.minY }
    }
}

extension View {
    /// Applies the BUG-37 slide, plus (knob on) the measurement the manual device pass needs.
    /// Attach to the TITLE TEXT ITSELF, BEFORE its `.padding(.top,)` — the modifier reads the
    /// text's own frame, so padding applied first would shift what it measures.
    func pinnedRowTitleTracking(rowKey: String) -> some View {
        modifier(PinnedRowTitleTracking(rowKey: rowKey))
    }
}

private struct PinnedRowTitleTracking: ViewModifier {
    let rowKey: String

    func body(content: Content) -> some View {
        content
            .visualEffect { effect, proxy in
                effect.offset(y: PinnedRowTitle.slide(proxy))
            }
            .modifier(PinnedRowTitleProbe(rowKey: rowKey, enabled: HomeGeometryProbe.enabled))
    }
}

/// `[HomeScrollProbe] title row=… margin=… slide=… net=…`, so a single manual up-walk MEASURES
/// BUG-37 instead of eyeballing it, per row:
///  - `margin` — title top vs the viewport's top edge BEFORE the slide. Negative is round 8's
///    failure reproducing, and its magnitude is that rest's share of the 0–67pt envelope.
///  - `slide`  — how far this fix moved the title (0 at a true rest).
///  - `net`    — what the viewer actually sees. **This must stay ≥ 0**; a negative `net` means the
///    rest exceeded `heroPinnedRowTitleMaxSlide` and the clamp needs raising.
/// Not attached at all when the knob is off, so disabled builds evaluate none of it.
private struct PinnedRowTitleProbe: ViewModifier {
    let rowKey: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            // Captured by value so the geometry closure holds a plain String rather than this
            // (view-isolated) modifier.
            let key = rowKey
            content.onGeometryChange(for: String.self, of: { proxy in
                guard let margin = PinnedRowTitle.rawMargin(proxy) else { return "" }
                let slide = PinnedRowTitle.slide(proxy)
                return "row=\(key) margin=\(probeBucket(margin)) slide=\(probeBucket(slide)) net=\(probeBucket(margin + slide))"
            }, action: { _, value in
                guard !value.isEmpty else { return }
                NSLog("[HomeScrollProbe] title %@", value)
            })
        } else {
            content
        }
    }
}

/// 2pt buckets. `onGeometryChange` only fires when its value CHANGES, so quantizing turns a
/// per-frame scroll animation into a handful of lines per row per hop while staying an order of
/// magnitude finer than the 40–67pt envelope being measured.
private nonisolated func probeBucket(_ value: CGFloat) -> Int {
    Int((value / 2).rounded()) * 2
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
        let active = inlineTrailersEnabled && UIAccessibility.isVideoAutoplayEnabled
        // BUG-55: both gates default OFF, and a fresh container silently resets the toggle — a
        // no-trailers session must say WHY in the log, once per state change, not per render.
        InlineTrailerGateProbe.report(enabled: inlineTrailersEnabled, autoplay: UIAccessibility.isVideoAutoplayEnabled)
        return active
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

    /// H3 hardening (BUG-47): the previous version fired-and-forgot a detached `Task` per
    /// expansion. A rapid re-focus while one was still mid-flight (the 450ms deferred correction
    /// pass) left it running loose against a `proxy`/row that could already be torn down by a pop —
    /// scrolling into a `ScrollViewReader` whose `ScrollView` no longer exists. Tracking the task
    /// lets a new expansion supersede the old one and lets `.onDisappear` cancel it outright.
    @State private var expansionScrollTask: Task<Void, Never>?

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
                //
                // BUG-37: "inside the region the frames cover" is necessary but not sufficient on
                // hardware — a rest that falls 40–67pt short leaves the top of that region above
                // the viewport's clip edge, title included. `pinnedRowTitleTracking` rides the
                // title down to the clip edge for exactly that shortfall (render-time only; no
                // layout, no state, no identity). See its doc comment for why the band cannot
                // simply be widened and why card-anchoring the title buys nothing.
                .overlay(alignment: .topLeading) {
                    if cardTopReach > 0 {
                        Text(section.title)
                            .font(Theme.Font.sectionTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            // Legibility for the slid state only: at a short rest the title parks
                            // against the clip edge and can overlap the top of the artwork. Over
                            // the flat background of a true rest this is invisible.
                            .shadow(color: .black.opacity(0.7), radius: 8, y: 2)
                            .pinnedRowTitleTracking(rowKey: section.key)
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
        // H3: the row (and its ScrollViewReader) can disappear mid-flight — a pop while the
        // deferred 450ms correction pass is still pending. Cancel rather than let it fire against
        // a torn-down proxy.
        .onDisappear { expansionScrollTask?.cancel() }
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
        // H3: supersede any still-pending correction pass from a previous expansion rather than
        // letting both race the same proxy.
        expansionScrollTask?.cancel()
        if CatalogGridProbe.enabled { CatalogGridProbe.log("expansionChanged fire item=\(itemId)") }
        expansionScrollTask = Task { @MainActor in
            scrollToExpanded(itemId, anchor: anchor, proxy: proxy)
            try? await Task.sleep(nanoseconds: 450_000_000)
            // H3: the row may have disappeared (or a newer expansion may have superseded this
            // task) during the sleep — bail instead of scrolling a proxy that could be gone.
            guard !Task.isCancelled else {
                if CatalogGridProbe.enabled { CatalogGridProbe.log("expansionChanged cancelled skip item=\(itemId)") }
                return
            }
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
