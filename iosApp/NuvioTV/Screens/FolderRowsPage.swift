import Combine
import SharedCore
import SwiftUI

// Home Stage & Strip (H5, FEAT-43; P2 spec §2, W2-B): a collection folder opened from a Stage Home
// is a stage-and-strip page of its own. It reuses W1-A's seams and edits none of them (P1 §1.5):
//
//     FolderRowsPage                         ZStack(.topLeading), ignores the safe area
//     ├─ Theme background
//     ├─ AmbientWashLayer  "debug_wash_folder"     the blurred wash of the stage's title (S2, S8)
//     ├─ StageView         "debug_stage_folder"    the folder, then the focused title (S1, S3, S7)
//     ├─ FolderStageLogoLayer                      the folder's own logo/title: docked, then risen (§2.5)
//     └─ VStack
//        ├─ Color.clear  stageHeight               nothing focusable over the stage
//        └─ StripPager   stripHeight               one row per source tab, no "All" (S4)
//
// The Edit band (Layout picker + Edit Filters) is `FolderDetailView`'s, mounted outside the
// Rows/Grid switch so choosing a layout keeps focus on it (§2.6).
//
// Remote (§2.7): Down/Up page one row per press (P1's strip); Up from the top row reaches the Edit
// band (the strip never consumes it); Menu pops from any row (`menuPagesToTop: false` installs no
// exit handler); Back from a pushed Detail restores the same card (the strip's per-row memory, and
// this page's `@State` survives the push).
//
// Re-render rule (#5, BUG-126): the controller is held, never observed (it publishes nothing); the
// stage text, art and wash leaves observe their own sources; per-report bookkeeping lives in a
// reference box; the Edit band gate (`rowsAtTop`) is written only when it changes; the DEBUG probe
// is a leaf over its own readout state.

/// See the file header.
struct FolderRowsPage: View {
    @ObservedObject var model: FolderDetailViewModel
    /// The Edit band's gate (§2.6): true while the strip's focused row is its top focusable row, and
    /// before any row has had focus (the band is then the page's focus anchor, BUG-47). Written only
    /// when it changes, so `FolderDetailView` re-renders at the crossing, never per hop.
    @Binding var rowsAtTop: Bool
    /// §2.3's initial focus (the first card once a row is focusable). False when this page was
    /// mounted by a layout switch (Edit › Layout › Rows): choosing a layout keeps focus on the Edit
    /// menu (§2.6), so the page must not pull it into the strip.
    let requestsInitialFocus: Bool

    /// Held for its lifetime, never observed: it publishes nothing (#5).
    @StateObject private var stage = StageController()
    /// Report bookkeeping that never drives rendering.
    @State private var box = FolderRowsPageBox()
    /// §2.3: initial focus stops waiting for an earlier row still loading
    /// (`FolderRowsPlan.initialFocusWaitLimit` after the page appears).
    @State private var initialFocusWaitOver = false
    /// Q1: the stage follows focus from the viewer's first move, for good. Drives the logo's rise.
    @State private var followsFocus = false
    /// The deepest tab the strip has had focus on. It feeds `FolderRowsPlan.visible` in place of the
    /// current tab, so an empty or failed row, once the strip has gone past it, stays: rows are only
    /// ever added above the scroll position by a move, never removed from between the viewer and the
    /// row a glide is heading to (a page removed mid-glide could jump the strip).
    @State private var deepestFocusedTab: Int?
    #if DEBUG
    /// The `folder_rows_state` readout's own source, observed only by the probe leaf.
    @State private var debug = FolderRowsDebugState()
    #endif

    /// R1: the rail's content shift (36 with the rail Always Visible, from `.railTabRoot`; else 0).
    @Environment(\.railLeadingInset) private var railLeadingInset
    @Environment(\.posterStyle) private var posterStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false

