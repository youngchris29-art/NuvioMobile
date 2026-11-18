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
/// - a filter bar, one row of menus: List, Type, Genre, Year, Show (the smart filters as one
///   choice), Sort, Refresh and Clear Filters (W5, upstream 2da28d707; the owner's layout pick B).
///   List and type are remembered per profile; the row scrolls sideways when it is wider than
///   the pane (provider libraries);
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
                    // Pre-cut follow-ups 2.2: the one bar-focus observer, on the always-mounted pane,
                    // so focus on the source chips is reported on the Cloud tab and in Saved's
                    // non-grid states too (the filter row is absent there). It only reports; nothing
                    // writes `barFocus` in response.
                    .onChange(of: barFocus, initial: true) { _, focus in model.barFocusChanged(focus) }
                    // The DEBUG probe moved here with the observer (every field kept). The bar's own
                    // geometry readers stay on the row; without the row its fields keep their last values.
                    .overlay(alignment: .topLeading) { barProbe }
                    // W5 probe: the pane's laid-out width inside the screen padding (writes only on change).
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        barGeometry.pane = Int($0.width.rounded())
                        barGeometry.paneGlobalMinX = Int($0.minX.rounded())
                    }
                    // The probe measures each bar control's frame in the pane's own space.
                    .coordinateSpace(.named(LibraryBarGeometry.paneSpace))
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

    /// Title, count line and source badge; for a provider library, the Refresh pill at the trailing
    /// end (W5, the owner's call: out of the filter row, so the row fits the pane at rest).
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text("Library")
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)

            if showsSavedChrome {
                countLine
                    .lineLimit(1)
                    .layoutPriority(1)
                    .modifier(LibraryHeaderProbe(enabled: LibraryDebugFlags.geometryProbe, geometry: $barGeometry, ideal: countLineIdeal))

                if model.showsProviderControls {
                    Spacer(minLength: Theme.Spacing.md)
                    // Batch D review r2 P2: the user-initiated pull for a provider library.
                    if model.isLoading { ProgressView() }
                    refreshPill
                }
            }
        }
        // One full-width focus section: Up from any pill of the filter row reaches Refresh (and a
        // second Up the tab bar), wherever the row has scrolled to.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    private var countLine: CountLine {
        CountLine(
            text: LibraryDebugFlags.countLineOverride ?? (model.content == .grid ? model.countLine : nil),
            badge: LibraryGridPolicy.sourceBadge(sourceModeName: model.sourceModeName),
            badgeAccessibilityLabel: model.providerName
        )
    }

    /// The count line at its ideal width, for the probe's truncation check.
    private var countLineIdeal: AnyView { AnyView(countLine.lineLimit(1).fixedSize()) }

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

        // W5: one `controls` for the grid and the no-matches state, so a pick that empties the grid
        // (a genre with the Show menu on Watched) keeps the bar mounted and focus on the pill;
        // two copies, one per case, remounted the bar and dropped focus to the tab bar.
        if model.content == .grid || model.content == .noMatches {
            controls
        }

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
            noMatchesState
        case .grid:
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
        // W5: one focus section as wide as the pane, so Down from a pill at the far end of the filter
        // row (Clear Filters, Sort) reaches a card even when the filtered grid is one short row.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    // MARK: - Filter bar (W5: List · Type · Genre · Year · Show · Sort · Refresh · Clear Filters)

    // Which menus draw is `LibraryBarResolver`'s call (published by the model).
    private var showsGenre: Bool { model.showsGenre }
    private var showsYear: Bool { model.showsYear }
    private var showsWatch: Bool { model.showsShow }

    /// One horizontal row of pills on the stock platter (today's height). In a provider library the
    /// row is wider than the pane and scrolls sideways; the focus engine scrolls the focused pill in.
    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.md) {
                if model.sections.count > 1 { listMenu }
                if model.showsType { typeMenu }
                if showsGenre { genreMenu }
                if showsYear { yearMenu }
                if showsWatch { watchMenu }
                if !model.availableSortOptions.isEmpty { sortMenu }
                if model.filtersActive { clearPill }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barGeometry.row1w = Int($0.rounded()) }
            .padding(.vertical, Theme.Spacing.xs)
        }
        // The stock Menu buttons lift on focus; don't crop the lift…
        .scrollClipDisabled()
        // …but clip at the pane's leading and trailing edges (W5: a scrolled pill drew under the
        // rail). The mask reaches well above and below the row, so the lift and its shadow stay.
        .mask { Rectangle().padding(.vertical, -LibraryBarGeometry.liftAllowance) }
        // Full width: the focus engine searches straight up and down.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            barGeometry.barGlobalMinY = Int($0.minY.rounded())
            barGeometry.barGlobalMaxY = Int($0.maxY.rounded())
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            barGeometry.row1 = Int($0.rounded())
            barGeometry.bar = Int($0.rounded())
        }
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
        .modifier(barControl(.genre))
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
        .modifier(barControl(.year))
    }

    /// The type menu: "All types (14)", "Movies (8)", … (counts under the chosen genre and year).
    private var typeMenu: some View {
        PillMenu(
            title: model.selectedType.map(LibraryGridPolicy.typeLabel) ?? String(localized: "All types"),
            systemImage: "film.stack",
            selection: Binding(get: { model.selectedType ?? "" }, set: { model.selectType($0.isEmpty ? nil : $0) }),
            options: [""] + model.types.map(\.key),
            id: "library.typePicker",
            pickerTitle: String(localized: "Type"),
            label: { key in
                key.isEmpty ? LibraryGridPolicy.typeOptionLabel(nil, count: model.allTypesCount)
                    : LibraryGridPolicy.typeOptionLabel(key, count: model.types.first { $0.key == key }?.count ?? 0)
            },
            accessibilityName: String(localized: "Type"),
            accessibilityCurrentValue: model.selectedType.map(LibraryGridPolicy.typeLabel) ?? String(localized: "All types")
        )
        .modifier(barControl(.type))
    }

    /// The Show menu: the smart filters as one choice (All Titles / Unwatched / In Progress / Watched).
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
        .modifier(barControl(.watch))
    }

    private var clearPill: some View {
        PillButton(title: String(localized: "Clear Filters"), systemImage: "xmark.circle", id: "library.clearFilters") {
            model.clearFilters()
            // The pill goes with the filters; hand focus to a control that stays (Genre, Year,
            // Show, Type, else Sort: `LibraryBarKeep.focusAfterClear`).
            barFocus = model.focusAfterClear
        }
        .modifier(barControl(.clear))
    }

    /// A bar control's focus binding, plus (probe on) its laid-out frame in the pane's space.
    private func barControl(_ control: LibraryBarFocus) -> LibraryBarControl {
        LibraryBarControl(control: control, focus: $barFocus, geometry: $barGeometry)
    }

    @ViewBuilder
    private var barProbe: some View {
        #if DEBUG
        if LibraryDebugFlags.geometryProbe {
            let g = barGeometry
            let focused = barFocus.flatMap { g.frames[$0] }
            let widths = LibraryBarFocus.allCases.compactMap { c in g.frames[c].map { "\(c.rawValue):\($0.width)" } }
            Text(verbatim: "debug_library_bar pane=\(g.pane) pill=\(g.pill) row1=\(g.row1) row2=0 row1w=\(g.row1w) bar=\(g.bar) count=\(model.entries.count) content=\(LibraryBarGeometry.contentToken(model.content)) list=\(model.selectedSectionKey ?? "-") type=\(model.selectedType ?? "-") genre=\(model.selectedGenre ?? "-") year=\(model.selectedYear ?? "-") show=\(LibraryGridPolicy.watchChoice(for: model.activeSmartFilters).rawValue) focus=\(barFocus?.rawValue ?? "-") fminx=\(focused.map { "\($0.minX)" } ?? "-") fmaxx=\(focused.map { "\($0.maxX)" } ?? "-") panegx=\(g.paneGlobalMinX) bary=\(g.barGlobalMinY)-\(g.barGlobalMaxY) cminx=\(g.countMinX) cmaxx=\(g.countMaxX) cideal=\(g.countIdeal) hdry=\(g.headerGlobalMidY) writes=\(model.debugPickWrites) keep=\(model.barKeep.menu?.rawValue ?? "-") widths=\(widths.joined(separator: ","))")
                .font(.system(size: 8))
                .opacity(0.011)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug_library_bar")
        }
        #endif
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
        .modifier(barControl(.list))
    }

    private var refreshPill: some View {
        PillButton(title: String(localized: "Refresh"), systemImage: "arrow.clockwise", id: "library.refresh") {
            model.refresh()
        }
        .modifier(barControl(.refresh))
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
        .modifier(barControl(.sort))
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
                // This button goes with the no-matches state; focus lands on a bar control that stays.
                barFocus = model.focusAfterClear
            } label: {
                Label("Clear Filters", systemImage: "xmark.circle")
                    .font(Theme.Font.meta)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xs)
            }
            .buttonStyle(.chip)
            .accessibilityIdentifier("library.noMatches.clearFilters")
        }
        .padding(.top, Theme.Spacing.lg)
        // W5: one focus section as wide as the pane, so Down from any pill of the bar (the row
        // scrolls, so the focused pill can sit far right of this button) lands on Clear Filters.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
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
            // Pre-cut follow-ups 2.2: the chips are bar controls, so focus on one releases a kept menu.
            FilterChip(title: String(localized: "Saved"), isActive: !showingCloud) { showingCloud = false }
                .modifier(barControl(.savedChip))
            FilterChip(title: String(localized: "Debrid Cloud"), isActive: showingCloud) { showingCloud = true }
                .modifier(barControl(.cloudChip))
        }
        // One focus section as wide as the screen: the focus engine only searches straight up, so
        // without it Up from the Sort pill (or anything right of these two chips) found nothing.
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        // 2.3 (best-effort): entering the row lands on the active chip where tvOS honours this.
        // Nothing corrects focus if it does not (decision GB(b)).
        .defaultFocus($barFocus, showingCloud ? .cloudChip : .savedChip, priority: .userInitiated)
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

