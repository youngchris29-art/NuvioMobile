import Combine
import SwiftUI
import UIKit
import SharedCore
// Kotlin's `Collection` model collides with Swift's stdlib `Collection` protocol, and plain
// `SharedCore.Collection` doesn't work either (the framework also exports a *class* named
// `SharedCore`, which wins the qualification). A scoped import shadows the stdlib name in this
// file; the typealias gives the rest of the target an unambiguous name.
import class SharedCore.Collection

/// The shared Kotlin `Collection` model (a group of folders), aliased to dodge the name collision.
typealias NuvioCollection = Collection

// Collections (browse-only, Phase 5b): renders collections curated on mobile — the cloud sync
// already delivers them (SyncManager.pullAllForProfile → CollectionSyncService.pullFromServer).
// A collection appears on Home as a row of folder tiles; a folder opens a tabbed paginated grid
// backed entirely by the shared `FolderDetailRepository`. Structural editing stays on mobile; the
// one on-device edit is a tmdb source's Discover filters (`TmdbFilterEditorView`, from the
// folder grid's Edit Filters button).

/// Navigation value for a collection folder's detail grid. Hashes on the stable ids; carries the
/// titles for the destination's initial render (same wrapper approach as `TitleRoute`).
struct FolderRoute: Hashable {
    let collectionId: String
    let folderId: String
    let folderTitle: String
    /// BUG-38 (folder page): the folder's configured title logo, carried so the page's first
    /// frame already has it — the repository's `folder` lands a beat later. Identity (==/hash)
    /// stays collectionId + folderId; this is display-only. The backdrop is deliberately NOT
    /// drawn on this page (round three, reporter: "if we keep the background image inside, it
    /// makes the text unreadable depending on the image") — it belongs to the Home hero.
    let titleLogoUrl: String?

    init(collectionId: String, folder: CollectionFolder) {
        self.collectionId = collectionId
        self.folderId = folder.id
        self.folderTitle = folder.title
        self.titleLogoUrl = folder.titleLogoUrl.nonBlankTrimmed
    }

    static func == (lhs: FolderRoute, rhs: FolderRoute) -> Bool {
        lhs.collectionId == rhs.collectionId && lhs.folderId == rhs.folderId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(collectionId)
        hasher.combine(folderId)
    }
}

/// One collection as a horizontal row of focusable folder tiles (Home).
struct CollectionRowView: View {
    let collection: NuvioCollection
    /// BUG-38 round three: the focused folder (nil when nothing in this row holds focus), so
    /// Home can hand the folder's configured backdrop + title logo to the pinned hero exactly
    /// the way a catalog row's `onItemFocusChange` hands it a title — the reporter's actual ask
    /// was the Home page, not the folder page.
    var onFolderFocusChange: ((CollectionFolder?) -> Void)? = nil
    @FocusState private var focusedFolderId: String?
    /// BUG-108: read here only for `rowGap`'s doc and `liftedTileZIndex` — the tile's own
    /// treatments read the same keys inside `FolderTile`.
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    /// Pinned-hero card reach (UX-7 extension, device rounds 4–5) — see `rowCardTopReach` /
    /// `rowCardBottomReach` in BrowseComponents for the mechanism. 0 (no-op) outside pinned Home.
    @Environment(\.rowCardTopReach) private var cardTopReach
    @Environment(\.rowCardBottomReach) private var cardBottomReach
    /// BUG-87/89 (rc11): see `EnvironmentValues.rowCardLinkFrameFloor`. 0 for every row but Home's
    /// last — and, since rc14 (BUG-122), every collection row (the mixed-shape short row).
    @Environment(\.rowCardLinkFrameFloor) private var cardLinkFrameFloor
    @Environment(\.pinnedRowIsLast) private var isLastRow
    @Environment(\.posterStyle) private var style

    /// rc14 (BUG-122): see `PinnedRowGeometry.shortRowLayoutCompensation`. The natural shelf is
    /// `shelfMinHeight`'s pre-floor value — the tallest tile plus its caption chrome, inside the
    /// reaches.
    private var shortRowCompensation: CGFloat {
        PinnedRowGeometry.shortRowLayoutCompensation(floor: cardLinkFrameFloor,
                                                     naturalLabel: naturalShelfHeight,
                                                     isLastRow: isLastRow)
    }

    /// Wave 4 item 6 (tester: the section title sliding onto his "Streaming Services" tiles): the
    /// SHORTEST artwork height in this row, handed to the pinned title's slide clamp so its
    /// intrusion is a fraction of the tile rather than a fixed 46pt — which on a Small square
    /// folder tile (183pt) was a quarter of the artwork, landing on the centred wordmark that IS
    /// the tile's content. See `PinnedRowTitle.maxSlide`.
    ///
    /// The MINIMUM, not the average: this row is deliberately mixed-shape (poster / landscape /
    /// square folders side by side, top-aligned so their reach frames share a top edge), one title
    /// rides over all of them, and the clamp has to protect the tile with the least room. Empty
    /// rows fall back to the poster height — nothing is drawn over, and it matches what a folder
    /// added later would most likely be.
    private var shortestTileHeight: CGFloat {
        collection.folders
            .map { FolderTile.artworkHeight(for: $0, style: style) }
            .min() ?? style.height
    }

    /// BUG-108 / BUG-106: ring mode's lift is a UNIFORM scale of `1 + 2 × 20 / artworkHeight`, so a
    /// 16:9 folder tile grows `2 × 20 × 16/9 ≈ 71pt` of width at every Poster Size — ≈35.5 per side,
    /// which overruns `rowGap` (28) by ≈7.5 and lands the raised tile's 4pt ring on its neighbour's
    /// artwork. Exactly the BUG-106 arithmetic and exactly the BUG-106 dial, applied whenever this
    /// mixed-shape row holds a landscape folder at all (square tiles grow 20/side → 8 clear,
    /// posters ≈13.3/side → ≈14.7 clear, so they keep `rowGap`).
    ///
    /// NOT gated on the ring setting, for two reasons: the native `.borderless` lift grows the tile
    /// by a comparable amount in the default mode, and a row gap that changed with an Appearance
    /// toggle would move this row's scroll geometry under the focus engine. Nothing in the pinned
    /// math reads the gap (`shortestTileHeight`, `shelfMinHeight` and `focusedTileLockupExtent` are
    /// all vertical).
    private var rowGap: CGFloat {
        collection.folders.contains { $0.posterShape == PosterShape.landscape }
            ? Theme.Spacing.landscapeLiftRowGap
            : Theme.Spacing.rowGap
    }

    /// BUG-108: ring mode's lift is SwiftUI's own `.scaleEffect`, which — unlike the native lift —
    /// does not composite the focused card into its own layer, so without an explicit zIndex the
    /// raised tile (and its ring, and its drop shadow) can draw UNDER its unfocused neighbours.
    /// `PosterCard` carries the same rule (PosterCard.swift, `.zIndex(focusMode.raisesFocusedCard …)`);
    /// the difference is WHERE: this one has to sit on the `LazyHStack`'s own child — a zIndex
    /// inside the `NavigationLink` label has no siblings to order against.
    private func liftedTileZIndex(_ folder: CollectionFolder) -> Double {
        let raises = CardFocusMode.resolve(accentFocusRing: accentFocusRing,
                                           noZoomOnFocus: noZoomOnFocus).raisesFocusedCard
        return raises && focusedFolderId == folder.id ? 1 : 0
    }

    /// Wave 4 item 2 (the source fix; tester repro: scroll a mixed-shape collection row right,
    /// then back up — the pinned title parks ON the card artwork, worst at Large).
    ///
    /// `LazyHStack` sizes itself to its REALIZED subviews only. This row deliberately mixes
    /// shapes — poster folders are `1.5 × style.width` tall, square/landscape folders are only
    /// `style.width` tall (`FolderTile.artworkHeight` takes that height from the row's width dial
    /// on purpose — see that function's own comment) — so scrolling past the last poster-shaped
    /// tile drops the stack's natural height by up to `0.5 × style.width` (≈134pt at Large), then
    /// regrows it scrolling back. The up-reveal's settle target is computed against whatever
    /// height happened to be realized at that moment, so a rest taken mid this collapse/regrow
    /// settles against stale geometry and the overlaid title parks on the artwork instead of
    /// above it.
    ///
    /// The fix: float the stack's height on a floor that does NOT depend on which tiles are
    /// currently realized — the max artwork height over `collection.folders`, the MODEL array
    /// (scroll-stable, unlike the `LazyHStack`'s realized children), plus the fixed vertical
    /// chrome every realized subview carries around its own artwork inside this stack:
    ///
    ///     minHeight = maxArtworkHeight                  // tallest folder's own artwork
    ///               + Theme.Spacing.sm                  // FolderTile's VStack spacing between
    ///                                                    //   its artwork ZStack and its caption
    ///               + folderCaptionHeight                // Theme.Font.cardTitle (.caption2)
    ///                                                    //   single-line caption — see that
    ///                                                    //   constant's own comment for the 23pt
    ///               + cardTopReach + cardBottomReach     // the reach padding: NOT inside
    ///                                                    //   FolderTile — CollectionRowView adds
    ///                                                    //   it OUTSIDE the tile, directly on the
    ///                                                    //   NavigationLink button label, so it
    ///                                                    //   is still part of what the LazyHStack
    ///                                                    //   would naturally realize as height
    ///
    /// The caption term is a constant worst case, not a per-folder measurement: every folder tile
    /// carries the same VStack spacing and, whenever it's showing plain text rather than an
    /// already-loaded title logo, the same single-line caption. Charging it even for a tile
    /// currently mid-logo-load only makes the floor very slightly taller than that one tile's own
    /// realized height — `minHeight` absorbs that as harmless extra room below the shelf, never a
    /// clip. Classic mode (`cardTopReach == 0`) gets the same floor for free: it can only ever
    /// GROW the shelf up to its tallest tile's natural size, never shrink one, so it is a no-op
    /// wherever classic already rendered correctly.
    private var shelfMinHeight: CGFloat {
        // PER-FOLDER floor (Codex 2026-08-29 P2 ×2): the max of each folder's artwork PLUS that
        // folder's OWN caption chrome — a caption on a shorter tile must not be billed to the
        // tallest artwork (no rendered child has that combined height, and the oversized frame
        // floats classic mode's centered children), and an all-hidden row gets no caption term
        // at all. The caption height comes from live type metrics, not a constant: the caption
        // is semantic `.caption2`, which grows under Larger Text — a fixed 23pt floor would sit
        // below the realized tile and the LazyHStack would still collapse on recycle, the exact
        // instability this frame exists to prevent.
        // Alignment note (Codex 2026-08-29 P2 round 3): the floor is applied `.top`-aligned in
        // BOTH modes. It can legitimately exceed every rendered child — a folder with
        // hideTitle=false whose title LOGO loads drops its text caption, a state unknowable at
        // layout time — and top alignment turns that overshoot into stable bottom padding
        // instead of a centered mid-frame float that jumps when the logo arrives.
        // BUG-87/89 (rc11): the scroll-stable floor must agree with the per-label floor
        // (`rowCardLinkFrameFloor`) or a recycle pass can still collapse the stack below the
        // height the last row's labels are actually holding.
        return max(naturalShelfHeight, cardLinkFrameFloor)
    }

    /// rc14 (BUG-122): `shelfMinHeight` before the floor — the tallest tile plus its own caption
    /// chrome, inside the reaches. Split out so the layout compensation can compare the floor
    /// against the same number.
    private var naturalShelfHeight: CGFloat {
        let captionChrome = Theme.Spacing.sm + Self.folderCaptionHeight
        let maxTileHeight = collection.folders
            .map { FolderTile.artworkHeight(for: $0, style: style) + ($0.hideTitle ? 0 : captionChrome) }
            .max() ?? style.height
        return maxTileHeight + cardTopReach + cardBottomReach
    }

