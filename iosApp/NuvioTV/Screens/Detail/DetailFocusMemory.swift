import Foundation
import UIKit

/// BUG-187 (Steven rc9: "back from a cast member, focus goes back to Play"). The main fix keeps
/// the rows mounted across the reload (`DetailMetaAdoption`), so the focus engine can restore the
/// card itself. This is the fallback: the last card focus held in the Cast, Studios, Collection
/// and More Like This rows, re-applied after a pop with FEAT-79's rungs (`CollectionsUI`'s
/// `restoreClassicRowsFocus`) when the engine's own restoration does not land there.
///
/// A reference box held in `@State` with no published state: writing it on every Left/Right
/// never invalidates `DetailView`. The rows write it from their own focus state; `DetailView`
/// arms it when the page disappears and takes the armed target when it appears again.
@MainActor
final class DetailFocusMemory {
    /// The remembered row and card key, nil when none: the Cast row's stable `DetailCreditItem.key`
    /// (A4.4: `cast:tmdb:<id>|<role>` or the crew `creditKey`, never an index, so a row that gains
    /// crew or reorders keeps the card), the studio index, or the item id.
    private(set) var row: DetailRowID?
    private(set) var key: String?
    private var armed = false
    /// Review r1: false from `arm()` (the page's `onDisappear`) until `takeArmedTarget()` (its
    /// `onAppear`). The focus engine can report Play in between (the pushed page's teardown, the
    /// pop's first layout), and that report must not disarm the restore it is about to need.
    private(set) var pageVisible = true
    private var generation = 0

    /// A card in a tracked row took focus. A nil key (focus left the row, which a push also does)
    /// keeps the last card: `clear()` is what forgets it.
    func note(row: DetailRowID, key: String?) {
        guard let key else { return }
        self.row = row
        self.key = key
    }

    /// Focus settled somewhere this box does not track (the hero, another row). A no-op while
    /// the page is not visible (review r1): a focus report between `arm()` and the next
    /// `takeArmedTarget()` belongs to the push/pop, not to the viewer.
    func clear() {
        guard pageVisible else { return }
        row = nil
        key = nil
        armed = false
    }

    /// The page is going away with a remembered card (a push from that card).
    func arm() {
        armed = row != nil && key != nil
        pageVisible = false
    }

    /// The armed target, once: a later appearance without a new push restores nothing. Called on
    /// every appearance, so it also marks the page visible again (armed or not).
    func takeArmedTarget() -> (row: DetailRowID, key: String)? {
        pageVisible = true
        guard armed, let row, let key else { return nil }
        armed = false
        return (row, key)
    }

    /// A new restore; any older one's pending rungs stand down.
    func beginRestore() -> Int {
        generation &+= 1
        return generation
    }

    func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    /// The live restore's generation, for a re-grab scheduled from a focus change (BUG-194, rc11).
    var currentGeneration: Int { generation }

    // MARK: Pop gate (Batch P, P7 / BUG-194)

    /// The card a live restore is steering focus to; nil when no restore is live.
    private(set) var liveTarget: (row: DetailRowID, key: String)?

    /// True from `goLive` until `endRestore`: a pop restore is steering focus to `liveTarget` and the
    /// page holds still for the engine's strays. Play is the only default focus candidate throughout
    /// (the sentinel `.defaultFocus` is gone, Wave 1 pass); the card gets there by the forced rungs'
    /// request and by the re-grab.
    var restoreLive: Bool { liveTarget != nil }

    /// The pop's restore began: `target` is the card the rungs and the re-grab steer focus to.
    func goLive(_ target: (row: DetailRowID, key: String), startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        liveTarget = target
        popStartedAt = startedAt
        popLandedAt = nil
        popMoves = 0
        popRegrabs = 0
        popLandings = 0
        popStrayAt = nil
        popAway = 0
        heldFocusChange = nil
    }

