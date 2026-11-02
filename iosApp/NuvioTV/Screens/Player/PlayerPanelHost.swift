import AVKit
import SwiftUI
import UIKit

// The native player's UIKit host. Insights wave 1c (2026-11-01): the app-drawn swipe-down top
// panel is gone from this route — the system swipe down shows tvOS 26's own pill row, which carries
// the app's text pills (`NativeInfoPills.swift`) and round tool buttons (`NativeTransportMenus`).
// Two pieces stay here:
//
//  - `NativePlayerHostController` — container VC whose only child is the `AVPlayerViewController`.
//    Remote presses are dispatched to the FOCUSED view's responder chain; gesture recognizers on
//    any superview in that chain observe them too, so the any-press recognizer on this container's
//    view sees presses regardless of which internal AVPVC view holds focus, and Menu the system
//    player did not consume passes through `pressesBegan` (the up-next chip dismiss).
//  - `PlayerPanelHostController` — a presented full-screen sheet over the live player (now only
//    the Sync Line sheet). Presenting (`.overFullScreen`, clear background) gives focus
//    containment, keeps the video rendering underneath, and lets us swallow Menu deterministically
//    so it closes the sheet instead of popping the player.
final class NativePlayerHostController: UIViewController, UIGestureRecognizerDelegate, AVPlayerViewControllerDelegate {
    let playerVC = AVPlayerViewController()
    /// The system transport bar is about to show (`true`) or hide (`false`). Reported from the
    /// AVPlayerViewController delegate (P4 B16, the native pause card's "bar known hidden" input).
    var onTransportBarVisibilityChange: ((Bool) -> Void)?
    /// Any remote press (Select, Play/Pause, the arrows, Menu), observed without consuming it
    /// (P4 B16: a press hides the pause card).
    var onAnyPress: (() -> Void)?
    /// Last reported transport-bar visibility, so the log line prints transitions only.
    private var lastBarVisible: Bool?
    /// Fired after a presented sheet has been dismissed (any way: Menu, swipe up, programmatic).
    var onPanelClosed: (() -> Void)?
    /// Menu press hook (upstream 4026ec92 parity): return true to consume it — the up-next chip
    /// was dismissed — or false to let the press continue up to SwiftUI, whose `fullScreenCover`
    /// pops the player exactly as today.
    var onMenuPress: (() -> Bool)?
    private var swallowMenuRelease = false
    private(set) var panelHost: PlayerPanelPresenting?
    private var anyPress: UITapGestureRecognizer!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "player.native"
        addChild(playerVC)
        playerVC.view.frame = view.bounds
        playerVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(playerVC.view)
        playerVC.didMove(toParent: self)
        // P4 B16: transport-bar visibility for the native pause card (nothing else sets it).
        playerVC.delegate = self

        // P4 B16 [C-5]: presses reach `pressesBegan` here only when the focused AVPVC view did not
        // consume them (in practice Menu with the bar hidden), so Select, the arrows and
        // Play/Pause are observed with a simultaneous recogniser that consumes
        // nothing. Menu is left out of it on purpose and reported from `pressesBegan` instead: a
        // recogniser on Menu would sit in front of the player's Menu-to-exit path.
        anyPress = UITapGestureRecognizer(target: self, action: #selector(handleAnyPress))
        anyPress.allowedPressTypes = [UIPress.PressType.select, .playPause, .upArrow, .downArrow,
                                      .leftArrow, .rightArrow].map { NSNumber(value: $0.rawValue) }
        anyPress.cancelsTouchesInView = false
        anyPress.delegate = self
        view.addGestureRecognizer(anyPress)
    }

    @objc private func handleAnyPress() { onAnyPress?() }

