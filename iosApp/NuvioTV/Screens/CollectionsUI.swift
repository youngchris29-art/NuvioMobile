import Combine
import SwiftUI
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
// backed entirely by the shared `FolderDetailRepository`. Editing stays on mobile.

/// Navigation value for a collection folder's detail grid. Hashes on the stable ids; carries the
/// titles for the destination's initial render (same wrapper approach as `TitleRoute`).
struct FolderRoute: Hashable {
    let collectionId: String
    let folderId: String
    let folderTitle: String

    init(collectionId: String, folder: CollectionFolder) {
        self.collectionId = collectionId
        self.folderId = folder.id
        self.folderTitle = folder.title
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
                           spacing: Theme.Spacing.rowGap) {
                    ForEach(collection.folders, id: \.id) { folder in
                        NavigationLink(value: FolderRoute(collectionId: collection.id, folder: folder)) {
                            FolderTile(folder: folder)
                                .padding(.top, cardTopReach)
                                .padding(.bottom, cardBottomReach)
                        }
                        .buttonStyle(.borderless)
                        .posterButtonShape()   // BUG-32/BUG-25: without this the system radius overrides Corners
                    }
                }
                // Always positive — the reach lives inside the buttons (see CatalogRowView).
                // Pinned TOP matches the catalog/CW shelves' 24pt: `heroPinnedRowTitleInset`
                // assumes a 24 + reach band, and the tighter 12pt here left the overlaid title
                // only ~36pt of clearance — overlapping folder art at larger text sizes
                // (Codex review, device-pass gating round). Classic keeps the original 12.
                .padding(.top, cardTopReach > 0 ? Theme.Spacing.lg : Theme.Spacing.sm)
                .padding(.bottom, Theme.Spacing.sm)
            }
            .overlay(alignment: .topLeading) {
                if cardTopReach > 0 {
                    Text(collection.title)
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        // BUG-37: same clip-edge slide the catalog/CW shelves got — short
                        // real-swipe rests must never leave this row's title off-screen.
                        .shadow(color: .black.opacity(0.7), radius: 8, y: 2)
                        .pinnedRowTitleTracking(rowKey: collection.id)
                        .padding(.top, Theme.Size.heroPinnedRowTitleInset)
                        .allowsHitTesting(false)
                }
            }
        }
        .focusSection()
    }
}

/// A single folder tile: cover art (or emoji / initial fallback) shaped per the folder's
/// `tileShape` (poster / landscape / square), following the user's Poster Style width.
struct FolderTile: View {
    let folder: CollectionFolder

    @Environment(\.isFocused) private var isFocused
    @Environment(\.posterStyle) private var style

    /// BUG-38 display-time fallback: genre folders are TMDB DISCOVER sources, which
    /// `TmdbCollectionSourceResolver.importMetadata` never mints a cover for (only
    /// COLLECTION/COMPANY/NETWORK/PERSON get one) — upstream mobile has the same gap. Resolved
    /// lazily by `FolderCoverResolver` (shared, in-memory-cached, never persisted) and rendered
    /// through the exact same `CachedAsyncImage` slot as a real cover. Stays nil for folders that
    /// already have a cover or a user-chosen emoji — see the `.task` guard below.
    @State private var fallbackCoverUrl: String?

    private var tileWidth: CGFloat {
        folder.posterShape == PosterShape.landscape ? style.width * 16 / 9 : style.width
    }