    /// `Theme.Font.cardTitle` (`.caption2`) single-line height under the CURRENT content size
    /// category — 23pt at default scale (Theme.swift's own record for this style), taller under
    /// Larger Text. `FolderTile`'s caption uses this style with `lineLimit(1)` and no extra
    /// vertical padding.
    private static var folderCaptionHeight: CGFloat {
        Theme.Font.uiFont(for: .caption2).lineHeight.rounded(.up)
    }

    /// BUG-89: `shelfMinHeight`'s arithmetic, reachable statically so `HomeView.rowsInsets` can
    /// size its bottom inset against the LAST Home row's height before any `CollectionRowView`
    /// instance for it has ever been laid out (the row it needs to measure may not even be
    /// visible yet — it is the one below the fold). `cardTopReach`/`cardBottomReach` are read from
    /// an environment on the live instance; here they are the fixed pinned-mode values `HomeView`
    /// always sets (`Theme.Size.heroPinnedRowTopPad` / `heroPinnedRowBottomReach`) — this helper
    /// has no other caller, so that is never an approximation.
    ///
    /// Adds this row's own vertical chrome around the shelf: in pinned mode the section-title
    /// `Text` above the shelf is NOT rendered (`:205`, overlaid instead), so the row's total
    /// height is exactly the shelf plus its own top/bottom padding — `Theme.Spacing.lg` (24) top
    /// (`:249`, pinned branch) and `Theme.Spacing.sm` (12) bottom (`:250`), with no extra `VStack`
    /// spacing term (a single child has none).
    static func pinnedRowHeight(collection: NuvioCollection, style: PosterStyle) -> CGFloat {
        let cardTopReach = Theme.Size.heroPinnedRowTopPad
        let cardBottomReach = Theme.Size.heroPinnedRowBottomReach
        let captionChrome = Theme.Spacing.sm + Self.folderCaptionHeight
        let maxTileHeight = collection.folders
            .map { FolderTile.artworkHeight(for: $0, style: style) + ($0.hideTitle ? 0 : captionChrome) }
            .max() ?? style.height
        let shelfMinHeight = maxTileHeight + cardTopReach + cardBottomReach
        return shelfMinHeight + Theme.Spacing.lg + Theme.Spacing.sm
    }

    /// Distance from this row's TOP edge to the FOCUSED folder tile's lockup BOTTOM — the bound the
    /// settle re-reveal's correction must respect (Codex r11 P2-2).
    ///
    /// Only this row needs to state it. `shelfMinHeight` floors the shelf at the TALLEST folder's
    /// lockup, and the `LazyHStack` is top-aligned in pinned mode, so a focused square or landscape
    /// tile (which takes its height from `style.width`, not `style.height` — see
    /// `FolderTile.artworkHeight`) ends far above the row's own bottom edge. Bounding the correction
    /// by the row bottom therefore reported little or no room on exactly the tiles the tester's
    /// "Streaming Services" complaint was about, refusing a correction the focused tile could have
    /// absorbed whole and handing the title to the visibility belt to hide instead.
    ///
    /// The arithmetic walks the same layout the row builds: row top → the shelf's pinned top
    /// padding (`Spacing.lg`, matched to `heroPinnedRowTitleInset`'s assumption) → the card reach
    /// band the `NavigationLink` label carries → the tile's own artwork and, only when the tile is
    /// actually RENDERING one, its caption chrome. Nil while nothing here holds focus, or in
    /// classic mode, where the row's own frame is already the right bound.
    ///
    /// The caption term goes through `FolderTile.rendersTextCaption` rather than `hideTitle` alone
    /// (Codex r11 round 2): a folder whose `titleLogoUrl` has LOADED draws the logo instead of the
    /// text, so charging the chrome anyway overstated the protected bottom by ~31pt and refused
    /// corrections that were perfectly safe — reintroducing, on exactly the wordmark tiles this
    /// bound exists for, the title-on-artwork the corrector is supposed to remove.
    ///
    /// Error direction, applied the same way as the shortest-vs-focused argument above:
    /// over-counting only refuses corrections (recoverable, and the belt still hides the title),
    /// while under-counting pushes real artwork past the fold (not recoverable). So every state
    /// that still shows the text — no logo URL, load failed, and the TRANSITIONAL still-loading
    /// state — keeps the chrome; only a confirmed cache hit drops it.
    ///
    /// Staleness note: `ArtworkStore.cached` is not observable, so a logo that finishes loading
    /// while its tile is already focused does not by itself re-render this row — the extent stays
    /// on the conservative (chrome-counted) side until the next body pass. The logo's arrival does
    /// change the tile's layout, so the row's own `onGeometryChange` re-fires and the MEASUREMENT
    /// refreshes; it is only this parameter that waits. In practice the next focus move recomputes
    /// it (`focusedFolderId` is a body dependency), and by the time a tile is focused its logo has
    /// almost always already loaded — it has been on screen. Conservative direction, bounded
    /// window, no correctness hazard.
    private var focusedTileLockupExtent: CGFloat? {
        guard cardTopReach > 0,
              let focusedFolderId,
              let folder = collection.folders.first(where: { $0.id == focusedFolderId })
        else { return nil }
        let caption = FolderTile.rendersTextCaption(for: folder)
            ? Theme.Spacing.sm + Self.folderCaptionHeight
            : 0
        return Theme.Spacing.lg + cardTopReach
            + FolderTile.artworkHeight(for: folder, style: style) + caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Pinned mode overlays the title inside the shelf's reach band instead (see
            // CatalogRowView's structural comment — out-of-bounds frames froze the focus
            // engine; all paddings must stay positive).
            if cardTopReach == 0 {
                Text(collection.title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                // Pinned: TOP-aligned so mixed-shape folders (poster/landscape/square heights)
                // all start their reach frames at the same y — center alignment shifted the
                // shorter tiles' frames below the overlaid title, breaking the reveal-contains-
                // title invariant for them (Codex review). Classic keeps center, as ever.
                LazyHStack(alignment: cardTopReach > 0 ? .top : .center,
                           spacing: rowGap) {
                    ForEach(collection.folders, id: \.id) { folder in
                        NavigationLink(value: FolderRoute(collectionId: collection.id, folder: folder)) {
                            FolderTile(
                                folder: folder,
                                collectionBackdropUrl: collection.backdropImageUrl,
                                collectionId: collection.id,
                                // Focus truth from the row's own FocusState (Codex rounds 3-5:
                                // a second .focused binding collides with focusedFolderId's, and
                                // the ring must hug the tile artwork, so it's drawn inside).
                                stillFocused: focusedFolderId == folder.id
                            )
                                .padding(.top, cardTopReach)
                                .padding(.bottom, cardBottomReach)
                                // BUG-87/89 (rc11): transparent floor on the REVEALED frame — 0 for
                                // every row but Home's last. `.top` so the artwork and caption do
                                // not move a point.
                                .frame(minHeight: cardLinkFrameFloor > 0 ? cardLinkFrameFloor : nil,
                                       alignment: .top)
                        }
                        // BUG-108: this label draws its own ring AND (since rc10) its own ring-mode
                        // lift, so ring mode must take the native `.borderless` lift away from it —
                        // `CardButtonLift.card`, the default. On the native lift the ring stayed at
                        // base geometry while the artwork rose (rc9 device photos).
                        .cardFocusButtonStyle()
                        .posterButtonShape()   // BUG-32/BUG-25: without this the system radius overrides Corners
                        .focused($focusedFolderId, equals: folder.id)
                        // BUG-109: a stable identity for native focus restoration after the folder page
                        // pops — parity with CatalogRowView's `.id(item.id)` on its cards.
                        .id(folder.id)
                        .zIndex(liftedTileZIndex(folder))
                    }
                }
                // Wave 4 item 2: floor the stack's height independent of scroll position — see
                // `shelfMinHeight`'s own comment for the collapse/regrow mechanism this fixes and
                // the arithmetic. Alignment matches the stack's own, so the extra room a shorter
                // realized frame needs to reach the floor distributes the same way the tiles
                // themselves are already aligned (top in pinned mode, center in classic).
                .frame(minHeight: shelfMinHeight, alignment: .top)
                // Always positive — the reach lives inside the buttons (see CatalogRowView).
                // Pinned TOP matches the catalog/CW shelves' 24pt: `heroPinnedRowTitleInset`
                // assumes a 24 + reach band, and the tighter 12pt here left the overlaid title
                // only ~36pt of clearance — overlapping folder art at larger text sizes
                // (Codex review, device-pass gating round). Classic keeps the original 12.
                .padding(.top, cardTopReach > 0 ? Theme.Spacing.lg : Theme.Spacing.sm)
                .padding(.bottom, Theme.Spacing.sm)
            }
            // BUG-103 (u/mrStevenx3, 2026-09-10 photos + video): this row was the only Home row
            // still clipped to its own padded bounds, so its first and last visible tiles were cut
            // ~60 pt inside the screen edges while every catalog row (`CatalogRowView`,
            // BrowseComponents.swift) bleeds to the edge through the same modifier. Unlike the
            // catalog rows there is no `RowLeadingEdgeClip` here on purpose: BUG-92's leading-edge
            // clip exists for the inline trailer's rightward morph, and a folder tile has no
            // trailer — its only bleed past the padded edge is the native lift + ring, the exact
            // allowance that clip lets through anyway.
            .scrollClipDisabled()
            // BUG-118: see `RowEdgeEffectStyleModifier`.
            .rowEdgeEffectStyle()
            .overlay(alignment: .topLeading) {
                if cardTopReach > 0 {
                    Text(collection.title)
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        // BUG-37: same clip-edge slide the catalog/CW shelves got — short
                        // real-swipe rests must never leave this row's title off-screen.
                        .shadow(color: .black.opacity(0.7), radius: 8, y: 2)
                        // Codex r7 P2: `isFocused` picks which clearance the belt judges this row
                        // by — only a FOCUSED row's tiles are raised by the focus treatment.
                        //
                        // Codex r9 P2 / BUG-108: this row's cards now resolve through
                        // `CardFocusMode` like every other pinned row's — `FolderTile` carries
                        // `CardArtworkFocusLift`, so its zoom-on rise IS
                        // `heroPinnedRowFocusLiftAllowance` in both zoom modes rather than the
                        // native lift's ~20pt by coincidence. `.plainBorderless` described the
                        // pre-BUG-108 architecture and is gone; the published allowance is
                        // unchanged either way (`focusLiftAllowance` charges 20 unless No Zoom).
                        .pinnedRowTitleTracking(rowKey: collection.id,
                                                artworkHeight: shortestTileHeight,
                                                isFocused: focusedFolderId != nil,
                                                treatment: .cardTreatment)
                        .padding(.top, Theme.Size.heroPinnedRowTitleInset)
                        .allowsHitTesting(false)
                }
            }
        }
        .focusSection()
        // rc14 (BUG-122): cancel the floor's layout growth so the row's reported height stays its
        // natural one while the tiles keep their floored (tall) focusable frames. AFTER the focus
        // section (review r1 P1: frames outside their own section froze directional focus on
        // device) and before the settle tracker, which must measure the natural row.
        .padding(.bottom, -shortRowCompensation)
        // Settle re-reveal (2026-08-30) — one line, same as every other pinned row; see
        // `pinnedRowSettleTracking` in BrowseComponents. This row is the mixed-shape one, so it is
        // also the one whose stale-relayout rests Wave 4 item 2 could only floor, not correct.
        // `focusedLockupExtent` (Codex r11 P2-2): this is the one mixed-shape pinned row, so its
        // own frame — floored at the TALLEST tile — overstates where the focused tile actually
        // ends. See `focusedTileLockupExtent`.
        .pinnedRowSettleTracking(rowKey: collection.id,
                                 isFocused: focusedFolderId != nil,
                                 focusedLockupExtent: focusedTileLockupExtent)
        // BUG-112 (Item A)
        .pinnedRowUpFallbackTarget(rowKey: collection.id,
                                   firstId: collection.folders.first?.id,
                                   focus: $focusedFolderId)
        .onChange(of: focusedFolderId) { _, id in
            // FEAT-33 (Wave 1, agent C; Codex r1): armed BEFORE the callback below. The callback
            // is synchronous, so with the default leg its `reportRowFocus` hero work — and any
            // main-thread stall it causes — would already be over before the display link took
            // its first sample; the 600 ms window is long enough to cover everything that follows.
            // `rowKey` is the collection title (readable off a tester's photo of the About pane)
            // rather than `collection.id` — the id is opaque and this probe's whole point is a
            // human reading the summary line, not code matching on it.
            if CollectionFocusFrameProbe.enabled, let id {
                let focusedFolder = collection.folders.first { $0.id == id }
                // Parenthesized so `.nonBlankTrimmed` (the `Optional<String>` extension below)
                // resolves against the flattened `String?` the chain produces, rather than the
                // compiler trying to continue unwrapping through it.
                let gif = focusedFolder?.focusGifEnabled == true && (focusedFolder?.focusGifUrl).nonBlankTrimmed != nil
                CollectionFocusFrameSampler.shared.arm(rowKey: collection.title, gif: gif)
            }
            onFolderFocusChange?(id.flatMap { fid in collection.folders.first { $0.id == fid } })
        }
    }
}