    /// BUG-194 bookkeeping, outside SwiftUI state on purpose (writes must not re-evaluate the body):
    /// the pop's clock stamp, the landing stamp, the move counter for the probe, and the one focus
    /// change the gate held back so `endRestore` can hand it to the caller for a replay.
    var popStartedAt: TimeInterval = 0
    private(set) var popLandedAt: TimeInterval?
    private(set) var popMoves = 0
    private(set) var heldFocusChange: (old: DetailRowID?, new: DetailRowID?)?

    /// BUG-194 (Steven rc11): re-grabs issued for the engine's stray landings (`DetailPopGate.Decision.regrab`),
    /// landings on the target row, and the time focus spent OFF the target after its first landing
    /// (what the viewer sees as the second move; the probe's `away=`).
    private(set) var popRegrabs = 0
    private(set) var popLandings = 0
    private(set) var popStrayAt: TimeInterval?
    private(set) var popAway: TimeInterval = 0

    /// One `focusedRow` report during a live restore (review r3 P3-3): counts the move, asks
    /// `DetailPopGate.decide`, and does the per-decision bookkeeping. `DetailView.onChange(of: focusedRow)`
    /// and `DetailPopRegrabTests` both call this, so a test cannot pass while the view drops a step.
    /// The caller owns what follows (`.release`: end the restore; `.regrab`: schedule the re-grab; the
    /// probe lines). `target.key` is handed to the gate only when the reported row is the target row
    /// (a landing is decided by the ROW, never by the card).
    func report(row: DetailRowID?, old: DetailRowID?, target: (row: DetailRowID, key: String),
                viewerInput: Bool, clockLive: Bool, at now: TimeInterval) -> DetailPopGate.Decision {
        popMoves += 1
        let decision = DetailPopGate.decide(focusedRow: row, focusedKey: row == target.row ? target.key : nil,
                                            target: target, viewerInput: viewerInput,
                                            regrabs: popRegrabs, clockLive: clockLive)
        switch decision {
        case .landed:
            noteLanding(at: now)
            dropHeldFocusChange()
        case .hold:
            noteStray(at: now)
            holdFocusChange(old: old, new: row)
        case .regrab:
            noteStray(at: now)
            popRegrabs += 1
            holdFocusChange(old: old, new: row)
        case .release:
            break
        }
        return decision
    }

    /// Focus landed on the target row: the first landing is `popLandedAt`; a landing after a stray
    /// stops the away clock.
    func noteLanding(at now: TimeInterval) {
        popLandings += 1
        if popLandedAt == nil { popLandedAt = now }
        if let strayAt = popStrayAt {
            popAway += max(0, now - strayAt)
            popStrayAt = nil
        }
    }

    /// Focus left the target (or landed elsewhere). Starts the away clock only after a landing: before
    /// it, focus has not been on the card yet, so nothing visible moved off it.
    func noteStray(at now: TimeInterval) {
        guard popLandedAt != nil, popStrayAt == nil else { return }
        popStrayAt = now
    }

    /// Time off the target since the first landing, counting a stray still running at `now`.
    func awayTime(at now: TimeInterval) -> TimeInterval {
        popAway + (popStrayAt.map { max(0, now - $0) } ?? 0)
    }

    /// Keeps the FIRST `old` of a run of held changes and the latest `new`.
    func holdFocusChange(old: DetailRowID?, new: DetailRowID?) {
        heldFocusChange = (heldFocusChange?.old ?? old, new)
    }

    /// A landing ran the handler for itself: a later hold starts a fresh run (review r2 P3-1).
    func dropHeldFocusChange() { heldFocusChange = nil }

    /// The restore ended (released by viewer input or retired): back to Play as the default.
    /// Ends the live restore and returns the held focus change, if any, for the caller to replay.
    @discardableResult
    func endRestore() -> (old: DetailRowID?, new: DetailRowID?)? {
        liveTarget = nil
        popLandedAt = nil
        defer { heldFocusChange = nil }
        return heldFocusChange
    }
}

