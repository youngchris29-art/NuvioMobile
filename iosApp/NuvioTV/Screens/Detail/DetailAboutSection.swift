import SwiftUI

// FEAT-35 (Detail revamp "Cinematic Clean", P1 §G): the Cinematic page's last row. The Details
// table that Classic shows inside its top block moves here, below Comments, so the first screen
// stays clean. Classic's `infoSection`/`infoRows` are untouched.

nonisolated struct DetailAboutRow: Equatable, Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// beta.19-rc1 verdict (D1, BUG-137): the Status value. TMDB's status words ("Released", "Ended", …)
/// reach the page as English text, which stayed English in Steven's French screenshot ("Statut
/// Released"). Known words map to a `String(localized:)` key so they translate with the rest of the
/// page; an unknown value (an add-on's own wording) is shown as given, and a blank one is no row.
nonisolated enum DetailStatusText {
    /// Matching is case-insensitive and ignores surrounding whitespace. TMDB's movie statuses are
    /// Rumored, Planned, In Production, Post Production, Released and Canceled; its series statuses
    /// are Returning Series, Planned, In Production, Ended, Canceled and Pilot. "Continuing" is
    /// the word several add-ons and TVDB use for a running series; "Cancelled" is the British spelling.
    static func localized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Own `detail.status.*` keys, never the bare English word: the catalog populate script
        // harvests translations from the phone app by English text, and the phone app uses
        // "Released" as a row LABEL (fr "Date de sortie"), so a bare key would pick up that label as
        // the status value. The catalog carries an explicit English value for each key.
        switch trimmed.lowercased() {
        case "released": return String(localized: "detail.status.released", defaultValue: "Released")
        case "ended": return String(localized: "detail.status.ended", defaultValue: "Ended")
        case "returning series": return String(localized: "detail.status.returningSeries", defaultValue: "Returning Series")
        case "continuing": return String(localized: "detail.status.continuing", defaultValue: "Continuing")
        case "canceled", "cancelled": return String(localized: "detail.status.canceled", defaultValue: "Canceled")
        case "in production": return String(localized: "detail.status.inProduction", defaultValue: "In Production")
        case "planned": return String(localized: "detail.status.planned", defaultValue: "Planned")
        case "post production": return String(localized: "detail.status.postProduction", defaultValue: "Post Production")
        case "rumored": return String(localized: "detail.status.rumored", defaultValue: "Rumored")
        case "pilot": return String(localized: "detail.status.pilot", defaultValue: "Pilot")
        default: return trimmed
        }
    }
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
        add(String(localized: "Status"), DetailStatusText.localized(status))
        add(String(localized: "Awards"), awards)
        if showRatings, !ratings.isEmpty {
            add(String(localized: "Ratings"), ratings.map { "\($0.label) \($0.value)" }.joined(separator: " \u{00B7} "))
        }
        return rows
    }
}

/// A4.2 (Apple TV detail): the show's / movie's own overview at the top of About. The Cinematic
/// hero shows the Play target EPISODE's synopsis for a series (`DetailHeroSynopsis`), so without
/// this block a series' show synopsis appeared nowhere on the page.
nonisolated enum DetailAboutOverview {
    /// The overview About shows: trimmed, nil when blank.
    static func text(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the About section has anything to draw (`DetailSectionAvailability`'s `hasContent`).
    static func hasContent(rows: [DetailAboutRow], overview: String?) -> Bool {
        !rows.isEmpty || text(overview) != nil
    }
}

/// Title "About", the title's overview, then a two-column label/value grid. The text is not
/// focusable; the overview and grid together are ONE inert focus target (`.focusable()` with no
/// action — Select does nothing, Menu still pops), so Down from the row above has somewhere to land
/// and the page scrolls the section into view. Same pattern as the Person page's BUG-34 top block,
/// including its platter.
///
/// A4.2: the overview is drawn in full (no line cap). A capped paragraph would need a "more" control
/// that opens the full text in a cover, and every cover the page puts over itself is owned by
/// `DetailView` (`DetailTrailerGate`), so it is not added from here.
struct DetailAboutSection: View {
    let rows: [DetailAboutRow]
    /// A4.2: the show's / movie's own overview (`DetailView.overview`). Nil or blank: no paragraph.
    var overview: String? = nil
    /// `DetailView` passes `focusedRow == .about`.
    let isFocused: Bool

    /// Review r1 #7: the platter snaps instead of fading under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let labelColumnWidth: CGFloat = 220
    static let valueMaxWidth: CGFloat = 1100
    /// The overview spans the label column, the grid gap and the value column.
    static let overviewMaxWidth: CGFloat = labelColumnWidth + Theme.Spacing.lg + valueMaxWidth

    var body: some View {
        let overviewText = DetailAboutOverview.text(overview)
        if !rows.isEmpty || overviewText != nil {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(String(localized: "About"))
                    .font(Theme.Font.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    if let overviewText {
                        Text(overviewText)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: Self.overviewMaxWidth, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !rows.isEmpty {
                        grid
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

    private var grid: some View {
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
