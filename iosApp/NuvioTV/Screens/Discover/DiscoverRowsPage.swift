import Combine
import SharedCore
import SwiftUI

// Search & Discover batch 2026-10-06 (O3 Stage Discover, plan A1–A4): Discover as a stage-and-strip
// page. The folder Rows page (`FolderRowsPage`, FEAT-43) is its template: the same layer stack and
// the same strip, minus the folder's own logo layer, its Q1 latch and its seed. The pure half (rows,
// visibility, initial focus, page states) is `StripRowsPlan` + `DiscoverRowsPlan`; the rows come from
// `DiscoverRowsViewModel`.
//
//     DiscoverRowsPage                       ZStack(.top)
//     ├─ ZStack(.topLeading), ignores the safe area
//     │  ├─ Theme background
//     │  ├─ AmbientWashLayer  "debug_wash_discover"    the blurred wash of the stage's title
//     │  ├─ StageView         "debug_stage_discover"   the focused title (seeded with row 0's first)
//     │  ├─ VStack
//     │  │  ├─ Color.clear  stageHeight              nothing focusable over the stage
//     │  │  └─ StripPager   stripHeight              one row per genre, `.id(selectionKey)`
//     │  └─ DEBUG probe leaf `discover_rows_state`
//     └─ DiscoverPillBand                             Type / Catalog / Grid, at the top while the
//                                                     strip rests on its top row (the folder band's
//                                                     place and gate)
//
// Remote (A3):
//
//     Down from a pill            strip row 0
//     Up from row 0               the band (the strip never consumes Up); Tabs: Up again → tab bar
//     Menu at row ≥ 1             row 0 (`menuPagesToTop: true`)
//     Menu at row 0 / the band    Own tab: Rail → open the rail (unless it holds focus), Tabs → the
//                                 system default; pushed from Search → pop
//     Right out of a Left rail    `.railReturnRoute` "discover": the strip row it left, else the band
//     Back from Detail / Grid     the same row and card (per-row memory; the cover lifts on appear)
//
// Hosting (A4): `.tab` = the Discover tab's root (`DiscoverTabRoot`, tab value 6): the rail's Hide
// While Browsing follows the strip's pages like Home's (`setScrolledDown(tab: 6, …)`) and the page
// root carries `.railMenuReveal()`. `.pushed` = Under Search: Search pushes `DiscoverRoute()` and
// owns the view model; Menu at the top pops back to Search's idle page and the rail writes nothing
// (Search already hides the rail by its own rule).
//
// No background trailer: only `StageStripHome` arms one, so a focused poster here plays its In Row
// preview when Trailers on Focus is on, whatever the Trailer Location (the folder page's call).
//
// Re-render rule (#5, BUG-126): the controller is held, never observed (it publishes nothing); the
// stage text, art and wash leaves observe their own sources; per-report bookkeeping lives in a
// reference box; the band gate (`rowsAtTop`) is written only when it changes; the DEBUG probe is a
// leaf over its own readout state.

/// Search's navigation value for the pushed stage Discover page (Under Search placement). `type`
/// is the Stremio type the entry tile stands for ("movie" / "series"); nil keeps the selection.
struct DiscoverRoute: Hashable {
    var type: String? = nil
}

/// Where the page is mounted (A4).
enum DiscoverHost {
    /// The Discover tab's root (`DiscoverTabRoot`).
    case tab
    /// Pushed from Search's idle page (`DiscoverRoute`).
    case pushed

    /// The Discover tab's `TabView` value (A6: after Search; Profile stays 5).
    static let tabValue = 6
}

/// See the file header.
struct DiscoverRowsPage: View {
    @ObservedObject var model: DiscoverRowsViewModel
    let host: DiscoverHost
    /// Pushed: the entry tile's type (`DiscoverRoute.type`), selected once on first appear.
    let routeType: String?
    /// Pushes the Grid pill's (and nothing else's) `CatalogRoute` on the host's stack.
    let onOpenGrid: (CatalogRoute) -> Void