/// BUG-194 (Steven rc10: back from a biography went up to Play, then down to the card). The same
/// shape as BUG-156's Home pop and Batch N's fix, with Play as the only default focus candidate:
/// the forced rungs fall inside the pop transition and stick on neither turn, the request lands the
/// card when the transition ends (~570 ms), and the engine's own late restoration then lands on
/// Play ~30 ms later. While a restore is live the gate holds the page still for every report that
/// is not the card (`hold`), takes the card back at once when the viewer-input clock is live
/// (`regrab`), and decides by the ROW the engine landed on and by viewer input, never by timestamps
/// (DetailView passes the target key only when the row matches, so the card never decides). Pure;
/// `DetailView` owns the state and `DetailFocusMemory.report` the bookkeeping.
nonisolated enum DetailPopGate {
    nonisolated enum Decision: Equatable, Sendable {
        /// Focus is not on the target yet; keep steering and keep the page still.
        case hold
        /// Focus is on the target row: the one move. (No landed window: the request's retire ends the restore.)
        case landed
        /// The viewer moved focus: stand down at once.
        case release
        /// BUG-194 (Steven rc11, his config and the Wave 1 config alike: `moves=3`): focus went off the
        /// target with no viewer input since the pop. That is the engine's late pop restoration onto
        /// its default candidate (Play, `.defaultFocus($heroFocus, .play)`), ~30 ms after the forced
        /// rung's request landed the card at the end of the transition (~570 ms). Hold the page AND
        /// take the card back now; the 0.8 s free rung used to leave Play focused for ~230 ms.
        case regrab
    }

    /// Re-grabs per restore, Home's count with a live clock: Classic Home saw the engine fire its
    /// default-candidate restoration twice (0.59 s and 0.98 s after the pop).
    ///
    /// Two known residuals of this budget (review r3 P3-1; no code yet, each waits for a rig sign):
    /// - Strays BEFORE the first landing (`stray … landed=0`) spend it during the transition, where
    ///   forced writes do not stick; if they exhaust it, the real post-landing stray falls back to
    ///   `.hold` (rc11's behaviour). Fix if rig item 1 shows `landed=0` strays: gate `.regrab` on
    ///   `popLandedAt != nil` (the ladder's forced rungs already cover the transition).
    /// - Input the viewer clock never sees (VoiceOver gestures, a game controller's thumbstick) is
    ///   undone, at most 3 times within the 1.3 s retire; the recognizer stamps every press and 40 pt
    ///   swipe at begin, so Siri Remote input is not affected. Fix if rig item 5 shows a lost press:
    ///   re-grab at once only for the `.defaultFocus` signature (`row == nil && heroFocus == .play`,
    ///   the analogue of Home's `regrabsImmediately(fillerFocused:)`) and take the `regrabDefer`
    ///   path with a clock re-check for anything else.
    static let maxRegrabs: Int = UncoverRestorePolicy.maxRegrabs(clockLive: true)

    /// Viewer input wins, then a focus report on the target row (the caller passes the target key when the row matches) lands;
    /// anything else (the hero, another row, another card) is the engine's: re-grabbed while the viewer-input
    /// clock is live and `regrabs` is under `maxRegrabs`, else held for the late rungs (the pre-rc11 rule).
    /// Positions and the input clock decide, never timestamps (Batch N). `regrabs` and `clockLive` have no
    /// defaults (review r3 P3-3): a new caller must say whether the clock is live, not silently get the
    /// pre-rc11 hold (`clockLive: false`).
    static func decide(focusedRow: DetailRowID?, focusedKey: String?,
                       target: (row: DetailRowID, key: String), viewerInput: Bool,
                       regrabs: Int, clockLive: Bool) -> Decision {
        if viewerInput { return .release }
        if focusedRow == target.row, focusedKey == target.key { return .landed }
        // Without a live clock the viewer's move cannot be told from the engine's: hold, as before.
        guard clockLive, regrabs < maxRegrabs else { return .hold }
        return .regrab
    }

    /// Whether a scheduled re-grab should still act when its run-loop turn comes (review r3 P3-3,
    /// `DetailView.regrabPopTarget`): the restore it was scheduled for is still the newest (`current`),
    /// still live (a retire or a viewer end stands it down), and the viewer has not pressed or swiped
    /// since the pop. Pure, so the stand-down rule is tested without a view.
    static func regrabStillWanted(current: Bool, restoreLive: Bool, inputSincePop: Bool) -> Bool {
        current && restoreLive && !inputSincePop
    }
}

