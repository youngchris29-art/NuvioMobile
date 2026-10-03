import CoreGraphics
import Foundation
import SharedCore

// FEAT-35 (Detail revamp "Cinematic Clean", 2026-10-02): the pure geometry and formatting rules
// behind `DetailCinematicHero`. Every type here is `nonisolated` and free of `Theme` references
// (spec correction F16), so `DetailCinematicLayoutTests` can call it synchronously; where a value
// mirrors a `Theme` token, the mirror is pinned against the token by a unit test.

/// Fixed slots and the hero height. Nothing above the bottom-anchored text stack may change height
/// after first paint (correction F3), so every slot that can fill in late has a constant here.
nonisolated enum DetailCinematicLayout {
    /// Left text column: logo, meta line, ratings, synopsis and the action row.
    static let textColumnMaxWidth: CGFloat = 900
    /// Right-aligned credits block beside the action row.
    static let creditsMaxWidth: CGFloat = 640
    /// The logo slot never changes height: the logo (or the title fallback) sits bottom-leading in
    /// it, so a logo landing late never moves the text below it (Plex's logo-shift bug).
    static let logoSlotHeight: CGFloat = 180
    static let logoMaxWidth: CGFloat = 600
    /// Correction F3: the meta line is a fixed slot too, sized for one `metaStrong` line plus the
    /// stroked age chip. No spinner inside it in Cinematic.
    static let metaLineHeight: CGFloat = 40
    /// The MDBList strip's reserved slot (present only while the strip is gated on).
    static let ratingsSlotHeight: CGFloat = 44
    /// How much of the first row shows under the hero on landing.
    static let peekBand: CGFloat = 140
    static let heroMinimumHeight: CGFloat = 520
    /// == `Theme.Spacing.screen` (the page VStack's padding); pinned by a unit test.
    static let screenPadding: CGFloat = 60
    /// == `Theme.Spacing.lg + Theme.Spacing.sm` (the page VStack's spacing); pinned by a unit test.
    static let pageRowSpacing: CGFloat = 36

    /// Correction F5: driven by `.containerRelativeFrame(.vertical)`, so `containerHeight` is the
    /// scroll view's container height as SwiftUI reports it to that modifier. The hero fills it
    /// minus the page's top padding, the gap to the first row and the peek band, never below the
    /// floor. Gate 1 reads the real value off `debug_detail_hero h=`; if the peek is off, only
    /// `peekBand` should move.
    static func heroHeight(containerHeight: CGFloat) -> CGFloat {
        max(heroMinimumHeight, containerHeight - screenPadding - pageRowSpacing - peekBand)
    }
}

// MARK: - Ratings strip

/// One MDBList rating as the strip needs it, decoupled from the Kotlin type so tests can build it.
nonisolated struct DetailRatingInput: Equatable {
    let source: String
    let value: Double

    init(source: String, value: Double) {
        self.source = source
        self.value = value
    }

    init(_ rating: MetaExternalRating) {
        self.init(source: rating.source, value: rating.value)
    }
}

nonisolated struct DetailRatingEntry: Equatable, Identifiable {
    let source: String
    let label: String
    let value: String
    var id: String { source }
}