/// A single folder tile: cover art (or emoji / initial fallback) shaped per the folder's
/// `tileShape` (poster / landscape / square), following the user's Poster Style width.
/// BUG-38 (beta.13): release-safe cover-resolution probe — `defaults write com.nuvio.media.NuvioTV
/// debug.collectionCoverProbe -bool YES`, greppable `[CollectionCover]`. One line per folder tile
/// naming which artwork fields the synced payload actually carried, which one the tile drew, the
/// folder's source kinds, and — the part nothing else can answer — the raw JSON keys on that folder
/// that this build does NOT read (`CollectionRepository.unknownFolderKeysFromRawPayload`). A cover
/// another client wrote under a spelling we don't decode shows up there by name. Same house
/// pattern as `HomeGeometryProbe`/`TrailerProbe` (not `#if DEBUG`: the reporter runs release).
enum CollectionCoverProbe {
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.collectionCoverProbe")
    @MainActor private static var logged = Set<String>()

    @MainActor static func report(folder: CollectionFolder, collectionId: String, collectionBackdropUrl: String?, shown: String) {
        guard enabled else { return }
        func present(_ value: String?) -> Int { (value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? 0 : 1 }
        let unknown = (CollectionRepository.shared.unknownFolderKeysFromRawPayload()["\(collectionId)|\(folder.id)"] as? [String]) ?? []
        let sourceKinds = folder.resolvedSources.map { source -> String in
            if source.isTmdb { return "tmdb:\(source.tmdbSourceType ?? "?")" }
            if source.isTrakt { return "trakt" }
            return "addon"
        }
        let line = String(
            format: "[CollectionCover] collection=%@ folder=%@ title=%@ own=%d heroBackdrop=%d collectionBackdrop=%d logo=%d emoji=%d gif=%d shape=%@ sources=[%@] unknownKeys=[%@] shown=%@",
            collectionId, folder.id, folder.title, present(folder.coverImageUrl), present(folder.heroBackdropUrl),
            present(collectionBackdropUrl), present(folder.titleLogoUrl), present(folder.coverEmoji),
            present(folder.focusGifUrl), folder.tileShape, sourceKinds.joined(separator: ","),
            unknown.joined(separator: ","), shown
        )
        // De-duplicated on the WHOLE line: the locally persisted payload renders first and the
        // cloud pull re-renders — a synced change to any field (or to the unknown keys) must log
        // again, only a byte-identical re-render is quiet.
        guard !logged.contains(line) else { return }
        logged.insert(line)
        NSLog("%@", line)
    }
}

struct FolderTile: View {
    let folder: CollectionFolder
    /// BUG-38 (2026-08-10 re-specification): the parent collection's user-configured
    /// `backdropImageUrl` — configurable in mobile's collection editor and synced for as long as
    /// the field has existed, but rendered by NO client until now. Folder-level artwork still
    /// wins (it's the more specific pick); this only replaces the positional first-item fallback
    /// that showed the reporter "the first movie from my home list" instead of their own artwork.
    var collectionBackdropUrl: String? = nil
    /// BUG-38 probe: folder ids are unique per COLLECTION, so the diagnostics key on both.
    var collectionId: String = ""

