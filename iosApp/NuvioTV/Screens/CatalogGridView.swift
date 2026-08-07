import SwiftUI
import SharedCore

/// Full-screen focusable poster grid for a single catalog ("See All"), backed by the shared
/// paginated `CatalogRepository`. Pushed from a `CatalogRowView` header via `CatalogRoute`.
///
/// This screen relies on the ancestor `NavigationStack` (Home / Search) for navigation: its poster
/// `NavigationLink`s push `TitleRoute`, which those stacks already resolve to `DetailView`.
struct CatalogGridView: View {
    let route: CatalogRoute
    @StateObject private var model: CatalogGridViewModel

    init(route: CatalogRoute) {
        self.route = route
        _model = StateObject(wrappedValue: CatalogGridViewModel(target: route.target))
    }

    @Environment(\.posterStyle) private var posterStyle
    @Environment(\.dismiss) private var dismiss

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: posterStyle.width + Theme.Spacing.rowGap),
            spacing: Theme.Spacing.rowGap
        )]
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    Text(route.title)
                        .font(Theme.Font.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)

                    if model.items.isEmpty {
                        stateView
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

                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Theme.Spacing.xl)
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

    @ViewBuilder
    private var stateView: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if model.isLoading {
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text("Loading\u{2026}")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            } else if let message = model.errorMessage {
                Text(message)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.accent)
            } else {
                Text("No titles here yet.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            // A pushed screen with no focusable content strands focus on the ancestor
            // tab bar, where Menu exits the app instead of popping this screen
            // (observed on tvOS 27; BUG-47's "crash to the home screen"). Keeping a
            // focusable control in every non-grid state pins focus inside this screen
            // so Menu always pops.
            Button("Go Back") { dismiss() }
        }
        .padding(.vertical, Theme.Spacing.sectionGap)
    }
}