nonisolated enum DetailRatings {
    /// The plan's order; everything else follows in MDBList's own `PROVIDER_PRIORITY_ORDER`, which
    /// is the order `externalRatings` already arrives in.
    static let leadingOrder = ["imdb", "tomatoes", "metacritic", "trakt", "letterboxd"]

    /// Deduped by source (first wins), `leadingOrder` first, the rest stable in input order.
    static func ordered(_ input: [DetailRatingInput]) -> [DetailRatingEntry] {
        var seen = Set<String>()
        var unique: [DetailRatingInput] = []
        for rating in input where seen.insert(rating.source.lowercased()).inserted {
            unique.append(rating)
        }
        let leading = leadingOrder.compactMap { key in unique.first { $0.source.lowercased() == key } }
        let rest = unique.filter { !leadingOrder.contains($0.source.lowercased()) }
        return (leading + rest).map {
            DetailRatingEntry(source: $0.source,
                              label: label(for: $0.source),
                              value: formatted(source: $0.source, value: $0.value))
        }
    }

    /// Brand names stay as they are in every language; "Audience" is the one plain word.
    static func label(for source: String) -> String {
        switch source.lowercased() {
        case "imdb": return "IMDb"
        case "tomatoes": return "Rotten Tomatoes"
        case "metacritic": return "Metacritic"
        case "trakt": return "Trakt"
        case "letterboxd": return "Letterboxd"
        case "tmdb": return "TMDB"
        case "audience": return String(localized: "Audience")
        case "mal": return "MyAnimeList"
        default: return source.capitalized
        }
    }

    /// Scales per `MdbListRatingsDecoder`: IMDb/MAL 0–10, Letterboxd 0–5, the rest 0–100.
    static func formatted(source: String, value: Double) -> String {
        switch source.lowercased() {
        case "imdb", "mal", "letterboxd":
            return String(format: "%.1f", value)
        case "tomatoes", "audience", "trakt", "tmdb":
            return "\(Int(value.rounded()))%"
        case "metacritic":
            return "\(Int(value.rounded()))"
        default:
            return value <= 10 ? String(format: "%.1f", value) : "\(Int(value.rounded()))"
        }
    }

    /// Correction F4: the strip's slot is reserved only when MDBList could actually fetch for this
    /// title — the same "has a `tt…` id somewhere" rule as `MdbListMetadataService.shouldFetchForMeta`
    /// (meta id, the request's fallback id, or the meta's `imdb_id`).
    static func hasUsableImdbId(metaId: String?, fallbackId: String?, imdbId: String?) -> Bool {
        [metaId, fallbackId, imdbId].contains { value in
            guard let value, !value.isEmpty else { return false }
            return value.range(of: "tt\\d+", options: .regularExpression) != nil
        }
    }

    /// D10: the meta line's IMDb ★ shows only with the Ratings section ON and the MDBList strip off
    /// or empty. Ratings OFF hides it too.
    static func showsImdbStar(sectionRatings: Bool, ratingsGateOn: Bool, ratingCount: Int, imdbRating: String?) -> Bool {
        guard sectionRatings, let imdbRating, !imdbRating.isEmpty else { return false }
        return !(ratingsGateOn && ratingCount > 0)
    }
}

// MARK: - Synopsis teaser

nonisolated enum DetailSynopsisTeaser {
    static let maxLines = 4
    /// Sub-point rounding between the measured full height and `lineHeight × maxLines` must not
    /// read as truncation.
    static let lineTolerance: CGFloat = 1

    static func slotHeight(lineHeight: CGFloat, maxLines: Int = maxLines) -> CGFloat {
        (lineHeight * CGFloat(maxLines)).rounded(.up)
    }

    /// True when the full text needs more than `maxLines` lines. No measurement yet → not truncated
    /// (the teaser stays a plain, non-focusable Text until the measurement lands).
    static func isTruncated(fullTextHeight: CGFloat, lineHeight: CGFloat, maxLines: Int = maxLines) -> Bool {
        guard lineHeight > 0, fullTextHeight > 0 else { return false }
        return fullTextHeight > lineHeight * CGFloat(maxLines) + lineTolerance
    }

    /// Gate 1 bug (Dune Part Two showed 3 lines, not 4): `UIFont.lineHeight` (≈30 pt for system
    /// caption1) is SHORTER than the line pitch SwiftUI actually draws (≈31.7 pt measured off the
    /// Gate 1 screenshots). A slot of `4 × lineHeight` = 120 pt therefore proposed less than four
    /// rendered lines to the `lineLimit(4)` Text, and SwiftUI truncates to whatever whole lines fit
    /// the proposed height — three. The slot is now the MEASURED height of four rendered lines of
    /// the same font (a hidden four-line probe in `DetailCinematicHero`, font-only, so it never
    /// depends on the title's data), falling back to the metric before the probe lands.
    static func resolvedSlotHeight(measuredFourLineHeight: CGFloat, lineHeight: CGFloat,
                                   maxLines: Int = maxLines) -> CGFloat {
        guard measuredFourLineHeight > 0 else { return slotHeight(lineHeight: lineHeight, maxLines: maxLines) }
        return measuredFourLineHeight.rounded(.up)
    }

    /// The truncation decision against the resolved slot (the measured four-line height), so the
    /// teaser becomes focusable exactly when the full text needs more than the slot shows.
    static func isTruncated(fullTextHeight: CGFloat, slotHeight: CGFloat) -> Bool {
        guard slotHeight > 0, fullTextHeight > 0 else { return false }
        return fullTextHeight > slotHeight + lineTolerance
    }
}

// MARK: - Credits

