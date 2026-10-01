import SwiftUI
import UIKit
// `touchesBegan(_:with:)` and the settable `state` used by `TouchBaselineRecognizer` are declared
// in `UIGestureRecognizerSubclass.h`, which Swift does not surface from the umbrella import.
import UIKit.UIGestureRecognizerSubclass

/// The pure half of the swipe catcher's one decision: given what focus looked like when the finger
/// went DOWN and what it looks like now, did the focus engine resolve this swipe?
///
/// Lives outside the `UIViewRepresentable` so it can be tested without a window, a focus system or
/// a gesture recognizer (`HomeUpSwipeCatcherTests`). The view keeps the plumbing — when a baseline
/// is taken, when the deadline fires — and this decides.
enum HomeUpSwipeDecision {

    /// What focus looked like when the touch sequence BEGAN, i.e. before the focus engine had a
    /// chance to read the flick.
    struct Baseline: Equatable {
        /// `CatcherView.focusGeneration` at touch-down. Monotonic, bumped by every
        /// `UIFocusSystem.didUpdateNotification`.
        var focusGeneration: Int
        /// Identity of the focused item at touch-down, or nil if nothing was focused.
        ///
        /// `ObjectIdentifier` rather than a weak reference: it retains nothing, and the recycled-
        /// address hazard a weak reference would guard against cannot produce a false `.fallBack`
        /// here, because focus cannot change without posting a focus update, and any focus update
        /// moves `focusGeneration` — which is checked first and on its own is sufficient. The
        /// identity comparison is belt and braces for a focus system that somehow re-pointed
        /// without notifying.
        var focusedItem: ObjectIdentifier?
    }

    /// When the question is being asked. The two phases differ only in what a moved focus MEANS,
    /// which is worth naming because the two readings say different things about the bug:
    /// `.callback` catching a change is the P2 this function exists for (the engine's update beat
    /// the recognizer's own callback), while `.deadline` catching one is the ordinary case the
    /// settle window was designed for.
    enum Phase: Equatable {
        /// The recognizer's target callback, immediately on recognition.
        case callback
        /// After the settle window has elapsed.
        case deadline
    }

    enum Verdict: Equatable {
        /// Focus did not move at all between touch-down and now: nothing consumed the swipe.
        case fallBack
        /// Focus had ALREADY moved by the time the recognizer called back — the engine resolved
        /// this swipe and merely reported later than it applied.
        case consumedBeforeCallback
        /// Focus moved during the settle window.
        case movedInWindow
        /// No touch sequence was recorded for this evaluation. Declines, because with no baseline
        /// there is nothing to compare against and the safe bias is not to fire.
        case noBaseline
    }

    /// The whole decision. Deliberately biased toward NOT firing: a missed fallback leaves today's
    /// behaviour (the user swipes again), while a spurious one runs a ladder that moves focus — a
    /// double move, which is the defect this signature was reshaped to prevent.
    static func verdict(phase: Phase,
                        baseline: Baseline?,
                        focusGeneration: Int,
                        focusedItem: ObjectIdentifier?) -> Verdict {
        guard let baseline else { return .noBaseline }
        let moved = focusGeneration != baseline.focusGeneration || focusedItem != baseline.focusedItem
        guard moved else { return .fallBack }
        switch phase {
        case .callback: return .consumedBeforeCallback
        case .deadline: return .movedInWindow
        }
    }
}

