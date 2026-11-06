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

    /// The overview's line cap. About is ONE focus target, so whatever runs past the viewport could
    /// never be reached. Worst realistic case on a 1080 pt screen: the row anchors 72 pt from the
    /// top and keeps the 60 pt bottom margin (948 left); the title and its gap take ~64, the grid's
    /// nine rows (Created by … Ratings) at a caption1 line plus spacing ~300, with two values
    /// wrapping ~360, the platter's padding 32 and the overview gap 24. That leaves ~460 pt, about
    /// eleven body lines; six keeps the whole section on one screen with room for Larger Text.
    static let lineCap = 6

    /// Sub-point rounding between the capped and the full measurement must not read as truncation.
    static let truncationTolerance: CGFloat = 1

    /// The capped paragraph hides text: Select on About then opens the full overview.
    static func isTruncated(fullHeight: CGFloat, cappedHeight: CGFloat) -> Bool {
        guard fullHeight > 0, cappedHeight > 0 else { return false }
        return fullHeight > cappedHeight + truncationTolerance
    }
}

/// Title "About", the title's overview, then a two-column label/value grid. The text is not
/// focusable; the overview and grid together are ONE focus target (`.focusable()`; Select does
/// nothing unless the overview is truncated, see below; Menu still pops), so Down from the row above has somewhere to land
/// and the page scrolls the section into view. Same pattern as the Person page's BUG-34 top block,
/// including its platter.
///
/// The overview is capped at `DetailAboutOverview.lineCap` lines so the one focus target always
/// fits on screen. When the cap hides text, Select on the target calls `onOpenOverview`, and
/// `DetailView` (which owns every cover the page puts over itself, `DetailTrailerGate`) presents the
/// full text in the synopsis overlay. Untruncated, the target stays inert as before.
struct DetailAboutSection: View {
    let rows: [DetailAboutRow]
    /// A4.2: the show's / movie's own overview (`DetailView.overview`). Nil or blank: no paragraph.
    var overview: String? = nil
    /// `DetailView` passes `focusedRow == .about`.
    let isFocused: Bool
    /// Opens the full overview; called on Select only while the paragraph is truncated.
    var onOpenOverview: (() -> Void)? = nil

    /// The paragraph's height at the cap and in full (a hidden probe, same width and font).
    @State private var cappedOverviewHeight: CGFloat = 0
    @State private var fullOverviewHeight: CGFloat = 0
    private var overviewTruncated: Bool {
        DetailAboutOverview.isTruncated(fullHeight: fullOverviewHeight, cappedHeight: cappedOverviewHeight)
    }

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
                            .lineLimit(DetailAboutOverview.lineCap)
                            .truncationMode(.tail)
                            .frame(maxWidth: Self.overviewMaxWidth, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded(.up) }) { height in
                                if cappedOverviewHeight != height { cappedOverviewHeight = height }
                            }
                            .background(alignment: .topLeading) {
                                // Hidden probe: the same paragraph uncapped.
                                Text(overviewText)
                                    .font(Theme.Font.body)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: Self.overviewMaxWidth, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .hidden()
                                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded(.up) }) { height in
                                        if fullOverviewHeight != height { fullOverviewHeight = height }
                                    }
                                    .accessibilityHidden(true)
                            }
                    }
                    if !rows.isEmpty {
                        grid
                    }
                }
                .background { platter }
                .focusable()
                // Select (tvOS delivers the focused view's primary press as a tap) opens the full
                // overview only while the cap hides text; otherwise it does nothing, as before. The
                // gesture is always attached so the target's identity never changes under focus.
                .onTapGesture {
                    if overviewTruncated { onOpenOverview?() }
                }
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

