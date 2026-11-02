import Foundation

/// What Menu does on the mpv player, highest precedence first (P1 spec, Insights levels added
/// 2026-11-01): a presented controller takes it, then inside an open shelf or popover one level per
/// press (the Cast actor view back to the cards, then the shelf or popover closes back to its pill),
/// then an active step/scan is cancelled, then the up-next chip is dismissed, then a focused pill
/// (disc or text pill) or the bar hides, and only then the player exits. Pure, so the order has
/// unit-test proof.
enum MenuPrecedence {
    enum Action: Equatable {
        case panel           // a presented controller handles it (it never reaches the player)
        case actorBack       // the Cast shelf's actor view closes back to the card row
        case closeOverlay    // the open shelf or popover closes; its pill keeps the focus
        case cancelMode      // stepping / scrubbing: nothing committed; scanning: back to the scan origin
        case dismissUpNext
        case hidePill        // hides the bar and clears the pill focus
        case hideBar
        case exit
    }

    static func resolve(panelOpen: Bool, actorViewOpen: Bool = false, overlayOpen: Bool = false,
                        modeActive: Bool, upNextShowing: Bool,
                        pillFocused: Bool, infoPillFocused: Bool = false, barUp: Bool) -> Action {
        if panelOpen { return .panel }
        if overlayOpen {
            return actorViewOpen ? .actorBack : .closeOverlay
        }
        if modeActive { return .cancelMode }
        if upNextShowing { return .dismissUpNext }
        if pillFocused || infoPillFocused { return .hidePill }
        if barUp { return .hideBar }
        return .exit
    }

    /// Every consumed action swallows its release too, so UIKit never sees a half press.
    /// BUG-165 (rc4 verdict): `.exit` used to let its release run up the responder chain while the
    /// cover's dismissal was in flight; an unhandled Menu at the end of that chain is "leave the
    /// app" on tvOS, which is what Steven's remote and the device rig both hit. Only `.panel` keeps
    /// its release (the presented panel owns the whole press).
    static func swallowsRelease(_ action: Action) -> Bool { action != .panel }
}

/// What D-pad Down does on the mpv player once a seek mode has had its say (scrub, scan and step
/// are handled first by the controller). Insights (2026-11-01): Down no longer opens a top panel;
/// with nothing else to do it raises the bar with the text pill row focused. The up-next and skip
/// chips keep their place ahead of it. `playUpNext` runs only when its turn comes (it acts).
enum DownPressRule {
    enum Action: Equatable {
        case ignore          // a shelf or popover is open, or the pill row already has the focus
        case discToTrack     // a focused disc hands the focus back to the track
        case playedUpNext
        case skip
        case focusInfoPills
    }

    static func resolve(overlayOpen: Bool, discFocused: Bool, infoPillFocused: Bool, skipChip: Bool,
                        playUpNext: () -> Bool) -> Action {
        if overlayOpen { return .ignore }
        if discFocused { return .discToTrack }
        if infoPillFocused { return .ignore }
        if playUpNext() { return .playedUpNext }
        if skipChip { return .skip }
        return .focusInfoPills
    }
}

/// The Siri Remote's touch surface reports a light tap at touch-up even when the touch was a click
/// (any button, arrows included). The tap is ignored while any press is down and within 0.5 s of
/// the last press beginning or ending.
enum LightTapGuard {
    static let clickWindowSec: TimeInterval = 0.5

    static func allows(now: TimeInterval, lastPressUptime: TimeInterval, pressesDown: Int) -> Bool {
        pressesDown == 0 && now - lastPressUptime >= clickWindowSec
    }
}
