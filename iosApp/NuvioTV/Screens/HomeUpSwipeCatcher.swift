import SwiftUI
import UIKit

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
/// **The settle window.** A swipe the engine DID resolve fires this recognizer too — the engine's
/// move and this callback are two readings of one gesture. Telling them apart is a question about
/// the future ("did focus move?"), so the evaluation waits `settleWindow` and then asks. Both
/// available signals must agree that nothing happened: no `UIFocusSystem.didUpdateNotification`
/// since the swipe, and the same focused item as at swipe time. Requiring both biases the whole
/// mechanism toward NOT firing, which is the correct bias — a missed fallback leaves today's
/// behaviour (the user swipes again), while a spurious one runs a ladder that can move focus.
struct HomeUpSwipeCatcher: UIViewRepresentable {
    /// Called on the main actor when an Up swipe produced no focus movement at all. The receiver
    /// still applies every situational guard — this only reports the gesture.
    var onUnconsumedSwipeUp: () -> Void

    func makeUIView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onUnconsumedSwipeUp = onUnconsumedSwipeUp
        return view
    }

    func updateUIView(_ uiView: CatcherView, context: Context) {
        // The closure captures HomeView's current state (`self` is a struct re-created on every
        // body evaluation), so it has to be replaced on every update or the callback would act on
        // a stale snapshot of `focusedRowKey`/`heroFocused`.
        uiView.onUnconsumedSwipeUp = onUnconsumedSwipeUp
    }

    static func dismantleUIView(_ uiView: CatcherView, coordinator: ()) {
        uiView.uninstall()
    }

    #if DEBUG
    /// The live catcher, for the simulator proxy trigger (`HomeUpFallbackKnobs.swipeForced`).
    /// `weak` so a torn-down Home cannot be kept alive by this, and so a stale pointer can never
    /// be called into.
    nonisolated(unsafe) fileprivate static weak var current: CatcherView?

    /// DEBUG-only: runs the identical evaluation an Up swipe starts, including the settle window.
    /// The simulator's focus engine resolves every Up (test63/test64 record exactly that), so the
    /// shipped trigger is unreachable there — the same reason `HomeUpFallbackKnobs.forced` exists
    /// for the press path. Bound to Play/Pause by `HomeView.forcedUpFallbackTrigger`, which moves
    /// no focus, so the did-focus-move check passes honestly and the whole path runs for real.
    @MainActor static func simulateSwipeUp() {
        current?.handleSwipe()
    }
    #endif

    final class CatcherView: UIView, UIGestureRecognizerDelegate {
        var onUnconsumedSwipeUp: (() -> Void)?

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
        private weak var installedOn: UIWindow?
        private var focusObserver: NSObjectProtocol?
        /// One evaluation in flight at a time. A flick can fire the recognizer twice in quick
        /// succession (or the user can swipe again inside the window); the second must not queue a
        /// second ladder behind the first.
        private var evaluating = false
        private var focusMovedSinceSwipe = false
        /// The focused item at swipe time. `weak` so a view torn down inside the window cannot be
        /// kept alive here, and so the identity comparison can never match a recycled address.
        private weak var focusedItemAtSwipe: AnyObject?

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
            // The Siri Remote's touch surface. Without this the recognizer would also fire for
            // direct touches, which tvOS does not have, and — more to the point — stating it makes
            // the intent unambiguous to anyone reading it next to the press path.
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            // Never interfere with the focus engine's own reading of these same touches: don't
            // cancel them in the view they were delivered to, don't hold `began`/`ended` back
            // waiting on this recognizer, and recognize alongside everything else (below). There is
            // deliberately no `require(toFail:)` anywhere — that is the modifier that WOULD delay
            // the engine.
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            swipe = recognizer
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

        deinit {
            // `uninstall()` is @MainActor-safe work on UIKit objects; deinit can run off the main
            // thread in principle, so tear down the pieces that are safe to touch anywhere and let
            // `dismantleUIView` (always main-actor) handle the rest. The recognizer is owned by the
            // window, so a leaked one would keep firing into a dead target — hence the explicit
            // removal in `uninstall()`, called from `dismantleUIView` and from `didMoveToWindow`.
            if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        }

        func uninstall() {
            if let swipe, let installedOn {
                installedOn.removeGestureRecognizer(swipe)
            }
            swipe = nil
            installedOn = nil
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
            focusMovedSinceSwipe = true
            if HomeGeometryProbe.enabled {
                // Part 1 step 6 (investigate, don't ship): his 30–260 ms rung-1 landings prove row
                // 1 was MOUNTED when the fallback fired, so the `LazyVStack`'s culling is NOT what
                // makes the engine give up. The remaining candidate is a focus candidate the engine
                // preferred and then rejected — the minimized classic tab bar. These two class
                // names, read on the device with `-debug.homeScrollProbe YES`, are what would say
                // so. Probe-gated, no behaviour attached.
                let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
                NSLog("[HomeScrollProbe] focusUpdate prev=%@ next=%@",
                      context?.previouslyFocusedItem.map { String(describing: type(of: $0)) } ?? "-",
                      context?.nextFocusedItem.map { String(describing: type(of: $0)) } ?? "-")
            }
        }

        @objc private func handleSwipeGesture() {
            handleSwipe()
        }

        /// Starts one evaluation: snapshot what focus looks like now, wait `settleWindow`, and
        /// report only if nothing at all moved. `fileprivate` so the DEBUG proxy trigger can enter
        /// through exactly this door rather than calling the callback directly — the sim proof is
        /// worth nothing if it skips the check it is proving.
        fileprivate func handleSwipe() {
            guard !evaluating else { return }
            evaluating = true
            focusMovedSinceSwipe = false
            focusedItemAtSwipe = focusSystemItem()

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleWindow) { [weak self] in
                guard let self else { return }
                self.evaluating = false
                guard !self.focusMovedSinceSwipe else { return }
                guard self.focusSystemItem() === self.focusedItemAtSwipe else { return }
                if HomeGeometryProbe.enabled {
                    NSLog("[HomeScrollProbe] upSwipe unconsumed=1")
                }
                self.onUnconsumedSwipeUp?()
            }
        }

        private func focusSystemItem() -> AnyObject? {
            guard let window, let system = UIFocusSystem.focusSystem(for: window) else { return nil }
            return system.focusedItem.map { $0 as AnyObject }
        }
    }
}