    /// Held for its lifetime, never observed: it publishes nothing (#5).
    @StateObject private var stage = StageController()
    /// Report bookkeeping that never drives rendering.
    @State private var box = DiscoverRowsPageBox()
    /// Initial focus stops waiting for an earlier row still loading (`initialFocusWaitLimit`).
    @State private var initialFocusWaitOver = false
    /// The band's gate: the strip's focused row is its top row, or no row has had focus yet.
    /// Written only when it changes, so the page re-renders at the crossing, never per hop.
    @State private var rowsAtTop = true
    /// The deepest row `order` the strip has had focus on in this selection. It feeds
    /// `StripRowsPlan.visible` in place of the current row, so an empty or failed row the strip has
    /// gone past stays: rows are never removed between the viewer and the row a glide heads to.
    /// The same `order` values the rows carry (`DiscoverRowSpec.order`).
    @State private var deepestFocusedOrder: Int?

    /// R1: the rail's content shift (36 with the rail Always Visible, from `.railTabRoot`; else 0).
    @Environment(\.railLeadingInset) private var railLeadingInset
    @Environment(\.posterStyle) private var posterStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    /// Held, never observed: read at Menu-press time and in the page-start write only.
    @Environment(\.navigationChrome) private var navigationChrome
    @AppStorage("no_zoom_on_focus") private var noZoomOnFocus = false

    init(model: DiscoverRowsViewModel,
         host: DiscoverHost,
         routeType: String? = nil,
         onOpenGrid: @escaping (CatalogRoute) -> Void) {
        self.model = model
        self.host = host
        self.routeType = routeType
        self.onOpenGrid = onOpenGrid
    }

    var body: some View {
        ZStack(alignment: .top) {
            stageStack
            // A2: outside the stage stack's safe-area escape, so it sits where the folder page's
            // Edit band sits (the safe area's top + `FolderHeaderGeometry.restTop`).
            DiscoverPillBand(model: model,
                             isActive: rowsAtTop,
                             gridSection: { [box] in model.gridSection(focusedRowKey: box.focusedRowKey) },
                             onOpenGrid: onOpenGrid)
        }
        .modifier(DiscoverMenuRevealModifier(enabled: host == .tab))
    }