    var body: some View {
        let geo = geometry
        let allRows = model.stripRows
        let shownRows = FolderRowsPlan.visible(allRows, focusedTabIndex: deepestFocusedTab)
        let state = FolderRowsPlan.pageState(allRows, allSettled: model.allSettled)
        let folderIdentity = folderPreview.map { "\($0.type):\($0.id)" }
        ZStack(alignment: .topLeading) {
            Theme.Palette.background
                .ignoresSafeArea()
            // S2 / S8: the wash observes the swap driver's wash feed itself, so this page never
            // re-renders on a swap; switched off, it draws nothing and the background shows through.
            AmbientWashLayer(feed: stage.swap.washFeed, probeID: "debug_wash_folder")
            // S3: while the stage displays the folder, its own logo slot is empty; the folder logo
            // layer below owns that slot (one logo in the slot at a time).
            StageView(controller: stage,
                      geometry: geo,
                      hidesLogoWhenDisplaying: folderIdentity,
                      probeID: "debug_stage_folder")
            FolderStageLogoLayer(title: model.folderTitle,
                                 logoUrl: model.titleLogoUrl,
                                 geometry: geo,
                                 docked: FolderStageLogo.docked(followsFocus: followsFocus))
            VStack(spacing: 0) {
                // The stage block's place: nothing focusable lives here, so Up from the top row
                // goes straight to the Edit band.
                Color.clear
                    .frame(height: geo.stageHeight)
                    .allowsHitTesting(false)
                stripArea(state: state, rows: shownRows, geometry: geo)
                    .frame(height: geo.stripHeight)
            }
            #if DEBUG
            FolderRowsProbeLabel(debug: debug,
                                 stageDebug: stage.swap.debug,
                                 visibleCount: shownRows.count,
                                 removedCount: allRows.count - shownRows.count,
                                 docked: FolderStageLogo.docked(followsFocus: followsFocus),
                                 state: state)
            #endif
        }
        // The strip's page arithmetic is in full-screen points, exactly as on Home.
        .ignoresSafeArea()
        // The stage frame changes only with a settings change, animated like Home's.
        .animation(.easeInOut(duration: 0.28), value: geo)
        .onAppear {
            stage.start()
            stage.swap.setReduceMotion(reduceMotion)
            if !initialFocusWaitOver {
                DispatchQueue.main.asyncAfter(deadline: .now() + FolderRowsPlan.initialFocusWaitLimit) {
                    initialFocusWaitOver = true
                }
            }
            // A pop back from Detail or See All lifts the cover (P1 §4.3's push rule).
            stage.setCovered(false, restoresFocus: true)
            seedStage()
        }
        .onDisappear {
            stage.setCovered(true, restoresFocus: true)
        }
        // R2 (P4 §2.5, H9): this page's rail return route, the Stage shape keyed by `\.railTabIndex`:
        // registered on appear and removed on disappear by `.railReturnRoute` (a push over this page
        // triggers both, so a pushed Detail's route is the one on top). Rail mode only.
        .railReturnRoute { folderRailRoute }
        // §2.4 first paint: the folder, with its cover as the wash's fallback. A changed preview
        // identity before the first real commit re-seeds; after it the seed is ignored.
        .onChange(of: folderIdentity ?? "-", initial: true) { _, _ in
            seedStage()
        }
        // §2.3 initial focus: row 0's first card. A later row that loads first waits for the
        // rows above it (`FolderRowsPlan.initialFocusTarget`).
        .onChange(of: FolderRowsPlan.initialFocusTarget(shownRows, waitOver: initialFocusWaitOver)?.id,
                  initial: true) { _, key in
            requestInitialFocus(key)
        }
        .onChange(of: allRows) { _, rows in
            stage.memory.prune(keeping: Set(rows.map(\.id)))
            refreshFocusDerived(rows: rows)
        }
        .onChange(of: reduceMotion) { _, motion in
            stage.swap.setReduceMotion(motion)
        }
    }

    // MARK: Geometry

    /// The same inputs as Home (S1), so the stage block sits exactly where Home's does.
    private var geometry: StripGeometry {
        StripGeometry.make(.live(style: posterStyle, noZoom: noZoomOnFocus, leadingInset: railLeadingInset))
    }

    // MARK: Strip

    @ViewBuilder
    private func stripArea(state: FolderRowsPlan.PageState,
                           rows: [FolderStripRow],
                           geometry geo: StripGeometry) -> some View {
        switch state {
        case .empty:
            statePanel(geometry: geo) { emptyPanel }
        case .failed:
            statePanel(geometry: geo) { failedPanel }
        case .rows, .loading:
            if rows.isEmpty {
                // Before the first emission: no tab exists yet.
                statePanel(geometry: geo) { loadingPanel }
            } else {
                StripPager(rowKeys: rows.map(\.id),
                           geometry: geo,
                           controller: stage,
                           // #9: link the tab bar, so in Tabs mode a rest never leaves it half shown
                           // (the BUG-66 class). Home's link is dropped when Home leaves the window.
                           linksTabBar: true,
                           // No rail mirror: the rail keeps Home's state (P4 §5.2).
                           reportsTab: nil,
                           // S4 / R3: no exit handler at all, so Menu pops from any row.
                           menuPagesToTop: false,
                           atTopExit: nil,
                           onRowChange: { _, key in
                               rowChanged(key: key)
                           },
                           // H9 (P4 §5.2): no rail write here. The page writes no mirror, so in
                           // Hide While Browsing the rail keeps Home's state.
                           onPageStart: { _, _ in },
                           onStripFocusLost: {
                               box.stripHasFocus = false
                               stage.stripFocusLost()
                           }) { key in
                    rowView(key, rows: rows)
                }
                // #23: a synced Poster Size too tall for the stage's floor lays out at the largest
                // height that fits (every row reads `\.posterStyle`), as on Home. The rows keep the
                // default `\.trailerPlaysInHero` (false): this page's stage never hosts a background
                // trailer (W2-A arms it only from `StageStripHome`), so a focused poster here plays
                // its In Row preview when Trailers on Focus is on, whatever the Trailer Location.
                .environment(\.posterStyle, geo.fits ? posterStyle : posterStyle.withHeight(geo.layoutPosterHeight))
            }
        }
    }

