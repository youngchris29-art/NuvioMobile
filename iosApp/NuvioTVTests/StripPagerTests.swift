import Combine
import XCTest
@testable import NuvioTV

/// Home Stage & Strip, review r1: the pager's handle (P1, the controller retain cycle) and its
/// mounted window (A P2-5: a hop re-renders only the pages that mount or unmount).
@MainActor
final class StripPagerTests: XCTestCase {

    // MARK: StripPagerHandle (P1)

    func testHandleForwardsWhileInstalled() {
        let handle = StripPagerHandle()
        let owner = StripPagerBox()
        var calls: [String] = []
        XCTAssertFalse(handle.isInstalled)
        handle.install(owner: owner) { key, itemId, reason in
            calls.append("\(key)|\(itemId ?? "-")|\(reason)")
        }
        XCTAssertTrue(handle.isInstalled)
        handle.requestFocus(rowKey: "row", itemId: "card", reason: "test")
        XCTAssertEqual(calls, ["row|card|test"])
        handle.uninstall(owner: owner)
        XCTAssertFalse(handle.isInstalled)
        handle.requestFocus(rowKey: "row", itemId: nil, reason: "test")
        XCTAssertEqual(calls.count, 1, "nothing forwards once uninstalled")
    }

    /// Home's placeholder ↔ pager swap can run the incoming pager's `onAppear` before the outgoing
    /// one's `onDisappear`: the late uninstall must not clear the incoming closure.
    func testOutgoingPagerCannotUninstallTheIncomingOne() {
        let handle = StripPagerHandle()
        let outgoing = StripPagerBox()
        let incoming = StripPagerBox()
        var incomingCalls = 0
        handle.install(owner: outgoing) { _, _, _ in }
        handle.install(owner: incoming) { _, _, _ in incomingCalls += 1 }
        handle.uninstall(owner: outgoing)
        XCTAssertTrue(handle.isInstalled)
        handle.requestFocus(rowKey: "row", itemId: nil)
        XCTAssertEqual(incomingCalls, 1)
        handle.uninstall(owner: incoming)
        XCTAssertFalse(handle.isInstalled)
    }

    /// The shape of the leak: the handle's owner holds the handle, and the installed closure holds
    /// the owner (the pager value holds `controller`). Uninstall breaks it.
    func testUninstallReleasesTheCycle() {
        @MainActor final class Holder {
            let handle = StripPagerHandle()
        }
        weak var weakHolder: Holder?
        do {
            let holder = Holder()
            weakHolder = holder
            let owner = StripPagerBox()
            holder.handle.install(owner: owner) { _, _, _ in _ = holder }
            holder.handle.uninstall(owner: owner)
        }
        XCTAssertNil(weakHolder)
    }

    // MARK: StripPagerBox mounted window (A P2-5)

    private func box(rows: Int) -> (StripPagerBox, [StripPageMount]) {
        let box = StripPagerBox()
        box.rowKeys = (0..<rows).map { "r\($0)" }
        let mounts = box.rowKeys.enumerated().map { index, key in
            box.mount(for: key, at: index, count: rows)
        }
        return (box, mounts)
    }

    func testOnlyThePagesThatFlipPublish() {
        let (box, mounts) = box(rows: 8)
        XCTAssertEqual(mounts.map(\.isMounted), [true, true, true, false, false, false, false, false])
        var published = Set<Int>()
        var bag = Set<AnyCancellable>()
        for (index, mount) in mounts.enumerated() {
            mount.objectWillChange.sink { _ in published.insert(index) }.store(in: &bag)
        }
        box.moveWindow(to: 1)
        XCTAssertEqual(mounts.map(\.isMounted), [true, true, true, true, false, false, false, false])
        XCTAssertEqual(published, [3], "a hop re-renders only the page that mounts")
        published.removeAll()
        box.moveWindow(to: 1)
        XCTAssertTrue(published.isEmpty, "no move, no publish")
        box.moveWindow(to: 4)
        XCTAssertEqual(mounts.map(\.isMounted), [false, false, true, true, true, true, true, false])
        XCTAssertEqual(published, [0, 1, 4, 5, 6])
    }

    func testAGlideKeepsThePassedRowsMountedUntilItEnds() {
        let (box, mounts) = box(rows: 8)
        box.moveWindow(to: 6)
        box.setGlideSpan(0...6)
        box.moveWindow(to: 0)
        XCTAssertEqual(mounts.map(\.isMounted), [true, true, true, true, true, true, true, false])
        box.setGlideSpan(nil)
        XCTAssertEqual(mounts.map(\.isMounted), [true, true, true, false, false, false, false, false])
    }

    /// The body can create a new row's flag before `rowKeys` catches up; a refresh in between must
    /// not drop it (its page would then never update again). Only `pruneMounts` drops flags.
    func testRefreshNeverPrunesAndPruneDropsRowsThatLeft() {
        let box = StripPagerBox()
        box.rowKeys = ["a", "b"]
        let a = box.mount(for: "a", at: 0, count: 3)
        let c = box.mount(for: "c", at: 2, count: 3)
        box.moveWindow(to: 1)
        XCTAssertTrue(box.mount(for: "c", at: 2, count: 3) === c, "kept across a refresh")
        box.pruneMounts(keeping: ["a"])
        XCTAssertTrue(box.mount(for: "a", at: 0, count: 1) === a)
        XCTAssertFalse(box.mount(for: "c", at: 2, count: 3) === c, "dropped once the row left")
    }

    func testIndicesFollowRowsInsertedAbove() {
        let (box, mounts) = box(rows: 6)
        box.moveWindow(to: 3)
        XCTAssertEqual(mounts.map(\.isMounted), [false, true, true, true, true, true])
        // Two rows arrive above: the old r1…r5 are now at 3…7, the window still centred on 3.
        box.rowKeys = ["n0", "n1"] + box.rowKeys
        box.refreshMounts()
        XCTAssertEqual(mounts.map(\.isMounted), [true, true, true, true, false, false],
                       "r0…r3 (now 2…5) are inside 1…5; r4 and r5 (now 6, 7) leave it")
    }
}