    /// Caller-supplied focus truth for the ring drawn on the artwork (Codex 2026-08-29 rounds
    /// 3-5): this tile has no focus treatment of its own, and the ring must hug the ARTWORK frame —
    /// only this view knows it — not the padded outer button bounds. Named for the no-zoom still
    /// ring it was added for; since BUG-102 (rc9) it gates the accent ring in zoom-on mode too.
    var stillFocused: Bool = false

    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false
    /// BUG-102: with zoom on and the accent ring on, every `PosterCard` in the neighbouring rows
    /// wore the ring and this tile drew nothing (it only knew the still ring). Same key as every
    /// other card, resolved through `PlainLabelRing` (PosterCard.swift).
    @AppStorage("accent_focus_ring") private var accentFocusRing = false
    /// rc14 FEAT-46 (Steven rc13 verdict, 2026-09-30): poster-coloured focus ring, default OFF —
    /// see `PosterCard`'s copy of these properties for the full rationale. Here it recolours
    /// whichever `PlainLabelRing` the tile draws (accent or still), keyed on `stillFocused` like
    /// the ring itself.
    @AppStorage("focus_ring_poster_color") private var ringTakesPosterColor = false
    @State private var posterRingTint: Color?
    /// beta.18 verdict (FEAT-46 corrected / FEAT-40 follow-up): "Depth Takes Poster Color", default
    /// OFF (Appearance owns the toggle; same independent-read pattern as the keys above). With it on,
    /// the card-depth rail takes the poster's dominant colour (`ArtworkColorStore`, `Use.rail`),
    /// sampled once per URL when the image loads, since the rail draws on UNFOCUSED cards. OFF: the
    /// rail is the white it always was and nothing is sampled.
    @AppStorage("depth_rail_poster_color") private var depthTakesPosterColor = false
    /// The last rail colour the store answered for this card; the re-render trigger for a colour
    /// sampled after the image landed (a store hit is read straight from `body`, never written here).
    @State private var depthRailTint: Color?
    @Environment(\.cardDepthStyle) private var depthStyle
    @Environment(\.isFocused) private var isFocused
    @Environment(\.posterStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// rc14 FEAT-46: sample only when the setting is on and a ring can draw on this tile
    /// (`PlainLabelRing.reservesBand` is exactly "accent ring on, or No Zoom on").
    private var samplesPosterColor: Bool {
        ringTakesPosterColor
            && PlainLabelRing.reservesBand(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus)
    }

    /// rc14 FEAT-46: the ring colour override — the cover's colour, nil with the setting off, while
    /// unfocused, or on the gradient placeholder (no cover to sample). See `PosterCard.posterTint`.
    private var posterTint: Color? {
        guard samplesPosterColor, stillFocused else { return nil }
        return ArtworkColorStore.shared.cachedColor(for: [coverURLString]) ?? posterRingTint
    }

    /// beta.18 verdict (FEAT-46 corrected / FEAT-40 follow-up): sample the rail colour only when the
    /// toggle is on AND depth actually draws for this surface (and the tile has a real cover to sample: the gradient placeholder keeps the white rail).
    private var samplesDepthColor: Bool {
        depthTakesPosterColor && depthStyle.isEnabled(for: .posters) && hasArtworkCover
    }

    /// The rail tint handed to `nuvioCardDepth`: store peek first (a read, so a colour sampled by
    /// another row or before a recycle is on the rail from the first frame), then the local state.
    private var depthRailTintResolved: Color? {
        guard samplesDepthColor else { return nil }
        return ArtworkColorStore.shared.cachedColor(for: [coverURLString], use: .rail) ?? depthRailTint
    }

    /// BUG-108: in ring mode this tile owns its lift, so the ring it draws on its own artwork rides
    /// that lift instead of standing still under the native one. `.still` (a no-op) in both other
    /// modes — see `PlainLabelRing.lift` for why it must never be `.systemLift` here.
    private var artworkLift: CardFocusMode {
        PlainLabelRing.lift(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus)
    }

    /// BUG-38 display-time fallback: genre folders are TMDB DISCOVER sources, which
    /// `TmdbCollectionSourceResolver.importMetadata` never mints a cover for (only
    /// COLLECTION/COMPANY/NETWORK/PERSON get one) — upstream mobile has the same gap. Resolved
    /// lazily by `FolderCoverResolver` (shared, in-memory-cached, never persisted) and rendered
    /// through the exact same `CachedAsyncImage` slot as a real cover. Stays nil for folders that
    /// already have a cover or a user-chosen emoji — see the `.task` guard below.
    @State private var fallbackCoverUrl: String?

    /// BUG-38: `CollectionFolder.titleLogoUrl` (shared model, `CollectionModels.kt:194`) was
    /// populated upstream but never read by any client. Loaded the same way `HeroLogo`
    /// (HomeView.swift) loads the Home hero's logo — through the shared `ArtworkStore` so it
    /// benefits from the same memory/disk cache as every other artwork on this tile — rather
    /// than a bare `AsyncImage`, which would re-fetch on every scroll recycle.
    @State private var titleLogoImage: UIImage?

    /// Resolved logo URL, or nil when the folder has none (blank/whitespace-only counts as
    /// absent, same trimming rule the cover/emoji checks below use).
    ///
    /// Also nil when the folder has its OWN cover (2026-08-08 device pass regression): service
    /// folders ship covers with the wordmark baked in — and upstream never renders titleLogoUrl
    /// anywhere — so overlaying the logo doubles the wordmark (filmed: prime video / Disney+ /
    /// HBO Max all twice on the Services row). The overlay exists to name a tile whose artwork
    /// doesn't name itself: genre DISCOVER folders (no cover — the tiles BUG-38 was filed about)
    /// and resolved first-item-art fallbacks keep it; explicit covers suppress it. Gated HERE,
    /// not at the render site, so the fetch task never loads the image and the plain-text title
    /// below (`titleLogoImage == nil`) stays visible on suppressed tiles.
    ///
    /// BUG-38 (beta.13): a refined gate keyed on TMDB company/network sources was tried and REVERTED
    /// on the 2026-08-18 device pass — the fork's curated Services folders (Netflix / Prime /
    /// Disney+ / HBO Max) are addon-sourced with a wordmark cover AND a titleLogoUrl, so the refined
    /// gate doubled every wordmark on the row (BUG-52 back, seen live). No provenance field exists to
    /// tell "cover already names the folder" from "user cover next to a logo", and the doubled
    /// wordmark is the worse failure, so any own cover keeps suppressing the logo. The
    /// `[CollectionCover]` probe (`debug.collectionCoverProbe`) is what answers the reporter's
    /// "title images don't show" — it names the payload keys this build reads and doesn't.
    private var titleLogoURL: URL? { Self.titleLogoURL(for: folder) }

    /// The gate above, as a static so `CollectionRowView` can ask the same question without
    /// re-deriving (and drifting from) its precedence rules — the same reason
    /// `artworkHeight(for:style:)` is a static.
    static func titleLogoURL(for folder: CollectionFolder) -> URL? {
        let ownCover = folder.coverImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !(ownCover?.isEmpty ?? true) { return nil }
        guard let raw = folder.titleLogoUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// Whether this folder's tile is currently rendering its plain-text caption BELOW the artwork
    /// — i.e. whether the caption chrome is part of its lockup height right now.
    ///
    /// Mirrors the render condition exactly (`!folder.hideTitle && titleLogoImage == nil`, see the
    /// caption's own branch): a loaded title logo REPLACES the text. `titleLogoImage` is the tile's
    /// own `@State`, but it is populated from `ArtworkStore` — and the tile's `.task` takes a
    /// synchronous `ArtworkStore.cached` hit as "render immediately" — so a warm cache answers this
    /// without reaching into the child's state.
    ///
    /// The three nil cases stay on the caption side, which is the correct direction: no logo URL,
    /// still loading, and load failure all render the text, so all three keep the chrome.
    static func rendersTextCaption(for folder: CollectionFolder) -> Bool {
        guard !folder.hideTitle else { return false }
        guard let url = titleLogoURL(for: folder) else { return true }
        return ArtworkStore.cached(url) == nil
    }

    private var tileWidth: CGFloat {
        folder.posterShape == PosterShape.landscape ? style.width * 16 / 9 : style.width
    }

    /// See the BUG-102 note on the `.scaleEffect` below.
    private var reservesRingBand: Bool {
        PlainLabelRing.reservesBand(accentFocusRing: accentFocusRing, noZoomOnFocus: noZoomOnFocus)
    }

    private var tileHeight: CGFloat { FolderTile.artworkHeight(for: folder, style: style) }

    /// A folder tile's ARTWORK height, without instantiating the tile — the pinned row needs it up
    /// front to size its title's slide clamp (Wave 4 item 6; see `PinnedRowTitle.maxSlide`).
    ///
    /// The square/landscape branches taking their height from `style.WIDTH` is correct, not a typo
    /// for `style.height`: a folder tile's shape is defined against the row's width dial, so
    /// landscape = `width × 16/9` wide by `width` tall (a true 16:9) and square = `width × width`
    /// (a true square). What follows is that non-poster tiles are simply SHORTER than a poster
    /// (`width` / `width × 1.5`), which is why a FIXED title intrusion eats a much larger share of
    /// them — the clamp is where that is fixed, not here: growing these tiles would change card
    /// layout heights, and the pinned focus-engine regime (link frames resting under the clip edge;
    /// this row's `LazyHStack` is top-aligned in pinned mode precisely so mixed shapes keep a
    /// common reach-frame top) is calibrated against the heights as they stand.
    static func artworkHeight(for folder: CollectionFolder, style: PosterStyle) -> CGFloat {
        switch folder.posterShape {
        case PosterShape.landscape: return style.width
        case PosterShape.square: return style.width
        default: return style.height
        }
    }

    /// BUG-110 (rc13): whether the ZStack in `body` is about to render a photographic/GIF cover, as
    /// opposed to the gradient+initial/emoji placeholder — mirrors the precedence chain the `body`
    /// cover `let` computes exactly (own cover, folder backdrop, emoji [no cover — falls through],
    /// collection backdrop, resolved fallback). Duplicated rather than hoisted out of the ZStack
    /// closure (same tradeoff as `rendersTextCaption`/the `.task` guard elsewhere in this file):
    /// `.nuvioCardDepth` is attached to the ZStack from OUTSIDE its own builder scope, where the
    /// `body` `let`s aren't visible. Feeds `artworkPresent:` below so a placeholder tile's rail
    /// clamps to the Subtle preset instead of reading as a glitch on a flat gradient.
    private var hasArtworkCover: Bool {
        !(coverURLString?.isEmpty ?? true)
    }

    /// The cover string the `body` ZStack hands `CachedAsyncImage(string:)` (nil/empty on the
    /// gradient placeholder branch) — the chain BUG-110 duplicated into `hasArtworkCover`, lifted
    /// into its own property for rc14 FEAT-46 so `ArtworkColorStore` samples the exact art on
    /// screen (same trimmed string, so the same `ArtworkStore` key). `hasArtworkCover` above reads
    /// it; the `body` `let`s still duplicate it for the BUG-110 reason given there.
    private var coverURLString: String? {
        let ownCover = folder.coverImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let emoji = folder.coverEmoji?.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderBackdrop = folder.heroBackdropUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let collectionBackdrop = collectionBackdropUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasOwnCover = !(ownCover?.isEmpty ?? true)
        let hasFolderBackdrop = !(folderBackdrop?.isEmpty ?? true)
        let hasCollectionBackdrop = !(collectionBackdrop?.isEmpty ?? true)
        let hasEmoji = !(emoji?.isEmpty ?? true)
        return hasOwnCover ? ownCover
            : hasFolderBackdrop ? folderBackdrop
            : hasEmoji ? nil
            : hasCollectionBackdrop ? collectionBackdrop
            : fallbackCoverUrl
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ZStack {
                // BUG-38: falls back to a resolved cover only when the folder has neither an
                // explicit cover nor a user-chosen emoji (the emoji is a deliberate pick — it
                // always wins). The emoji check lives HERE too, not just in the `.task` guard
                // (Codex review): a folder edited in place to gain an emoji keeps this view's
                // `@State` for one render before the re-keyed task clears it, and the stale
                // fallback must not cover the fresh emoji even for that frame.
                // Trimmed-blank checks (Codex review): the editor/import path can persist
                // whitespace-only values, which Kotlin-side code already treats as absent —
                // an untrimmed check here would classify them as explicit and leave the tile
                // blank (unusable URL, no fallback resolution).
                let ownCover = folder.coverImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
                let emoji = folder.coverEmoji?.trimmingCharacters(in: .whitespacesAndNewlines)
                // BUG-38 re-specification: the folder's own configured backdrop, then the parent
                // collection's — both are the user's deliberate artwork and must beat the
                // positional first-item fallback. The folder-level field outranks the emoji (a
                // more specific pick for THIS tile); the collection-level one is shared by every
                // folder in the row, so a folder-level emoji still wins over it.
                let folderBackdrop = folder.heroBackdropUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
                let collectionBackdrop = collectionBackdropUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
                let hasOwnCover = !(ownCover?.isEmpty ?? true)
                let hasFolderBackdrop = !(folderBackdrop?.isEmpty ?? true)
                let hasCollectionBackdrop = !(collectionBackdrop?.isEmpty ?? true)
                let hasEmoji = !(emoji?.isEmpty ?? true)
                let cover: String? = hasOwnCover ? ownCover
                    : hasFolderBackdrop ? folderBackdrop
                    : hasEmoji ? nil
                    : hasCollectionBackdrop ? collectionBackdrop
                    : fallbackCoverUrl
                let gifUrl: String? = folder.focusGifUrl
                let shownKind = hasOwnCover ? "own"
                    : hasFolderBackdrop ? "folderBackdrop"
                    : hasEmoji ? "emoji"
                    : hasCollectionBackdrop ? "collectionBackdrop"
                    : (fallbackCoverUrl == nil ? "none" : "fallback")
                let _ = CollectionCoverProbe.report(folder: folder, collectionId: collectionId, collectionBackdropUrl: collectionBackdropUrl, shown: shownKind)

                // BUG-19: the cover is mounted for the tile's WHOLE lifetime — it used to live in
                // the `else` branch of an `isFocused` test, so every D-pad step destroyed one
                // image pipeline and built another (a new @StateObject loader, a new
                // CachedAsyncImage, and — worse — a full AnimatedGifImage teardown that freed the
                // expanded GIF frame array on the main thread). That teardown/rebuild, not the
                // animation, is the 700–830 ms per-step main-thread hang the tester measured.
                if let cover, !cover.isEmpty {
                    // beta.19-rc1 verdict (I1, BUG-134): decoded for the tile's drawn size (points ×
                    // displayScale) instead of the old fixed 1920 px cap. The tile's own width
                    // (`tileWidth`: 16:9 for a landscape folder), not the row's poster width, so a
                    // landscape cover is not decoded for a square. No URL upgrade: folder covers
                    // are the user's own art on arbitrary hosts.
                    CachedAsyncImage(string: cover, decodeSize: .points(width: tileWidth, height: tileHeight))
                        // beta.18 verdict (FEAT-46 corrected / FEAT-40 follow-up): sample the rail colour once per URL when
                        // the image lands. No animation (the image's own fade is running); a store hit is already on the
                        // rail via `depthRailTintResolved`, so it writes no state.
                        .onImageLoaded { _ in
                            guard samplesDepthColor else { return }
                            let sources = [coverURLString]
                            if ArtworkColorStore.shared.cachedColor(for: sources, use: .rail) != nil { return }
                            ArtworkColorStore.shared.color(for: sources, use: .rail) { color in
                                if depthRailTint != color { depthRailTint = color }
                            }
                        }
                } else {
                    LinearGradient(
                        colors: [Theme.Palette.accent.opacity(0.55), Theme.Palette.background],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text(hasEmoji ? emoji! : String(folder.title.prefix(1)))
                        .font(Theme.Font.hero)
                }

                // BUG-38: an overlay ON TOP of whatever cover just rendered above (own cover,
                // resolved fallback, or the gradient+emoji/initial placeholder) — never a new
                // cover source, so the precedence chain above is untouched. Lower-leading,
                // matching the tile's own title text alignment below (`VStack(alignment:
                // .leading)`). Sits BELOW the focus GIF in z-order (added first here, so the
                // GIF layer below draws over it) — mirrors mobile's own logo-under-motion
                // layering and the tile's existing "GIF over cover" order.
                if let logoImage = titleLogoImage {
                    Image(uiImage: logoImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: tileWidth * 0.82, maxHeight: tileHeight * 0.36)
                        .frame(width: tileWidth, height: tileHeight, alignment: .bottomLeading)
                        .padding(Theme.Spacing.xs)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        // When the logo replaces the plain-text name below the tile, this image
                        // becomes the control's only name-bearing content — without an explicit
                        // label VoiceOver reads an unlabeled image (Codex round 3).
                        .accessibilityLabel(folder.title)
                }

                if folder.focusGifEnabled, let gifUrl, !gifUrl.isEmpty {
                    // Also mounted persistently, layered OVER the cover. Focus no longer changes
                    // view identity: it flips `isAnimating`, which starts/stops the UIImageView and
                    // cross-fades the GIF's opacity (AnimatedGifImage owns that fade — only it
                    // knows whether the frames have decoded yet, and it keeps the cover showing
                    // until they have). `fallback: nil` because the cover above already covers the
                    // loading/failure case; passing it here would decode the same artwork twice.
                    // The GIF's download+decode is deferred to this tile's FIRST focus, so a
                    // 15-tile Services row doesn't decode 15 GIFs the moment the row appears.
                    // BUG-39: `targetSize` is this tile's own rendered point size — already known
                    // synchronously here from `posterStyle`/`folder.posterShape`, no need to wait
                    // on a UIKit layout pass — so the decoder can downsample to roughly what's
                    // actually displayed instead of a fixed worst-case guess.
                    AnimatedGifImage(
                        string: gifUrl,
                        fallback: nil,
                        isAnimating: isFocused,
                        targetSize: CGSize(width: tileWidth, height: tileHeight)
                    )
                }
            }
            .frame(width: tileWidth, height: tileHeight)
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
            // BUG-105 (u/mrStevenx3, 2026-09-10: "depth effect does not apply to images in
            // collections"): this tile never carried the card-depth rail every PosterCard /
            // LandscapeCard / SagaCard wears. Attached BEFORE the ring-band `.scaleEffect` below so
            // the rail scales with the artwork and traces the picture, not the outer tile box —
            // the same "rail hugs the INSET artwork" rule BUG-91 set for PosterCard. `.posters` is
            // the surface a collection tile reads as (the Settings toggle that governs poster rows).
            //
            // BUG-110 (rc13) re-examined this against `PosterCard`/`LandscapeCard`'s
            // `max(0, cornerRadius - inset)` convention: those cards reserve a SMALLER inset artwork
            // frame for the ring band (`ringInset`) and attach the rail to that inner box before
            // re-framing back up to the card's outer size. This tile has no such inset frame — the
            // ring band is instead reserved by uniformly `.scaleEffect`-shrinking the WHOLE already-
            // drawn ZStack (cover + logo + GIF) below, itself, so there is no smaller artwork box to
            // move this modifier onto. The radius therefore stays the tile's own `style.cornerRadius`
            // unchanged (`max(0, r - 0)` would be a no-op), and the rail already traces the full,
            // un-inset artwork exactly as intended — it rides the same `.scaleEffect` as the ring, so
            // it shrinks concentrically with the picture once a ring band is reserved, same as BUG-91.
            //
            // `artworkPresent: hasArtworkCover` — the second BUG-110 finding — caps the rail to the
            // Subtle preset on the gradient+initial/emoji placeholder branch below (every TMDB
            // Discover genre folder with no configured cover), where a Balanced/Bold rail drawn over
            // a flat solid reads as a stray bright line rather than an edge catching light on a
            // picture. Photo/GIF-covered tiles are unaffected (`artworkPresent` true → the level the
            // user picked, unclamped).
            .nuvioCardDepth(
                RoundedRectangle(cornerRadius: style.cornerRadius),
                surface: .posters,
                artworkPresent: hasArtworkCover,
                railTint: depthRailTintResolved
            )
            // 2026-08-30 no-zoom investigation: same overpaint as TileFocusLift's ring, same fix —
            // the ring used to strokeBorder straight over this tile's own cover/logo/GIF stack.
            // That stack's internal layout (the logo overlay in particular) is pinned to this
            // view's own `tileWidth`/`tileHeight` instance properties, so it can't be redrawn at a
            // smaller size the way PosterCard redraws its own artwork frame — shrunk in place with
            // the same static, never-focus-linked `.scaleEffect` TileFocusLift uses instead, which
            // leaves the `.overlay` below measuring the TRUE, unscaled tile bounds.
            // BUG-102 (rc9): the band is reserved whenever a ring may ever draw (`ringInset`'s
            // rule — accent ring on OR no-zoom on), not only in still mode, so the accent ring
            // lands in the vacated margin instead of over the artwork's edge.
            .scaleEffect(
                x: reservesRingBand && tileWidth > 0 ? max(0, tileWidth - 2 * ringWidth) / tileWidth : 1,
                y: reservesRingBand && tileHeight > 0 ? max(0, tileHeight - 2 * ringWidth) / tileHeight : 1
            )
            .overlay {
                // Still ring (no-zoom) or accent ring (setting on, zoom on or off) on the artwork
                // itself — `PlainLabelRing` holds the precedence, shared with CastCard.
                // rc14 FEAT-46: `posterTint` (nil unless the poster-colour setting is on and the
                // cover has been sampled) replaces either ring's colour; same stroke, same geometry.
                if let ring = PlainLabelRing.resolve(accentFocusRing: accentFocusRing,
                                                     noZoomOnFocus: noZoomOnFocus,
                                                     focused: stillFocused) {
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .strokeBorder(posterTint ?? ring.color, lineWidth: ringWidth)
                }
            }
            // BUG-108 probe (test56): the tile box the ring is drawn on, inside the lift —
            // `.scaleEffect` is render-only, so in ring/no-zoom modes the drawn picture is
            // `ringWidth` smaller on each edge than this rect; test56's assertions are relative
            // (rise/growth), so this is the right box for them. Armed only by
            // `-debug.cardGeometryProbe YES`, DEBUG only.
            .modifier(DebugAXIdentifier("folder_artwork"))
            // BUG-108 (u/mrStevenx3, rc9 device photos: with the ring on, the collection tile's
            // picture lifts out of its ring): this tile's lift hangs HERE — outside the ring overlay
            // above, outside the ring band's `.scaleEffect`, outside `.nuvioCardDepth`'s rail, and
            // outside the `.clipShape` — so all four are one SwiftUI layer that scales together.
            // Attached after the overlay on purpose: the overlay must keep measuring the TRUE,
            // unscaled tile bounds (the band-scale comment above), and the lift must be the
            // outermost of the pair so it carries both.
            //
            // `stillFocused`, not `@Environment(\.isFocused)`: the ring is drawn off the ROW's own
            // FocusState (Codex 2026-08-29 rounds 3-5 — a second `.focused` binding collides with
            // `focusedFolderId`), and a lift keyed on a different truth could scale the artwork in a
            // frame where the ring is not drawn, which is the very split this bug is about.
            //
            // `artworkHeight: tileHeight` is what keeps the rise at exactly
            // `heroPinnedRowFocusLiftAllowance` (20pt) for all three tile shapes, so the pinned
            // row's clip budget (`PinnedRowTitle.focusLiftAllowance`, already 20 for this row) is
            // unchanged by this commit.
            .modifier(CardArtworkFocusLift(
                mode: artworkLift,
                isFocused: stillFocused,
                artworkHeight: tileHeight,
                cornerRadius: style.cornerRadius
            ))
            // BUG-108 probe (test56): the tile's LAYOUT box, outside the lift. `.scaleEffect` is
            // render-only, so this rect must NOT move when the tile lifts — that is the negative
            // control that proves the rise costs the row no reflow.
            .modifier(DebugAXIdentifier("folder_card"))
            // BUG-38: keyed on the folder's Kotlin data-class hash (NOT `isFocused` — see the
            // BUG-19 comment above on why this tile must never key off focus), so a cloud-sync
            // edit that keeps the folder's id but changes its sources/cover/emoji re-runs the
            // task and re-consults the resolver under the new source signature (Codex review —
            // an unkeyed `.task` on a `ForEach(id: \.id)` row never re-fires for such edits).
            // `FolderCoverResolver` caches per folder-id+source-signature, so recycled
            // LazyHStack tiles and unchanged re-renders resolve instantly from that cache.
            // BUG-38 re-specification (Codex gate 0): the collection backdrop participates in the
            // cover precedence above, so it must participate in this task's identity too — a cloud
            // sync that clears ONLY the collection backdrop leaves the folder's own hash unchanged,
            // and without it here the fallback resolution this guard skipped on the first run would
            // never happen, parking the tile on the gradient placeholder.
            .task(id: "\(folder.hash())|\(collectionBackdropUrl ?? "")") {
                // Recompute from scratch each (re)run: a folder that GAINED a real cover or an
                // emoji must drop a previously resolved fallback rather than keep rendering it.
                fallbackCoverUrl = nil
                // Trimmed like the render path above — whitespace-only values are "absent".
                guard folder.coverImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return }
                guard folder.coverEmoji?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return }
                // BUG-38 re-specification: a configured backdrop (folder- or collection-level)
                // renders instead of the resolved fallback, so don't spend the resolution.
                guard folder.heroBackdropUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return }
                guard collectionBackdropUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return }
                let resolved = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                    FolderCoverResolver.shared.fallbackCoverUrl(folder: folder) { url, _ in
                        continuation.resume(returning: url)
                    }
                }
                // Codex review: `.task(id:)` cancellation doesn't abort the Kotlin call —
                // a superseded task can resume here AFTER its replacement finished and would
                // otherwise install a cover from the old source set over the new one.
                guard !Task.isCancelled else { return }
                guard let resolved, !resolved.isEmpty else { return }
                fallbackCoverUrl = resolved
            }
            // BUG-38: independent of the cover-fallback task above (different cache, different
            // key) — mirrors `HeroLogo`'s own load: a synchronous `ArtworkStore.cached` check
            // first (so a warm logo never flashes in), then the async fetch.
            .task(id: titleLogoURL) {
                guard let titleLogoURL else {
                    titleLogoImage = nil
                    return
                }
                if let cached = ArtworkStore.cached(titleLogoURL) {
                    titleLogoImage = cached
                    return
                }
                titleLogoImage = nil
                if let fetched = try? await ArtworkStore.fetch(titleLogoURL) {
                    // `ArtworkStore.fetch` deliberately completes shared work even after this
                    // task is cancelled, so a superseded request can resume here after its
                    // replacement — never install a stale folder's logo (Codex round 1).
                    guard !Task.isCancelled, self.titleLogoURL == titleLogoURL else { return }
                    withAnimation(.easeIn(duration: 0.25)) { titleLogoImage = fetched }
                }
            }

