import SwiftUI
import SharedCore

/// The Library tab: the titles saved in the active library (the local Nuvio library, or the
/// Trakt / Simkl / MDBList library picked in Settings), plus — when a debrid provider with cloud
/// support is connected — a "Debrid Cloud" source listing the provider's cloud files for direct
/// playback.
///
/// Library L1 (2026-10-04, `docs/library-l1-grid-plan-2026-10-04.md` in the outer repo):
/// - header: title, a count line ("31 movies · 17 series") and a source badge (TRAKT / SIMKL /
///   MDBLIST);
/// - a filter bar: List, type, Sort and Refresh in the first row; Genre, Year, the smart filters
///   and Clear Filters in the second (W5, upstream 2da28d707). List and type are remembered per
///   profile. (Until the layout pick, `-debug.libraryBarLayout B` draws the one-row alternative.)
/// - cards with a watched tick or a progress bar (`PosterCard.watchBadge`);
/// - a hold menu with Mark as Watched / Unwatched and a list-aware Remove;
/// - real loading, failed (with Retry), empty and no-match states.
///
/// FEAT-89 (2026-10-30): with a Trakt or Simkl account connected, "Resume Watching" and a merged
/// "Watchlist" row sit above the controls in the Saved view (`LibraryProviderRowsView`).
struct LibraryView: View {
    @StateObject private var model = LibraryViewModel()
    @StateObject private var cloud = CloudLibraryViewModel()
    @StateObject private var providerRows = LibraryProviderRowsModel()
    /// FEAT-89: the Resume Watching card's stream picker, as Home's `resume`.
    @State private var resume: ResumeTarget?
    /// A title picked on the player's end screen, pushed once the picker cover is gone (Home's
    /// `homePostPlayPending`).
    @State private var postPlayPending: MetaPreview?
    /// Path-bound so Resume Watching › Go to Details can push; the grid's links append to it.
    @State private var path = NavigationPath()
    /// Home's Continue Watching Remove / Mark Episode Watched (they touch no Home state).
    @State private var cardActions = HomeRowActions()
    @Environment(\.posterStyle) private var posterStyle
    @State private var showingCloud = false
    @State private var filePicker: CloudFilePickerRoute?
    /// The filter bar's focus, so Clear Filters can hand focus to a pill that stays.
    @FocusState private var barFocus: LibraryBarFocus?
    /// DEBUG probe values (`-debug.libraryBarGeometry YES`), whole points.
    @State private var barGeometry = LibraryBarGeometry()
    private let barLayout = LibraryDebugFlags.barLayout

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: posterStyle.width + Theme.Spacing.rowGap),
            spacing: Theme.Spacing.rowGap
        )]
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        header

                        if cloud.hasConnectedProvider {
                            sourceChips
                        }

                        if showingCloud && cloud.hasConnectedProvider {
                            cloudContent
                        } else {
                            savedContent
                        }
                    }
                    // W5 probe: the pane's laid-out width inside the screen padding (writes only on change).
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                        barGeometry.pane = Int($0.rounded())
                    }
                    .padding(Theme.Spacing.screen)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollClipDisabled()
                .reportsScrollToTabBar(tab: "Library")
                // FEAT-30 / H9: Menu summons the rail in Rail mode (a second Menu, with focus in
                // the rail, exits as before). No modifier at all in tabs mode.
                .railMenuReveal()
            }
            // Simkl: leaving a status also clears the title's watched history and rating there, so
            // the hold menu's remove asks first (`LibraryRepository.removalNeedsConfirmation`).
            .alert(
                LibraryGridPolicy.removeConfirmationTitle(listTitle: model.pendingRemoval?.listTitle),
                isPresented: Binding(
                    get: { model.pendingRemoval != nil },
                    set: { if !$0 { model.cancelRemoval() } }
                ),
                presenting: model.pendingRemoval
            ) { removal in
                Button(String(localized: "Remove"), role: .destructive) {
                    model.confirmRemoval(removal)
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    model.cancelRemoval()
                }
            } message: { removal in
                Text(LibraryGridPolicy.removeConfirmationMessage(providerName: removal.providerName))
            }
            .navigationDestination(for: TitleRoute.self) { route in
                DetailView(preview: route.preview)
            }
            .navigationDestination(for: PersonRoute.self) { route in
                PersonDetailView(personId: route.id, personName: route.name)
            }
            .navigationDestination(for: EntityRoute.self) { route in
                EntityBrowseView(route: route)
            }
        }
        // A failed remove. The shared toast controller is a no-op on tvOS, so the screen says it.
        .alert(
            LibraryGridPolicy.removeFailedTitle(providerName: model.providerName),
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {
                model.actionError = nil
            }
        } message: {
            Text(model.actionError ?? "")
        }
        .onAppear {
            model.start()
            cloud.start()
            providerRows.start()
        }
        .onDisappear {
            model.stop()
            cloud.stop()
            providerRows.stop()
        }
        .fullScreenCover(item: $filePicker) { route in
            CloudFilePickerView(item: route.item) { file in
                cloud.play(item: route.item, file: file)
            }
        }
        .fullScreenCover(item: $cloud.playback) { ctx in
            // `.id` forces a fresh player per context (same rule as StreamPickerView).
            PlayerScreen(context: ctx)
                .ignoresSafeArea()
                .id(ctx.id)
        }
        // FEAT-89: a Resume Watching card opens the stream picker exactly as Home's Continue
        // Watching card does (same arguments as `HomeView`'s `resume` cover).
        .fullScreenCover(item: $resume, onDismiss: {
            guard let pick = postPlayPending else { return }
            postPlayPending = nil
            path.append(TitleRoute(preview: pick))
        }) { target in
            StreamPickerView(
                type: target.entry.parentMetaType,
                videoId: target.entry.videoId,
                title: target.entry.title,
                parentMetaId: target.entry.parentMetaId,
                season: target.entry.seasonNumber?.value,
                episode: target.entry.episodeNumber?.value,
                poster: target.entry.poster,
                background: { let b: String? = target.entry.background; return (b ?? "").isEmpty ? nil : b }(),
                episodeStill: { let still: String? = target.entry.episodeThumbnail; return (still ?? "").isEmpty ? nil : still }(),
                synopsis: { let d: String? = target.entry.pauseDescription; return (d ?? "").isEmpty ? nil : d }(),
                // The entry's saved title logo (blank counts as missing; the picker then reads the details record).
                logoUrl: { let logo: String? = target.entry.logo; return (logo ?? "").isEmpty ? nil : logo }(),
                forceManual: target.forceManual,
                startFromBeginning: target.startFromBeginning,
                resumePositionMs: target.entry.lastPositionMs > 0 ? target.entry.lastPositionMs : nil,
                resumeFraction: Double(target.entry.progressFraction),
                onOpenTitle: { postPlayPending = $0 }
            )
        }
    }

    // MARK: - Header

    private var showsSavedChrome: Bool {
        !(showingCloud && cloud.hasConnectedProvider)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text("Library")
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)

            if showsSavedChrome {
                CountLine(
                    text: model.content == .grid ? model.countLine : nil,
                    badge: LibraryGridPolicy.sourceBadge(sourceModeName: model.sourceModeName),
                    badgeAccessibilityLabel: model.providerName
                )
            }
        }
    }

    // MARK: - Saved library

    @ViewBuilder
    private var savedContent: some View {
        // FEAT-89: independent of the grid's state (a Trakt library still loading, a failed
        // MDBList source, an empty local library): drawn whenever they have cards.
        LibraryProviderRowsView(
            model: providerRows,
            onResume: { resume = $0 },
            onGoToDetails: { path.append(TitleRoute(preview: HomeRowPreviews.entry($0))) },
            cardActions: cardActions
        )

        switch model.content {
        case .loading:
            loadingState
        case .failed(let message):
            failedState(message: message)
        case .empty:
            // Every provider drops empty lists from its sections (Trakt, Simkl and MDBList alike),
            // so `.empty` only happens with no lists at all: there is nothing to switch to.
            messageState(
                systemImage: "books.vertical",
                title: LibraryGridPolicy.emptyTitle(providerName: model.providerName),
                message: LibraryGridPolicy.emptyMessage(providerName: model.providerName)
            )
        case .noMatches:
            controls
            noMatchesState
        case .grid:
            controls
            grid
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.xl) {
            ForEach(model.entries) { entry in
                NavigationLink(value: TitleRoute(preview: entry.item.toMetaPreview())) {
                    PosterCard(
                        title: entry.item.name,
                        imageURL: entry.item.poster,
                        fallbackImageURL: entry.item.rawPosterUrl,
                        watchBadge: PosterWatchBadge(isWatched: entry.state.isWatched, progress: entry.state.progress)
                    )
                }
                .cardFocusButtonStyle()
                .posterButtonShape()
                .libraryHoldMenu(preview: entry.item.toMetaPreview()) {
                    // Read once, when the menu is built: the label and the action name one list.
                    let listKey = model.selectedSectionKey
                    let listTitle = model.selectedSectionTitle
                    // Batch K: read-only MDBList lists (external, dynamic, liked) get no remove.
                    if model.selectedSectionAllowsRemove {
                        Button(role: .destructive) {
                            model.requestRemove(entry, listKey: listKey, listTitle: listTitle)
                        } label: {
                            Label(LibraryGridPolicy.removeLabel(listTitle: listTitle),
                                  systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Filter bar (W5: list · type · sort · refresh, then genre · year · watch filters)

    @ViewBuilder
    private var controls: some View {
        Group {
            switch barLayout {
            case .twoRows: twoRowBar
            case .oneRow: oneRowBar
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barGeometry.bar = Int($0.rounded()) }
        .overlay(alignment: .topLeading) { barProbe }
    }

    private var showsGenre: Bool { LibraryGridPolicy.showsFacet(model.genres, selected: model.selectedGenre) }
    private var showsYear: Bool { LibraryGridPolicy.showsFacet(model.years, selected: model.selectedYear) }
    /// Option A's second row draws only when it has a control.
    private var showsFilterRow: Bool {
        LibraryGridPolicy.showsFilterRow(showsGenre: showsGenre, showsYear: showsYear,
                                         smartFilters: model.visibleSmartFilters)
    }

    // Option A
    private var twoRowBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            barRow(measure: \.row1, width: \.row1w) {
                if model.sections.count > 1 { listMenu }
                if model.types.count > 1 {
                    FilterChip(title: String(localized: "All"), isActive: model.selectedType == nil, id: "library.type.all") {
                        model.selectType(nil)
                    }
                    ForEach(model.types, id: \.self) { type in
                        FilterChip(title: LibraryGridPolicy.typeLabel(type), isActive: model.selectedType == type,
                                   id: "library.type.\(type)") {
                            model.selectType(type)
                        }
                    }
                }
                if !model.availableSortOptions.isEmpty { sortMenu }
                if model.showsProviderControls {
                    // Batch D review r2 P2: the user-initiated pull for a provider library.
                    refreshPill
                    if model.isLoading { ProgressView() }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("libraryBar")).maxY } action: {
                barGeometry.row1MaxY = Int($0.rounded())
            }
            if showsFilterRow {
                barRow(measure: \.row2, width: \.row2w) {
                    if showsGenre { genreMenu }
                    if showsYear { yearMenu }
                    ForEach(model.visibleSmartFilters, id: \.self) { filter in
                        FilterChip(title: filter.title, isActive: model.activeSmartFilters.contains(filter),
                                   id: "library.smart.\(filter.rawValue)") {
                            model.toggleSmartFilter(filter)
                        }
                        .focused($barFocus, equals: .smart(filter))
                    }
                    if model.filtersActive { clearPill }
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("libraryBar")).minY } action: {
                    barGeometry.row2MinY = Int($0.rounded())
                }
            }
        }
        .coordinateSpace(.named("libraryBar"))
    }

    // Option B
    private var oneRowBar: some View {
        barRow(measure: \.row1, width: \.row1w) {
            if model.sections.count > 1 { listMenu }
            if model.types.count > 1 { typeMenu }
            if showsGenre { genreMenu }
            if showsYear { yearMenu }
            if !model.visibleSmartFilters.isEmpty || !model.activeSmartFilters.isEmpty { watchMenu }
            if !model.availableSortOptions.isEmpty { sortMenu }
            if model.showsProviderControls {
                refreshPill
                if model.isLoading { ProgressView() }
            }
            if model.filtersActive { clearPill }
        }
    }

    /// One bar row: a full-width horizontal scroll row and its own focus section, measured for the probe.
    private func barRow<Content: View>(
        measure height: WritableKeyPath<LibraryBarGeometry, Int>,
        width: WritableKeyPath<LibraryBarGeometry, Int>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.md) { content() }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barGeometry[keyPath: width] = Int($0.rounded()) }
                .padding(.vertical, Theme.Spacing.xs)
        }
        // The stock Menu buttons lift on focus; don't crop the lift.
        .scrollClipDisabled()
        // Full width: the focus engine searches straight up and down.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barGeometry[keyPath: height] = Int($0.rounded()) }
    }

    private var genreMenu: some View {
        let keys = model.genres.map(\.key)
        let labels = LibraryGridPolicy.genreLabels(keys)
        let counts = Dictionary(model.genres.map { ($0.key, $0.count) }, uniquingKeysWith: { first, _ in first })
        let selectedLabel = model.selectedGenre.map { labels[$0] ?? LibraryGridPolicy.genreLabel($0) }
        return PillMenu(
            title: LibraryGridPolicy.genrePillTitle(selectedLabel: selectedLabel),
            systemImage: model.selectedGenre == nil ? "theatermasks" : "theatermasks.fill",
            selection: Binding(get: { model.selectedGenre ?? "" }, set: { model.selectGenre($0.isEmpty ? nil : $0) }),
            options: [""] + keys,
            id: "library.genrePicker",
            pickerTitle: String(localized: "Genre"),
            label: { key in
                key.isEmpty ? String(localized: "All")
                    : LibraryGridPolicy.facetOptionLabel(labels[key] ?? key, count: counts[key] ?? 0)
            },
            accessibilityName: String(localized: "Genre"),
            accessibilityCurrentValue: LibraryGridPolicy.genreAccessibilityValue(selectedLabel: selectedLabel),
            optionAccessibilityLabel: { key in
                key.isEmpty ? String(localized: "All genres")
                    : LibraryGridPolicy.facetOptionAccessibilityLabel(labels[key] ?? key, count: counts[key] ?? 0)
            }
        )
        .focused($barFocus, equals: .genre)
    }

    private var yearMenu: some View {
        let keys = model.years.map(\.key)
        let counts = Dictionary(model.years.map { ($0.key, $0.count) }, uniquingKeysWith: { first, _ in first })
        return PillMenu(
            title: LibraryGridPolicy.yearPillTitle(selected: model.selectedYear),
            systemImage: "calendar",
            selection: Binding(get: { model.selectedYear ?? "" }, set: { model.selectYear($0.isEmpty ? nil : $0) }),
            options: [""] + keys,
            id: "library.yearPicker",
            pickerTitle: String(localized: "Year"),
            label: { key in
                key.isEmpty ? String(localized: "All") : LibraryGridPolicy.facetOptionLabel(key, count: counts[key] ?? 0)
            },
            accessibilityName: String(localized: "Year"),
            accessibilityCurrentValue: LibraryGridPolicy.yearAccessibilityValue(selected: model.selectedYear),
            optionAccessibilityLabel: { key in
                key.isEmpty ? String(localized: "All years")
                    : LibraryGridPolicy.facetOptionAccessibilityLabel(key, count: counts[key] ?? 0)
            }
        )
        .focused($barFocus, equals: .year)
    }

    // Option B only
    private var typeMenu: some View {
        PillMenu(
            title: model.selectedType.map(LibraryGridPolicy.typeLabel) ?? String(localized: "All types"),
            systemImage: "film.stack",
            selection: Binding(get: { model.selectedType ?? "" }, set: { model.selectType($0.isEmpty ? nil : $0) }),
            options: [""] + model.types,
            id: "library.typePicker",
            pickerTitle: String(localized: "Type"),
            label: { key in
                key.isEmpty ? LibraryGridPolicy.typeOptionLabel(nil, count: model.allTypesCount)
                    : LibraryGridPolicy.typeOptionLabel(key, count: model.typeCounts[key] ?? 0)
            },
            accessibilityName: String(localized: "Type"),
            accessibilityCurrentValue: model.selectedType.map(LibraryGridPolicy.typeLabel) ?? String(localized: "All types")
        )
    }

    // Option B only
    private var watchMenu: some View {
        let current = LibraryGridPolicy.watchChoice(for: model.activeSmartFilters)
        return PillMenu(
            title: current.title,
            systemImage: "eye",
            selection: Binding(get: { current }, set: { model.selectWatchChoice($0) }),
            options: LibraryGridPolicy.watchChoices(visible: model.visibleSmartFilters),
            id: "library.watchPicker",
            pickerTitle: String(localized: "Show"),
            label: { $0.title },
            accessibilityName: String(localized: "Show"),
            accessibilityCurrentValue: current.title
        )
        .focused($barFocus, equals: .watch)
    }

    private var clearPill: some View {
        PillButton(title: String(localized: "Clear Filters"), systemImage: "xmark.circle", id: "library.clearFilters") {
            model.clearFilters()
            // The pill goes with the filters; hand focus to a control that stays.
            barFocus = focusAfterClear()
        }
        .focused($barFocus, equals: .clear)
    }

    private func focusAfterClear() -> LibraryBarFocus? {
        if showsGenre { return .genre }
        if showsYear { return .year }
        if barLayout == .oneRow { return .watch }
        guard let first = model.visibleSmartFilters.first else { return nil }
        return .smart(first)
    }

    @ViewBuilder
    private var barProbe: some View {
        if LibraryDebugFlags.geometryProbe {
            let g = barGeometry
            // Row 2's numbers count only while Option A draws it (its callbacks stop when it goes).
            let row2Drawn = barLayout == .twoRows && showsFilterRow
            let row2 = row2Drawn ? g.row2 : 0
            let row2w = row2Drawn ? g.row2w : 0
            let gap = row2Drawn ? g.row2MinY - g.row1MaxY : 0
            Text(verbatim: "debug_library_bar layout=\(barLayout.rawValue) pane=\(g.pane) pill=\(g.pill) row1=\(g.row1) row2=\(row2) row1w=\(g.row1w) row2w=\(row2w) bar=\(g.bar) gap=\(gap) count=\(model.entries.count) genre=\(model.selectedGenre ?? "-") year=\(model.selectedYear ?? "-") focus=\(barFocus?.probeToken ?? "-")")
                .font(.system(size: 8))
                .opacity(0.011)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug_library_bar")
        }
    }

    /// The provider's lists (Trakt watchlist and lists, Simkl statuses, MDBList lists) as a native
    /// `Menu { Picker }`, the same control Settings uses for its choice rows.
    private var listMenu: some View {
        PillMenu(
            title: model.selectedSectionTitle ?? String(localized: "List"),
            systemImage: "list.bullet",
            selection: Binding(
                get: { model.selectedSectionKey ?? "" },
                set: { model.selectSection($0) }
            ),
            options: model.sections.map(\.type),
            id: "library.listPicker",
            pickerTitle: String(localized: "List"),
            label: { key in model.sections.first { $0.type == key }?.displayTitle ?? key },
            accessibilityName: String(localized: "List"),
            accessibilityCurrentValue: model.selectedSectionTitle ?? ""
        )
    }

    private var refreshPill: some View {
        PillButton(title: String(localized: "Refresh"), systemImage: "arrow.clockwise", id: "library.refresh") {
            model.refresh()
        }
    }

    private var sortMenu: some View {
        PillMenu(
            title: model.sortLabel(model.effectiveSortOption),
            systemImage: "arrow.up.arrow.down",
            selection: Binding(
                get: { model.effectiveSortOption },
                set: { model.setSort($0) }
            ),
            options: model.availableSortOptions,
            id: "library.sortPicker",
            pickerTitle: String(localized: "Sort"),
            label: { model.sortLabel($0) },
            accessibilityName: String(localized: "Sort"),
            accessibilityCurrentValue: model.sortLabel(model.effectiveSortOption)
        )
        // W5 probe: the stock Menu platter's laid-out height.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barGeometry.pill = Int($0.rounded()) }
    }

    // MARK: - States

    private var loadingState: some View {
        HStack(spacing: Theme.Spacing.md) {
            ProgressView()
            Text("Loading your library\u{2026}")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(.top, Theme.Spacing.lg)
    }

    /// Mobile's failed card: what failed, the provider's message, and Retry. Retry is the one
    /// focusable here, so focus lands on it.
    private func failedState(message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(LibraryGridPolicy.failedTitle(providerName: model.providerName))
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
            Button {
                model.retry()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(Theme.Font.meta)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xs)
            }
            .buttonStyle(.chip)
        }
        .padding(.top, Theme.Spacing.lg)
    }

    private var noMatchesState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(LibraryGridPolicy.noMatchesTitle)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Button {
                model.clearFilters()
            } label: {
                Label("Clear Filters", systemImage: "xmark.circle")
                    .font(Theme.Font.meta)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xs)
            }
            .buttonStyle(.chip)
        }
        .padding(.top, Theme.Spacing.lg)
    }

    private func messageState(systemImage: String, title: String, message: String?) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(Theme.Font.hero)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(title)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            if let message {
                Text(message)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.sectionGap)
    }

    // MARK: - Source switcher (Saved / Debrid Cloud)

    private var sourceChips: some View {
        HStack(spacing: Theme.Spacing.md) {
            FilterChip(title: String(localized: "Saved"), isActive: !showingCloud) { showingCloud = false }
            FilterChip(title: String(localized: "Debrid Cloud"), isActive: showingCloud) { showingCloud = true }
        }
        // One focus section as wide as the screen: the focus engine only searches straight up, so
        // without it Up from the Sort pill (or anything right of these two chips) found nothing.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    // MARK: - Debrid cloud content

    @ViewBuilder
    private var cloudContent: some View {
        if let error = cloud.errorMessage {
            Text(error)
                .font(Theme.Font.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: 1100, alignment: .leading)
        }

        HStack(spacing: Theme.Spacing.md) {
            Button {
                cloud.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(Theme.Font.meta)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xs)
            }
            .buttonStyle(.chip)
            if cloud.isRefreshing {
                ProgressView()
            }
        }
        // Full-width section, same as `sourceChips`: Down from "Debrid Cloud" reaches Refresh.
        .focusRow(alignment: .leading)

        ForEach(cloud.providers, id: \.providerId) { provider in
            CloudProviderSection(
                provider: provider,
                resolvingFileKey: cloud.resolvingFileKey
            ) { item in
                selectCloudItem(item)
            }
        }
    }

    private func selectCloudItem(_ item: CloudLibraryItem) {
        let files = item.playableFiles
        if files.count == 1, let file = files.first {
            cloud.play(item: item, file: file)
        } else if !files.isEmpty {
            filePicker = CloudFilePickerRoute(item: item)
        }
    }
}

/// W5: the Library filter bar's focusable controls that Clear Filters can hand focus to (and the
/// DEBUG probe reports).
enum LibraryBarFocus: Hashable {
    case genre, year, watch, clear
    case smart(LibraryGridPolicy.SmartFilter)

    var probeToken: String {
        switch self {
        case .genre: return "genre"
        case .year: return "year"
        case .watch: return "watch"
        case .clear: return "clear"
        case .smart(let filter): return "smart.\(filter.rawValue)"
        }
    }
}

/// W5: the filter bar's laid-out sizes for the DEBUG probe, whole points.
struct LibraryBarGeometry: Equatable {
    var pane = 0, pill = 0, row1 = 0, row2 = 0, row1w = 0, row2w = 0, bar = 0, row1MaxY = 0, row2MinY = 0
}
