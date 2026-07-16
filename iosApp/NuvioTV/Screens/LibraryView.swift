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

    // MARK: - Source switcher (Saved / Debrid Cloud)

    private var sourceChips: some View {
        HStack(spacing: Theme.Spacing.md) {
            sourceChip("Saved", isActive: !showingCloud) { showingCloud = false }
            sourceChip("Debrid Cloud", isActive: showingCloud) { showingCloud = true }
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
        .buttonStyle(.bordered)
        .tint(isActive ? Theme.Palette.accent : nil)
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
            .buttonStyle(.bordered)
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
