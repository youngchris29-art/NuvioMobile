import Combine
import SwiftUI

// beta.19-rc1 verdict (M3 + M4/FEAT-52): when may a focus-dwelled trailer start?
//
// Steven's beta.19-rc1 video (BUG-133): the inline trailer's morph started while the rows were
// still sliding. The old dwell was a 1 s wall clock from focus (`InlineTrailerCardModel.startDwell`),
// blind to row motion, and the engine's row slide after a Down press takes ~1.15 s to settle. The
// dwell now waits on a REST signal instead: the rows have stopped (no motion for `restQuiet`, and
// no settle decision still to come), then the Trailer Start Delay setting decides how long after
// that (Automatic) or after focus (1/2/3 s, never before rest) the trailer starts.
//
// Reused by the Stage & Strip batch (`docs/home-stage-strip-plan-2026-10-03.md`): its paging strip
// feeds `RowRestSource.custom` from its own page-animation signal, and "Automatic" there means
// "strip at rest + 1 s".

// MARK: - Rows motion clock

/// Rows motion stamp for hosts with no settle corrector (Search, classic Home, and the horizontal
/// scroll of every catalog row). Main-actor static, written from `onScrollGeometryChange` ACTIONS:
/// a timestamp write, never view state (the BUG-19/41 rule: no per-frame `@State` writes on a
/// scrolling view).
enum RowsMotionClock {
    /// `ProcessInfo.systemUptime` of the last stamp; nil until anything has moved this session.
    private static var lastMotion: TimeInterval?

    static func stamp(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastMotion = now
    }

    /// Seconds since the rows last moved; `.greatestFiniteMagnitude` when they never did (a row
    /// that mounted and was never scrolled is at rest by any reading).
    static func secondsSinceMotion(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        guard let lastMotion else { return .greatestFiniteMagnitude }
        return max(0, now - lastMotion)
    }

    /// Half-point buckets for the stamp observers below. `onScrollGeometryChange` only runs its
    /// action when the transformed value CHANGES, so bucketing the offset means the action fires
    /// once per 0.5 pt of cumulative travel: a slow ease-out tail whose per-frame delta is below
    /// half a point still stamps (a per-frame `abs(new − old) > 0.5` test would read it as rest
    /// while the row is visibly creeping), and a still row never fires at all.
    nonisolated static func bucket(_ offset: CGFloat) -> Int {
        Int((offset * 2).rounded())
    }

    #if DEBUG
    static func resetForTesting() { lastMotion = nil }
    #endif
}

private struct RowsMotionStampModifier: ViewModifier {
    let axis: Axis

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: Int.self, of: { [axis] geo in
            RowsMotionClock.bucket(axis == .vertical ? geo.contentOffset.y : geo.contentOffset.x)
        }, action: { _, _ in
            RowsMotionClock.stamp()
        })
    }
}

extension View {
    /// beta.19-rc1 verdict (M3): stamps `RowsMotionClock` whenever this scroll view's offset on
    /// `axis` moves by half a point or more (see `RowsMotionClock.bucket`). Attach to a ScrollView.
    /// Content-size growth (an inline trailer morph widening a row) does not move the offset, so it
    /// does not stamp.
    func rowsMotionStamp(_ axis: Axis) -> some View {
        modifier(RowsMotionStampModifier(axis: axis))
    }
}

// MARK: - Rest source

/// What a host publishes so a dwelling trailer knows when the rows are at rest.
/// The Stage & Strip batch feeds `.custom` from its strip's own paging signal.
@MainActor protocol RowRestSignal: AnyObject, Sendable {
    /// True while a rest decision is still to come (a page or settle animation in flight).
    var restPending: Bool { get }
    /// Seconds since the rows last moved; `.greatestFiniteMagnitude` when they never did.
    var secondsSinceMotion: TimeInterval { get }
}

