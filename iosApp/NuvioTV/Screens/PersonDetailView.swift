import SwiftUI
import SharedCore

/// Detail screen for a cast/crew member (TMDB-backed). Shows photo, name, life dates, known-for, a
/// short biography, and their movie/TV credits as focusable poster rows. Pushed from the Detail
/// screen's cast row via `PersonRoute` (only when the person has a `tmdbId`).
///
/// Relies on the ancestor `NavigationStack` (Home / Search / Library) for navigation: credit posters
/// push `TitleRoute`, which those stacks already resolve to `DetailView`.
struct PersonDetailView: View {
    let personId: Int
    let personName: String

    @StateObject private var model: PersonDetailViewModel

    init(personId: Int, personName: String) {
        self.personId = personId
        self.personName = personName
        _model = StateObject(wrappedValue: PersonDetailViewModel(personId: personId))
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    headerBlock

                    if let bio = model.person?.biography, !bio.isEmpty {
                        Text(bio)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .frame(maxWidth: 1100, alignment: .leading)
                    }

                    creditsRow(title: "Movies", items: model.person?.movieCredits ?? [])
                    creditsRow(title: "TV Shows", items: model.person?.tvCredits ?? [])

                    if model.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.xl)
                    } else if model.failed {
                        Text("Couldn\u{2019}t load details for \(personName). A TMDB API key is required for cast profiles.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .frame(maxWidth: 900, alignment: .leading)
                    }
                }
                .padding(Theme.Spacing.screen)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { model.start() }
    }

    // MARK: - Sections

    private var headerBlock: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            photo
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(model.person?.name ?? personName)
                    .font(Theme.Font.hero)
                    .foregroundStyle(Theme.Palette.textPrimary)

                if !lifeLine.isEmpty {
                    Text(lifeLine)
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }

                if let known = model.person?.knownFor, !known.isEmpty {
                    Text("Known for: \(known)")
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var photo: some View {
        AsyncImage(url: URL(string: model.person?.profilePhoto ?? "")) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Theme.Palette.surface
                    Image(systemName: "person.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
        .frame(width: Theme.Size.posterWidth, height: Theme.Size.posterWidth * 1.4)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    @ViewBuilder
    private func creditsRow(title: String, items: [MetaPreview]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(title)
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.lg) {
                        ForEach(items, id: \.id) { item in
                            NavigationLink(value: TitleRoute(preview: item)) {
                                PosterCard(
                                    title: item.name,
                                    imageURL: item.poster,
                                    width: Theme.Size.miniPosterWidth,
                                    height: Theme.Size.miniPosterHeight
                                )
                            }
                            .buttonStyle(.poster)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.md)
                }
                .scrollClipDisabled()
            }
        }
    }

    // MARK: - Derived

    private var lifeLine: String {
        var parts: [String] = []
        if let born = model.person?.birthday, !born.isEmpty { parts.append("Born \(born)") }
        if let died = model.person?.deathday, !died.isEmpty { parts.append("Died \(died)") }
        if let place = model.person?.placeOfBirth, !place.isEmpty { parts.append(place) }
        return parts.joined(separator: "  \u{00B7}  ")
    }
}