    private var stageStack: some View {
        let geo = geometry
        let allRows = model.stripRows
        let shownRows = StripRowsPlan.visible(allRows, focusedOrder: deepestFocusedOrder)
        let state = StripRowsPlan.pageState(allRows, allSettled: model.allSettled)
        return ZStack(alignment: .topLeading) {
            Theme.Palette.background
                .ignoresSafeArea()
            // The wash observes the swap driver's wash feed itself, so this page never re-renders on
            // a swap; switched off, it draws nothing and the background shows through.
            AmbientWashLayer(feed: stage.swap.washFeed, probeID: "debug_wash_discover")
            StageView(controller: stage,
                      geometry: geo,
                      hidesLogoWhenDisplaying: nil,
                      probeID: "debug_stage_discover")
            VStack(spacing: 0) {
                // The stage block's place: nothing focusable lives here, so Up from the top row
                // goes straight to the band.
                Color.clear
                    .frame(height: geo.stageHeight)
                    .allowsHitTesting(false)
                stripArea(state: state, rows: shownRows, geometry: geo)
                    .frame(height: geo.stripHeight)
            }
            #if DEBUG
            DiscoverRowsProbeLabel(debug: model.debug,
                                   stageDebug: stage.swap.debug,
                                   visibleCount: shownRows.count,
                                   removedCount: allRows.count - shownRows.count,
                                   state: stateToken(state),
                                   type: model.selectedType ?? "-",
                                   catalog: model.selectedCatalogKey ?? "-",
                                   loaded: model.loadedCount)
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
                DispatchQueue.main.asyncAfter(deadline: .now() + StripRowsPlan.initialFocusWaitLimit) {
                    initialFocusWaitOver = true
                }
            }
            // A pop back from Detail or the grid lifts the cover (P1 §4.3's push rule).
            stage.setCovered(false, restoresFocus: true)
            // The pushed host's view model belongs to Search; the tab root starts its own.
            if host == .pushed { model.start() }
            applyRouteType()
            seedStage()
        }
        .onDisappear {
            stage.setCovered(true, restoresFocus: true)
            if host == .pushed { model.stop() }
        }
        // R2 (P4 §2.5, H9): the page's rail return route (Rail mode only).
        .railReturnRoute { discoverRailRoute }
        // First paint: row 0's first item, like Home's seed (§4.3). After a selection change, the
        // new row 0's first item, so the stage follows the pick while focus stays on the pill.
        .onChange(of: seedSignature, initial: true) { _, _ in
            seedStage()
        }
        // Initial focus: the first loaded row's first card, waiting for a row above it still
        // loading (`StripRowsPlan.initialFocusTarget`).
        .onChange(of: StripRowsPlan.initialFocusTarget(shownRows, waitOver: initialFocusWaitOver)?.id,
                  initial: true) { _, key in
            requestInitialFocus(key)
        }
        .onChange(of: allRows) { _, rows in
            stage.memory.prune(keeping: Set(rows.map(\.id)))
            refreshFocusDerived(rows: rows)
        }
        .onChange(of: model.selectionKey) { old, _ in
            selectionChanged(from: old)
        }
        // The entry tile's type, once the add-on options have arrived (a first push can land
        // before the watcher's first value).
        .onChange(of: model.typeOptions) { _, _ in
            applyRouteType()
        }
        .onChange(of: reduceMotion) { _, motion in
            stage.swap.setReduceMotion(motion)
        }
    }

    // MARK: Geometry

    /// The same inputs as Home, so the stage block sits exactly where Home's does.
    private var geometry: StripGeometry {
        StripGeometry.make(.live(style: posterStyle, noZoom: noZoomOnFocus, leadingInset: railLeadingInset))
    }

    // MARK: Strip

    @ViewBuilder
    private func stripArea(state: StripRowsPlan.PageState,
                           rows: [StripRow],
                           geometry geo: StripGeometry) -> some View {
        if model.selectionKey.isEmpty {
            // No selection: the add-ons are loading, or none of them can browse.
            statePanel(geometry: geo) { sourcesPanel }
        } else {
            switch state {
            case .empty:
                statePanel(geometry: geo) { emptyPanel }
            case .failed:
                statePanel(geometry: geo) { failedPanel }
            case .rows, .loading:
                if rows.isEmpty {
                    statePanel(geometry: geo) { loadingPanel }
                } else {
                    StripPager(rowKeys: rows.map(\.id),
                               geometry: geo,
                               controller: stage,
                               // #9: link the tab bar, so in Tabs mode a rest never leaves it half
                               // shown (the BUG-66 class).
                               linksTabBar: true,
                               // No probe mirror: this page has its own readout.
                               reportsTab: nil,
                               // A3: Menu at row ≥ 1 pages to row 0; at row 0 the host's exit.
                               menuPagesToTop: true,
                               atTopExit: atTopExit,
                               onRowChange: { _, key in
                                   rowChanged(key: key)
                               },
                               onPageStart: { index, seconds in
                                   pageStarted(index: index, seconds: seconds)
                               },
                               onStripFocusLost: {
                                   box.stripHasFocus = false
                                   stage.stripFocusLost()
                                   #if DEBUG
                                   model.debug.setStrip(false)
                                   #endif
                               }) { key in
                        rowView(key, rows: rows)
                    }
                    // A selection change remounts the pager (window at row 0, handle reinstalled)
                    // instead of trusting `rowKeysChanged` with a position id that vanished.
                    .id(model.selectionKey)
                    // #23: a synced Poster Size too tall for the stage's floor lays out at the
                    // largest height that fits, as on Home.
                    .environment(\.posterStyle, geo.fits ? posterStyle : posterStyle.withHeight(geo.layoutPosterHeight))
                    // A1: genre headings name their add-on ("Sci-Fi · Cinemeta"), as Stage Home's
                    // catalog headings do.
                    .environment(\.rowHeadingShowsAddon, true)
                }
            }
        }
    }

    /// One strip row. A loaded row is focusable; a failed row's Retry chip is too (and reports the
    /// row like a card would); loading and empty rows are a heading over a skeleton or a line.
    @ViewBuilder
    private func rowView(_ key: String, rows: [StripRow]) -> some View {
        if let row = rows.first(where: { $0.id == key }) {
            switch row.status {
            case .loaded:
                if let section = row.section {
                    CatalogRowView(
                        section: section,
                        previewLimit: StripRowsPlan.previewLimit,
                        onItemFocusChange: { item in
                            cardReported(item, row: row, section: section)
                        }
                    )
                }
            case .loading:
                // The strip mounts the rows around the focused one (`StripMountWindow`): a mounted
                // loading row is the lazy-load trigger.
                StripLoadingRow(heading: row.heading)
                    .onAppear { model.rowAppeared(key) }
            case .failed:
                DiscoverFailedRow(rowKey: row.id, heading: row.heading) {
                    model.retry(row.id)
                }
            case .empty:
                StripMessageRow(heading: row.heading, message: "Nothing here yet.")
            }
        }
    }

    /// Page states, left-aligned at the top of the strip area.
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

    /// Settled with nothing to show. The band stays the focus anchor (BUG-47); pushed, Go Back too.
    private var emptyPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Nothing here yet.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            if host == .pushed {
                Button("Go Back") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// Every row of the selection failed.
    private var failedPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Couldn't load Discover.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: Theme.Spacing.md) {
                Button("Try Again") { model.retryAll() }
                    .buttonStyle(.bordered)
                if host == .pushed {
                    Button("Go Back") { dismiss() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    /// No selection: Search's Discover copy for each reason. A panel with no button has the band
    /// hidden too (no type to pick), so the tab bar / rail keeps focus, as Search's empty Discover did.
    @ViewBuilder
    private var sourcesPanel: some View {
        switch model.sourcesState {
        case .waiting, .ready:
            loadingPanel
        case .noAddons:
            sourcesMessage(String(localized: "Install and enable an add-on to browse its catalogs."))
        case .noCatalogs:
            sourcesMessage(String(localized: "Your add-ons don't expose browsable catalogs."))
        case .manifestFailure(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Couldn't load your add-ons.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.accent)
                Text(message)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(2)
                HStack(spacing: Theme.Spacing.md) {
                    Button {
                        model.retryAll()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(Theme.Font.meta)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.xs)
                    }
                    .buttonStyle(.chip)
                    if host == .pushed {
                        Button("Go Back") { dismiss() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func sourcesMessage(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text(text)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            if host == .pushed {
                Button("Go Back") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func stateToken(_ state: StripRowsPlan.PageState) -> String {
        model.selectionKey.isEmpty ? model.sourcesState.token : state.token
    }

    // MARK: Stage

    /// The stage's first title: the first loaded row's first item. Keyed on the selection too, so
    /// a new selection whose row 0 opens on the same title still counts as new.
    private var seedSignature: String {
        guard let item = StripRowsPlan.firstFocusable(model.stripRows)?.section?.items.first else {
            return "\(model.selectionKey)|-"
        }
        return "\(model.selectionKey)|\(item.type):\(item.id)"
    }

    /// Before the first real commit, a silent seed (Home's §4.3 rule). After it `seed` is a no-op,
    /// so a Type or Catalog change forwards the new row 0's first item as a report instead, while
    /// focus is on the band (a strip that holds focus reports its own cards). Each signature is
    /// acted on once, so a pop back from Detail never re-seeds over the restored card.
    private func seedStage() {
        let signature = seedSignature
        guard signature != box.seededSignature,
              let row = StripRowsPlan.firstFocusable(model.stripRows),
              let section = row.section,
              let item = section.items.first else { return }
        box.seededSignature = signature
        if !stage.hasCommitted {
            stage.seed(item)
        } else if !box.stripHasFocus {
            stage.report(item,
                         source: row.id,
                         logoCandidates: {
                             section.items.prefix(StripRowsPlan.previewLimit)
                                 .filter { TitleLogoStore.isLookupCandidate($0.logo) }
                         },
                         prefetch: { section.items.prefix(8).flatMap { heroBackdropPrefetchURLs(for: $0) } })
        }
    }

    /// Every card report goes to P1's funnel (`StageController.report`), as on Home.
    private func cardReported(_ item: MetaPreview?, row: StripRow, section: HomeCatalogSection) {
        if item != nil {
            // Any card focus answers the initial-focus request.
            box.pendingInitialFocus = false
            box.cardFocused = true
        }
        stage.report(item,
                     source: row.id,
                     logoCandidates: {
                         section.items.prefix(StripRowsPlan.previewLimit)
                             .filter { TitleLogoStore.isLookupCandidate($0.logo) }
                     },
                     prefetch: { section.items.prefix(8).flatMap { heroBackdropPrefetchURLs(for: $0) } })
    }

    // MARK: Chrome (A3, A4)

    /// Menu at row 0 (and the strip's handler is the only one installed there): the Own tab opens
    /// the rail in Rail mode (`StageStripHome.atTopExit`, verbatim) and is the system default in
    /// Tabs mode; pushed from Search, it pops back to Search.
    private var atTopExit: (() -> Void)? {
        switch host {
        case .tab:
            guard NavigationChrome.isRail() else { return nil }
            let chrome = navigationChrome
            return {
                // Read at press time, not as a body dependency.
                guard !chrome.isFocusedChrome else { return }
                chrome.requestReveal(.menu)
            }
        case .pushed:
            let pop = dismiss
            return { pop() }
        }
    }

    /// Rail Hide While Browsing (H9, #8): the Own tab's rail moves with the strip's page, like
    /// Home's. Pushed, nothing is written (Search's own rail rule applies).
    private func pageStarted(index: Int, seconds: TimeInterval) {
        guard host == .tab, NavigationChrome.isRail() else { return }
        navigationChrome.setScrolledDown(tab: DiscoverHost.tabValue, index > 0, motion: .page(seconds: seconds))
    }

    /// Where a rail exit puts focus back on this page. A Left from a strip row captures that row
    /// (the exit goes back to its remembered card); a Left from the band captures nothing, so the
    /// exit lands on default focus (the band) rather than pulling focus into the strip. A rail
    /// hand-off with no capture on this page (a tab switch to Discover through the rail) lands on
    /// the row the strip last owned, else the first row with posters, else the default.
    private var discoverRailRoute: RailReturnRoute {
        let controller = stage
        let pageBox = box
        let rowsModel = model
        return RailReturnRoute(
            name: "discover",
            capture: {
                pageBox.railCaptured = true
                pageBox.railSavedRow = pageBox.stripHasFocus ? controller.currentRowKey : nil
            },
            restore: {
                let captured = pageBox.railCaptured
                pageBox.railCaptured = false
                if captured {
                    guard let row = pageBox.railSavedRow else { return false }
                    controller.requestFocus(rowKey: row, itemId: controller.memory.itemId(for: row))
                    return true
                }
                let live = controller.currentRowKey.flatMap { key in
                    rowsModel.stripRows.contains { $0.id == key && $0.isFocusable } ? key : nil
                }
                guard let row = live ?? StripRowsPlan.firstFocusable(rowsModel.stripRows)?.id else { return false }
                pageBox.pendingInitialFocus = false
                controller.requestFocus(rowKey: row, itemId: controller.memory.itemId(for: row))
                return true
            },
            vetoesLeftArm: { false }
        )
    }

    // MARK: Focus

    /// Pushed from Search: once `initialFocusTarget` names a row while no card has had focus yet,
    /// put focus on its first card (the band holds focus until then, BUG-47). The tab host makes
    /// no such request: its focus arrives from the tab bar (Down, the system's pick) or from the
    /// rail (the return route above), and a request there would pull focus out of the tab bar.
    private func requestInitialFocus(_ key: String?) {
        guard host == .pushed, let key, box.pendingInitialFocus else { return }
        box.pendingInitialFocus = false
        let controller = stage
        // Next runloop turn: the pager installs its handle in its own `.onAppear`, which may run
        // after this page's first `onChange`.
        DispatchQueue.main.async {
            StageStripProbe.shared.log("discover initial focus row=\(key) pager=\(controller.pagerHandle.isInstalled ? 1 : 0)")
            if controller.pagerHandle.isInstalled {
                controller.requestFocus(rowKey: key, itemId: nil)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    controller.requestFocus(rowKey: key, itemId: nil)
                }
            }
        }
    }

    /// P2-5: the pushed page opens on the entry tile's type. Applied once per push, as soon as the
    /// type options name it; a type the add-ons don't offer leaves the selection alone. Runs before
    /// any card has focus, so the selection change it causes keeps the initial-focus request
    /// armed (`selectionChanged`).
    private func applyRouteType() {
        guard host == .pushed, let type = routeType, !box.routeTypeApplied else { return }
        let types = model.typeOptions
        guard !types.isEmpty else { return }
        box.routeTypeApplied = true
        guard types.contains(type), model.selectedType != type else { return }
        box.routeSelecting = true
        model.select(type: type)
        // No catalog for it after all: no selection change will come to clear the flag.
        if model.selectedType != type { box.routeSelecting = false }
    }

    /// A Type or Catalog pick: the new rows start from the top with focus on the band. The pager
    /// remounts on its own (`.id(selectionKey)`).
    ///
    /// Two selection changes are not picks and keep the pushed page's initial-focus request armed
    /// while no card has had focus yet: the FIRST selection (`old` empty: the view model's sources
    /// arrived after the push, `[Discover] select … reason=sources`) and the route's own type
    /// (`applyRouteType`). Gate 2 bug 2: the first one used to disarm the request, so a fresh
    /// push landed focus only if the focus engine happened to pick a card by itself; when it
    /// didn't (focus → nil while the rows loaded), the page sat with no focus at all.
    private func selectionChanged(from old: String) {
        // `cardFocused`, not `pendingInitialFocus`: a request already spent on the old selection's
        // row (which the remount just threw away) is re-armed too.
        let keepsInitialFocus = host == .pushed && !box.cardFocused && (old.isEmpty || box.routeSelecting)
        box.routeSelecting = false
        deepestFocusedOrder = nil
        box.focusedRowKey = nil
        box.stripHasFocus = false
        box.railSavedRow = nil
        box.pendingInitialFocus = keepsInitialFocus
        // The old selection's row keys mean nothing to the new pager (a rail restore would ask it
        // for a row it doesn't have).
        stage.currentRowKey = nil
        if !rowsAtTop { rowsAtTop = true }
        if host == .tab, NavigationChrome.isRail() {
            navigationChrome.setScrolledDown(tab: DiscoverHost.tabValue, false)
        }
        #if DEBUG
        model.debug.set(row: nil, order: nil)
        model.debug.setStrip(false)
        #endif
    }

    /// `StripPager.onRowChange`: a row took focus (or its index moved under rows inserted above it).
    private func rowChanged(key: String) {
        box.focusedRowKey = key
        box.stripHasFocus = true
        #if DEBUG
        model.debug.setStrip(true)
        #endif
        let rows = model.stripRows
        if let order = rows.first(where: { $0.id == key })?.order, order > (deepestFocusedOrder ?? Int.min) {
            deepestFocusedOrder = order
        }
        refreshFocusDerived(rows: rows)
    }

    /// The band gate (and the DEBUG readout) from the focused row's place among the rows the viewer
    /// can land on. No focused row, or one that is no longer one of them (a reload), reads as the
    /// top, so the band is available as the page's anchor. The gate only CLOSES while a strip row
    /// holds focus (the folder page's review r1 B P2-2: with focus on the band, a row above becoming
    /// focusable must not hide the band under the Menu that holds focus).
    private func refreshFocusDerived(rows: [StripRow]) {
        let shownRows = StripRowsPlan.visible(rows, focusedOrder: deepestFocusedOrder)
        let position = box.focusedRowKey.flatMap { DiscoverRowsPlan.focusPosition(of: $0, in: shownRows) }
        let atTop = (position ?? 0) == 0
        if rowsAtTop != atTop, atTop || box.stripHasFocus { rowsAtTop = atTop }
        #if DEBUG
        var order: Int?
        if position != nil, let key = box.focusedRowKey {
            order = rows.first(where: { $0.id == key })?.order
        }
        model.debug.set(row: position, order: order)
        #endif
    }
}

/// The page's report bookkeeping, in a reference box so a report writes no view state.
@MainActor
final class DiscoverRowsPageBox {
    /// Cleared by the initial-focus request or by any card report.
    var pendingInitialFocus = true
    /// The strip row that last took focus (kept while focus is on the band).
    var focusedRowKey: String?
    /// A strip row owns focus right now (set by `onRowChange`, cleared by `onStripFocusLost`).
    var stripHasFocus = false
    /// The row the rail route returns to (captured when the rail arms; nil = default focus).
    var railSavedRow: String?
    /// The rail armed from this page (`capture` ran) and its `restore` hasn't yet.
    var railCaptured = false
    /// The last `seedSignature` the stage was seeded or reported for.
    var seededSignature: String?
    /// A card on this page has had focus (any row, any selection).
    var cardFocused = false
    /// Pushed: the route's type has been looked at (applied or found absent).
    var routeTypeApplied = false
    /// Pushed: the selection change in flight is the route's own, not a pill pick.
    var routeSelecting = false
}

/// `.railMenuReveal()` for the tab host only (a pushed page pops on Menu, the system default).
private struct DiscoverMenuRevealModifier: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.railMenuReveal()
        } else {
            content
        }
    }
}

// MARK: - Failed row

/// A settled row whose page failed: its heading, one line and a Retry chip. The chip takes focus,
/// so the row reports focus ownership to the strip like a card row does (`\.pinnedRowFocusOwnership`)
/// and the pager pages to it and back. It reports the release when it leaves (Retry swaps it for a
/// loading row while the chip holds focus; a row that never reports `false` would keep the pager
/// from ever seeing focus leave the strip). Only shown above the deepest focused row
/// (`StripRowsPlan.visible`).
private struct DiscoverFailedRow: View {
    let rowKey: String
    let heading: String
    let onRetry: () -> Void

    @Environment(\.pinnedRowFocusOwnership) private var ownership
    @FocusState private var chipFocused: Bool
    @State private var owns = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            StripRowHeading(text: heading)
            HStack(spacing: Theme.Spacing.lg) {
                Text("Couldn't load this source.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .buttonStyle(.chip)
                .focused($chipFocused)
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .onChange(of: chipFocused) { _, focused in
            guard owns != focused else { return }
            owns = focused
            ownership.report(rowKey, focused)
        }
        .onDisappear {
            guard owns else { return }
            owns = false
            ownership.report(rowKey, false)
        }
    }
}

// MARK: - DEBUG readout

#if DEBUG
/// `discover_rows_state mode=rows rows=<visible> removed=<n> row=<focusable index|-> order=<order|->
/// disp=<displayed identity|-> state=<rows|loading|empty|failed|waiting|noaddons|nocatalogs|
/// manifestfailure> type=<type|-> catalog=<catalog key|-> loaded=<n> inflight=<n> strip=<0|1>`.
/// A LEAF: it observes the view model's debug readout and the stage's (for `disp`), never the swap
/// driver's output.
private struct DiscoverRowsProbeLabel: View {
    @ObservedObject var debug: DiscoverRowsDebugState
    @ObservedObject var stageDebug: StageDebugState
    let visibleCount: Int
    let removedCount: Int
    let state: String
    let type: String
    let catalog: String
    let loaded: Int

    var body: some View {
        let row = debug.row.map { String($0) } ?? "-"
        let order = debug.order.map { String($0) } ?? "-"
        Text(verbatim: "discover_rows_state mode=rows rows=\(visibleCount) removed=\(removedCount) row=\(row) order=\(order) disp=\(stageDebug.disp) state=\(state) type=\(type) catalog=\(catalog) loaded=\(loaded) inflight=\(debug.inFlight) strip=\(debug.strip ? 1 : 0)")
            .font(.system(size: 8))
            .opacity(0.011)
            .accessibilityIdentifier("discover_rows_state")
            .allowsHitTesting(false)
    }
}
#endif