/// Which rest signal a trailer host reads. Set per host through `EnvironmentValues.rowRestSource`
/// (catalog cards) or assigned straight onto the model (`HomeView`'s hero model).
nonisolated enum RowRestSource: Equatable, Sendable {
    /// `RowsMotionClock` only (Search, classic Home, any host that sets nothing).
    case motionClock
    /// Pinned Home: pending = `PinnedRowSettle.isRestPending`; sinceMotion = the smaller of
    /// `PinnedRowSettle.secondsSinceMotion()` and `RowsMotionClock.secondsSinceMotion()` —
    /// horizontal row scrolls are not in the settle corrector's clock, only in ours.
    case pinnedHome
    /// Any other host; `==` compares by `ObjectIdentifier`.
    case custom(any RowRestSignal)

    static func == (lhs: RowRestSource, rhs: RowRestSource) -> Bool {
        switch (lhs, rhs) {
        case (.motionClock, .motionClock), (.pinnedHome, .pinnedHome):
            return true
        case let (.custom(a), .custom(b)):
            return ObjectIdentifier(a) == ObjectIdentifier(b)
        default:
            return false
        }
    }

    /// `TrailerStartGate.isAtRest` over this source's readings.
    @MainActor func isAtRest() -> Bool {
        switch self {
        case .motionClock:
            return TrailerStartGate.isAtRest(sinceMotion: RowsMotionClock.secondsSinceMotion(), restPending: false)
        case .pinnedHome:
            let since = min(PinnedRowSettle.secondsSinceMotion(), RowsMotionClock.secondsSinceMotion())
            return TrailerStartGate.isAtRest(sinceMotion: since, restPending: PinnedRowSettle.isRestPending)
        case .custom(let signal):
            return TrailerStartGate.isAtRest(sinceMotion: signal.secondsSinceMotion, restPending: signal.restPending)
        }
    }

    /// Probe spelling for `[TrailerPipeline] gate` lines.
    var probeTag: String {
        switch self {
        case .motionClock: return "clock"
        case .pinnedHome: return "pinned"
        case .custom: return "custom"
        }
    }
}

private struct RowRestSourceKey: EnvironmentKey {
    static let defaultValue: RowRestSource = .motionClock
}

extension EnvironmentValues {
    /// beta.19-rc1 verdict (M3): the rest signal `InlineTrailerCard` hands its model before every
    /// dwell. Default `.motionClock`; Home's pinned container sets `.pinnedHome` (W2-E), the Stage
    /// & Strip batch sets `.custom(stripSignal)`.
    var rowRestSource: RowRestSource {
        get { self[RowRestSourceKey.self] }
        set { self[RowRestSourceKey.self] = newValue }
    }
}

// MARK: - FEAT-52 Trailer Start Delay

/// FEAT-52 "Trailer Start Delay": a device-local `@AppStorage` key, like every Home Screen trailer
/// key (`inline_trailers_enabled`, `trailer_playback_location`, `hero_trailer_autoplay`). No sync,
/// no Kotlin; `-trailer_start_delay 2` works as a launch argument.
///
/// Semantics (Christian, 2026-10-03): Automatic = the rows stopped + 1 s. 1/2/3 s = that long
/// after focus lands, never before the rows stop.
nonisolated enum TrailerStartDelay: String, CaseIterable, Sendable {
    case automatic = "auto"
    case oneSecond = "1"
    case twoSeconds = "2"
    case threeSeconds = "3"

    static let storageKey = "trailer_start_delay"

    /// Read once per dwell; missing or unknown → `.automatic`.
    static func current(_ defaults: UserDefaults = .standard) -> TrailerStartDelay {
        defaults.string(forKey: storageKey).flatMap(TrailerStartDelay.init(rawValue:)) ?? .automatic
    }

    /// Picker label. Same "N s" spelling as Playback's read-ahead picker ("30 s").
    var label: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .oneSecond: return String(localized: "1 s")
        case .twoSeconds: return String(localized: "2 s")
        case .threeSeconds: return String(localized: "3 s")
        }
    }

    /// Seconds from focus for the fixed values; nil for `.automatic` (counted from rest instead).
    var fixedSeconds: TimeInterval? {
        switch self {
        case .automatic: return nil
        case .oneSecond: return 1
        case .twoSeconds: return 2
        case .threeSeconds: return 3
        }
    }
}

// MARK: - The planner

