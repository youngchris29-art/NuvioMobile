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
/// - one control row: a List pill (the provider's lists), type segments (only with more than one
///   type), a Sort pill, and the smart filters Unwatched / In Progress / Watched (only the ones
///   that would change the grid);
/// - cards with a watched tick or a progress bar (`PosterCard.watchBadge`);
/// - a hold menu with Mark as Watched / Unwatched and a list-aware Remove;
/// - real loading, failed (with Retry), empty and no-match states.
struct LibraryView: View {
    @StateObject private var model = LibraryViewModel()
    @StateObject private var cloud = CloudLibraryViewModel()
    @Environment(\.posterStyle) private var posterStyle
    @State private var showingCloud = false
    @State private var filePicker: CloudFilePickerRoute?

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: posterStyle.width + Theme.Spacing.rowGap),
            spacing: Theme.Spacing.rowGap
        )]
    }

    var body: some View {
        NavigationStack {
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
                    .padding(Theme.Spacing.screen)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollClipDisabled()
                .reportsScrollToTabBar(tab: "Library")
                // FEAT-30: Menu summons the sidebar in sidebar mode (a second Menu, with focus in
                // the sidebar, exits as before). No modifier at all in tabs mode.
                .sidebarMenuReveal()
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
        }
        .onDisappear {
            model.stop()
            cloud.stop()
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
                if model.content == .grid, !model.countLine.isEmpty {
                    Text(model.countLine)
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                if let badge = LibraryGridPolicy.sourceBadge(sourceModeName: model.sourceModeName) {
                    Text(badge)
                        .font(Theme.Font.caption)
                        .tracking(2)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .padding(.vertical, Theme.Spacing.xxs)
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                .stroke(Theme.Palette.textSecondary, lineWidth: 1)
                        }
                        .accessibilityLabel(Text(model.providerName ?? badge))
                }
            }
        }
    }

    // MARK: - Saved library

    @ViewBuilder
    private var savedContent: some View {
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

    // MARK: - Control row (List · type · Sort · smart filters)

    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.md) {
                if model.sections.count > 1 {
                    listMenu
                }
                if model.types.count > 1 {
                    sourceChip(String(localized: "All"), isActive: model.selectedType == nil) {
                        model.selectType(nil)
                    }
                    ForEach(model.types, id: \.self) { type in
                        sourceChip(LibraryGridPolicy.typeLabel(type), isActive: model.selectedType == type) {
                            model.selectType(type)
                        }
                    }
                }
                if !model.availableSortOptions.isEmpty {
                    sortMenu
                }
                ForEach(model.visibleSmartFilters, id: \.self) { filter in
                    sourceChip(filter.title, isActive: model.activeSmartFilters.contains(filter)) {
                        model.toggleSmartFilter(filter)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
        // The List and Sort pills are stock `Menu` buttons, which lift on focus; don't crop the lift.
        .scrollClipDisabled()
        .focusSection()
    }

    /// The provider's lists (Trakt watchlist and lists, Simkl statuses, MDBList lists) as a native
    /// `Menu { Picker }`, the same control Settings uses for its choice rows.
    private var listMenu: some View {
        Menu {
            Picker(String(localized: "List"), selection: Binding(
                get: { model.selectedSectionKey ?? "" },
                set: { model.selectSection($0) }
            )) {
                ForEach(model.sections, id: \.type) { section in
                    Text(section.displayTitle).tag(section.type)
                }
            }
        } label: {
            pillLabel(model.selectedSectionTitle ?? String(localized: "List"), systemImage: "list.bullet")
        }
        .accessibilityIdentifier("library.listPicker")
    }

    private var sortMenu: some View {
        Menu {
            Picker(String(localized: "Sort"), selection: Binding(
                get: { model.effectiveSortOption },
                set: { model.setSort($0) }
            )) {
                ForEach(model.availableSortOptions, id: \.name) { option in
                    Text(model.sortLabel(option)).tag(option)
                }
            }
        } label: {
            pillLabel(model.sortLabel(model.effectiveSortOption), systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("library.sortPicker")
    }

    private func pillLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: systemImage)
            Text(title)
            Image(systemName: "chevron.down")
                .font(Theme.Font.caption)
        }
        .font(Theme.Font.meta)
        .padding(.horizontal, Theme.Spacing.xs)
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
                model.clearSmartFilters()
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
            sourceChip(String(localized: "Saved"), isActive: !showingCloud) { showingCloud = false }
            sourceChip(String(localized: "Debrid Cloud"), isActive: showingCloud) { showingCloud = true }
        }
    }

    private func sourceChip(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                }
                Text(label)
            }
            .font(Theme.Font.meta)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
        }
        .buttonStyle(.chip(selected: isActive))
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