/// BUG-187: a restore rung for a row that owns its own `FocusState` (Collection, More Like This).
/// `DetailView` sets it; the row applies it when `row` is its own.
struct DetailFocusRestoreRequest: Equatable {
    var row: DetailRowID?
    var key: String?
    var force: Bool
    var generation: Int

    static let none = DetailFocusRestoreRequest(row: nil, key: nil, force: false, generation: 0)
}

/// BUG-187: the pure halves of the fallback restore.
enum DetailFocusRestore {
    /// FEAT-79's rungs: two forced at once and after the first layout, then two late ones for the
    /// engine's own restoration (0.55–0.98 s late on hardware, Batch A). On hardware the two forced
    /// rungs fall inside the pop transition and neither sticks on its own turn (both log `applied`);
    /// the request lands the card when the transition ends (~570 ms). Since rc11 the engine's stray
    /// landing right after that is re-grabbed at once (`DetailPopGate.Decision.regrab`); the late
    /// rungs stay as the fallback (no input clock, re-grab limit, a dropped write).
    nonisolated static let rungs: [(delay: Double, force: Bool)] = [(0, true), (0.35, true), (0.8, false), (1.1, false)]
    /// When the request is retired, after the last rung.
    nonisolated static let retireDelay: Double = 1.3

    /// Rows that remember their card. Focus landing on any other row forgets it.
    nonisolated static func tracks(_ row: DetailRowID) -> Bool {
        switch row {
        case .cast, .logos, .collection, .moreLikeThis: true
        default: false
        }
    }

    /// Whether a rung moves focus. `current` is the row's focused card key (nil = focus is not in
    /// the row). A forced rung corrects any other card; a late rung only pulls focus back into a
    /// row it is not in at all (the engine put it on Play), never off a card in the row.
    nonisolated static func shouldApply(force: Bool, current: String?, target: String) -> Bool {
        force ? current != target : current == nil
    }
}

/// BUG-187: `-debug.detailFocusProbe YES` mounts the DEBUG `debug_detail_focus row= idx=` label
/// the UI leg reads (the tvOS 27 simulator never reports `hasFocus`). Launch-latched. The
/// `[DetailPop]` console lines (BUG-194) log under the same flag in every build, Release included.
enum DetailFocusProbe {
    nonisolated static let enabled = UserDefaults.standard.bool(forKey: "debug.detailFocusProbe")

    /// BUG-194 (rc11): what UIKit focus sits on now, for the `[DetailPop] stray` line: the item's
    /// runtime type and its window-space origin (Play is a responder item in the hero; BUG-188's
    /// lazy-row stand-in is a `UIKitFocusableFillerItem`). Probe-only; "-" when there is none.
    static func focusedItemSummary() -> String {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard let window, let item = UIFocusSystem.focusSystem(for: window)?.focusedItem else { return "-" }
        let name = String(describing: type(of: item))
        guard let space = item.parentFocusEnvironment?.focusItemContainer?.coordinateSpace else { return name }
        let frame = space.convert(item.frame, to: window.coordinateSpace)
        return "\(name)@\(Int(frame.minX)),\(Int(frame.minY))"
    }
}