    /// One strip row (§2.3). Only a loaded row is focusable; the others are a heading over a
    /// skeleton or a one-line message, which the focus engine skips.
    @ViewBuilder
    private func rowView(_ key: String, rows: [FolderStripRow]) -> some View {
        if let row = rows.first(where: { $0.id == key }) {
            switch row.status {
            case .loaded:
                if let section = row.section {
                    CatalogRowView(
                        section: section,
                        previewLimit: FolderRowsPlan.previewLimit,
                        onItemFocusChange: { item in
                            cardReported(item, row: row, section: section)
                        }
                    )
                }
            case .loading:
                FolderLoadingRow(heading: row.heading)
            case .failed:
                FolderMessageRow(heading: row.heading, message: "Couldn't load this source.")
            case .empty:
                FolderMessageRow(heading: row.heading, message: "Nothing here yet.")
            }
        }
    }

    /// Page states (§2.3), left-aligned at the top of the strip area.
    private func statePanel<Content: View>(geometry geo: StripGeometry,
                                           @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.leading, geo.contentLeading)
            .padding(.top, Theme.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var loadingPanel: some View {
        HStack(spacing: Theme.Spacing.md) {
            ProgressView()
            Text("Loading\u{2026}")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// BUG-47 anchor: Go Back, so a page with nothing to browse never strands focus on the tab bar.
    private var emptyPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Nothing here yet.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Button("Go Back") { dismiss() }
                .buttonStyle(.bordered)
        }
    }

    /// Every source failed. Try Again clears the repository and loads every source again (a plain
    /// `initialize` would early-return on the unchanged inputs and never refetch a failed tab).
    private var failedPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Couldn't load this folder.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: Theme.Spacing.md) {
                Button("Try Again") { model.retry() }
                    .buttonStyle(.bordered)
                Button("Go Back") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Stage (§2.4)

    /// The folder as the stage shows it: `HomeRowPreviews.folder` (S6, the Home folder hero), or,
    /// for a folder with neither a backdrop nor a logo, `plainFolderPreview` (same id and type).
    private var folderPreview: MetaPreview? {
        guard let collection = model.collection, let folder = model.folder else { return nil }
        return HomeRowPreviews.folder(collection: collection, folder: folder)
            ?? FolderRowsPlan.plainFolderPreview(collection: collection, folder: folder)
    }

    /// First paint (S2): the folder at once, no fade. Stage art is the folder's `heroBackdropUrl`
    /// only (Wave H: the cover is not a stage fallback); the wash gets the cover as its fallback, so
    /// a backdrop-less folder still washes in its own colours.
    private func seedStage() {
        guard let preview = folderPreview else { return }
        stage.seed(preview, washFallback: FolderRowsPlan.nonBlank(model.folder?.coverImageUrl))
    }

    /// Q1, through `FolderStageInput.step`: until the first move the stage keeps the folder (the
    /// initial landing and focus leaving a row are not moves); from the first move on, every report
    /// goes to P1's funnel (`StageController.report`), as on Home.
    private func cardReported(_ item: MetaPreview?, row: FolderStripRow, section: HomeCatalogSection) {
        let pageBox = box
        let card = item.map { FolderStageInput.cardKey(rowId: row.id, itemId: $0.id) }
        if card != nil {
            // Any card focus answers the initial-focus request (§2.3).
            pageBox.pendingInitialFocus = false
        }
        let before = FolderStageInput.State(initialCard: pageBox.initialCard, follows: followsFocus)
        let (after, forward) = FolderStageInput.step(before, report: card)
        pageBox.initialCard = after.initialCard
        if before.initialCard == nil, after.initialCard != nil {
            // The initial landing: warm this row's stage art, so the first move swaps on a warm cache.
            ArtworkStore.prefetch(section.items.prefix(8)
                .flatMap { heroBackdropPrefetchURLs(for: $0) }
                .compactMap(URL.init(string:)))
        }
        if after.follows != followsFocus {
            followsFocus = after.follows
            StageStripProbe.shared.log("folder follow from=\(before.initialCard ?? "-") to=\(card ?? "-")")
        }
        guard forward else { return }
        stage.report(item,
                     source: row.id,
                     logoCandidates: {
                         section.items.prefix(FolderRowsPlan.previewLimit)
                             .filter { TitleLogoStore.isLookupCandidate($0.logo) }
                     },
                     prefetch: { section.items.prefix(8).flatMap { heroBackdropPrefetchURLs(for: $0) } })
    }

    // MARK: Rail (P4 §2.5, R2)

    /// Where a rail exit puts focus back on this page. `capture` records the strip row only when the
    /// strip held focus at arm time (a Left from the Edit band captures nothing, so the exit lands on
    /// the page's default focus rather than pulling focus into the strip); `restore` asks the pager
    /// for that row's remembered card (`requestFocus(rowKey:itemId:)` moves the mounted window to the
    /// row first). Without this route a Right would land on default focus (the Edit band, or row 0)
    /// and the strip would page away from where the viewer was.
    private var folderRailRoute: RailReturnRoute {
        let controller = stage
        let pageBox = box
        return RailReturnRoute(
            name: "folder",
            capture: {
                pageBox.railSavedRow = pageBox.stripHasFocus ? controller.currentRowKey : nil
            },
            restore: {
                guard let row = pageBox.railSavedRow else { return false }
                controller.requestFocus(rowKey: row, itemId: controller.memory.itemId(for: row))
                return true
            },
            vetoesLeftArm: { false }
        )
    }

    // MARK: Focus (§2.3, §2.6)

    /// Once `FolderRowsPlan.initialFocusTarget` names a row while no card has had focus yet, put focus
    /// on its first card (S4; `itemId: nil` = the remembered card, else the first). The Edit band
    /// holds focus until then (BUG-47).
    private func requestInitialFocus(_ key: String?) {
        guard requestsInitialFocus, let key, box.pendingInitialFocus else { return }
        box.pendingInitialFocus = false
        let controller = stage
        // Next runloop turn: the pager installs its handle in its own `.onAppear`, which may run
        // after this page's first `onChange`.
        DispatchQueue.main.async {
            StageStripProbe.shared.log("folder initial focus row=\(key) pager=\(controller.pagerHandle.isInstalled ? 1 : 0)")
            if controller.pagerHandle.isInstalled {
                controller.requestFocus(rowKey: key, itemId: nil)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    controller.requestFocus(rowKey: key, itemId: nil)
                }
            }
        }
    }

