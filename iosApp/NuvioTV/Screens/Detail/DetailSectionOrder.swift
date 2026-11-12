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

    /// The section a focused row belongs to (nil = no row, i.e. the hero).
    @MainActor
    static func section(for row: DetailRowID?) -> DetailSection? {
        guard let row else { return nil }
        return allCases.first { $0.rowID == row }
    }

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

    /// Whether the title's meta may still arrive: none yet AND the request has not finished with
    /// an error. Before the first emission (not loading, no error) it counts as loading, so the
    /// page never flashes "empty"; a failed request is finished, so its sections read empty and
    /// Apple-style drops their placeholders instead of keeping them forever.
    static func metaLoading(hasMeta: Bool, isLoading: Bool, failed: Bool) -> Bool {
        guard !hasMeta else { return false }
        return isLoading || !failed
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
    /// `held`: sections whose reserved slot is kept though their data answered empty
    /// (`DetailSlotHold`); they render as the same empty slot.
    static func sections(layout: DetailLayout, isSeries: Bool,
                         availability: DetailSectionAvailability,
                         held: Set<DetailSection> = []) -> [DetailSection] {
        let keepPending = reservesPendingSlots(layout)
        return preset(layout: layout, isSeries: isSeries).filter { section in
            switch availability.state(section) {
            case .ready: return true
            case .pending: return keepPending
            case .empty: return keepPending && held.contains(section)
            case .hidden: return false
            }
        }
    }
}

/// Apple-style: rows must never shift under focus when a section ABOVE the focused row loses its
/// content. One rule covers every case: any section that was on screen in this visit (its pending
/// placeholder, or its real row) and then answers EMPTY while focus is in a row below it keeps its
/// last on-screen height as a non-focusable empty slot. The slot goes for good once focus is at or
/// above it (the hero included); leaving the page drops it (the hold lives in the page's
/// `@State`). Typical case: More Like This shows TMDB's recommendations, then enrichment (Trakt,
/// Simkl) answers with none or times out while the viewer is in Cast & Crew.
///
/// Focus that is OFF the page (a cover such as the synopsis overlay holds it, or focus is being
/// restored after a pop) is neither the hero nor a row: the last on-page focus stands, so opening
/// a cover never releases a slot under it. Cinematic and Classic never reserve, so nothing is ever
/// held there.
nonisolated struct DetailSlotHold: Equatable {
    /// Where focus is, as the page knows it.
    enum Focus: Equatable {
        case hero
        case row(DetailSection)
        /// Neither the hero nor a row holds focus (a cover, a pushed page, a restore in flight).
        case offPage
    }

    /// Each on-screen (or held) section's last on-screen height.
    private(set) var lastHeight: [DetailSection: CGFloat] = [:]
    /// The last on-page focus (`offPage` keeps it).
    private(set) var lastFocus: Focus = .hero

    /// - Parameters:
    ///   - order: the layout's preset (`DetailSectionOrder.preset`), hero first.
    ///   - height: the section's on-screen height in its current state: the reservation for a
    ///     pending placeholder, the measured row height for a ready row (nil while unmeasured; the
    ///     last known height then stands).
    /// - Returns: the sections to draw as empty slots now, with their heights.
    mutating func update(order: [DetailSection], availability: DetailSectionAvailability, focus: Focus,
                         reservesSlots: Bool,
                         height: (DetailSection, DetailSectionState) -> CGFloat?) -> [DetailSection: CGFloat] {
        guard reservesSlots else {
            lastHeight = [:]
            lastFocus = .hero
            return [:]
        }
        if focus != .offPage { lastFocus = focus }
        let focusIndex: Int
        switch lastFocus {
        case .row(let section): focusIndex = order.firstIndex(of: section) ?? 0
        case .hero, .offPage: focusIndex = 0
        }
        var held: [DetailSection: CGFloat] = [:]
        for (index, section) in order.enumerated() where section != .hero {
            let state = availability.state(section)
            switch state {
            case .pending, .ready:
                if let h = height(section, state), h > 0 { lastHeight[section] = h }
            case .empty:
                if let h = lastHeight[section], focusIndex > index {
                    held[section] = h
                } else {
                    lastHeight[section] = nil
                }
            case .hidden:
                lastHeight[section] = nil
            }
        }
        return held
    }
}