            // BUG-38: the logo overlay replaces this plain-text name once it loads — the text
            // stays as the fallback (no logo URL, load failure, or still loading).
            if !folder.hideTitle && titleLogoImage == nil {
                Text(folder.title)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .frame(width: tileWidth, alignment: .leading)
                    // BUG-108: in ring mode the artwork grows DOWNWARD by the same 20pt it rises,
                    // so the caption follows its bottom edge exactly as every other card's does.
                    // 0 in both other modes: the native lift moves the whole label itself, and
                    // still mode moves nothing. Render-only `.offset`, so the lockup's measured
                    // height is unchanged and `shortestTileHeight`/`shelfMinHeight` do not move.
                    .modifier(CardCaptionFocusDrop(
                        mode: artworkLift, isFocused: stillFocused, artworkHeight: tileHeight
                    ))
            }
        }
        // FEAT-33 (Wave 1, agent C): leg 2/3 of `debug.collectionFocusAB` drops this animation
        // entirely to test whether it's the source of the reported 30fps-looking focus step.
        // Identical to shipping behavior with the knob off (the default).
        // BUG-108: `reduceMotion` added because this animation now wraps `CardArtworkFocusLift`'s
        // manual scale. That modifier honours Reduce Motion by passing a nil animation; a blanket
        // `.animation` out here would animate the scale anyway and undo it.
        .animation(CollectionFocusAB.dropTileAnimation || reduceMotion
                   ? nil : .easeOut(duration: 0.15),
                   value: isFocused)
        // rc14 FEAT-46: focus-gain-only colour resolution — see `PosterCard`'s copy. Keyed on
        // `stillFocused`, the same row-owned focus truth the ring and lift use (never
        // `isFocused`, for the BUG-108 reason given on `CardArtworkFocusLift` above), so the tint
        // can never be resolved for a frame in which the ring is not drawn.
        .onChange(of: stillFocused, initial: true) { _, focused in
            guard focused, samplesPosterColor else { return }
            ArtworkColorStore.shared.color(for: [coverURLString]) { color in
                guard posterRingTint != color else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { posterRingTint = color }
            }
        }
    }
}

/// Backs `FolderDetailView`. The shared `FolderDetailRepository` is a singleton keyed by
/// `initialize(collectionId:folderId:)` — one folder screen at a time, `clear()` on exit.
@MainActor
final class FolderDetailViewModel: ObservableObject {
    /// The selected tab's tmdb source when its Discover filters can be edited on-device
    /// (`TmdbFilterEditorView`). Identifiable so it can drive `.fullScreenCover(item:)`.
    struct EditableSource: Identifiable {
        let collectionId: String
        let folderId: String
        /// Index into `folder.resolvedSources` (what `TmdbSourceFilterEditor.begin` takes).
        let sourceIndex: Int
        let title: String
        var id: String { "\(collectionId)|\(folderId)|\(sourceIndex)" }
    }

    @Published private(set) var folderTitle: String
    /// BUG-38 (folder page): `CollectionFolder.titleLogoUrl` as the page title — the key the
    /// Home tile deliberately does NOT draw over a folder's own cover (BUG-52: the logo over a
    /// self-naming cover doubled every wordmark). Blank/whitespace counts as absent, the same
    /// trimming rule the tile applies to every payload URL. The folder's `heroBackdropUrl` is
    /// the HOME hero's business (round three), not this page's.
    @Published private(set) var titleLogoUrl: String?
    @Published private(set) var tabs: [FolderTab] = []
    @Published private(set) var selectedTabIndex = 0
    @Published private(set) var items: [MetaPreview] = []
    @Published private(set) var isLoading = true
    @Published private(set) var canLoadMore = false
    @Published private(set) var tabIsLoading = false
    /// Non-nil when the selected tab is a filter-consuming tmdb source (DISCOVER / COMPANY /
    /// NETWORK — LIST/COLLECTION/PERSON/DIRECTOR ignore Discover filters at resolve time).
    @Published private(set) var editableSource: EditableSource?

    /// Home Stage & Strip (P2 §2.2): the Rows page's strip, one row per source tab (no "All"), built
    /// from EVERY tab's state — `FolderDetailRepository.initialize` already loads each source's first
    /// page concurrently, so this is Swift only. Assigned only when it changes; a row whose equality
    /// key is unchanged keeps its previous instance and section (`FolderRowsPlan.reusing`).
    @Published private(set) var stripRows: [FolderStripRow] = []
    /// P2 §2.2: no source is still on its first load (`!FolderDetailUiState.isLoading`).
    @Published private(set) var allSettled = false
    /// P2 §2.6: one entry per filter-editable source tab (the Rows page's Edit menu); the Grid page
    /// keeps `editableSource`, the selected tab's.
    @Published private(set) var editableSources: [EditableSource] = []
    /// P2 §2.2: the folder's collection, for the Rows page's stage preview (`HomeRowPreviews.folder`).
    /// Read at init, refreshed when the repository's folder changes.
    @Published private(set) var collection: NuvioCollection? = nil