    /// `StripPager.onRowChange`: a row took focus (or its index moved under rows inserted above it).
    private func rowChanged(key: String) {
        box.focusedRowKey = key
        box.stripHasFocus = true
        let rows = model.stripRows
        if let tab = rows.first(where: { $0.id == key })?.tabIndex, tab > (deepestFocusedTab ?? Int.min) {
            deepestFocusedTab = tab
        }
        refreshFocusDerived(rows: rows)
    }

    /// The Edit band gate (and the DEBUG readout) from the focused row's place among the focusable
    /// rows. No focused row, or a focused row that is no longer focusable (a reload), reads as the
    /// top, so the band is available as the page's anchor.
    private func refreshFocusDerived(rows: [FolderStripRow]) {
        let shownRows = FolderRowsPlan.visible(rows, focusedTabIndex: deepestFocusedTab)
        let position = box.focusedRowKey.flatMap { FolderRowsPlan.focusablePosition(of: $0, in: shownRows) }
        let atTop = (position ?? 0) == 0
        if rowsAtTop != atTop { rowsAtTop = atTop }
        #if DEBUG
        var tab: Int?
        if position != nil, let key = box.focusedRowKey {
            tab = rows.first(where: { $0.id == key })?.tabIndex
        }
        debug.set(row: position, tab: tab)
        #endif
    }
}

/// The page's report bookkeeping, in a reference box so a report writes no view state (only
/// `followsFocus`, once, and `deepestFocusedTab` when it grows).
@MainActor
final class FolderRowsPageBox {
    /// §2.3: cleared by the initial-focus request or by any card report.
    var pendingInitialFocus = true
    /// `FolderStageInput.State.initialCard`.
    var initialCard: String?
    /// The strip row that last took focus (kept while focus is on the Edit band).
    var focusedRowKey: String?
    /// H9: a strip row owns focus right now (set by `onRowChange`, cleared by `onStripFocusLost`).
    var stripHasFocus = false
    /// H9: the row the rail route returns to (captured when the rail arms; nil = default focus).
    var railSavedRow: String?
}

