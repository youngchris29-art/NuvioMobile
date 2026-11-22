#if DEBUG
import Combine
import SwiftUI

/// spec-mpv-return §5.3: the DEBUG switches of the mpv return legs (compiled out of Release).
/// - `debug.mpvReturnFault` = `failFreshStart` | `stuckOldQueue` | `slowPark`
/// - `debug.ownerFlip` = `beforeHome` | `away`
/// - `debug.subtitleSideLoadDelaySec <n>`: every subtitle side-load hand-off waits n seconds
/// - `debug.liveForceEOFAtSec <n>`: a return-started controller on a live stream reconnects n s after its load
enum MPVReturnDebug {
    static var fault: String? { UserDefaults.standard.string(forKey: "debug.mpvReturnFault") }
    static var ownerFlip: String? { UserDefaults.standard.string(forKey: "debug.ownerFlip") }
    static var subtitleSideLoadDelaySec: Double {
        max(0, UserDefaults.standard.double(forKey: "debug.subtitleSideLoadDelaySec"))
    }
    static var liveForceEOFAtSec: Double? {
        UserDefaults.standard.object(forKey: "debug.liveForceEOFAtSec") == nil
            ? nil : max(0, UserDefaults.standard.double(forKey: "debug.liveForceEOFAtSec"))
    }

    /// The mpv DEBUG background cycle ran in this process (it never runs twice: a retry player would
    /// otherwise background again at the same position).
    @MainActor static var cycleUsed = false

    /// `debug.ownerFlip`: from now on `PlaybackIdentity.current()` answers another profile (once).
    @MainActor
    static func flipIdentity(reason: String) {
        guard PlaybackIdentity.debugOverride == nil else { return }
        let real = PlaybackIdentity.current()
        PlaybackIdentity.debugOverride = PlaybackIdentity(accountKey: real.accountKey, profileId: real.profileId &+ 100)
        print("[MPVReturn] DEBUG owner flipped (\(reason))")
    }
}

/// Process-wide record for the legs that read state after the player closed (`debug_mpvReturnLedger`
/// on the smoke host): mpv controllers made, the last return phase, whether the lease holds criteria,
/// writes made after a park, and the last failure the smoke host saw.
@MainActor
final class MPVReturnDebugLedger: ObservableObject {
    static let shared = MPVReturnDebugLedger()
    @Published private(set) var controllers = 0
    @Published private(set) var phase = "none"
    @Published private(set) var lastController = 0
    @Published var crit = 0
    @Published private(set) var writesAfterPark = 0
    @Published var failure = "none"
    private var parked = false

    func nextSerial() -> Int { controllers += 1; return controllers }
    func note(phase: String, controller: Int) { self.phase = phase; lastController = controller }
    func noteParked() { parked = true }
    /// A progress or tracker write: counted once any controller parked.
    func noteWrite() { if parked { writesAfterPark += 1 } }

    var text: String {
        "mctl=\(controllers) mlast=\(lastController) mret=\(phase) mcrit=\(crit) mwrites=\(writesAfterPark) mfail=\(failure)"
    }
}

struct MPVReturnDebugLedgerLabel: View {
    @ObservedObject private var ledger = MPVReturnDebugLedger.shared

    var body: some View {
        Text(verbatim: ledger.text)
            .font(.system(size: 8))
            .opacity(0.011)
            .accessibilityIdentifier("debug_mpvReturnLedger")
            .allowsHitTesting(false)
    }
}
#endif

#if DEBUG
/// spec-mpv-return §6.3 (leg N7): `-debug.nativeRestartFirstSeekCoarse YES` makes the first native
/// restart seek of the process a default-tolerance one (lands on the segment start), so the landing
/// check's corrective exact seek is exercised.
@MainActor
enum NativeRestartDebug {
    private static var used = false
    static func takeCoarseFirstSeek() -> Bool {
        guard !used, UserDefaults.standard.bool(forKey: "debug.nativeRestartFirstSeekCoarse") else { return false }
        used = true
        print("[Return] DEBUG first restart seek is coarse")
        return true
    }
}
#endif
