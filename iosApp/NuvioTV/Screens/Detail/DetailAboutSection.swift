import SwiftUI

// FEAT-35 (Detail revamp "Cinematic Clean", P1 §G): the Cinematic page's last row. The Details
// table that Classic shows inside its top block moves here, below Comments, so the first screen
// stays clean. Classic's `infoSection`/`infoRows` are untouched.

nonisolated struct DetailAboutRow: Equatable, Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

nonisolated enum DetailAboutRows {
    /// The rows in the plan's order, skipping every empty or blank value. Labels go through
    /// `String(localized:)` and reuse Classic `infoRows`' keys where they exist (correction 8);
    /// "Created by" replaces "Director" for series (TMDB maps a show's `createdBy` into `director`,
    /// P1 §M conflict 2). The Ratings row follows the strip's order (`DetailRatings.ordered`) and
    /// exists only with the Ratings section on (D10).
    static func make(director: [String], writer: [String], studios: [String], networks: [String],
                     country: String?, language: String?, status: String?, awards: String?,
                     ratings: [DetailRatingEntry], showRatings: Bool, isSeries: Bool) -> [DetailAboutRow] {
        var rows: [DetailAboutRow] = []
        func add(_ label: String, _ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { rows.append(DetailAboutRow(label: label, value: trimmed)) }
        }
        func join(_ names: [String]) -> String {
            names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
        add(isSeries ? String(localized: "Created by") : String(localized: "Director"), join(director))
        add(String(localized: "Writers"), join(writer))
        add(String(localized: "Studios"), join(studios))
        add(String(localized: "Network"), join(networks))
        add(String(localized: "Country"), country)
        add(String(localized: "Language"), language)
        add(String(localized: "Status"), status)
        add(String(localized: "Awards"), awards)
        if showRatings, !ratings.isEmpty {
            add(String(localized: "Ratings"), ratings.map { "\($0.label) \($0.value)" }.joined(separator: " \u{00B7} "))
        }
        return rows
    }
}

/// Title "About" above a two-column label/value grid. The text is not focusable; the grid as a
/// whole is ONE inert focus target (`.focusable()` with no action — Select does nothing, Menu still
/// pops), so Down from the row above has somewhere to land and the page scrolls the section into
/// view. Same pattern as the Person page's BUG-34 top block, including its platter.
struct DetailAboutSection: View {
    let rows: [DetailAboutRow]
    /// `DetailView` passes `focusedRow == .about`.
    let isFocused: Bool

    /// Review r1 #7: the platter snaps instead of fading under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let labelColumnWidth: CGFloat = 220
    static let valueMaxWidth: CGFloat = 1100

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(String(localized: "About"))
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: Theme.Spacing.lg,
                     verticalSpacing: Theme.Spacing.sm) {
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.label)
                                .font(Theme.Font.meta)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .frame(width: Self.labelColumnWidth, alignment: .leading)
                            Text(row.value)
                                .font(Theme.Font.detail)
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .frame(maxWidth: Self.valueMaxWidth, alignment: .leading)
                        }
                    }
                }
                .background { platter }
                .focusable()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("detail_about")
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isFocused)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
    }

    /// Copy of `PersonDetailView.topFocusPlatter`: drawn outside the grid's bounds through negative
    /// padding, so focusing it never shifts the layout.
    private var platter: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.hero)
            .fill(Theme.Palette.surface.opacity(isFocused ? 0.9 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.hero)
                    .strokeBorder(Color.white.opacity(isFocused ? 0.55 : 0), lineWidth: 2) // neutral by design: the HIG contract bans accent focus rings
            )
            .padding(-Theme.Spacing.md)
    }
}
