import AVKit
import UIKit

/// Return from background on mpv (spec-mpv-return §3.6, M9; finding r2-4): one owner at a time for
/// the window's display criteria across a controller replacement. Held by `PlayerScreen` and handed
/// to every mpv controller it builds. A controller sets and clears criteria only through it, under
/// its own token; after `transfer(to:)` the old controller's clear does nothing, and the fresh one
/// finds the criteria already held (no display-mode hold, no second TV switch).
@MainActor
final class DisplayCriteriaLease {
    /// Where criteria are written. Production writes the window's `avDisplayManager`; tests record.
    typealias Writer = @MainActor (_ window: UIWindow?, _ criteria: AVDisplayCriteria?) -> Void

    private weak var window: UIWindow?
    private(set) var owner: Int?
    private(set) var criteria: AVDisplayCriteria?
    private let writer: Writer

    init(writer: @escaping Writer = { window, criteria in
        window?.avDisplayManager.preferredDisplayCriteria = criteria
    }) {
        self.writer = writer
    }

    /// Criteria are applied and owned by `token`.
    var holdsCriteria: Bool { criteria != nil }

    /// `token` sets criteria on `window`: it becomes the owner.
    func apply(_ criteria: AVDisplayCriteria, window: UIWindow, token: Int) {
        self.window = window
        self.criteria = criteria
        owner = token
        writer(window, criteria)
        #if DEBUG
        MPVReturnDebugLedger.shared.crit = 1
        #endif
    }

    /// Clears only when `token` owns the lease. Returns whether it cleared.
    @discardableResult
    func clear(token: Int) -> Bool {
        guard owner == token else { return false }
        let w = window
        criteria = nil
        window = nil
        owner = nil
        writer(w, nil)
        #if DEBUG
        MPVReturnDebugLedger.shared.crit = 0
        #endif
        return true
    }

    /// The fresh controller takes over whatever the old one applied (criteria and window stay).
    func transfer(to token: Int) {
        guard criteria != nil else { owner = nil; return }
        owner = token
    }

    /// An exit with no successor, or a discard: cleared whoever owns it.
    func clearAll() {
        guard let owner else { return }
        clear(token: owner)
    }
}
