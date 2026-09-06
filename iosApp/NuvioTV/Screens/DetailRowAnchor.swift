import SwiftUI

/// BUG-96 (beta.18): the detail page's rows had no resting place. The page is a plain vertical
/// `ScrollView`, each row is a title above a horizontal shelf of cards, and the cards are the only
/// focusable frames — so a vertical focus move scrolled by exactly the minimum tvOS needed to reveal
/// the focused card, and wherever that left the top edge was incidental. The tester's photos: the
/// film's Saga row focused, and the "Guide parental" header two rows up cut in half under the top
/// edge. Official Nuvio's Compose TV list pivots the focused row to a fixed viewport fraction, so
/// headers above scroll off whole.
///
/// The fix anchors the FOCUSED ROW to a fixed top inset: on a focused-row change, `DetailView`
/// issues an animated `scrollTo(rowId, anchor:)` at once, so the engine's own reveal and the anchor
/// move run as one motion rather than a land-then-nudge (the Home "oops" class). There is nothing
/// here for the two to fight over — no pinned header, no compression, and every row is far shorter
/// than the viewport, so the engine's rest is unique and ours simply supersedes it.
enum DetailRowAnchor {
    /// Where a focused row's TOP rests, in points from the scroll view's top edge. Room for the
    /// row above's bottom padding to have scrolled away whole, and for the focused row's title to
    /// sit clear of the top edge with a cushion under the dim ramp's first steps.
    static let topInset: CGFloat = 72

    /// How long after a focus change the anchor move is issued: the engine's own reveal animates
    /// for roughly a quarter second and overrides anything issued before it finishes.
    static let settleDelay: TimeInterval = 0.35

    /// The named coordinate space on the scroll content (the padded VStack), so row tops can be read
    /// as content offsets.
    static let contentSpace = "detailContent"

    /// The content offset that rests a row whose top is at `rowTop` (content coordinates) at
    /// `topInset` below the viewport's top: `rowTop − topInset`, never negative. The scroll view
    /// clamps the far end itself. This is the same mechanism Home's settle corrector uses
    /// (`ScrollPosition.scrollTo(y:)`); `ScrollViewProxy.scrollTo(id, anchor:)` is ignored by the
    /// focus-driven vertical scroll on this runtime (first fixture runs: nothing ever moved).
    static func targetOffset(rowTop: CGFloat, topInset: CGFloat = topInset) -> CGFloat {
        max(rowTop - topInset, 0)
    }

    /// Where the focused row's TOP rests on SCREEN, in points from the top edge. Content scrolls
    /// under the scroll view's top content inset (157 pt on the fixture: safe area plus the page
    /// chrome's reservation), and nothing covers it, so the rest is set in screen terms.
    static let screenRest: CGFloat = 108

    /// The strip above the rest shows the previous row's tail (its chips, captions, or the bottom
    /// of a header — fixture step 3: the "Parental Guide" header half under the edge). A fixed top
    /// scrim fades that strip to black once the page has scrolled, the same way the dim ramp
    /// treats the backdrop, so cut content reads as scrolled away; the rest sits just under it.
    static let topScrimHeight: CGFloat = 96

    /// `ScrollPosition.scrollTo(y:)` takes CONTENT coordinates and lands the content offset at
    /// `y − contentInsets.top` (fixture probe: `y=890` → `off=733` with `inset=157`). The row's
    /// screen top is then `rowTop − offset`, so for a rest at `screenRest`:
    /// `y = rowTop + contentInsetTop − screenRest`, never negative.
    static func scrollTarget(rowTop: CGFloat, contentInsetTop: CGFloat, screenRest: CGFloat = screenRest) -> CGFloat {
        max(rowTop + contentInsetTop - screenRest, 0)
    }

    /// The content offset that target produces, for the verify pass.
    static func expectedOffset(scrollTarget y: CGFloat, contentInsetTop: CGFloat) -> CGFloat {
        y - contentInsetTop
    }

    /// A rest further than this from the expected offset gets ONE re-issue: the focused card's
    /// thumbnails can finish loading after the settle, and the engine re-reveals the resized card
    /// (fixture step 6: 286 pt short). One retry, never a loop — the Home bounce class.
    static let verifyTolerance: CGFloat = 24
    static let verifyDelay: TimeInterval = 0.45

    /// `scrollTo(_:anchor:)` aligns the row's anchor POINT with the scroll view's same anchor point:
    /// `row.minY + k·rowHeight == viewport.minY + k·viewportHeight`. Solving for the row's top to
    /// land at `topInset`: `k = topInset / (viewportHeight − rowHeight)`. Clamped to the unit range;
    /// a row taller than the remaining viewport can only be top-aligned.
    static func anchor(rowHeight: CGFloat, viewportHeight: CGFloat, topInset: CGFloat = topInset) -> UnitPoint {
        let room = viewportHeight - rowHeight
        guard room > 0 else { return .top }
        let k = topInset / room
        return UnitPoint(x: 0, y: min(max(k, 0), 1))
    }
}

/// The rows the anchor tracks. `topBlock` (hero, synopsis, actions) is deliberately absent: focus
/// there means "the page is at the top", and anchoring it would scroll the backdrop away.
enum DetailRowID: Hashable {
    case logos, parental, episodes, cast, collection, trailers, moreLikeThis, comments
}

/// Attach to each detail row at its call site: gives it a scroll id, reports whether focus is
/// inside it, and measures its height (rarely changing, so no per-frame invalidation — the BUG-41
/// rule) for the anchor math.
struct DetailRowAnchored: ViewModifier {
    let id: DetailRowID
    let focusedRow: FocusState<DetailRowID?>.Binding
    /// Each row's top, in the scroll CONTENT's own coordinate space (`DetailRowAnchor.contentSpace`):
    /// content coordinates do not move as the page scrolls, so this changes only on layout.
    let offsets: Binding<[DetailRowID: CGFloat]>

    func body(content: Content) -> some View {
        content
            .id(id)
            .focused(focusedRow, equals: id)
            .onGeometryChange(for: CGFloat.self,
                              of: { $0.frame(in: .named(DetailRowAnchor.contentSpace)).minY },
                              action: { top in
                if offsets.wrappedValue[id] != top { offsets.wrappedValue[id] = top }
            })
    }
}

extension View {
    func detailRowAnchored(_ id: DetailRowID,
                           focusedRow: FocusState<DetailRowID?>.Binding,
                           offsets: Binding<[DetailRowID: CGFloat]>) -> some View {
        modifier(DetailRowAnchored(id: id, focusedRow: focusedRow, offsets: offsets))
    }
}