/// `DetailView`'s holder for `DetailSlotHold`: a reference in `@State`, updated once per body
/// evaluation (focus and row-height changes re-run the body), so it never invalidates the view.
final class DetailSlotHoldBox {
    var hold = DetailSlotHold()
    /// The last `update` result, read by the page's other section-list consumers.
    private(set) var held: [DetailSection: CGFloat] = [:]

    func resolve(order: [DetailSection], availability: DetailSectionAvailability, focus: DetailSlotHold.Focus,
                 reservesSlots: Bool,
                 height: (DetailSection, DetailSectionState) -> CGFloat?) -> [DetailSection: CGFloat] {
        held = hold.update(order: order, availability: availability, focus: focus,
                           reservesSlots: reservesSlots, height: height)
        return held
    }
}

extension DetailSectionOrder {
    /// The height a `.pending` section reserves (Apple-style only). Only More Like This can land
    /// late (the enrichment emission) while focus is below the hero; every other row's data comes
    /// with the first meta, while focus is still in the hero, so they reserve nothing. More Like
    /// This is `DetailPosterLinkRow`'s geometry, read from the same tokens and setting the row uses
    /// (`moreLikeThisHeight`): the row title line, `md` gap, the mini poster inside its `md`
    /// vertical padding, and `PosterCard`'s caption (`md` gap plus one `cardTitle` line) only while
    /// poster titles show (Hide Labels off, `PosterStyle.showTitle`).
    @MainActor
    static func reservedHeight(_ section: DetailSection, posterTitlesShown: Bool) -> CGFloat {
        switch section {
        case .moreLikeThis:
            return moreLikeThisHeight(
                sectionTitleLine: Theme.Font.sectionTitleLineHeight, gap: Theme.Spacing.md,
                posterHeight: Theme.Size.miniPosterHeight,
                captionLine: posterTitlesShown ? Theme.Font.uiFont(for: .caption2).lineHeight : nil)
        default:
            return 0
        }
    }