/// W5: the Library filter bar's controls, for focus (Clear Filters hands focus to one that stays)
/// and the DEBUG probe's `focus=` token and widths.
nonisolated enum LibraryBarFocus: String, Hashable, CaseIterable, Sendable {
    case list, type, genre, year, watch, sort, refresh, clear
    /// Pre-cut follow-ups 2.2: the Saved / Debrid Cloud source chips (no menu; focus on one
    /// releases a kept menu).
    case savedChip, cloudChip
}

/// W5: the filter bar's laid-out sizes for the DEBUG probe, whole points.
struct LibraryBarGeometry: Equatable {
    static let paneSpace = "libraryPane"

    /// How far the row's mask reaches above and below it, so a focused pill's lift and shadow are
    /// never cut (the mask only clips the pane's leading and trailing edges).
    static let liftAllowance: CGFloat = 60

    var pane = 0, pill = 0, row1 = 0, row1w = 0, bar = 0
    /// Screen positions, for the UI leg's pixel check of the clipped edges.
    var paneGlobalMinX = 0, barGlobalMinY = 0, barGlobalMaxY = 0, headerGlobalMidY = 0
    /// The header's count line: laid-out extent in the pane and its ideal (untruncated) width.
    var countMinX = 0, countMaxX = 0, countIdeal = 0
    /// Each control's laid-out frame in the pane's coordinate space (scroll offset included).
    var frames: [LibraryBarFocus: LibraryBarFrame] = [:]

