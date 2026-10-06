import Foundation
import SharedCore

// Search & Discover batch 2026-10-06 (B3 a): the ambient wash behind Search follows focus.
//
// Search has no stage and no swap core, so it feeds `AmbientWashLayer` through a `StageWashFeed` of
// its own: a focused title becomes the feed's `pending` at once (the layer warms its render) and its
// `displayed` after 0.45 s of quiet, Home's pause, so the re-ranks that arrive while typing don't
// thrash the wash; the layer's own 0.4 s cross-fade follows. A new title re-arms the wait.
//
// Who the wash shows:
// - a focused result card (a grouped or per-add-on row, the Top result card);
// - while focus is NOT in the results (the keyboard, the suggestion chips), the Top result, so the
//   page under the keyboard takes the colour of what the search would open first;
// - a focused person keeps the last wash (a face makes a poor wash);
// - an empty query clears it (the idle page's Discover tiles report nothing).
//
// "Focus is in the results" is known exactly in Rail mode (`NavigationChromeModel
// .searchKeyboardFocused`, B4) and inferred everywhere: a card or person report sets it, typing or
// the keyboard flag clears it. A card's nil report (focus left that row) is ignored, because the row
// gaining focus and the row losing it report in no fixed order.

/// The pure timing half, generic so tests drive it with plain strings and an injected clock.
nonisolated struct SearchWashPolicy<Item: Equatable> {
    /// Home's pause before the wash follows a new title.
    static var quietDelay: TimeInterval { 0.45 }

    /// What the wash warms (the latest proposal).
    private(set) var pending: Item?
    /// What the wash shows.
    private(set) var displayed: Item?
    /// When `pending` becomes `displayed`; nil when nothing is waiting.
    private(set) var deadline: TimeInterval?
    /// Focus is on a result (card or person), so a Top result change must not move the wash.
    private(set) var focusInResults = false

    init() {}

    /// A result card reported focus. nil (focus left a row) is ignored: see the file header.
    mutating func report(_ item: Item?, now: TimeInterval) {
        guard let item else { return }
        focusInResults = true
        propose(item, now: now)
    }

    /// Focus moved onto a result that never drives the wash (a person): keep the wash, and stop
    /// following the Top result.
    mutating func noteResultFocus() {
        focusInResults = true
    }

    /// The system keyboard took focus (Rail mode's exact signal): show the Top result.
    mutating func keyboardFocused(topResult: Item?, now: TimeInterval) {
        focusInResults = false
        if let topResult { propose(topResult, now: now) }
    }

    /// The query changed: whoever is typing holds the keyboard. Nothing moves until the next
    /// Top result arrives.
    mutating func queryTyped() {
        focusInResults = false
    }

    /// The search's Top result changed. Followed only while focus is outside the results; nil
    /// keeps the last wash (a new search loading, or nothing found yet).
    mutating func topResultChanged(_ topResult: Item?, now: TimeInterval) {
        guard !focusInResults, let topResult else { return }
        propose(topResult, now: now)
    }

    /// The pending title is due: returns true when `displayed` changed.
    mutating func tick(now: TimeInterval) -> Bool {
        guard let deadline, now + 0.000_5 >= deadline else { return false }
        self.deadline = nil
        guard displayed != pending else { return false }
        displayed = pending
        return true
    }

    /// Empty query: nothing warms, nothing shows.
    mutating func clear() {
        pending = nil
        displayed = nil
        deadline = nil
        focusInResults = false
    }

    private mutating func propose(_ item: Item, now: TimeInterval) {
        if item == displayed {
            // Back on what the wash already shows: nothing to wait for.
            pending = item
            deadline = nil
            return
        }
        // The same title again (a row re-reporting its focused card) keeps the running wait.
        guard item != pending || deadline == nil else { return }
        pending = item
        deadline = now + Self.quietDelay
    }
}

/// Owns Search's wash feed and the one scheduled wake the policy needs. Held by `SearchViewOwner`
/// (never published); only `AmbientWashLayer` observes `feed`.
@MainActor
final class SearchWashDriver {
    let feed = StageWashFeed()

    private var policy = SearchWashPolicy<StageFeedItem>()
    private var wake: DispatchWorkItem?
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// A result card's focus report (`CatalogRowView.onItemFocusChange`, the Top result card).
    func report(_ item: MetaPreview?) {
        policy.report(item.map(Self.feedItem), now: now())
        publish()
    }

    /// A person took focus: the wash stays where it is.
    func noteResultFocus() {
        policy.noteResultFocus()
    }

    /// Rail mode: the system keyboard took focus.
    func keyboardFocused(topResult: MetaPreview?) {
        policy.keyboardFocused(topResult: topResult.map(Self.feedItem), now: now())
        publish()
    }

    /// The field's text changed (non-empty).
    func queryTyped() {
        policy.queryTyped()
    }

    func topResultChanged(_ topResult: MetaPreview?) {
        policy.topResultChanged(topResult.map(Self.feedItem), now: now())
        publish()
    }

    /// Empty query.
    func clear() {
        wake?.cancel()
        wake = nil
        policy.clear()
        feed.setPending(nil)
        feed.setDisplayed(nil)
    }

    private func publish() {
        feed.setPending(policy.pending)
        schedule()
    }

    private func schedule() {
        wake?.cancel()
        wake = nil
        guard let deadline = policy.deadline else { return }
        let item = DispatchWorkItem { [weak self] in self?.fire() }
        wake = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - now()), execute: item)
    }

    private func fire() {
        wake = nil
        if policy.tick(now: now()) {
            feed.setDisplayed(policy.displayed)
        } else if policy.deadline != nil {
            schedule()
        }
    }

    private static func feedItem(_ item: MetaPreview) -> StageFeedItem {
        StageFeedItem(item: item, identity: "\(item.type):\(item.id)", washFallback: nil)
    }
}