    /// Internal (P2 §2.2): the folder page builds its per-folder layout key from them.
    let collectionId: String
    let folderId: String
    private var watcher: FlowWatcher?
    /// The repository folder `collection` was last refreshed for.
    private var lastFolder: CollectionFolder?

    /// The folder this page shows, from `collection` (the route carries only ids and titles).
    var folder: CollectionFolder? {
        collection?.folders.first { $0.id == folderId }
    }

    init(route: FolderRoute) {
        collectionId = route.collectionId
        folderId = route.folderId
        folderTitle = route.folderTitle
        titleLogoUrl = route.titleLogoUrl
        collection = CollectionRepository.shared.getCollection(id: route.collectionId)
    }

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(FolderDetailRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? FolderDetailUiState else { return }
            if let folder = state.folder {
                self.folderTitle = folder.title
                self.titleLogoUrl = folder.titleLogoUrl.nonBlankTrimmed
            }
            self.tabs = state.tabs
            self.selectedTabIndex = Int(state.selectedTabIndex)
            self.items = state.selectedTab?.items ?? []
            self.isLoading = state.isLoading
            self.canLoadMore = state.selectedTabCanLoadMore
            self.tabIsLoading = state.selectedTab?.isLoading ?? false
            self.editableSource = Self.editableSource(
                forTabAt: Int(state.selectedTabIndex),
                in: state,
                collectionId: self.collectionId,
                folderId: self.folderId
            )
            self.applyStripState(state)
        }
        FolderDetailRepository.shared.initialize(collectionId: collectionId, folderId: folderId)
    }

    /// P2 §2.2: the Rows page's per-tab state, published only when it changes.
    private func applyStripState(_ state: FolderDetailUiState) {
        // The repository is a singleton: an emission still carrying another folder (before this
        // page's `initialize` replaced it) is never drawn as this folder's rows.
        if let folder = state.folder, folder.id != folderId { return }
        let snapshots = state.tabs.enumerated().map { index, tab in
            FolderTabSnapshot(tab: tab, tabIndex: index)
        }
        let rows = FolderRowsPlan.reusing(
            stripRows,
            for: FolderRowsPlan.rows(snapshots, collectionId: collectionId, folderId: folderId)
        )
        if rows != stripRows { stripRows = rows }
        let settled = !state.isLoading
        if settled != allSettled { allSettled = settled }
        let sources = state.tabs.indices.compactMap { index in
            Self.editableSource(forTabAt: index, in: state, collectionId: collectionId, folderId: folderId)
        }
        if sources.map(\.id) != editableSources.map(\.id) || sources.map(\.title) != editableSources.map(\.title) {
            editableSources = sources
        }
        if let folder = state.folder, folder != lastFolder {
            lastFolder = folder
            let fresh = CollectionRepository.shared.getCollection(id: collectionId)
            if fresh != collection { collection = fresh }
        }
    }

    /// P2 §2.3 (the Rows page's Try Again): clear, then load every source again. `reload()` is not
    /// enough here: `initialize` early-returns on unchanged inputs, so it never refetches a failed tab.
    func retry() {
        FolderDetailRepository.shared.clear()
        FolderDetailRepository.shared.initialize(collectionId: collectionId, folderId: folderId)
    }

    /// Re-runs `initialize` for the same folder after the filter editor saved: the repository's
    /// retained-inputs guard (UX-14) sees the changed `folder` and does a full refetch; when
    /// nothing changed (Cancel) it early-returns and keeps the grid as-is.
    func reload() {
        let previousTab = selectedTabIndex
        FolderDetailRepository.shared.initialize(collectionId: collectionId, folderId: folderId)
        // A full re-init rebuilds the tabs with index 0 selected; put the user back on the tab
        // whose filters they just edited (tabs are built synchronously inside initialize).
        let tabCount = (FolderDetailRepository.shared.uiState.value_ as? FolderDetailUiState)?.tabs.count ?? 0
        if previousTab > 0, previousTab < tabCount {
            FolderDetailRepository.shared.selectTab(index: Int32(previousTab))
        }
    }

    /// Maps tab `tabIndex` back to its `resolvedSources` index. FolderDetailRepository builds
    /// one tab per source, with an "All" tab first when `showAllTab` (`tabIndex = showAll ?
    /// sourceIndex + 1 : sourceIndex`, FolderDetailRepository.kt:278). Addon sources whose
    /// catalog can't be materialised are skipped while building tabs, which would shift the
    /// indices — so the offset result is verified against the folder's sources and corrected by
    /// identity when it doesn't line up. The Grid page asks for the selected tab; the Rows page's
    /// Edit menu (P2 §2.6) for every tab.
    private static func editableSource(
        forTabAt tabIndex: Int,
        in state: FolderDetailUiState,
        collectionId: String,
        folderId: String
    ) -> EditableSource? {
        let tabs = state.tabs
        guard tabs.indices.contains(tabIndex) else { return nil }
        let tab = tabs[tabIndex]
        guard !tab.isAllTab, let source = tab.source, source.isTmdb else { return nil }
        // Same fallback as the shared `CollectionSource.tmdbType()`: unknown/missing → DISCOVER.
        let rawType: String? = source.tmdbSourceType
        let type = (rawType ?? "DISCOVER").uppercased()
        if ["LIST", "COLLECTION", "PERSON", "DIRECTOR"].contains(type) { return nil }

        var sourceIndex = tabIndex - (state.showAllTab ? 1 : 0)
        if let resolved = state.folder?.resolvedSources {
            let aligned = resolved.indices.contains(sourceIndex) && resolved[sourceIndex] == source
            if !aligned, let match = resolved.firstIndex(where: { $0 == source }) {
                sourceIndex = match
            }
        }
        guard sourceIndex >= 0 else { return nil }
        return EditableSource(
            collectionId: collectionId,
            folderId: folderId,
            sourceIndex: sourceIndex,
            title: tab.label
        )
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        // UX-14: `onDisappear` also fires when a pushed title screen merely COVERS this grid —
        // `clear()` here meant popping back rebuilt the grid at the top. `detach()` cancels
        // in-flight loads but keeps the repository's state, so `initialize()`'s same-key
        // early-return preserves the items (and the lazy grid's scroll position) on pop-back.
        // Same UX-13 contract as CatalogGridViewModel.stop() → CatalogRepository.detach().
        FolderDetailRepository.shared.detach()
    }

    func selectTab(_ index: Int) {
        FolderDetailRepository.shared.selectTab(index: Int32(index))
    }

    /// Infinite scroll: page the selected tab when focus nears the end of the grid.
    func itemAppeared(at index: Int) {
        guard canLoadMore, index >= items.count - 8 else { return }
        FolderDetailRepository.shared.loadMoreSelectedTab()
    }
}

/// C (Steven beta.19-rc1 verdict, 2026-10-03; BUG-135): the folder page header's geometry. Pure, so
/// `FolderHeaderGeometryTests` pins it without a view host.
///
/// The header (title logo + tab chips) sits at the top of the grid's scroll content. As the grid
/// scrolls by `s`, the logo rises from `restTop` to `compactTop` and shrinks from `logoSlot` to
/// `compactLogoSlot` over the first `riseDistance` points; the chips and the opaque band behind
/// them move with the content until `s == riseDistance`, then pin at the compact position. Every
/// moving piece reads `s` from its own `GeometryProxy` inside its own `.visualEffect`, so nothing
/// writes view state per scroll frame (BUG-19/BUG-41).
///
/// Both blocks are one `VStack(spacing: gap)` of [logo slot, chips?] then a `gap` and a `fade`:
///   full    Bf = restTop + logoSlot + [gap + chips] + gap + fade
///   compact Bc = compactTop + compactLogoSlot + [gap + chips] + gap + fade
/// so `Bf − Bc == riseDistance` whatever the chip row's height.
nonisolated enum FolderHeaderGeometry {
    /// T: the logo's top at rest (today's header top, rc14 device round 2).
    static let restTop: CGFloat = Theme.Spacing.screen - Theme.Spacing.lg - Theme.Spacing.xxs   // 32
    /// Lf: the full logo slot.
    static let logoSlot: CGFloat = Theme.Size.heroLogoSlotHeight                                 // 150
    /// Tc: the logo's top once compact.
    static let compactTop: CGFloat = Theme.Spacing.sm                                            // 12
    /// Lc: the compact logo slot.
    static let compactLogoSlot: CGFloat = 64
    /// g: logo → chips, chips → fade.
    static let gap: CGFloat = Theme.Spacing.md                                                   // 16
    /// F: the band's fade under the chips (`EdgeFadeCurve`, background colour → clear).
    static let fade: CGFloat = 36
    /// The bottom-of-page fade (outside the scroll view).
    static let bottomFade: CGFloat = 60
    /// R: how far the grid scrolls while the header rises. (T − Tc) + (Lf − Lc).
    static var riseDistance: CGFloat { (restTop - compactTop) + (logoSlot - compactLogoSlot) }  // 106
    /// The named coordinate space on the scroll CONTENT; `s` = a piece's minY in this space minus
    /// its minY in the scroll view's visible space.
    static let contentSpace = "folderContent"

    /// 0 at rest, 1 once the header is compact.
    static func progress(scrolled s: CGFloat) -> CGFloat {
        guard riseDistance > 0, s.isFinite else { return s > 0 ? 1 : 0 }
        return min(max(s / riseDistance, 0), 1)
    }

    static func logoScale(scrolled s: CGFloat) -> CGFloat {
        let p = progress(scrolled: s)
        return 1 + (compactLogoSlot / logoSlot - 1) * p
    }

    /// The logo's offset on top of the content's own scroll: it cancels the scroll (`+ s`) and
    /// moves from `restTop` to `compactTop`. Overscroll (s ≤ 0) moves it with the content.
    static func logoOffsetY(scrolled s: CGFloat) -> CGFloat {
        guard s > 0 else { return 0 }
        let p = progress(scrolled: s)
        return (restTop + (compactTop - restTop) * p) - restTop + s
    }

    /// The chips' and band's offset: zero while the header rises, then cancels the scroll.
    static func pinnedOffsetY(scrolled s: CGFloat) -> CGFloat {
        max(0, s - riseDistance)
    }

    /// 0…4, for the DEBUG probe only.
    static func phase(scrolled s: CGFloat) -> Int {
        Int(progress(scrolled: s) * 4)
    }
}

/// A collection folder's contents: tab chips (one per source + "All") over an adaptive paginated
/// poster grid. All view modes render as the tabbed grid on tvOS (v1 simplification). Pushed within
/// the Home stack, so `TitleRoute` resolves against the ancestor's destination.
///
/// C (Steven beta.19-rc1 verdict, 2026-10-03; BUG-135, a regression from build 133's R4): the
/// header used to LEAVE the view tree once the grid scrolled, inside a clipped fixed-height slot
/// with a 0.3 s move + fade, which read as a 1–2-frame cut on hardware; the tab chips were the
/// scroll content's first child, so they scrolled away on the next press and came back in steps;
/// and every poster flashed its grey shimmer for 0.25–0.5 s on open. Now the title rises and
/// stays (compact, centred), the chips pin under it, and the grid is held back for at most 0.45 s
/// while its first posters warm. See `FolderHeaderGeometry`.
///
/// Home Stage & Strip (H5, FEAT-43; P2 spec §2): a folder follows the Home layout. Classic Home
/// keeps this grid exactly (`gridPage`, with its Edit Filters button). Stage Home opens the folder
/// as a stage-and-strip page (`FolderRowsPage`), and the grid stays available per folder through
/// the Edit menu (`FolderEditMenuBand`: Layout › Rows / Grid, plus Edit Filters), which replaces
/// the Edit Filters button in Stage and is mounted OUTSIDE the Rows/Grid switch, so choosing a
/// layout keeps focus on it. Both layouts share the one view model; the per-folder Grid choice is
/// device-local (`FolderLayoutStore`). `home_layout` and the choice are read live, so a folder left
/// open while Home Layout flips in Settings shows the new layout on return.
struct FolderDetailView: View {
    @StateObject private var model: FolderDetailViewModel

