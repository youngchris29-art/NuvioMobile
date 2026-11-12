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

    /// What a held stop's hand-off does this pass.
    enum HandoffAction: Equatable {
        /// A person link is realized: assign focus to it (the stop is released on the next pass).
        case assign
        /// No id-bearing card is realized yet (the first one sits beyond the cards a `LazyHStack` has
        /// built): scroll the row to it by offset and look again; the stop stays focused meanwhile.
        case scroll
    }

    /// Review round 2 (finding 1): how many scroll-and-look-again attempts a held stop gets before it
    /// is dropped anyway (the target never appeared). Each attempt is one `performTailHandoff` run,
    /// ~0.4 s apart, so a stop is never held for more than a couple of seconds.
    static let maxScrollAttempts = 4

    /// Whether a scroll action taken as attempt `attempt` (0-based) actually scrolls: the attempt after
    /// the last one is a wait for the last scroll's cards, then the stop is dropped.
    static func issuesScroll(attempt: Int) -> Bool { attempt < maxScrollAttempts }

    /// What `resolve` decided for one body pass.
    struct Resolution: Equatable {
        /// The sections that are a tail stop this pass.
        var stops: Set<DetailSection>
        /// A section whose stop held focus when its own focus targets arrived (Cast & Crew gaining
        /// TMDB ids): the wrapper is gone this pass, so focus must be handed to one of the new
        /// links or it falls to nil. nil = no hand-off.
        var handoff: DetailSection?
        /// What the hand-off does (nil exactly when `handoff` is nil).
        var action: HandoffAction?
    }

    /// The tail plus a previous stop that still holds focus: a stop never vanishes under focus
    /// (a late comments or More Like This arrival below it), and is released when focus leaves.
    ///
    /// A stop is active only while its section has no focus target of its own, so focus anywhere in
    /// that section IS focus on the stop until links appear. When the section gains targets
    /// (`hasOwnTargets`) while its stop holds focus (round 1 P2), the stop is kept for that pass and
    /// reported as a hand-off (focus goes to a link); once focus is on a link (`linkFocused`) the stop
    /// is dropped, so the links are reachable and visible to VoiceOver and focus never falls to nil.
    /// A stop that does not hold focus is dropped at once.
    ///
    /// Review finding A: an ASSIGN hand-off lasts ONE pass. When the previous pass already reported
    /// it for this section (`previousHandoff`), the stop is dropped now whatever happened to focus:
    /// it is not retried, so a link that could not take focus can never leave the stop over live
    /// person links (cards hidden from VoiceOver, Select dead).
    ///
    /// Review round 2 (finding 1): when no link card is realized (`targetRealized` false) the stop is
    /// held with a SCROLL action instead, so focus stays in the row while it moves toward the first
    /// link; `scrollAttempts` (the attempts already made) bounds this: the stop is held for one more
    /// check pass after the last issued scroll (`scrollAttempts == maxScrollAttempts`, whose pass
    /// issues no scroll, see `issuesScroll`) and dropped once past it, so every issued scroll is checked. Leaving the row, or the section losing its targets, ends the hold at once.
    static func resolve(tail: Set<DetailSection>, previous: Set<DetailSection>, focused: DetailSection?,
                        hasOwnTargets: (DetailSection) -> Bool,
                        linkFocused: (DetailSection) -> Bool = { _ in false },
                        previousHandoff: DetailSection? = nil,
                        targetRealized: (DetailSection) -> Bool = { _ in true },
                        scrollAttempts: Int = 0) -> Resolution {
        guard let focused, previous.contains(focused) else { return Resolution(stops: tail, handoff: nil, action: nil) }
        guard hasOwnTargets(focused) else { return Resolution(stops: tail.union([focused]), handoff: nil, action: nil) }
        if linkFocused(focused) || previousHandoff == focused { return Resolution(stops: tail, handoff: nil, action: nil) }
        if targetRealized(focused) { return Resolution(stops: tail.union([focused]), handoff: focused, action: .assign) }
        if scrollAttempts > maxScrollAttempts { return Resolution(stops: tail, handoff: nil, action: nil) }
        return Resolution(stops: tail.union([focused]), handoff: focused, action: .scroll)
    }

    /// Review finding A: the hand-off's target, the first card that carries a person link AND is
    /// realized (a `LazyHStack` builds only the cards near the viewport, and a focus assignment to an
    /// unbuilt card does not take). nil = none is on screen: the stop is dropped anyway and focus stays
    /// wherever the engine puts it within the row.
    /// - Parameter cards: the row's cards in order, `hasLink` = carries a TMDB id.
    static func handoffTarget(cards: [(key: String, hasLink: Bool)], realized: Set<String>) -> String? {
        cards.first { $0.hasLink && realized.contains($0.key) }?.key
    }

    /// Review round 2 (finding 1): the index of the first card that carries a person link, realized or
    /// not (where the row must scroll to). nil = no card has one.
    static func firstLinkIndex(cards: [(key: String, hasLink: Bool)]) -> Int? {
        cards.firstIndex { $0.hasLink }
    }

    /// The horizontal offset that brings card `index` into a row of `pitch`-wide slots: one slot
    /// before it (so the card is well inside the viewport and the lazy stack builds it), nudged a half
    /// slot further on each later `attempt` (0-based) so an estimate that is a little short still
    /// converges. Never negative.
    static func scrollOffset(index: Int, pitch: Double, attempt: Int) -> Double {
        max(0, (Double(index) - 1 + 0.5 * Double(max(0, attempt))) * pitch)
    }

    /// Review round 2 (finding 2): what VoiceOver reads for a names-only Cast stop (after the heading):
    /// every person's name, each followed by the line the card shows under it (character, "Director",
    /// "Writer") when there is one. "Name, role, Name, Name, role".
    static func castStopPeopleLabel(_ people: [(name: String, subtitle: String?)]) -> String {
        people.map { person in
            let role = person.subtitle ?? ""
            return role.isEmpty ? person.name : "\(person.name), \(role)"
        }.joined(separator: ", ")
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

    /// What each section holds, judged the way its row builder judges it. Bools, not counts: only
    /// "any" matters, and a count over a Kotlin-bridged list allocates the whole Swift array
    /// (review finding B).
    struct Facts: Equatable {
        /// Videos with a season or episode number (what `EpisodesSection` lists).
        var numberedEpisodes = false
        var trailers = false
        var bonus = false
        var moreLikeThis = false
        var collection = false
        var comments = false
        var castItems = false
        var castWithIds = false
        var logos = false
        var logosWithIds = false
        var warnings = false
    }

    /// Data-driven: a section is focusable only if it has a focusable item (round 1 P2: a series
    /// with no numbered videos has an Episodes section with no focus target).
    static func kind(of section: DetailSection, facts: Facts) -> Kind {
        func list(_ any: Bool) -> Kind { any ? .focusable : .contentless }
        switch section {
        case .hero, .about: return .focusable
        case .episodes: return list(facts.numberedEpisodes)
        case .trailers: return list(facts.trailers)
        case .bonus: return list(facts.bonus)
        case .moreLikeThis: return list(facts.moreLikeThis)
        case .collection: return list(facts.collection)
        case .comments: return list(facts.comments)
        case .castAndCrew:
            return !facts.castItems ? .contentless : (facts.castWithIds ? .focusable : .inert)
        case .companies:
            return !facts.logos ? .contentless : (facts.logosWithIds ? .focusable : .inert)
        case .parentalGuide: return facts.warnings ? .inert : .contentless
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
    /// What the latest hand-off does, nil when none.
    private(set) var action: DetailTrailingFocus.HandoffAction?
    /// Scroll attempts made for the current hold (counted when `performTailHandoff` consumes a scroll
    /// action, not per body pass: unrelated re-renders must not use them up). Reset when no hold is active.
    private(set) var scrollAttempts = 0
    /// True once the latest `resolve`'s action was taken (focus assignment issued). An assign counts
    /// as the previous hand-off for the next `resolve`'s one-pass rule only once taken: an assign no
    /// `performTailHandoff` picked up stays an assign on the next pass instead of being dropped.
    private var taken = false

    func resolve(sections: [DetailSection], contentless: Set<DetailSection>, focused: DetailSection?,
                 hasOwnStop: (DetailSection) -> Bool,
                 linkFocused: (DetailSection) -> Bool = { _ in false },
                 targetRealized: (DetailSection) -> Bool = { _ in true }) -> Set<DetailSection> {
        let tail = DetailTrailingFocus.tailStops(sections: sections, contentless: contentless,
                                                 hasOwnStop: hasOwnStop)
        let result = DetailTrailingFocus.resolve(tail: tail, previous: stops, focused: focused,
                                                 hasOwnTargets: hasOwnStop, linkFocused: linkFocused,
                                                 previousHandoff: (action == .assign && taken) ? handoff : nil,
                                                 targetRealized: targetRealized, scrollAttempts: scrollAttempts)
        stops = result.stops
        handoff = result.handoff
        action = result.action
        taken = false
        if result.action != .scroll { scrollAttempts = 0 }
        return stops
    }

    /// The pending hand-off, taken once per `resolve`: a scroll action counts one attempt.
    func takeAction() -> (section: DetailSection, action: DetailTrailingFocus.HandoffAction, attempt: Int)? {
        guard !taken, let section = handoff, let action else { return nil }
        taken = true
        let attempt = scrollAttempts
        if action == .scroll { scrollAttempts += 1 }
        return (section, action, attempt)
    }
}