/// rc13 (BUG-112, the half rc12 left open) — the touch-surface Up swipe the focus engine could not
/// resolve.
///
/// rc12 shipped the press half: `HomeView`'s `.onMoveCommand` catches an Up the engine DID NOT
/// CONSUME and runs the hand-off ladder itself. Steven's 09-13 verdict was that it works on a
/// button press and never on a swipe. That is not a bug in the ladder — it is SwiftUI's move
/// grammar: `onMoveCommand` is fed by `UIPress` events from the remote's directional buttons.
/// A Siri Remote touch-surface flick produces an indirect TOUCH sequence, the focus engine reads
/// the gesture itself, and when it finds no candidate the swipe simply ends — there is no
/// unconsumed *press* for SwiftUI to hand anywhere. So the swipe needs its own listener.
///
/// **Why the window and not the view.** Remote presses and swipes are dispatched to the FOCUSED
/// view's responder chain, and gesture recognizers attached to any view in that chain observe
/// them (`Player/PlayerPanelHost.swift` states the same rule, and relies on it for the player's
/// Down-swipe panel). A `.background` representable is a SIBLING of the focused card, not an
/// ancestor of it, so a recognizer on its own view would never see the swipe. Installing on
/// `window` in `didMoveToWindow` puts the recognizer above every focusable thing in the app —
/// `HiddenTabBarFocusBlocker.BlockerView` (`SidebarOverlay.swift`) is the precedent for reaching
/// the window from a zero-size representable.
///
/// **The cost of that reach, and how it is paid.** This recognizer sees every indirect swipe in
/// the app: the player, Detail, Search, Settings, the sidebar. It is made inert everywhere else by
/// the GUARDS on the callback, not by where it is attached — see `HomeView.handleUpSwipe`, which
/// declines unless Home's rows are the pinned, uncovered, focused surface. The recognizer itself
/// is deliberately passive: `cancelsTouchesInView = false` and unconditional simultaneous
/// recognition mean it never delays, cancels or competes with the focus engine's own handling of
/// the same touches, and it never uses `require(toFail:)` (which would).
///
/// **Telling a resolved swipe from an unresolved one.** A swipe the engine DID resolve fires this
/// recognizer too — the engine's move and this callback are two readings of one gesture. The
/// baseline for that comparison is taken when the FINGER GOES DOWN, not when the recognizer calls
/// back, and that ordering is the whole point of the second, passive recognizer below.
///
/// Codex round 1 found the defect the first draft had here: it snapshotted focus inside
/// `handleSwipe`, which assumes the recognizer's target callback runs BEFORE the focus engine
/// applies its own update for the same touches. Nothing guarantees that order. When
/// `UIFocusSystem.didUpdateNotification` lands first, the snapshot is of the DESTINATION item and
/// the "did focus move?" flag has just been reset by the snapshot itself — so both checks pass 150
/// ms later and the ladder hops one row further from a row the engine had already moved to. A
/// double move, on the exact gesture this feature exists to fix, and invisible to the simulator
/// proxy (Play/Pause moves no focus, so there is no engine update to arrive early). Taking the
/// baseline at `touchesBegan` puts it unambiguously before any focus work the engine does for
/// those touches, whichever way the two callbacks are ordered afterwards.
///
/// Both available signals must then agree that nothing happened: `focusGeneration` — a monotonic
/// count of focus updates, which cannot be reset by a late-arriving anything — unchanged since
/// touch-down, and the same focused item as at touch-down. Requiring both biases the whole
/// mechanism toward NOT firing, which is the correct bias.
struct HomeUpSwipeCatcher: UIViewRepresentable {
    /// Called on the main actor when an Up swipe produced no focus movement at all. The receiver
    /// still applies every situational guard — this only reports the gesture.
    var onUnconsumedSwipeUp: () -> Void
    /// rc14 (BUG-112 residue): called on the main actor for EVERY recognised Up swipe, before the
    /// verdict — consumed ones included. Home stamps the input time from it so a hero focus gain
    /// that follows a consumed swipe can be told from one gained any other way.
    var onAnySwipeUp: (() -> Void)? = nil

