import Foundation
import SwiftUI

/// A2 (D1): one Detail page section, in display terms. Raw values are stable ids: probes, tests and
/// any future persisted order use them, so never rename one.
nonisolated enum DetailSection: String, CaseIterable, Sendable {
    case hero
    /// Studio / network logo chips (`companyLogosRow`).
    case companies
    /// `parentalGuideSection`.
    case parentalGuide
    /// `EpisodesSection` (series only).
    case episodes
    /// `castRow`.
    case castAndCrew
    /// `collectionRow`.
    case collection
    /// `trailersRow`: every video in Cinematic and Classic, Trailer/Teaser only in Apple-style.
    case trailers
    /// Apple-style only: the non-trailer videos (`bonusRow`).
    case bonus
    /// `moreLikeThisRow`.
    case moreLikeThis
    /// `commentsSection`.
    case comments
    /// `DetailAboutSection` (Cinematic and Apple-style).
    case about

    /// The scroll / focus / offsets key. nil for the hero (focus in the hero is `focusedRow == nil`).
    /// Main-actor like `DetailRowID` itself (default isolation); the page and the tests are too.
    @MainActor
    var rowID: DetailRowID? {
        switch self {
        case .hero: return nil
        case .companies: return .logos
        case .parentalGuide: return .parental
        case .episodes: return .episodes
        case .castAndCrew: return .cast
        case .collection: return .collection
        case .trailers: return .trailers
        case .bonus: return .bonus
        case .moreLikeThis: return .moreLikeThis
        case .comments: return .comments
        case .about: return .about
        }
    }
}

/// What the page knows about one section right now.
nonisolated enum DetailSectionState: Equatable, Sendable {
    /// Switched off in Settings, or not applicable (Episodes on a film, About in Classic).
    case hidden
    /// Its data has answered and there is nothing to show.
    case empty
    /// Its data has not answered yet and may still bring content.
    case pending
    /// Has content.
    case ready
}

nonisolated struct DetailSectionAvailability: Equatable, Sendable {
    /// Missing key = `.hidden`. `.hero` is always shown and is never looked up.
    var states: [DetailSection: DetailSectionState] = [:]

    init(states: [DetailSection: DetailSectionState] = [:]) {
        self.states = states
    }

    func state(_ section: DetailSection) -> DetailSectionState {
        section == .hero ? .ready : (states[section] ?? .hidden)
    }

    /// The common derivation: toggle off → hidden; content → ready; still loading → pending; else empty.
    static func state(enabled: Bool, hasContent: Bool, loading: Bool) -> DetailSectionState {
        guard enabled else { return .hidden }
        if hasContent { return .ready }
        return loading ? .pending : .empty
    }
}

/// A2 (D1): the section order per layout and type. `layout` is the user's choice
/// (`DetailView.detailLayoutChoice`), never its `visualBase`.
nonisolated enum DetailSectionOrder {
    /// The full preset before availability, hero first.
    static func preset(layout: DetailLayout, isSeries: Bool) -> [DetailSection] {
        switch layout {
        case .cinematic, .classic:
            // Today's order exactly. About is dropped for Classic by availability (hidden), not by
            // the preset, so the two presets stay one list.
            return [.hero, .companies, .parentalGuide]
                + (isSeries ? [.episodes] : [])
                + [.castAndCrew, .collection, .trailers, .moreLikeThis, .comments, .about]
        case .appleStyle:
            // Studios and Parental Guide are kept (no cut), after the last meta-backed row: the
            // Parental Guide loads after meta, so a late arrival never lands above a focusable
            // row. Comments and About stay last (`DetailRowAnchor.direction` assumes it).
            let tail: [DetailSection] = [.companies, .parentalGuide, .comments, .about]
            return isSeries
                ? [.hero, .episodes, .trailers, .bonus, .moreLikeThis, .castAndCrew, .collection] + tail
                : [.hero, .trailers, .bonus, .moreLikeThis, .collection, .castAndCrew] + tail
        }
    }

    /// Whether a `.pending` section keeps its slot. Cinematic and Classic never reserve (a row
    /// appears when its data does); Apple-style does, so a late More Like This cannot push Cast &
    /// Crew down under a focused card.
    static func reservesPendingSlots(_ layout: DetailLayout) -> Bool { layout == .appleStyle }

    /// The ordered sections to render: `.hidden` and `.empty` dropped; `.pending` kept only where
    /// the layout reserves slots. Always starts with `.hero`.
    static func sections(layout: DetailLayout, isSeries: Bool,
                         availability: DetailSectionAvailability) -> [DetailSection] {
        let keepPending = reservesPendingSlots(layout)
        return preset(layout: layout, isSeries: isSeries).filter { section in
            switch availability.state(section) {
            case .ready: return true
            case .pending: return keepPending
            case .hidden, .empty: return false
            }
        }
    }
}

extension DetailSectionOrder {
    /// The height a `.pending` section reserves (Apple-style only). Only More Like This can land
    /// late (the enrichment emission) while focus is below the hero; every other row's data comes
    /// with the first meta, while focus is still in the hero, so they reserve nothing. More Like
    /// This is `DetailPosterLinkRow`'s geometry: title line, `md` gap, the mini poster inside its
    /// `md` vertical padding, and the `PosterCard` caption (`md` gap plus one body line). Refine on
    /// the Mac against `detailRowHeights[.moreLikeThis]` (the `debug_ux6` probe).
    @MainActor
    static func reservedHeight(_ section: DetailSection) -> CGFloat {
        switch section {
        case .moreLikeThis:
            return Theme.Font.sectionTitleLineHeight + Theme.Spacing.md
                + Theme.Size.miniPosterHeight + 2 * Theme.Spacing.md
                + Theme.Spacing.md + Theme.Font.bodyLineHeight
        default:
            return 0
        }
    }
}

/// A2: the reserved slot of a section whose data has not answered yet (Apple-style only). Not
/// focusable and not anchored: it never takes focus, never takes the row's `.id(DetailRowID)` and
/// never reports a row top, so the real row takes that identity when it arrives.
struct DetailSectionSlot: View {
    let height: CGFloat

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .accessibilityHidden(true)
    }
}
