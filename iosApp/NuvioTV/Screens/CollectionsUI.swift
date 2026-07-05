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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(collection.title)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.Spacing.rowGap) {
                    ForEach(collection.folders, id: \.id) { folder in
                        NavigationLink(value: FolderRoute(collectionId: collection.id, folder: folder)) {
                            FolderTile(folder: folder)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.vertical, Theme.Spacing.sm)
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
                let cover: String? = folder.coverImageUrl
                if let cover, !cover.isEmpty {
                    CachedAsyncImage(string: cover)
                } else {
                    LinearGradient(
                        colors: [Theme.Palette.accent.opacity(0.55), Theme.Palette.background],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    let emoji: String? = folder.coverEmoji
                    Text(emoji?.isEmpty == false ? emoji! : String(folder.title.prefix(1)))
                        .font(.system(size: 64))
                }
            }
            .frame(width: tileWidth, height: tileHeight)
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: style.cornerRadius)
                    .strokeBorder(Theme.Palette.accentFocus, lineWidth: isFocused ? 4 : 0)
            )

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
                                .buttonStyle(.card)
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
        .buttonStyle(.card)
    }
}