    func makeUIView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onUnconsumedSwipeUp = onUnconsumedSwipeUp
        view.onAnySwipeUp = onAnySwipeUp
        return view
    }

    func updateUIView(_ uiView: CatcherView, context: Context) {
        // The closure captures HomeView's current state (`self` is a struct re-created on every
        // body evaluation), so it has to be replaced on every update or the callback would act on
        // a stale snapshot of `focusedRowKey`/`heroFocused`.
        uiView.onUnconsumedSwipeUp = onUnconsumedSwipeUp
        uiView.onAnySwipeUp = onAnySwipeUp
    }

    static func dismantleUIView(_ uiView: CatcherView, coordinator: ()) {
        uiView.uninstall()
    }

    #if DEBUG
    /// The live catcher, for the simulator proxy trigger (`HomeUpFallbackKnobs.swipeForced`).
    /// `weak` so a torn-down Home cannot be kept alive by this, and so a stale pointer can never
    /// be called into.
    nonisolated(unsafe) fileprivate static weak var current: CatcherView?

    /// DEBUG-only: runs the identical evaluation an Up swipe starts, including the touch-down
    /// baseline and the settle window.
    ///
    /// The simulator's focus engine resolves every Up (test63/test64 record exactly that), so the
    /// shipped trigger is unreachable there — the same reason `HomeUpFallbackKnobs.forced` exists
    /// for the press path. Bound to Play/Pause by `HomeView.forcedUpFallbackTrigger`, which moves
    /// no focus, so the did-focus-move check passes honestly and the whole path runs for real.
    ///
    /// It has to seed the baseline itself: Play/Pause is a press, so no indirect touch sequence
    /// ever begins and the passive recognizer never fires. Seeding through the same
    /// `beginTouchBaseline()` the real path uses keeps the proxy honest — it enters one step
    /// earlier than before rather than skipping a check.
    @MainActor static func simulateSwipeUp() {
        guard let view = current else { return }
        view.beginTouchBaseline()
        view.handleSwipe()
    }
    #endif

    /// A recognizer that recognizes nothing. Its only job is to be told when an indirect touch
    /// sequence BEGINS, which is the moment the baseline has to be taken (see the type doc).
    ///
    /// It fails itself immediately after reporting, so it can never enter a state that competes
    /// with, delays, or is waited on by any other recognizer — a failed recognizer is simply out
    /// of the running, and UIKit resets it to `.possible` for the next sequence.
    final class TouchBaselineRecognizer: UIGestureRecognizer {
        var onTouchesBegan: (() -> Void)?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            super.touchesBegan(touches, with: event)
            onTouchesBegan?()
            state = .failed
        }
    }

    final class CatcherView: UIView, UIGestureRecognizerDelegate {
        var onUnconsumedSwipeUp: (() -> Void)?
        /// rc14: every recognised Up swipe, before the verdict. See the representable's doc.
        var onAnySwipeUp: (() -> Void)?

        /// How long to wait before asking whether focus moved. 0.15 s.
        ///
        /// It only has to cover the DISPATCH gap, not the focus animation: `UIFocusSystem` applies
        /// an update (and posts `didUpdateNotification`) at the start of the animation, not at its
        /// end. Against that, every millisecond here is latency on the one case the user is stuck
        /// in — the wedge this exists to unwedge — and the ladder's own second rung is only 0.3 s
        /// behind the first. A slow deliberate swipe whose focus lands LATE is not a correctness
        /// problem either: rung 1 (a focus request the row refuses while it already holds focus)
        /// is harmless, and the moment the engine's own move lands, `handleRowFocusOwnership`
        /// retires the attempt and `shouldContinueUpFallback` kills rungs 2+ silently.
        private static let settleWindow: TimeInterval = 0.15

        private var swipe: UISwipeGestureRecognizer?
        private var touchBaselineRecognizer: TouchBaselineRecognizer?
        private weak var installedOn: UIWindow?
        private var focusObserver: NSObjectProtocol?
        /// One evaluation in flight at a time. A flick can fire the recognizer twice in quick
        /// succession (or the user can swipe again inside the window); the second must not queue a
        /// second ladder behind the first.
        private var evaluating = false
        /// Monotonic count of focus updates. Replaces the old `focusMovedSinceSwipe` flag, which
        /// the evaluation itself reset — the reset being exactly what let an early-arriving focus
        /// update go unnoticed. A counter cannot be cleared by the thing it is meant to catch.
        private var focusGeneration = 0
        /// What focus looked like when the current touch sequence began, or nil if no indirect
        /// touch sequence has begun since this view was installed.
        ///
        /// Deliberately NOT cleared when a sequence ends. A finger held on the touch surface can
        /// produce several flicks inside ONE sequence, and the later flicks then compare against a
        /// baseline from before the first — so if the engine resolved any of them, every later one
        /// reads as consumed and declines. That is a false NEGATIVE, the safe direction: the user's
        /// next swipe is a new finger-down with a fresh baseline.
        private var touchBaseline: HomeUpSwipeDecision.Baseline?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window else {
                uninstall()
                return
            }
            guard window !== installedOn else { return }
            uninstall()

            let recognizer = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeGesture))
            recognizer.direction = .up
            configurePassively(recognizer)
            window.addGestureRecognizer(recognizer)
            swipe = recognizer

            // Installed on the same window and configured identically, so it observes the same
            // touch sequences the swipe recognizer does — one step earlier.
            let baseline = TouchBaselineRecognizer()
            baseline.onTouchesBegan = { [weak self] in self?.beginTouchBaseline() }
            configurePassively(baseline)
            window.addGestureRecognizer(baseline)
            touchBaselineRecognizer = baseline

            installedOn = window

            if focusObserver == nil {
                focusObserver = NotificationCenter.default.addObserver(
                    forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main
                ) { [weak self] note in
                    self?.noteFocusUpdate(note)
                }
            }
            #if DEBUG
            HomeUpSwipeCatcher.current = self
            #endif
        }

        /// The shared "see everything, affect nothing" configuration, applied to both recognizers.
        ///
        /// Never interfere with the focus engine's own reading of these same touches: only the
        /// remote's touch surface (`.indirect` — tvOS has no direct touches, and stating it makes
        /// the intent unambiguous next to the press path), don't cancel them in the view they were
        /// delivered to, don't hold `began`/`ended` back waiting on this recognizer, and recognize
        /// alongside everything else. There is deliberately no `require(toFail:)` anywhere — that
        /// is the modifier that WOULD delay the engine.
        private func configurePassively(_ recognizer: UIGestureRecognizer) {
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
        }

        deinit {
            // `uninstall()` is @MainActor-safe work on UIKit objects; deinit can run off the main
            // thread in principle, so tear down the pieces that are safe to touch anywhere and let
            // `dismantleUIView` (always main-actor) handle the rest. The recognizers are owned by
            // the window, so a leaked one would keep firing into a dead target — hence the explicit
            // removal in `uninstall()`, called from `dismantleUIView` and from `didMoveToWindow`.
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        }

        func uninstall() {
            if let installedOn {
                if let swipe { installedOn.removeGestureRecognizer(swipe) }
                if let touchBaselineRecognizer { installedOn.removeGestureRecognizer(touchBaselineRecognizer) }
            }
            swipe = nil
            touchBaselineRecognizer?.onTouchesBegan = nil
            touchBaselineRecognizer = nil
            installedOn = nil
            touchBaseline = nil
            if let focusObserver {
                NotificationCenter.default.removeObserver(focusObserver)
                self.focusObserver = nil
            }
            #if DEBUG
            if HomeUpSwipeCatcher.current === self { HomeUpSwipeCatcher.current = nil }
            #endif
        }

        /// Recognize alongside everyone else, always — the same rule (and the same words)
        /// `NativePlayerHostController` states for the player's panel gestures. Returning `false`
        /// anywhere here would let this recognizer's state machine gate somebody else's.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        private func noteFocusUpdate(_ note: Notification) {
            focusGeneration &+= 1
            if HomeGeometryProbe.enabled {
                // Part 1 step 6 (investigate, don't ship): his 30–260 ms rung-1 landings prove row
                // 1 was MOUNTED when the fallback fired, so the `LazyVStack`'s culling is NOT what
                // makes the engine give up. The remaining candidate is a focus candidate the engine
                // preferred and then rejected — the minimized classic tab bar. These two class
                // names, read on the device with `-debug.homeScrollProbe YES`, are what would say
                // so. Probe-gated, no behaviour attached.
                let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
                NSLog("[HomeScrollProbe] focusUpdate gen=%d prev=%@ next=%@",
                      focusGeneration,
                      context?.previouslyFocusedItem.map { String(describing: type(of: $0)) } ?? "-",
                      context?.nextFocusedItem.map { String(describing: type(of: $0)) } ?? "-")
            }
        }

        /// Records what focus looks like right now as the baseline for whatever this touch sequence
        /// turns out to be. Called from the passive recognizer's `touchesBegan` (and, in DEBUG,
        /// from the simulator proxy, which has no touches of its own).
        fileprivate func beginTouchBaseline() {
            touchBaseline = HomeUpSwipeDecision.Baseline(focusGeneration: focusGeneration,
                                                         focusedItem: focusedItemIdentity())
        }

        @objc private func handleSwipeGesture() {
            handleSwipe()
        }

        /// Runs one evaluation against the touch-down baseline: decline immediately if the engine
        /// has already moved focus (it resolved this swipe and reported later than it applied),
        /// otherwise wait `settleWindow` for a focus update still in flight and report only if
        /// nothing at all moved.
        ///
        /// `fileprivate` so the DEBUG proxy trigger can enter through exactly this door rather than
        /// calling the callback directly — the sim proof is worth nothing if it skips the check it
        /// is proving.
        fileprivate func handleSwipe() {
            // rc14: stamped for EVERY recognised swipe, ahead of the verdict and of the
            // `evaluating` gate — a consumed swipe is exactly the one Home needs to know about.
            onAnySwipeUp?()
            guard !evaluating else { return }
            // Captured by VALUE: a new touch sequence starting inside the settle window replaces
            // `touchBaseline`, and the deadline below must still be judging the sequence it
            // started with.
            let baseline = touchBaseline

            let atCallback = HomeUpSwipeDecision.verdict(phase: .callback,
                                                         baseline: baseline,
                                                         focusGeneration: focusGeneration,
                                                         focusedItem: focusedItemIdentity())
            guard atCallback == .fallBack else {
                logVerdict(atCallback)
                return
            }

            evaluating = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleWindow) { [weak self] in
                guard let self else { return }
                self.evaluating = false
                let settled = HomeUpSwipeDecision.verdict(phase: .deadline,
                                                          baseline: baseline,
                                                          focusGeneration: self.focusGeneration,
                                                          focusedItem: self.focusedItemIdentity())
                self.logVerdict(settled)
                guard settled == .fallBack else { return }
                self.onUnconsumedSwipeUp?()
            }
        }

        private func logVerdict(_ verdict: HomeUpSwipeDecision.Verdict) {
            guard HomeGeometryProbe.enabled else { return }
            NSLog("[HomeScrollProbe] upSwipe verdict=%@ gen=%d", String(describing: verdict), focusGeneration)
        }

        private func focusedItemIdentity() -> ObjectIdentifier? {
            guard let window, let system = UIFocusSystem.focusSystem(for: window) else { return nil }
            return system.focusedItem.map { ObjectIdentifier($0 as AnyObject) }
        }
    }
}
