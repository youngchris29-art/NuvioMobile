import SwiftUI

/// The Cast pill's content on both engines: a horizontal row of person cards (headshot, name,
/// role), and in place of it the compact actor view while `model.actorView` is set. Selecting a
/// card calls `model.openPerson(_:)`; focus returns to the card `model.lastOpenedPersonId` names
/// when the actor view closes. Menu is handled by the host (`model.menuBack()`), never here.
struct PlayerCastContent: View {
    @ObservedObject var model: PlayerTopPanelModel
    @FocusState private var focusedPerson: Int?
    @FocusState private var actorFocused: Bool

    var body: some View {
        Group {
            if let person = model.actorView {
                PlayerActorView(person: person, detail: model.actorDetail, isFocused: $actorFocused)
                    .onAppear { actorFocused = true }
            } else {
                cardRow
            }
        }
        .frame(maxHeight: 400, alignment: .top)
        .onChange(of: model.actorView?.id) { _, newValue in
            guard newValue == nil, let id = model.lastOpenedPersonId else { return }
            // Next runloop turn: the row is rebuilt this pass, so the card must exist first.
            DispatchQueue.main.async { focusedPerson = id }
        }
    }

    private var cardRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Spacing.lg) {
                    ForEach(model.people) { person in
                        Button { model.openPerson(person) } label: {
                            PlayerCastCard(person: person)
                        }
                        .buttonStyle(.card)
                        .focused($focusedPerson, equals: person.id)
                        .id(person.id)
                        .accessibilityIdentifier("player.cast.card.\(person.id)")
                    }
                }
                .padding(.vertical, Theme.Spacing.md)
                .padding(.horizontal, Theme.Spacing.xs)
            }
            .focusSection()
            .onChange(of: focusedPerson) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

private struct PlayerCastCard: View {
    let person: PlayerPanelPerson
    private let side: CGFloat = 160

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            CachedAsyncImage(url: person.photo, contentMode: .fill, failure: {
                ZStack {
                    Theme.Palette.surface
                    Image(systemName: "person.fill")
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            })
            .frame(width: side, height: side)
            .clipShape(Circle())
            .background(Circle().fill(Theme.Palette.surface))
            Text(person.name)
                .font(Theme.Font.meta.weight(.semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            Text(person.role ?? " ")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
        }
        .frame(width: side + Theme.Spacing.xl)
        .padding(Theme.Spacing.sm)
    }
}

/// The compact actor view: headshot, name, department · life dates, a biography excerpt and a
/// display-only known-for row. ONE focusable, non-interactive region (the BUG-34 pattern from
/// `PersonDetailView.topBlock`) so focus has somewhere to land and Menu reaches the host.
private struct PlayerActorView: View {
    let person: PlayerPanelPerson
    let detail: PlayerPanelPersonDetail?
    var isFocused: FocusState<Bool>.Binding

    private var metaLine: String? {
        let parts = [detail?.knownForDepartment, detail?.lifeDates].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            CachedAsyncImage(url: detail?.photo ?? person.photo, contentMode: .fill, failure: {
                ZStack {
                    Theme.Palette.surface
                    Image(systemName: "person.fill")
                        .font(Theme.Font.hero)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            })
            .frame(width: 200, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(detail?.name ?? person.name)
                    .font(Theme.Font.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let detail {
                    if let metaLine {
                        Text(metaLine)
                            .font(Theme.Font.meta)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    if let bio = detail.biography {
                        Text(bio)
                            .font(Theme.Font.detail)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(6)
                    }
                    if !detail.knownFor.isEmpty {
                        knownForRow(detail.knownFor)
                    }
                } else {
                    ProgressView().padding(.top, Theme.Spacing.sm)
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.hero)
                .fill(Theme.Palette.surface.opacity(isFocused.wrappedValue ? 0.9 : 0))
        )
        .focusable()
        .focused(isFocused)
        .animation(.easeInOut(duration: 0.15), value: isFocused.wrappedValue)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.cast.actor")
    }

    private func knownForRow(_ items: [PlayerPanelKnownFor]) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            ForEach(items.prefix(10)) { item in
                VStack(spacing: Theme.Spacing.xxs) {
                    CachedAsyncImage(url: item.poster, contentMode: .fill)
                        .frame(width: 72, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
                    Text(item.title)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .frame(width: 72)
                }
            }
        }
    }
}

/// The Up Next pill's content: `model.upNext` as one card (still, title, subtitle) with a Play Now
/// button that calls `model.onPlayUpNext`.
struct PlayerUpNextContent: View {
    @ObservedObject var model: PlayerTopPanelModel

    var body: some View {
        if let next = model.upNext {
            HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                CachedAsyncImage(url: next.still, contentMode: .fill)
                    .frame(width: 360, height: 203)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(next.title)
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2)
                    if let subtitle = next.subtitle {
                        Text(subtitle)
                            .font(Theme.Font.meta)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    Button { model.onPlayUpNext?() } label: {
                        Label(String(localized: "Play Now"), systemImage: "play.fill")
                    }
                    .padding(.top, Theme.Spacing.sm)
                    .accessibilityIdentifier("player.upnext.play")
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.md)
            .focusSection()
        }
    }
}