/// The pure start planner, unit-tested as a table (`TrailerStartGateTests`).
nonisolated enum TrailerStartGate {
    /// Quiet time that counts as rest. = `RowStepAB.restThreshold` (the BUG-126 hero-commit gate).
    static let restQuiet: TimeInterval = 0.12
    /// Automatic: start this long after the rows came to rest.
    static let automaticAfterRest: TimeInterval = 1.0
    /// Focus → start cap while no rest has been seen: start anyway (`via=ceiling`). Covers a
    /// phantom-armed corrector (the rc13 class) that would otherwise hold the trailer forever.
    static let restCeiling: TimeInterval = 3.0
    /// R2 (§2.3): the tile-art prefetch starts at the first at-rest reading or this far into the
    /// dwell, whichever is first — never at focus, so a horizontal scrub fires no fetch per card.
    static let artPrefetchAfter: TimeInterval = 0.3
    static let poll: TimeInterval = 0.05

    static func isAtRest(sinceMotion: TimeInterval, restPending: Bool) -> Bool {
        !restPending && sinceMotion >= restQuiet
    }

    nonisolated enum Step: Equatable, Sendable {
        case wait(TimeInterval)
        case start(via: String)
    }

    /// - Parameters:
    ///   - focusAge: seconds since focus landed.
    ///   - restAge: seconds since the CURRENT rest began; nil while the rows are not at rest.
    ///
    /// Automatic starts at rest + 1 s. A fixed N starts at max(focus + N, rest): counted from focus
    /// but never before the rows stop (Christian 2026-10-03). With no rest at all, the ceiling.
    static func step(delay: TrailerStartDelay, focusAge: TimeInterval, restAge: TimeInterval?) -> Step {
        guard let restAge else {
            return focusAge >= restCeiling ? .start(via: "ceiling") : .wait(poll)
        }
        let need: TimeInterval
        if let fixed = delay.fixedSeconds {
            need = fixed - focusAge
        } else {
            need = automaticAfterRest - restAge
        }
        return need <= 0 ? .start(via: "rest") : .wait(min(need, poll))
    }
}

// MARK: - Row morph scroll (M3 §1.6)

/// One horizontal-row `onScrollGeometryChange` sample, kept in `RowHScrollBox` (a reference box,
/// never view state). `nonisolated` + `Sendable` like `TabBarScrollSample` / `PinnedRowSettle
/// .ScrollSample`, so the transform closure can build it without an isolation hop.
///
/// `offsetX` is the raw `contentOffset.x` (which reads `−insetLeading` at rest), and the insets are
/// carried alongside, so the caller can map into the padded-content space `RowMorphScroll` works in
/// (critique #24). The rows have no horizontal content insets today; nothing pins that.
nonisolated struct RowHScrollSample: Equatable, Sendable {
    var offsetX: CGFloat
    var viewportWidth: CGFloat
    var contentWidth: CGFloat
    var insetLeading: CGFloat
    var insetTrailing: CGFloat

    init(offsetX: CGFloat, viewportWidth: CGFloat, contentWidth: CGFloat,
         insetLeading: CGFloat, insetTrailing: CGFloat) {
        self.offsetX = offsetX
        self.viewportWidth = viewportWidth
        self.contentWidth = contentWidth
        self.insetLeading = insetLeading
        self.insetTrailing = insetTrailing
    }

    init(_ geo: ScrollGeometry) {
        self.init(offsetX: geo.contentOffset.x,
                  viewportWidth: geo.containerSize.width,
                  contentWidth: geo.contentSize.width,
                  insetLeading: geo.contentInsets.leading,
                  insetTrailing: geo.contentInsets.trailing)
    }

    /// The viewport's leading edge in padded-content space (0 at rest whatever the inset).
    var paddedVisibleMinX: CGFloat { offsetX + insetLeading }
    /// The whole scrollable extent in padded-content space.
    var paddedContentWidth: CGFloat { insetLeading + contentWidth + insetTrailing }
}

/// `CatalogRowView`'s per-row scroll box. Written from the row's `onScrollGeometryChange` ACTION on
/// every horizontal scroll frame, read by the morph-scroll pass; a reference type held in `@State`
/// so a write never invalidates the row (the `SettleWorkBox` / `TitleTrackingCache` pattern).
final class RowHScrollBox {
    private(set) var sample: RowHScrollSample?
    /// Offset at the last `RowsMotionClock` stamp, so the stamp follows cumulative travel (≥ 0.5 pt)
    /// rather than per-frame deltas, and content-width growth during a morph never stamps.
    private var lastStampedOffsetX: CGFloat?

    func record(_ new: RowHScrollSample) {
        sample = new
        if let last = lastStampedOffsetX {
            if abs(new.offsetX - last) > 0.5 {
                lastStampedOffsetX = new.offsetX
                RowsMotionClock.stamp()
            }
        } else {
            // First reading after mount: a baseline, not motion.
            lastStampedOffsetX = new.offsetX
        }
    }
}