    /// `captionLine` nil: Hide Labels is on and `PosterCard` draws no caption (nor its gap).
    nonisolated static func moreLikeThisHeight(sectionTitleLine: CGFloat, gap: CGFloat, posterHeight: CGFloat,
                                               captionLine: CGFloat?) -> CGFloat {
        let caption = captionLine.map { gap + $0 } ?? 0
        return sectionTitleLine + gap + posterHeight + 2 * gap + caption
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

/// BUG-244: which sections need a focus stop of their own because nothing focusable follows them.
///
/// The page scrolls only to reveal a focused view, so a content section after the last focus stop
/// (Parental Guide always; Cast & Crew when no card carries a TMDB id; Studio Logos when no chip
/// does) is shown only if it happens to fit under the engine's reveal margin. Each such section
/// becomes ONE focus stop (`DetailTailFocusStop`). Pure and `nonisolated`: the page's tests build
/// `sections` with the real presets.
nonisolated enum DetailTrailingFocus {
    /// Content sections after the last section that has a focus stop of its own (each needs one).
    /// - Parameters:
    ///   - sections: `DetailSectionOrder.sections(...)` output, in page order. The hero (a stop)
    ///     may be present or absent; it never lands in the tail.
    ///   - contentless: pending and held slots: no content, never a stop, skipped.
    ///   - hasOwnStop: whether a section has a focus stop without help (comments always: its cards
    ///     are built eagerly, `DetailCommentsList`).
    static func tailStops(sections: [DetailSection], contentless: Set<DetailSection>,
                          hasOwnStop: (DetailSection) -> Bool) -> Set<DetailSection> {
        var tail: Set<DetailSection> = []
        for section in sections.reversed() {
            if section == .hero || contentless.contains(section) { continue }
            if hasOwnStop(section) { break }
            tail.insert(section)
        }
        return tail
    }

    /// What `resolve` decided for one body pass.
    struct Resolution: Equatable {
        /// The sections that are a tail stop this pass.
        var stops: Set<DetailSection>
        /// A section whose stop held focus when its own focus targets arrived (Cast & Crew gaining
        /// TMDB ids): the wrapper is gone this pass, so focus must be handed to one of the new
        /// links or it falls to nil. nil = no hand-off.
        var handoff: DetailSection?
    }

    /// The tail plus a previous stop that still holds focus: a stop never vanishes under focus
    /// (a late comments or More Like This arrival below it), and is released when focus leaves.
    ///
    /// A stop is active only while its section has no focus target of its own, so focus anywhere in
    /// that section IS focus on the stop until links appear. When the section gains targets
    /// (`hasOwnTargets`) while its stop holds focus (round 1 P2), the stop is kept for that pass and
    /// reported as a hand-off (focus goes to the first link); once focus is on a link
    /// (`linkFocused`) the stop is dropped, so the links are reachable and visible to VoiceOver and
    /// focus never falls to nil. A stop that does not hold focus is dropped at once.
    static func resolve(tail: Set<DetailSection>, previous: Set<DetailSection>, focused: DetailSection?,
                        hasOwnTargets: (DetailSection) -> Bool,
                        linkFocused: (DetailSection) -> Bool = { _ in false }) -> Resolution {
        guard let focused, previous.contains(focused) else { return Resolution(stops: tail, handoff: nil) }
        guard hasOwnTargets(focused) else { return Resolution(stops: tail.union([focused]), handoff: nil) }
        if linkFocused(focused) { return Resolution(stops: tail, handoff: nil) }
        return Resolution(stops: tail.union([focused]), handoff: focused)
    }

    /// How a section behaves for the tail calculation, from what it ACTUALLY holds right now.
    enum Kind: Equatable {
        /// Has at least one focus target of its own.
        case focusable
        /// Has content but nothing focusable (Parental Guide; names-only Cast; Studio Logos without ids).
        case inert
        /// Present but empty (or not yet answered): no content, never a stop, skipped.
        case contentless
    }

    /// What each section holds, counted the way its row builder counts it.
    struct Facts: Equatable {
        /// Videos with a season or episode number (what `EpisodesSection` lists).
        var numberedEpisodes = 0
        var trailers = 0
        var bonus = 0
        var moreLikeThis = 0
        var collection = 0
        var comments = 0
        var castItems = 0
        var castWithIds = 0
        var logos = 0
        var logosWithIds = 0
        var warnings = 0
    }

    /// Data-driven: a section is focusable only if it has a focusable item (round 1 P2: a series
    /// with no numbered videos has an Episodes section with no focus target).
    static func kind(of section: DetailSection, facts: Facts) -> Kind {
        func list(_ count: Int) -> Kind { count > 0 ? .focusable : .contentless }
        switch section {
        case .hero, .about: return .focusable
        case .episodes: return list(facts.numberedEpisodes)
        case .trailers: return list(facts.trailers)
        case .bonus: return list(facts.bonus)
        case .moreLikeThis: return list(facts.moreLikeThis)
        case .collection: return list(facts.collection)
        case .comments: return list(facts.comments)
        case .castAndCrew:
            return facts.castItems == 0 ? .contentless : (facts.castWithIds > 0 ? .focusable : .inert)
        case .companies:
            return facts.logos == 0 ? .contentless : (facts.logosWithIds > 0 ? .focusable : .inert)
        case .parentalGuide: return facts.warnings > 0 ? .inert : .contentless
        }
    }

    /// `tailStops` driven by `Facts`: pending and held slots plus every present-but-empty section
    /// are contentless; only `.focusable` sections end the scan.
    static func tailStops(sections: [DetailSection], pendingOrHeld: Set<DetailSection>, facts: Facts) -> Set<DetailSection> {
        let empty = Set(sections.filter { kind(of: $0, facts: facts) == .contentless })
        return tailStops(sections: sections, contentless: pendingOrHeld.union(empty),
                         hasOwnStop: { kind(of: $0, facts: facts) == .focusable })
    }
}

/// `DetailView`'s holder for `DetailTrailingFocus`: a reference in `@State`, written once per body
/// evaluation (focus and layout changes re-run the body), so it never invalidates the view.
final class DetailTailStopBox {
    private(set) var stops: Set<DetailSection> = []
    /// The hand-off of the latest `resolve`, nil when none (set on the one pass it happens).
    private(set) var handoff: DetailSection?

    func resolve(sections: [DetailSection], contentless: Set<DetailSection>, focused: DetailSection?,
                 hasOwnStop: (DetailSection) -> Bool,
                 linkFocused: (DetailSection) -> Bool = { _ in false }) -> Set<DetailSection> {
        let tail = DetailTrailingFocus.tailStops(sections: sections, contentless: contentless,
                                                 hasOwnStop: hasOwnStop)
        let result = DetailTrailingFocus.resolve(tail: tail, previous: stops, focused: focused,
                                                 hasOwnTargets: hasOwnStop, linkFocused: linkFocused)
        stops = result.stops
        handoff = result.handoff
        return stops
    }
}