    @Environment(\.posterStyle) private var posterStyle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    /// P2 §2.1: the Home layout, read live (`HomeLayout` is the one copy of the key).
    @AppStorage(HomeLayout.defaultsKey) private var homeLayoutRaw = HomeLayout.defaultValue.rawValue
    /// P2 §2.1: the device-local per-folder Grid choices (`FolderLayoutStore`).
    @AppStorage(FolderLayoutStore.defaultsKey) private var folderLayoutRaw = ""
    /// P2 §2.6: the Rows page's Edit band gate, written by `FolderRowsPage` only when it changes
    /// (true while the strip's focused row is its top focusable row, or before any row had focus).
    @State private var rowsAtTop = true
    /// A layout switch happened while this page was open (Edit › Layout, or Home Layout flipped in
    /// Settings): a Rows page mounted by it leaves focus where it is instead of pulling it to the
    /// first card (P2 §2.6: choosing a layout keeps focus on the Edit menu).
    @State private var layoutSwitched = false
    /// Drives the TMDB filter editor cover for the selected tab's tmdb source (Grid) or the source
    /// picked in the Edit menu (Rows).
    @State private var editing: FolderDetailViewModel.EditableSource?
    /// True once the grid has scrolled past its top (content offset > 8 pt). Derived through a Bool
    /// transform in `onScrollGeometryChange`, so it writes once per crossing, not per scroll frame.
    /// C: drives only `Edit Filters` (fade + disabled) and the probe now; the header itself is
    /// driven by `.visualEffect`.
    @State private var gridScrolled = false
    /// C: the grid stays covered until its first posters are warm (≤ 0.45 s), instead of every card
    /// flashing its shimmer. One write per load; reset without animation on a tab change.
    @State private var gridRevealed = false
    /// C (probe only): which tab chip holds focus.
    @FocusState private var focusedChip: Int?
    #if DEBUG
    /// C (probe only): `FolderHeaderGeometry.phase`, from an Int transform (5 buckets).
    @State private var headerPhase = 0
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// C: how many posters the reveal warms (the first rows at any Poster Size) and how long it
    /// waits for them.
    private static let revealPrefetchCount = 12
    private static let revealTimeout: TimeInterval = 0.45