/// beta.19-rc1 verdict (M3, BUG-133): the morph's row scroll is horizontal-only and is dropped when
/// the expanding tile already fits. The old `proxy.scrollTo(itemId)` pair aimed at the card's
/// `.id` Group, whose frame carries the 88 pt pinned top reach, so a "minimal" scroll could spill
/// into the enclosing vertical rows `ScrollView` and re-arm the settle corrector mid-morph. A
/// horizontal `ScrollPosition` cannot move the rows vertically.
nonisolated enum RowMorphScroll {
    /// Launch-latched escape hatch for the §1.6.4 fallback, read once (all builds, like
    /// `debug.rowStepAB`, so it can also be tried on a device sideload):
    ///
    ///     -debug.trailerMorphScrollProxy YES
    ///
    /// YES = no `.scrollPosition` on the row at all; one `proxy.scrollTo(itemId, anchor: nil)` at
    /// morph end, only when `target` reports an overflow, preceded by
    /// `PinnedRowSettle.noteExternalScroll(reason: "trailer-morph")` in pinned Home. Take it if the
    /// Gate 1 checks fail: `.scrollPosition($rowPosition)` writing the binding per frame during
    /// focus-driven scrolling (a temporary `_printChanges()` in `CatalogRowView.body`), or
    /// `scrollTo(x:)` landing short.
    static let useProxyFallback = UserDefaults.standard.bool(forKey: "debug.trailerMorphScrollProxy")

    /// Offset (padded-content space: x = 0 is the scroll view's leading edge at rest) that brings an
    /// expanding card's tile fully inside the row viewport, or nil when it already fits. Card i's
    /// leading edge is `insetLeading + i × (restingWidth + gap)`.
    ///
    /// - Parameters:
    ///   - visibleMinX: the viewport's leading edge in the same space.
    ///   - contentWidth: the row's scrollable extent in the same space.
    ///   - contentAlreadyGrown: whether `contentWidth` already includes the tile's growth.
    static func target(index: Int, restingWidth: CGFloat, expandedWidth: CGFloat, gap: CGFloat,
                       visibleMinX: CGFloat, viewportWidth: CGFloat, contentWidth: CGFloat,
                       insetLeading: CGFloat, contentAlreadyGrown: Bool) -> CGFloat? {
        guard expandedWidth > restingWidth else { return nil }
        let leading = insetLeading + CGFloat(index) * (restingWidth + gap)
        let trailing = leading + expandedWidth
        guard trailing > visibleMinX + viewportWidth + 0.5 else { return nil }
        let grownContent = contentWidth + (contentAlreadyGrown ? 0 : expandedWidth - restingWidth)
        let maxOffset = max(0, grownContent - viewportWidth)
        return min(max(trailing - viewportWidth, 0), maxOffset)
    }
}

/// Attaches `.scrollPosition` to a row's horizontal `ScrollView` unless the proxy fallback is armed.
/// The branch reads a launch-latched constant, so it can never re-identify the row mid-session.
struct RowMorphScrollPositionModifier: ViewModifier {
    @Binding var position: ScrollPosition

    func body(content: Content) -> some View {
        if RowMorphScroll.useProxyFallback {
            content
        } else {
            content.scrollPosition($position)
        }
    }
}

// MARK: - DEBUG trailer event log

#if DEBUG
/// One line per trailer event for the UI legs, rendered by a HomeView LEAF view (spec §5.6,
/// W2-E), never by HomeView's body. DEBUG-only, a handful of writes per dwell.
///
/// Spellings (append-only, harness-parsed):
/// - `event=gate host=card|hero key=… delay=auto|1|2|3 rest=<s|-> start=<s> via=rest|ceiling`
/// - `event=reveal|wide|shrink|dissolve|abort|defer host=… key=… style=instant|animated stage=…`
/// - `event=play host=card|hero key=…`
/// - `event=mute muted=0|1 key=…`
final class InlineTrailerDebugLog: ObservableObject {
    static let shared = InlineTrailerDebugLog()

    @Published private(set) var last = "-"
    private(set) var abortCount = 0

    private init() {}

    func note(_ line: String) {
        if line.hasPrefix("event=abort") { abortCount += 1 }
        last = line
    }
}
#endif