    static func contentToken(_ content: LibraryGridPolicy.Content) -> String {
        switch content {
        case .loading: return "loading"
        case .failed: return "failed"
        case .empty: return "empty"
        case .noMatches: return "noMatches"
        case .grid: return "grid"
        }
    }
}

/// Whole-point horizontal extent of one bar control inside the pane.
nonisolated struct LibraryBarFrame: Equatable, Sendable {
    var minX: Int
    var maxX: Int
    var width: Int { maxX - minX }
}

/// Binds a bar control to the bar's focus state and, with the probe on, records its frame.
struct LibraryBarControl: ViewModifier {
    let control: LibraryBarFocus
    let focus: FocusState<LibraryBarFocus?>.Binding
    @Binding var geometry: LibraryBarGeometry

    func body(content: Content) -> some View {
        if LibraryDebugFlags.geometryProbe {
            content
                .focused(focus, equals: control)
                .onGeometryChange(for: LibraryBarFrame.self) { proxy in
                    let frame = proxy.frame(in: .named(LibraryBarGeometry.paneSpace))
                    return LibraryBarFrame(minX: Int(frame.minX.rounded()), maxX: Int(frame.maxX.rounded()))
                } action: { geometry.frames[control] = $0 }
        } else {
            content.focused(focus, equals: control)
        }
    }
}

/// W5: with the probe on, records the header count line's laid-out extent (pane space), its ideal
/// width (a hidden fixed-size copy) and the header's screen position.
struct LibraryHeaderProbe: ViewModifier {
    let enabled: Bool
    @Binding var geometry: LibraryBarGeometry
    let ideal: AnyView

    func body(content: Content) -> some View {
        if enabled {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LibraryBarGeometry.paneSpace)) } action: {
                    geometry.countMinX = Int($0.minX.rounded())
                    geometry.countMaxX = Int($0.maxX.rounded())
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: {
                    geometry.headerGlobalMidY = Int($0.rounded())
                }
                .background(alignment: .leading) {
                    ideal
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                            geometry.countIdeal = Int($0.rounded())
                        }
                }
        } else {
            content
        }
    }
}
