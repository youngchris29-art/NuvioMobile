import Foundation

/// Add-ons hub v2 (A4): the Installed pane's Move mode, pure. Holds only the mode's state; the UI
/// asks it what to do on each press and performs the actual reorder itself.
nonisolated struct AddonMoveMode: Equatable, Sendable {
    /// Direction of one Up/Down press.
    nonisolated enum Direction: Equatable, Sendable { case up, down }

    /// The add-on being moved (manifest URL), or nil when not moving.
    private(set) var movingUrl: String?
    /// Its index when the move started (Menu cancels back to it).
    private(set) var origin: Int = 0
    /// When the last accepted step happened (uptime seconds), for the throttle.
    private(set) var lastStepAt: TimeInterval?
    /// A4 review r1: the add-ons that were ABOVE the moving one when the move started. Menu
    /// restores the position relative to the survivors, so an add-on removed (sync) mid-move does
    /// not turn the stored index into an out-of-range or wrong destination.
    private(set) var predecessors: Set<String> = []

    /// Minimum time between two accepted steps.
    static let stepInterval: TimeInterval = 0.112

    /// True while an add-on is lifted.
    var isMoving: Bool { movingUrl != nil }

    /// True only for the add-on currently being moved.
    func isMoving(_ manifestUrl: String) -> Bool { movingUrl == manifestUrl }

    /// Starts moving `manifestUrl` from `index` in `order` (the list's manifest URLs; replaces any
    /// move in progress).
    mutating func start(manifestUrl: String, index: Int, order: [String] = []) {
        movingUrl = manifestUrl
        origin = index
        lastStepAt = nil
        predecessors = Set(order.prefix(max(0, min(index, order.count))).filter { $0 != manifestUrl })
    }

    /// The destination index for one press from `currentIndex` in a list of `count`, or nil when
    /// not moving, at the end in that direction, or inside the throttle window since the last
    /// ACCEPTED step. An accepted step records `now` as `lastStepAt`.
    mutating func step(_ direction: Direction, currentIndex: Int, count: Int, now: TimeInterval) -> Int? {
        guard isMoving else { return nil }
        guard let target = AddonsViewModel.moveTarget(
            index: currentIndex, by: direction == .up ? -1 : 1, count: count
        ) else { return nil }
        if let last = lastStepAt, now - last < Self.stepInterval { return nil }
        lastStepAt = now
        return target
    }

    /// Ends the move keeping the current position. Returns the URL that was moving.
    @discardableResult
    mutating func commit() -> String? {
        let url = movingUrl
        reset()
        return url
    }

    /// Ends the move and returns where the add-on must go back to: (url, index), or nil when not
    /// moving. With `currentOrder` (review r1) the index is the slot right after the last add-on
    /// still listed that was above it when the move started (0 when none survives), so removals
    /// and arrivals during the move are respected; without it, the stored start index. The caller
    /// moves the add-on from its current index to that one.
    mutating func cancel(currentOrder: [String]? = nil) -> (manifestUrl: String, origin: Int)? {
        guard let url = movingUrl else { return nil }
        var back = origin
        if let currentOrder {
            let others = currentOrder.filter { $0 != url }
            back = (others.lastIndex(where: { predecessors.contains($0) }) ?? -1) + 1
        }
        reset()
        return (url, back)
    }

    private mutating func reset() {
        movingUrl = nil
        origin = 0
        lastStepAt = nil
        predecessors = []
    }
}
