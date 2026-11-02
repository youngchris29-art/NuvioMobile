import AVKit
import Combine
import SharedCore

/// The native player's speed, kept in step with the system transport bar's speed pill (P4 D4).
/// Insights wave 1c: the system pill is the only speed control on this route; `rate` is refreshed
/// from `playerVC.selectedSpeed` when the transport bar hides and when Remember is toggled, and the
/// remembered speed is applied before play.
@MainActor
final class NativeSpeedModel: ObservableObject {
    @Published var rate: Double = 1
    /// P5 B23: "Remember Speed for This Show". `rememberAvailable` is false for movies.
    @Published var remember = false
    var rememberAvailable = false
    var showId: String?
    var onRememberChange: ((Bool) -> Void)?

    /// Saves `rate` under the show when Remember is on (no-op otherwise).
    func saveIfRemembered(rate: Double) {
        guard remember, let showId else { return }
        PlayerTrackPreferenceStorage.shared.savePlaybackSpeed(parentMetaId: showId, speed: rate)
    }

    /// Applies `value` through `AVPlayerViewController.selectSpeed(_:)` (so the system pill
    /// agrees) and makes the live rate follow while playing [C-16]: `selectedSpeed` mirrors
    /// `player.defaultRate`, not the live `rate`.
    static func apply(_ value: Double, on playerVC: AVPlayerViewController, model: NativeSpeedModel) {
        guard let match = playerVC.speeds.first(where: { abs(Double($0.rate) - value) < 0.001 }) else {
            print("[NativePlayer] speed → \(value) not in the player's speed list")
            return
        }
        playerVC.selectSpeed(match)
        model.rate = Double(match.rate)
        var fixed = false
        if let player = playerVC.player, player.timeControlStatus != .paused, player.rate != match.rate {
            player.rate = match.rate
            fixed = true
        }
        print("[NativePlayer] speed → \(String(format: "%g", value)) (remembered)\(fixed ? " rateFixed=1" : "")")
    }
}
