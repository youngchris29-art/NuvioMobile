import SwiftUI
import SharedCore

/// The Library tab: a focusable poster grid of the titles saved via "Add to Library" (tap opens
/// detail; long-press removes), plus — when a debrid provider with cloud support is connected —
/// a "Debrid Cloud" source listing the provider's cloud files for direct playback.
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
                        Text("Library")
                            .font(Theme.Font.screenTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)

                        if cloud.hasConnectedProvider {
                            sourceChips
                        }

                        if showingCloud && cloud.hasConnectedProvider {
                            cloudContent
                        } else if model.items.isEmpty {
                            emptyState
                        } else {
                            sortChips
                            LazyVGrid(columns: columns, spacing: Theme.Spacing.xl) {
                                ForEach(model.items, id: \.id) { item in
                                    NavigationLink(value: TitleRoute(preview: item.toMetaPreview())) {
                                        PosterCard(title: item.name, imageURL: item.poster)
                                    }
                                    .buttonStyle(.poster)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            model.remove(item)
                                        } label: {
                                            Label("Remove from Library", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.screen)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollClipDisabled()
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

    // MARK: - Sort (shared LibraryDisplaySettingsRepository — persisted + profile-scoped)

    private var sortChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.md) {
                ForEach(model.availableSortOptions, id: \.name) { option in
                    sourceChip(Self.sortLabel(option), isActive: option == model.sortOption) {
                        model.setSort(option)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private static func sortLabel(_ option: LibrarySortOption) -> String {
        if option == .default_ { return String(localized: "Trakt Order") }
        if option == .addedDesc { return String(localized: "Recently Added") }
        if option == .addedAsc { return String(localized: "Oldest First") }
        if option == .titleAsc { return String(localized: "A\u{2013}Z") }
        if option == .titleDesc { return String(localized: "Z\u{2013}A") }
        return option.name
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

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "books.vertical")
                .font(.system(size: 80))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("Your library is empty")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Add movies and shows with the + button on a title\u{2019}s page.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.sectionGap)
    }
}