nonisolated struct DetailCreditsText: Equatable {
    nonisolated enum CrewLabel: Equatable {
        case directedBy
        case createdBy
    }

    let castNames: String?
    let crewLabel: CrewLabel?
    let crewNames: String?

    var isEmpty: Bool { castNames == nil && crewNames == nil }
}

nonisolated enum DetailCredits {
    /// "With" = the first three cast names, skipping crew names (TMDB prepends crew to `cast`).
    /// The crew line = the first two directors; series read "Created by", because TMDB maps a show's
    /// `createdBy` into `director` and `MetaDetails` has no creator field (P1 §M conflict 2).
    static func make(cast: [String], director: [String], writer: [String], isSeries: Bool) -> DetailCreditsText {
        func clean(_ names: [String]) -> [String] {
            names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let directors = clean(director)
        let crew = Set(directors + clean(writer))
        let castNames = clean(cast).filter { !crew.contains($0) }.prefix(3)
        let crewNames = directors.prefix(2)
        return DetailCreditsText(
            castNames: castNames.isEmpty ? nil : castNames.joined(separator: ", "),
            crewLabel: crewNames.isEmpty ? nil : (isSeries ? .createdBy : .directedBy),
            crewNames: crewNames.isEmpty ? nil : crewNames.joined(separator: ", ")
        )
    }
}

// MARK: - Meta line

nonisolated struct DetailMetaLineModel: Equatable {
    let year: String?
    let runtime: String?
    let genres: [String]
    let ageRating: String?
    let imdbRating: String?
}

nonisolated enum DetailMetaLine {
    /// Year · Runtime · "Genre 1, Genre 2" — only the non-empty parts; the caller joins with " · ".
    static func textParts(year: String?, runtime: String?, genres: [String]) -> [String] {
        var parts: [String] = []
        if let year, !year.isEmpty { parts.append(year) }
        if let runtime, !runtime.isEmpty { parts.append(runtime) }
        let genreText = genres.filter { !$0.isEmpty }.prefix(2).joined(separator: ", ")
        if !genreText.isEmpty { parts.append(genreText) }
        return parts
    }
}

// MARK: - Start Over

nonisolated enum DetailStartOver {
    /// Series: the primary action carries a resume position. Movie: a saved, not-yet-finished
    /// position.
    static func isAvailable(isSeries: Bool, seriesResumePositionMs: Int64?, movieEntryPositionMs: Int64?,
                            movieEntryResumable: Bool) -> Bool {
        if isSeries { return (seriesResumePositionMs ?? 0) > 0 }
        return (movieEntryPositionMs ?? 0) > 0 && movieEntryResumable
    }
}

// MARK: - Scroll dim (consumed by W2-A)

nonisolated enum DetailDim {
    static let classicRampDistance: CGFloat = 400
    static let ceiling: Double = 0.85

    /// Classic keeps today's 400 pt ramp; Cinematic saturates as the hero fully leaves.
    static func rampDistance(layout: DetailLayout, heroHeight: CGFloat) -> CGFloat {
        switch layout {
        case .classic: return classicRampDistance
        case .cinematic: return max(classicRampDistance, heroHeight)
        }
    }

    /// W2-A: how far the page has scrolled, as the dim ramp measures it. Classic keeps today's
    /// formula byte for byte (`contentOffset − inset`, which on this runtime only starts counting
    /// once the page has moved `2 × inset` from the top, because the top rests at
    /// `contentOffset == −inset`: `scrollTo(y: 0)` lands at `0 − inset`). Cinematic measures the
    /// real distance from the top (`contentOffset + inset`), so a ramp equal to the hero height
    /// saturates as the hero leaves: the hero-exit rest (`≈ heroHeight − 12 + inset` from the top)
    /// is past the ramp, which puts the dim at the ceiling and the trailer latch (0.80) over it.
    static func scrolledDistance(layout: DetailLayout, contentOffset: CGFloat, contentInsetTop: CGFloat) -> CGFloat {
        switch layout {
        case .classic: return contentOffset - contentInsetTop
        case .cinematic: return contentOffset + contentInsetTop
        }
    }

    /// Same clamp and 0.05 quantisation as the live dim closure in `DetailView`.
    static func value(scrolled: CGFloat, rampDistance: CGFloat) -> Double {
        guard rampDistance > 0 else { return 0 }
        let raw = min(max(Double(scrolled / rampDistance), 0), 1) * ceiling
        return (raw * 20).rounded() / 20
    }
}
