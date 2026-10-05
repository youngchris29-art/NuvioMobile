import SwiftUI

// Home Stage & Strip (P1 §3.3): per-row focus memory for the strip.
//
// `UIFocusSystem.requestFocusUpdate(to:)` does not stick on SwiftUI items (Wave 0.5 spike), so the
// memory is SwiftUI-side: every Home row already applies `pinnedRowUpFallbackTarget` to its own
// `@FocusState`, and with `\.stripFocusMemory` set (the strip is the only host that sets it) that
// modifier records the focused card per row and names it to `.defaultFocus` and to focus requests.
// Classic never sets the key, so every new path there is dead.

/// The last focused card per strip row, keyed by the row key the rows pass to
/// `pinnedRowUpFallbackTarget(rowKey:)` ("continue-watching", "upcoming", `section.key`, the bare
/// `collection.id`).
///
/// A reference box, NOT observed: rows re-evaluate on their own focus changes, so `.defaultFocus`
/// reads a fresh value whenever it matters, and Home never re-renders per horizontal step (the
/// BUG-126 rule).
@MainActor
final class StripFocusMemory {
    /// Whether remembered cards drive `.defaultFocus` on Down/Up (`StageStripTuning
    /// .focusMemoryDefaultFocus`, `-debug.stripFocusMemory off`). Recording, Menu restores and rail
    /// restores work either way.
    let drivesDefaultFocus: Bool

    private var byRow: [String: String] = [:]

    #if DEBUG
    /// The `debug_strip … foc=` readout. DEBUG only, set by `StageController`.
    var onRemember: (@MainActor (_ rowKey: String, _ itemId: String) -> Void)?
    #endif

    init(drivesDefaultFocus: Bool = true) {
        self.drivesDefaultFocus = drivesDefaultFocus
    }

    func remember(rowKey: String, itemId: String) {
        byRow[rowKey] = itemId
        #if DEBUG
        onRemember?(rowKey, itemId)
        #endif
    }

    func itemId(for rowKey: String) -> String? {
        byRow[rowKey]
    }

    /// Drops rows that are no longer on Home (called on every row-set change).
    func prune(keeping keys: Set<String>) {
        byRow = byRow.filter { keys.contains($0.key) }
    }

    /// Rows with a remembered card (tests and probes).
    var rememberedRowCount: Int { byRow.count }
}

private struct StripFocusMemoryKey: EnvironmentKey {
    static let defaultValue: StripFocusMemory? = nil
}

extension EnvironmentValues {
    /// Set only by `StripPager` (Home's strip and the folder Rows page). nil everywhere else, which
    /// keeps `pinnedRowUpFallbackTarget` byte-identical for Classic, Search and Library.
    var stripFocusMemory: StripFocusMemory? {
        get { self[StripFocusMemoryKey.self] }
        set { self[StripFocusMemoryKey.self] = newValue }
    }
}

/// A row the strip remounted (it mounts only the rows inside `StripMountWindow`) has lost its
/// horizontal offset, so its remembered card may be unrealized and `.defaultFocus` cannot land on
/// it. This is the offset that brings card `index` back into view with the least travel.
///
/// Horizontal-only on purpose: the row scrolls through its own `ScrollPosition`
/// (`CatalogRowView.rowPosition`, the M3 morph-scroll path), which cannot move the strip vertically.
/// An item-anchored `ScrollViewProxy.scrollTo` can spill into the enclosing vertical scroll view
/// (the M3 note on `RowMorphScroll`), and in the strip that would knock the page off its boundary.
nonisolated enum StripRowRestore {
    /// Raw scroll-coordinate x for `ScrollPosition.scrollTo(x:)`, or nil when card `index` is
    /// already fully visible. Uniform card widths (`cardWidth` + `gap` per step), as every catalog
    /// row lays out.
    static func offset(index: Int, cardWidth: CGFloat, gap: CGFloat, sample: RowHScrollSample) -> CGFloat? {
        guard index >= 0, cardWidth > 0, sample.viewportWidth > 0 else { return nil }
        let leading = sample.insetLeading + CGFloat(index) * (cardWidth + gap)
        let trailing = leading + cardWidth
        let visibleMin = sample.paddedVisibleMinX
        let visibleMax = visibleMin + sample.viewportWidth
        let target: CGFloat
        if leading < visibleMin - 0.5 {
            target = leading
        } else if trailing > visibleMax + 0.5 {
            target = trailing - sample.viewportWidth
        } else {
            return nil
        }
        let maxOffset = max(0, sample.paddedContentWidth - sample.viewportWidth)
        return min(max(target, 0), maxOffset) - sample.insetLeading
    }
}

/// Review r1 (A P3-8): a row heading in the strip stays on one line, as `StripGeometry`'s row
/// height assumes (with No Zoom there is no lift slack for a second line). Absent outside the
/// strip, where `\.stripFocusMemory` is nil, so Classic's headings are unchanged.
struct StripHeadingLineLimit: ViewModifier {
    @Environment(\.stripFocusMemory) private var stripFocusMemory

    func body(content: Content) -> some View {
        if stripFocusMemory != nil {
            content.lineLimit(1)
        } else {
            content
        }
    }
}

extension View {
    func stripHeadingLineLimit() -> some View {
        modifier(StripHeadingLineLimit())
    }
}

/// Review r1 (A P2-3): `StripRowRestore`'s inputs for a row with no morph-scroll path of its own
/// (Continue Watching): the row's horizontal geometry into a reference box (never view state) and
/// a horizontal `ScrollPosition` target. Structurally absent when `enabled` is false, i.e. outside
/// the strip, so Classic's row is unchanged; `enabled` is constant for a row's lifetime.
struct StripRowScrollRestore: ViewModifier {
    let enabled: Bool
    let box: RowHScrollBox
    @Binding var position: ScrollPosition

    func body(content: Content) -> some View {
        if enabled {
            content
                .onScrollGeometryChange(for: RowHScrollSample.self, of: { geo in
                    RowHScrollSample(geo)
                }, action: { _, sample in
                    box.record(sample)
                })
                .scrollPosition($position)
        } else {
            content
        }
    }
}

/// Which strip rows mount real content: the window's centre and `radius` rows on each side. Every
/// other page is an empty frame of the same height, so the strip keeps its full scroll geometry
/// while only a few rows exist. The row above and the row below the focused one are always inside,
/// so a Down or Up never lands in a row that is being built (see `StripPager`'s body).
nonisolated enum StripMountWindow {
    static let radius = 2

    static func range(center: Int, count: Int, radius: Int = StripMountWindow.radius) -> ClosedRange<Int> {
        guard count > 0 else { return 0...0 }
        let c = min(max(center, 0), count - 1)
        return max(0, c - radius)...min(count - 1, c + radius)
    }
}