    init(route: FolderRoute) {
        _model = StateObject(wrappedValue: FolderDetailViewModel(route: route))
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: posterStyle.width), spacing: Theme.Spacing.xl)]
    }

    private var hasChips: Bool { model.tabs.count > 1 }

    private var homeLayout: HomeLayout { HomeLayout.resolve(homeLayoutRaw) }

    /// P2 §2.1: Classic → the grid; Stage → Rows unless this folder has a stored Grid choice.
    private var pageLayout: FolderPageLayout {
        FolderPageLayout.resolve(
            homeLayout: homeLayout,
            gridOverride: FolderLayoutStore.isGrid(folderLayoutRaw,
                                                   collectionId: model.collectionId,
                                                   folderId: model.folderId)
        )
    }

    /// The Edit menu's Layout picker: writes (or clears) this folder's Grid choice.
    private var layoutBinding: Binding<FolderPageLayout> {
        Binding(
            get: { pageLayout },
            set: { newLayout in
                let updated = FolderLayoutStore.setting(folderLayoutRaw,
                                                        grid: newLayout == .grid,
                                                        collectionId: model.collectionId,
                                                        folderId: model.folderId)
                if updated != folderLayoutRaw { folderLayoutRaw = updated }
            }
        )
    }

    var body: some View {
        let layout = pageLayout
        ZStack(alignment: .top) {
            switch layout {
            case .rows:
                FolderRowsPage(model: model, rowsAtTop: $rowsAtTop, requestsInitialFocus: !layoutSwitched)
            case .grid:
                gridPage
            }
            if homeLayout == .stage {
                // §2.6: visible and enabled at the top of the page (the strip's top focusable row,
                // or the grid not scrolled), the existing Edit Filters rule.
                FolderEditMenuBand(model: model,
                                   layout: layoutBinding,
                                   isActive: layout == .rows ? rowsAtTop : !gridScrolled,
                                   editing: $editing)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        // A layout switch mounts a fresh page: its scroll starts at the top and no strip row has
        // focus yet.
        .onChange(of: layout) { _, _ in
            if gridScrolled { gridScrolled = false }
            if !rowsAtTop { rowsAtTop = true }
            if !layoutSwitched { layoutSwitched = true }
        }
        // House pattern for full-screen flows (`ProfileEditTarget`, DetailView's players). On
        // dismiss — Save, Cancel, or Menu — re-run initialize: the repository's retained-inputs
        // guard refetches only when the folder actually changed. Serves both layouts.
        .fullScreenCover(item: $editing, onDismiss: { model.reload() }) { source in
            TmdbFilterEditorView(target: source)
        }
    }

    /// Today's folder page, moved verbatim from `body`: Classic always, Stage when this folder's
    /// layout is Grid. Its tab-change reset and its reveal task live here, so the Rows page never
    /// prefetches a grid. Classic keeps the Edit Filters button; Stage has the Edit band instead.
    private var gridPage: some View {
        ZStack(alignment: .top) {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // C: the COMPACT block's footprint, layout only. The scroll view starts below it,
                // so the focus engine reveals grid rows under the pinned title and chips, never
                // beneath them. Its chip row is a hidden, disabled copy that only lends its height.
                // `fixedSize` so the greedy scroll view below can never stretch the hidden chip
                // row: the ghost must be exactly as tall as the real block minus `riseDistance`.
                compactGhost
                    .fixedSize(horizontal: false, vertical: true)

                // BUG-38 round three: the folder's backdrop is NOT painted behind this page any
                // more (it shipped that way in beta.14; the reporter found it made the page text
                // unreadable depending on the image). The logo-as-title stays; the backdrop moved
                // to the Home hero, which follows the focused folder tile.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        // C: laid out `riseDistance` tall and bottom-aligned, so the header's full
                        // height overflows UP by exactly the compact block above: at rest it draws
                        // from the top of the page. `zIndex(1)` keeps it (and its opaque band)
                        // painted over the grid cards passing under it (the Codex P2 rc13
                        // paint-order rule: a VStack paints in declaration order).
                        header
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(height: FolderHeaderGeometry.riseDistance, alignment: .bottom)
                            .zIndex(1)

                        gridContent
                    }
                    .coordinateSpace(.named(FolderHeaderGeometry.contentSpace))
                }
                .scrollClipDisabled()
                // The one Bool this page derives from scrolling (Edit Filters + probe). SwiftUI
                // only calls `action` when the answer flips.
                .onScrollGeometryChange(for: Bool.self, of: { geometry in
                    geometry.contentOffset.y > 8
                }, action: { _, scrolled in
                    gridScrolled = scrolled
                })
                #if DEBUG
                // C (probe only): five buckets, so at most four writes per rise.
                .onScrollGeometryChange(for: Int.self, of: { geometry in
                    FolderHeaderGeometry.phase(scrolled: geometry.contentOffset.y + geometry.contentInsets.top)
                }, action: { _, phase in
                    headerPhase = phase
                })
                #endif
            }

            if homeLayout == .classic {
                editFiltersOverlay
            }

            // C: the bottom edge fades into the background instead of cutting cards off at the
            // bezel. Outside the scroll view, never hit-tested.
            LinearGradient(stops: EdgeFadeCurve.stops(rising: true, color: Theme.Palette.background),
                           startPoint: .top, endPoint: .bottom)
                .frame(height: FolderHeaderGeometry.bottomFade)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)

            #if DEBUG
            // Invisible, harness-readable header state for test69 (`folder_header_state`) — same
            // hidden-Text pattern as HomeView's `debug_*` labels. C: XCUITest frames ignore
            // `.offset`/`.scaleEffect`, so the rise is asserted through this label and pixels.
            Text("scrolled=\(gridScrolled ? 1 : 0) phase=\(headerPhase) chip=\(focusedChip.map { String($0) } ?? "-") reveal=\(gridRevealed ? 1 : 0)")
                .font(.system(size: 8))
                .opacity(0.011)
                .allowsHitTesting(false)
                .accessibilityIdentifier("folder_header_state")
            #endif
        }
        // C: a new tab hides the grid at once (no fade-out), then the task below reveals it when
        // the new tab's first posters are warm.
        .onChange(of: model.selectedTabIndex) { _, _ in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { gridRevealed = false }
        }
        .task(id: GridRevealKey(tab: model.selectedTabIndex, hasItems: !model.items.isEmpty)) {
            await revealGridWhenWarm()
        }
    }

    // MARK: - Grid

    private var gridContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if model.items.isEmpty {
                if model.isLoading || model.tabIsLoading {
                    HStack(spacing: Theme.Spacing.md) {
                        ProgressView()
                        Text("Loading\u{2026}").foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .padding(.top, Theme.Spacing.xl)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        Text("Nothing here yet.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        // BUG-47 class: a pushed screen with no focusable content strands focus
                        // on the ancestor tab bar, where Menu exits the app instead of popping.
                        // The Edit Filters button anchors focus when present; otherwise keep a Go
                        // Back control here (same as CatalogGridView).
                        if model.editableSource == nil {
                            Button("Go Back") { dismiss() }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top, Theme.Spacing.xl)
                }
            } else {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.xl) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        NavigationLink(value: TitleRoute(preview: item)) {
                            PosterCard(title: item.name, imageURL: item.poster, fallbackImageURL: item.rawPosterUrl)
                        }
                        .cardFocusButtonStyle()
                        .posterButtonShape()
                        .titleHoldMenu(preview: item)
                        .onAppear { model.itemAppeared(at: index) }
                        // UI test69: only the first tile needs an identifier — the test reads its
                        // frame to prove it clears the header's bottom fade.
                        .accessibilityIdentifier(index == 0 ? "folder_grid_first_tile" : "")
                    }
                }
                // C: the reveal gate. A cover in the page colour rather than `.opacity(0)` on the
                // grid, so the grid stays focusable while it is held back (a zero-opacity view can
                // be skipped when tvOS picks the first focus, and a pushed page with nothing
                // focusable strands focus on the tab bar — the BUG-47 class). It overhangs the grid
                // by `xl` so a focused first card's lift and shadow are covered too, and fades out
                // once the first posters are warm.
                .overlay {
                    Theme.Palette.background
                        .padding(-Theme.Spacing.xl)
                        .opacity(gridRevealed ? 0 : 1)
                        .allowsHitTesting(false)
                }

                if model.canLoadMore || model.tabIsLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, Theme.Spacing.lg)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.screen)
        .padding(.bottom, Theme.Spacing.screen)
        // C: the header (with its own bottom fade and gap) is the scroll content's first child, so
        // the grid only needs room for a focused first-row card's lift plus its shadow's reach
        // above the frame. At rest the first row sits within a few points of rc14's.
        .padding(.top, Theme.Size.heroPinnedRowFocusLiftAllowance + Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Reveal gate (C)

    private struct GridRevealKey: Equatable {
        let tab: Int
        let hasItems: Bool
    }

    /// C: warm exactly what the first posters will ask for (the card's head URL at the card's
    /// decode bucket, `PosterCard.decodeRequest`, critique #22), wait at most `revealTimeout`, then
    /// fade the grid in. A no-op while the tab has no items or once the grid is shown.
    private func revealGridWhenWarm() async {
        guard !model.items.isEmpty, !gridRevealed else { return }
        let decode = PosterCard.decodeRequest(width: posterStyle.width, height: posterStyle.height, scale: displayScale)
        let urls = model.items.prefix(Self.revealPrefetchCount).compactMap { Self.revealPrefetchURL(poster: $0.poster) }
        await ArtworkStore.prefetchAndWait(urls, decode: decode, timeout: Self.revealTimeout)
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { gridRevealed = true }
    }

    /// The first URL a `PosterCard` asks for: the larger rendition of its poster when one is known
    /// (`ArtworkURLUpgrade`, role `.poster`), else the poster itself. A card without a poster URL
    /// draws a flat surface and loads nothing, so there is nothing to warm.
    private static func revealPrefetchURL(poster: String?) -> URL? {
        guard let poster, !poster.isEmpty, let url = URL(string: poster) else { return nil }
        return ArtworkURLUpgrade.upgraded(url, role: .poster) ?? url
    }

    // MARK: - Header (C)

    /// FEAT-40 (rc13, "official Nuvio" folder header ask) → beta.18 verdict R4 → C (beta.19-rc1
    /// verdict): the centred title logo (or the folder's name in `Theme.Font.hero` when it has no
    /// logo) over the tab chips, on an opaque band in the page colour that fades out under the
    /// chips. It is the scroll content's first child; `.visualEffect` makes the logo rise and shrink
    /// to the compact slot and pins the chips and band once the grid has scrolled `riseDistance`.
    ///
    /// H-2: the parent collection's title ("Genres", "Services de Streaming") stays removed — a
    /// tvOS-only invention a tester flagged 2026-08-22 — so this header is logo/title-only.
    /// BUG-38 round three: no backdrop on this page.
    ///
    /// The title stays in the view tree the whole time (VoiceOver and the harness keep it), and
    /// `folder_header` is this container: at rest its frame is exactly what is drawn.
    private var header: some View {
        VStack(alignment: .leading, spacing: FolderHeaderGeometry.gap) {
            VStack(alignment: .leading, spacing: FolderHeaderGeometry.gap) {
                logoSlot
                    .visualEffect { content, proxy in
                        let s = proxy.frame(in: .named(FolderHeaderGeometry.contentSpace)).minY
                            - proxy.frame(in: .scrollView(axis: .vertical)).minY
                        return content
                            .scaleEffect(FolderHeaderGeometry.logoScale(scrolled: s), anchor: .top)
                            .offset(y: FolderHeaderGeometry.logoOffsetY(scrolled: s))
                    }
                    .padding(.top, FolderHeaderGeometry.restTop)

                if hasChips {
                    chipsRow(bindsFocus: true)
                        // F (FEAT-54): the chips row fades at the screen edges like every other row.
                        .rowEdgeEffectStyle()
                        .padding(.horizontal, Theme.Spacing.screen)
                        .visualEffect { content, proxy in
                            let s = proxy.frame(in: .named(FolderHeaderGeometry.contentSpace)).minY
                                - proxy.frame(in: .scrollView(axis: .vertical)).minY
                            return content.offset(y: FolderHeaderGeometry.pinnedOffsetY(scrolled: s))
                        }
                }
            }
            // The band: opaque page colour from 600 pt above the header (it covers cards that have
            // scrolled up past the screen top) down to the chips' bottom (the logo slot's bottom
            // with one tab), then a `fade`-tall eased fade to clear. A background of the logo +
            // chips block, so it sizes itself to them; it pins with the chips.
            .background(alignment: .top) {
                VStack(spacing: 0) {
                    Theme.Palette.background
                    LinearGradient(stops: EdgeFadeCurve.stops(rising: false, color: Theme.Palette.background),
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: FolderHeaderGeometry.fade)
                }
                .padding(.top, -600)
                .padding(.bottom, -FolderHeaderGeometry.fade)
                .allowsHitTesting(false)
                .visualEffect { content, proxy in
                    let s = proxy.frame(in: .named(FolderHeaderGeometry.contentSpace)).minY
                        - proxy.frame(in: .scrollView(axis: .vertical)).minY
                    return content.offset(y: FolderHeaderGeometry.pinnedOffsetY(scrolled: s))
                }
            }

            Color.clear.frame(height: FolderHeaderGeometry.fade)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // rc13 UI test69 → C: the real header container. At rest its (layout) frame equals what is
        // drawn; while scrolled, XCUITest still reports the layout frame (it ignores the
        // `.visualEffect` offsets), so test69 reads the rise from `folder_header_state` and pixels.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("folder_header")
    }

    /// The compact block's footprint (see `body`): the same stack as `header` with the compact logo
    /// slot, so `header`'s height minus this one is exactly `riseDistance`.
    private var compactGhost: some View {
        VStack(alignment: .leading, spacing: FolderHeaderGeometry.gap) {
            VStack(alignment: .leading, spacing: FolderHeaderGeometry.gap) {
                Color.clear.frame(height: FolderHeaderGeometry.compactTop + FolderHeaderGeometry.compactLogoSlot)
                if hasChips {
                    // Critique #22: layout only. Hidden and disabled so it can never take focus,
                    // and without `rowEdgeEffectStyle` (it draws nothing to fade).
                    chipsRow(bindsFocus: false)
                        .padding(.horizontal, Theme.Spacing.screen)
                        .hidden()
                        .disabled(true)
                        .accessibilityHidden(true)
                }
            }
            Color.clear.frame(height: FolderHeaderGeometry.fade)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }

    /// The full-size logo slot: `TitleLogoHeader` centred and pinned to the top of a fixed
    /// `logoSlot`-tall frame (rc14 device round 2: top-aligned so a short wordmark sits as high as
    /// a tall one). A folder without a logo shows its name in the same slot, so the geometry does
    /// not depend on whether a logo exists.
    private var logoSlot: some View {
        TitleLogoHeader(
            title: model.folderTitle,
            logoUrl: model.titleLogoUrl,
            alignment: .top,
            textFont: Theme.Font.hero,
            slotHeight: Theme.Size.heroLogoSlotHeight,
            // beta.19-rc1 verdict (I1 row 9b, BUG-134): decoded for the slot it is drawn in instead
            // of the old fixed 1920 px cap. No URL upgrade: folder logos are the user's own art.
            decodeSize: .points(width: 1200, height: Theme.Size.heroLogoSlotHeight)
        )
        .multilineTextAlignment(.center)
        .padding(.horizontal, Theme.Spacing.screen)
        .frame(maxWidth: .infinity)
        .frame(height: FolderHeaderGeometry.logoSlot, alignment: .top)
    }

    /// The tab chips. `bindsFocus` is true only for the real row in `header`; the compact ghost's
    /// copy (critique #22) must never carry the focus binding.
    private func chipsRow(bindsFocus: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.md) {
                ForEach(Array(model.tabs.enumerated()), id: \.offset) { index, tab in
                    let chip = TabChip(label: tab.label, isSelected: index == model.selectedTabIndex) {
                        model.selectTab(index)
                    }
                    if bindsFocus {
                        chip.focused($focusedChip, equals: index)
                    } else {
                        chip
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.sm)
        }
        // F: a focused chip's lift and shadow are not clipped, and the edge fade can reach the bezel.
        .scrollClipDisabled()
    }

    /// On-device TMDB Discover filter editing for the selected tmdb tab (upstream 0fc4616b's
    /// exclusion filters + the existing include fields). Only shown for filter-consuming sources;
    /// doubles as the empty state's focus anchor (BUG-47) when the source currently matches nothing.
    ///
    /// C: an overlay at the page's top-trailing corner, level with the logo's rest position, no
    /// longer part of the header. It fades on the `gridScrolled` crossing and is disabled while
    /// the grid is scrolled, so Up from the first grid row cannot land on an invisible button.
    @ViewBuilder
    private var editFiltersOverlay: some View {
        if let source = model.editableSource {
            HStack {
                Spacer()
                Button {
                    editing = source
                } label: {
                    Label("Edit Filters", systemImage: "line.3.horizontal.decrease.circle")
                        .font(Theme.Font.meta)
                }
                .buttonStyle(.bordered)
                .disabled(gridScrolled)
                .accessibilityIdentifier("folder.editFilters")
            }
            .padding(.top, FolderHeaderGeometry.restTop)
            .padding(.trailing, Theme.Spacing.screen)
            .opacity(gridScrolled ? 0 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: gridScrolled)
        }
    }
}

/// Home Stage & Strip (P2 §2.6): the folder page's Edit menu in Stage, in place of the Edit Filters
/// button: Layout › Rows / Grid (this folder's device-local choice), then Edit Filters — one entry
/// per filter-editable source on the Rows page, the selected tab's on the Grid page (today's label).
/// Always present in Stage, so it is also the page's focus anchor while nothing else is focusable
/// (BUG-47).
///
/// Mounted once by `FolderDetailView`, outside the Rows/Grid switch, so picking a layout keeps focus
/// on it. A full-width focus section (the Library L1 pattern): Up from ANY card of the strip's top
/// row (or from the grid's chips) reaches it, and Down returns to the row the strip shows (its own
/// focus section). Visible and enabled only at the top of the page (`isActive`), faded like the
/// Edit Filters button it replaces.
struct FolderEditMenuBand: View {
    @ObservedObject var model: FolderDetailViewModel
    @Binding var layout: FolderPageLayout
    /// Rows: the strip's focused row is its top focusable row (or none has had focus yet). Grid: the
    /// grid has not scrolled.
    let isActive: Bool
    @Binding var editing: FolderDetailViewModel.EditableSource?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Menu {
                Picker(String(localized: "Layout"), selection: $layout) {
                    Text("Rows").tag(FolderPageLayout.rows)
                    Text("Grid").tag(FolderPageLayout.grid)
                }
                ForEach(filterEntries) { source in
                    Button {
                        editing = source
                    } label: {
                        Label(entryTitle(for: source), systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            } label: {
                Label("Edit", systemImage: "slider.horizontal.3")
                    .font(Theme.Font.meta)
            }
            // HIG contract: system styles only. If `.button` does not draw a bordered pill on tvOS,
            // drop both modifiers and keep the system Menu look.
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .disabled(!isActive)
            .accessibilityIdentifier("folder.editMenu")
        }
        .padding(.top, FolderHeaderGeometry.restTop)
        .padding(.trailing, Theme.Spacing.screen)
        .focusSection()
        .opacity(isActive ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isActive)
    }

    private var filterEntries: [FolderDetailViewModel.EditableSource] {
        switch layout {
        case .rows:
            return model.editableSources
        case .grid:
            return model.editableSource.map { [$0] } ?? []
        }
    }

    /// Rows names the source ("Edit Filters: Action"); Grid keeps today's label (the selected tab's).
    private func entryTitle(for source: FolderDetailViewModel.EditableSource) -> String {
        switch layout {
        case .rows:
            return String(localized: "Edit Filters: \(source.title)")
        case .grid:
            return String(localized: "Edit Filters")
        }
    }
}

// BUG-38 (folder page hero): this screen's title-logo header used to live here as a private
// `FolderHeroTitle` — the folder's `titleLogoUrl` as the page title when it loads (the same
// ArtworkStore path `HeroLogo` in HomeView uses for the Home hero's logo), falling back to plain
// `screenTitle` text until then / when there is none. rc13 (FEAT-40) promoted it to
// `DesignSystem/TitleLogoHeader.swift` — generalized with `alignment`/`textFont`/`slotHeight`
// parameters so `FolderDetailView`'s header (centred, larger, pinned above the grid) and
// `StreamPickerView`'s header (FEAT-42, unchanged leading/screenTitle/pinned layout) share one
// implementation instead of two copies. See that file for the Codex round-1 fixes it carries
// forward; `FolderDetailView.logoSlot` above is the only call site left in this file.

private extension Optional where Wrapped == String {
    /// Blank/whitespace-only payload URLs count as absent — the rule every other cover/logo
    /// check in this file applies (the editor/import path can persist whitespace-only values).
    var nonBlankTrimmed: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// A focusable pill used for the folder's source tabs.
///
/// BUG-49: the old hand-rolled label owned its color AND drew its own capsule fill, both blind
/// to focus — a focused-but-unselected chip painted near-white text on the chip style's
/// near-white platter, and any label-side fix would still leave the label's own dark capsule
/// covering that platter. `ChipButtonStyle(selected:)` already resolves fill and label for all
/// four focus×selection states (accent at rest when selected, white platter + dark label on
/// focus), so the chip must not override either.
private struct TabChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.body)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
        }
        .buttonStyle(.chip(selected: isSelected))
    }
}
