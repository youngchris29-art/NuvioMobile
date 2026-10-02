import UIKit
import XCTest
@testable import NuvioTV

/// beta.18 verdict (BUG-66): the pure pieces of the tab-bar scroll link and its probe —
/// `TabBarContentScrollLink.resolveEnabled` (the About A/B knob, default ON),
/// `TabBarStateProbe.trackedLabel`/`composeLine`/`latchBits` (the pane line the tester
/// photographs), and the `TabBarScrollSample` hysteresis, whose crossings must not move with the
/// top inset (classic 157, pinned 0). The UIKit association itself is device/UI-test territory
/// (`TabBarScrollLinkTests` in the UI target).
@MainActor
final class TabBarContentScrollLinkTests: XCTestCase {

    // MARK: - resolveEnabled

    private func freshDefaults() -> UserDefaults {
        let suite = "TabBarContentScrollLinkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testResolveEnabledDefaultsOnWhenUnset() {
        XCTAssertTrue(TabBarContentScrollLink.resolveEnabled(freshDefaults()))
    }

    func testResolveEnabledLaunchArgumentNoStringIsOff() {
        let d = freshDefaults()
        d.set("NO", forKey: TabBarContentScrollLink.defaultsKey)
        XCTAssertFalse(TabBarContentScrollLink.resolveEnabled(d))
    }

    func testResolveEnabledFollowsStoredBool() {
        let d = freshDefaults()
        d.set(false, forKey: TabBarContentScrollLink.defaultsKey)
        XCTAssertFalse(TabBarContentScrollLink.resolveEnabled(d))
        d.set(true, forKey: TabBarContentScrollLink.defaultsKey)
        XCTAssertTrue(TabBarContentScrollLink.resolveEnabled(d))
    }

    // MARK: - trackedLabel

    func testTrackedLabel() {
        let rows = UIScrollView()
        let other = UIScrollView()
        XCTAssertEqual(TabBarStateProbe.trackedLabel(tracked: nil, homeRows: rows), "none")
        XCTAssertEqual(TabBarStateProbe.trackedLabel(tracked: nil, homeRows: nil), "none")
        XCTAssertEqual(TabBarStateProbe.trackedLabel(tracked: rows, homeRows: rows), "rows")
        XCTAssertEqual(TabBarStateProbe.trackedLabel(tracked: other, homeRows: rows), "other")
        XCTAssertEqual(TabBarStateProbe.trackedLabel(tracked: other, homeRows: nil), "other")
    }

    // MARK: - composeLine

    private static let keys = ["y", "h", "a", "hid", "tbh", "st", "sel", "trk", "sd", "sdt", "m", "r"]

    func testComposeLineFitsThePaneAtTheExtremes() {
        let line = TabBarStateProbe.composeLine(
            minY: -1431, height: 999, alpha: 1, isHidden: true, tabBarHidden: true, state: "part",
            selectedIndex: 5, tracked: "other", selectedScrolledDown: true, latchBits: "1111",
            sidebar: false, reason: "attach")
        // The pane stamps `<N>ms ` in front; the budget is quoted against a five-digit stamp.
        XCTAssertLessThanOrEqual(("12345ms " + line).count, 95, line)

        // Clamps keep the bound even for values UIKit should never report.
        let wild = TabBarStateProbe.composeLine(
            minY: -123_456, height: 12_345, alpha: 7, isHidden: true, tabBarHidden: true, state: "part",
            selectedIndex: Int.max, tracked: "other", selectedScrolledDown: true,
            latchBits: "1111", sidebar: false, reason: "attach")
        XCTAssertLessThanOrEqual(("12345ms " + wild).count, 95, wild)
        XCTAssertTrue(wild.contains("sel=- "), wild)
    }

    func testComposeLineCarriesEveryKeyOnce() {
        let line = TabBarStateProbe.composeLine(
            minY: 46, height: 140, alpha: 1, isHidden: false, tabBarHidden: false, state: "exp",
            selectedIndex: 0, tracked: "rows", selectedScrolledDown: false, latchBits: "0---",
            sidebar: true, reason: "tab2")
        let tokens = line.split(separator: " ").map(String.init)
        for key in Self.keys {
            let hits = tokens.filter { $0.hasPrefix("\(key)=") }
            XCTAssertEqual(hits.count, 1, "key \(key) in \(line)")
        }
        XCTAssertEqual(tokens.count, Self.keys.count, line)
        XCTAssertTrue(line.contains("sel=0 trk=rows"), line)
        XCTAssertTrue(line.hasSuffix("m=sb r=tab2"), line)
    }

    func testLatchBits() {
        XCTAssertEqual(TabBarStateProbe.latchBits([:]), "----")
        XCTAssertEqual(TabBarStateProbe.latchBits([0: true, 2: false]), "1-0-")
        XCTAssertEqual(TabBarStateProbe.latchBits([0: false, 1: true, 2: true, 3: false, 5: true]), "0110")
    }

    // MARK: - Residual invariance (TabBarScrollSample)

    func testResidualIsZeroAtTheTrueTopForBothInsets() {
        for inset: CGFloat in [0, 157] {
            XCTAssertEqual(TabBarScrollSample(offsetY: -inset, insetTop: inset).residual, 0, "inset \(inset)")
        }
    }

    /// Walk the same content distance under both insets: the hide and show crossings must fire at
    /// the same residual, i.e. the link (which may change the inset the scroll view reports) never
    /// moves the BUG-27 Menu-to-top latch.
    func testHysteresisCrossesAtTheSameResidualForBothInsets() {
        func crossings(inset: CGFloat) -> (hide: CGFloat?, show: CGFloat?) {
            var latch = false
            var hideAt: CGFloat?
            var showAt: CGFloat?
            let down = stride(from: CGFloat(0), through: 600, by: 2)
            let up = stride(from: CGFloat(600), through: 0, by: -2)
            for distance in Array(down) + Array(up) {
                let sample = TabBarScrollSample(offsetY: distance - inset, insetTop: inset)
                let next = TabBarScrollSample.latch(after: latch, residual: sample.residual)
                if next, !latch, hideAt == nil { hideAt = sample.residual }
                if !next, latch, showAt == nil { showAt = sample.residual }
                latch = next
            }
            return (hideAt, showAt)
        }
        let classic = crossings(inset: 157)
        let pinned = crossings(inset: 0)
        XCTAssertNotNil(classic.hide)
        XCTAssertNotNil(classic.show)
        XCTAssertEqual(classic.hide, pinned.hide)
        XCTAssertEqual(classic.show, pinned.show)
        XCTAssertGreaterThan(classic.hide ?? 0, TabBarScrollSample.hideArm)
        XCTAssertLessThan(classic.show ?? .infinity, TabBarScrollSample.showArm)
    }

    // MARK: - topRestExempt pin (BUG-122, untouched by this wave)

    func testTopRestExemptPinnedBothSides() {
        XCTAssertTrue(PinnedRowSettle.topRestExempt(offsetY: 0, margin: 60, bandHigh: 48))
        XCTAssertFalse(PinnedRowSettle.topRestExempt(offsetY: 0, margin: 40, bandHigh: 48))
    }

    // MARK: - linkTargets (review r1 P2-1)

    func testLinkTargetsDropsNavigationControllersAndKeepsOrder() {
        let a = UIViewController()
        let nav = UINavigationController()
        let b = UIViewController()
        let targets = TabBarContentScrollLink.linkTargets(in: [a, nav, b])
        XCTAssertEqual(targets.count, 2)
        XCTAssertTrue(targets[0] === a)
        XCTAssertTrue(targets[1] === b)
    }
}