    private var tileHeight: CGFloat {
        switch folder.posterShape {
        case PosterShape.landscape: return style.width
        case PosterShape.square: return style.width
        default: return style.height
        }
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
                let hasOwnCover = !(ownCover?.isEmpty ?? true)
                let hasEmoji = !(emoji?.isEmpty ?? true)
                let cover: String? = hasOwnCover ? ownCover : (hasEmoji ? nil : fallbackCoverUrl)
                let gifUrl: String? = folder.focusGifUrl

                // BUG-19: the cover is mounted for the tile's WHOLE lifetime — it used to live in
                // the `else` branch of an `isFocused` test, so every D-pad step destroyed one
                // image pipeline and built another (a new @StateObject loader, a new
                // CachedAsyncImage, and — worse — a full AnimatedGifImage teardown that freed the
                // expanded GIF frame array on the main thread). That teardown/rebuild, not the
                // animation, is the 700–830 ms per-step main-thread hang the tester measured.
                if let cover, !cover.isEmpty {
                    CachedAsyncImage(string: cover)
                } else {
                    LinearGradient(
                        colors: [Theme.Palette.accent.opacity(0.55), Theme.Palette.background],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text(hasEmoji ? emoji! : String(folder.title.prefix(1)))
                        .font(Theme.Font.hero)
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
            // BUG-38: keyed on the folder's Kotlin data-class hash (NOT `isFocused` — see the
            // BUG-19 comment above on why this tile must never key off focus), so a cloud-sync
            // edit that keeps the folder's id but changes its sources/cover/emoji re-runs the
            // task and re-consults the resolver under the new source signature (Codex review —
            // an unkeyed `.task` on a `ForEach(id: \.id)` row never re-fires for such edits).
            // `FolderCoverResolver` caches per folder-id+source-signature, so recycled
            // LazyHStack tiles and unchanged re-renders resolve instantly from that cache.
            .task(id: folder.hash()) {
                // Recompute from scratch each (re)run: a folder that GAINED a real cover or an
                // emoji must drop a previously resolved fallback rather than keep rendering it.
                fallbackCoverUrl = nil
                // Trimmed like the render path above — whitespace-only values are "absent".
                guard folder.coverImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return }
                guard folder.coverEmoji?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return }
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

            if !folder.hideTitle {
                Text(folder.title)
                    .font(Theme.Font.cardTitle)
                    .foregroundStyle(isFocused ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .frame(width: tileWidth, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Backs `FolderDetailView`. The shared `FolderDetailRepository` is a singleton keyed by
/// `initialize(collectionId:folderId:)` — one folder screen at a time, `clear()` on exit.
@MainActor
final class FolderDetailViewModel: ObservableObject {
    @Published private(set) var folderTitle: String
    @Published private(set) var collectionTitle = ""
    @Published private(set) var tabs: [FolderTab] = []
    @Published private(set) var selectedTabIndex = 0
    @Published private(set) var items: [MetaPreview] = []
    @Published private(set) var isLoading = true
    @Published private(set) var canLoadMore = false
    @Published private(set) var tabIsLoading = false

    private let collectionId: String
    private let folderId: String
    private var watcher: FlowWatcher?

    init(route: FolderRoute) {
        collectionId = route.collectionId
        folderId = route.folderId
        folderTitle = route.folderTitle
    }

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(FolderDetailRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? FolderDetailUiState else { return }
            if let folder = state.folder { self.folderTitle = folder.title }
            self.collectionTitle = state.collectionTitle
            self.tabs = state.tabs
            self.selectedTabIndex = Int(state.selectedTabIndex)
            self.items = state.selectedTab?.items ?? []
            self.isLoading = state.isLoading
            self.canLoadMore = state.selectedTabCanLoadMore
            self.tabIsLoading = state.selectedTab?.isLoading ?? false
        }
        FolderDetailRepository.shared.initialize(collectionId: collectionId, folderId: folderId)
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        FolderDetailRepository.shared.clear()
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

/// A collection folder's contents: tab chips (one per source + "All") over an adaptive paginated
/// poster grid. All view modes render as the tabbed grid on tvOS (v1 simplification). Pushed within
/// the Home stack, so `TitleRoute` resolves against the ancestor's destination.
struct FolderDetailView: View {
    @StateObject private var model: FolderDetailViewModel

    @Environment(\.posterStyle) private var posterStyle

    init(route: FolderRoute) {
        _model = StateObject(wrappedValue: FolderDetailViewModel(route: route))
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: posterStyle.width), spacing: Theme.Spacing.xl)]
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        if !model.collectionTitle.isEmpty {
                            Text(model.collectionTitle)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Text(model.folderTitle)
                            .font(Theme.Font.screenTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                    }

                    if model.tabs.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Spacing.md) {
                                ForEach(Array(model.tabs.enumerated()), id: \.offset) { index, tab in
                                    TabChip(
                                        label: tab.label,
                                        isSelected: index == model.selectedTabIndex
                                    ) {
                                        model.selectTab(index)
                                    }
                                }
                            }
                            .padding(.vertical, Theme.Spacing.sm)
                        }
                    }

                    if model.items.isEmpty {
                        if model.isLoading || model.tabIsLoading {
                            HStack(spacing: Theme.Spacing.md) {
                                ProgressView()
                                Text("Loading\u{2026}").foregroundStyle(Theme.Palette.textSecondary)
                            }
                            .padding(.top, Theme.Spacing.xl)
                        } else {
                            Text("Nothing here yet.")
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .padding(.top, Theme.Spacing.xl)
                        }
                    } else {
                        LazyVGrid(columns: columns, spacing: Theme.Spacing.xl) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                NavigationLink(value: TitleRoute(preview: item)) {
                                    PosterCard(title: item.name, imageURL: item.poster)
                                }
                                .buttonStyle(.borderless)
                                .posterButtonShape()
                                .onAppear { model.itemAppeared(at: index) }
                            }
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
                .padding(Theme.Spacing.screen)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

/// A focusable pill used for the folder's source tabs.
private struct TabChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Font.body)
                .foregroundStyle(isSelected ? Theme.Palette.background : Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    Capsule().fill(isSelected ? Theme.Palette.accent : Theme.Palette.surface)
                )
        }
        .buttonStyle(.chip)
    }
}