    // MARK: AVPlayerViewControllerDelegate

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              willTransitionToVisibilityOfTransportBar visible: Bool,
                              with coordinator: any AVPlayerViewControllerAnimationCoordinator) {
        if lastBarVisible != visible {
            lastBarVisible = visible
            // Kept in every build during P4 (transitions only): the device pass reads it to decide
            // whether tvOS 26's bar ever hides while paused (spec §4.2).
            print("[NativePlayer] bar visible=\(visible ? 1 : 0)")
        }
        onTransportBarVisibilityChange?(visible)
    }

    /// Recognize alongside AVPlayerViewController's own recognizers — never block the system player.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    // This controller sits between AVPlayerViewController and the SwiftUI host in the focused
    // responder chain, so a Menu the system player did not consume (transport bar hidden) passes
    // through here on its way to the cover's default exit. Not while our sheet or one of AVPVC's
    // own popovers is up — those own Menu themselves (`presentedViewController` reports ancestors'
    // presentations, not the child's, so the player VC is checked explicitly).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // P4 B16: Menu is the one press the any-press recogniser leaves out; report it here
        // (observation only, the handling below is unchanged).
        if presses.contains(where: { $0.type == .menu }) { onAnyPress?() }
        if presses.contains(where: { $0.type == .menu }),
           panelHost == nil, presentedViewController == nil, playerVC.presentedViewController == nil,
           onMenuPress?() == true {
            swallowMenuRelease = true
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Swallow the matching Menu release too, so nothing above sees a half press.
        if swallowMenuRelease, presses.contains(where: { $0.type == .menu }) {
            swallowMenuRelease = false
            return
        }
        super.pressesEnded(presses, with: event)
    }

    /// Present a sheet over the live player. `crossDissolve` fades the host; the panel content
    /// animates its own slide-in. Reduce Motion → no animation at all.
    func present<Content: View>(panel: PlayerPanelHostController<Content>) {
        guard panelHost == nil, presentedViewController == nil else { return }
        panel.modalPresentationStyle = .overFullScreen
        panel.modalTransitionStyle = .crossDissolve
        panel.onClosed = { [weak self] in
            self?.panelHost = nil
            self?.onPanelClosed?()
        }
        panelHost = panel
        present(panel, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    func closePanel(animated: Bool) {
        panelHost?.close(animated: animated)
    }
}

/// Type-erased handle on a presented panel host (the hosting controller itself is generic).
protocol PlayerPanelPresenting: AnyObject {
    func close(animated: Bool)
}

/// Hosts the SwiftUI panel over the player. Menu closes the panel (swallowed here so it never
/// reaches the SwiftUI `fullScreenCover` that would pop the whole player); swipe up also closes.
final class PlayerPanelHostController<Content: View>: UIHostingController<Content>, PlayerPanelPresenting {
    var onClosed: (() -> Void)?
    private var closing = false
    private var reportedClose = false
    /// Review r3: the after-a-child follow-up close runs at most once per viewer close.
    private var didFollowUp = false
    /// BUG-186 review r1: watchdog retries for the current close; it gives up after `maxCloseRetries`.
    private var closeRetries = 0
    private static var maxCloseRetries: Int { 2 }  // computed: a generic class has no static stored properties

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "player.panel"
        let up = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeUp))
        up.direction = .up
        view.addGestureRecognizer(up)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            close(animated: true)
            return
        }
        #if DEBUG
        // BUG-186 UI leg: the simulator cannot swipe, so `-debug.panelSwipeUpForce YES` binds
        // Play/Pause on the panel to the swipe-up handler itself.
        if Self.swipeUpForced, presses.contains(where: { $0.type == .playPause }) {
            handleSwipeUp()
            return
        }
        #endif
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Swallow the matching Menu release too, so nothing below sees a half press.
        if presses.contains(where: { $0.type == .menu }) { return }
        #if DEBUG
        if Self.swipeUpForced, presses.contains(where: { $0.type == .playPause }) { return }
        #endif
        super.pressesEnded(presses, with: event)
    }

    #if DEBUG
    private static var swipeUpForced: Bool { UserDefaults.standard.bool(forKey: "debug.panelSwipeUpForce") }
    #endif

    @objc private func handleSwipeUp() { close(animated: true) }

    func close(animated: Bool) {
        guard !closing else { return }
        // A viewer close starts a fresh retry budget; the watchdog's retries go through `beginClose`.
        closeRetries = 0
        didFollowUp = false
        beginClose(animated: animated)
    }

    private func beginClose(animated: Bool) {
        guard !closing else { return }
        closing = true
        // BUG-186: `closing` used to latch for good. A Menu during the ~0.25 s present (or while
        // focus was being reclaimed) asked UIKit to dismiss a controller still being presented;
        // UIKit dropped that dismiss, the panel stayed up, and every later Menu hit the guard
        // above and was swallowed, so the player could not be left. Now a close that lands
        // mid-present waits for the present to finish, the flag is reset once a dismiss
        // completes, and a watchdog retries a dismiss that never started.
        if isBeingPresented, let coordinator = transitionCoordinator {
            _ = coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.performDismiss(animated: animated)
            }
        } else {
            performDismiss(animated: animated)
        }
        armCloseWatchdog()
    }

    private func performDismiss(animated: Bool) {
        let onClosed = onClosed
        dismiss(animated: animated && !UIAccessibility.isReduceMotionEnabled) { [weak self] in
            // A panel already released is gone: report the close (the pre-r1 behaviour).
            guard let self else { onClosed?(); return }
            self.closing = false
            // BUG-186 review r1: with a child presented over the panel (a Menu/picker), `dismiss`
            // closes only that child and the panel stays up; reporting the close here would leave
            // the owner with a stale `panelHost`. Report only once the panel itself is gone.
            guard self.presentingViewController == nil else {
                // Review r2: a close aimed at the panel stopped at the child it dismissed; finish
                // the panel itself once, so a programmatic close (a source or episode pick) lands.
                if self.presentedViewController == nil, !self.didFollowUp {
                    self.didFollowUp = true
                    self.performDismiss(animated: false)
                }
                return
            }
            // A watchdog retry can race a late original completion: report the close once.
            guard !self.reportedClose else { return }
            self.reportedClose = true
            onClosed?()
        }
    }

    /// BUG-186: 0.6 s after a close, a panel that is still presented and not mid-dismiss had its
    /// dismiss dropped; reset the latch and close again without animation. `isBeingDismissed`
    /// keeps a slow (but live) dismiss from being doubled. Review r1: at most `maxCloseRetries`
    /// retries per close (it used to re-arm forever); the give-up is logged once.
    private func armCloseWatchdog() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, self.closing, self.presentingViewController != nil,
                  !self.isBeingDismissed else { return }
            guard self.closeRetries < Self.maxCloseRetries else {
                print("[PlayerPanel] BUG-186 watchdog: dismiss still dropped after \(Self.maxCloseRetries) retries, giving up")
                self.closing = false
                return
            }
            self.closeRetries += 1
            print("[PlayerPanel] BUG-186 watchdog: dismiss dropped, retry \(self.closeRetries)/\(Self.maxCloseRetries)")
            self.closing = false
            self.beginClose(animated: false)
        }
    }
}