// MARK: - Folder logo (§2.5)

/// One persistent layer, always mounted, never removed or re-identified (Steven: "title always
/// visible"): the folder's title logo, or its name in `Theme.Font.hero` when it has none. Docked
/// in the stage's logo slot at full size until the first move, then risen to 60 % above the stage
/// block with the strip's page curve, and never re-docked (Q1).
private struct FolderStageLogoLayer: View {
    let title: String
    let logoUrl: String?
    let geometry: StripGeometry
    let docked: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let slot = geometry.logoSlot
        TitleLogoHeader(title: title,
                        logoUrl: logoUrl,
                        alignment: .topLeading,
                        textFont: Theme.Font.hero,
                        slotHeight: slot,
                        decodeSize: .points(width: Theme.Size.heroInfoPanelWidth, height: slot))
            // A long folder name wraps inside the slot instead of running into the meta line.
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.leading)
            .frame(width: Theme.Size.heroInfoPanelWidth, height: slot, alignment: .topLeading)
            .scaleEffect(docked ? 1 : FolderStageLogo.compactScale, anchor: .topLeading)
            .offset(y: FolderStageLogo.offsetY(docked: docked, blockTop: geometry.stageBlockTop, slot: slot))
            // The strip's page curve, so the rise and a Down's glide retune together.
            .animation(reduceMotion ? nil : .easeOut(duration: StageStripTuning.pageSeconds), value: docked)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("folder_stage_logo")
            .padding(.top, geometry.stageBlockTop)
            .padding(.leading, geometry.stageBlockLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
    }
}

// MARK: - Non-focusable rows (§2.3)

/// A row heading, as `CatalogRowView` draws it outside pinned Home.
private struct FolderRowHeading: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.sectionTitle)
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(1)
    }
}

/// A source still loading: its heading over skeleton cards at the row's card size, laid out like a
/// loaded row so its posters land where the real ones will. Nothing here is focusable.
private struct FolderLoadingRow: View {
    let heading: String
    @Environment(\.posterStyle) private var style

    var body: some View {
        let width = style.landscapeCatalogRows ? Theme.Size.landscapeWidth : style.width
        let height = style.landscapeCatalogRows ? Theme.Size.landscapeHeight : style.height
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            FolderRowHeading(text: heading)
            HStack(spacing: Theme.Spacing.rowGap) {
                ForEach(0..<FolderRowsPlan.skeletonCount, id: \.self) { _ in
                    ShimmerView()
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
                }
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A settled source with nothing to show: its heading and one line.
private struct FolderMessageRow: View {
    let heading: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            FolderRowHeading(text: heading)
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.vertical, Theme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - DEBUG readout (§2.8)

#if DEBUG
/// The strip's focused row and tab for `folder_rows_state`, written per hop and observed only by the
/// probe leaf. Write-on-change.
@MainActor
final class FolderRowsDebugState: ObservableObject {
    /// The focused row's index among the focusable rows (0 = the top row).
    @Published private(set) var row: Int?
    @Published private(set) var tab: Int?

    func set(row: Int?, tab: Int?) {
        if self.row != row { self.row = row }
        if self.tab != tab { self.tab = tab }
    }
}

/// `folder_rows_state mode=rows rows=<visible> removed=<n> row=<focusable index|-> tab=<tabIndex|->
/// docked=<0|1> disp=<displayed identity|-> state=<rows|loading|empty|failed>`. A LEAF: it observes
/// its own readout and the stage's debug readout (for `disp`), never the swap driver's output.
private struct FolderRowsProbeLabel: View {
    @ObservedObject var debug: FolderRowsDebugState
    @ObservedObject var stageDebug: StageDebugState
    let visibleCount: Int
    let removedCount: Int
    let docked: Bool
    let state: FolderRowsPlan.PageState

    var body: some View {
        let row = debug.row.map { String($0) } ?? "-"
        let tab = debug.tab.map { String($0) } ?? "-"
        Text(verbatim: "folder_rows_state mode=rows rows=\(visibleCount) removed=\(removedCount) row=\(row) tab=\(tab) docked=\(docked ? 1 : 0) disp=\(stageDebug.disp) state=\(state.token)")
            .font(.system(size: 8))
            .opacity(0.011)
            .accessibilityIdentifier("folder_rows_state")
            .allowsHitTesting(false)
    }
}
#endif
