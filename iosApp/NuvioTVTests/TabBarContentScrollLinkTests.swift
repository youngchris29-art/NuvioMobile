import UIKit
import XCTest
@testable import NuvioTV

/// beta.18 verdict (BUG-66): the pure pieces of the tab-bar scroll link and its probe —
/// `TabBarContentScrollLink.resolveEnabled` (the About A/B knob, default ON),
/// `TabBarStateProbe.trackedLabel`/`composeLine`/`latchBits` (the pane line the tester
/// photographs), and the `TabBarScrollSample` hysteresis, whose crossings must not move with the
/// top inset (classic 157, pinned 0). The UIKit association itself is device/UI-test territory
/// (`TabBarScrollLinkTests` in the UI target).
///
/// T1 (Steven beta.19-rc1 verdict, 2026-10-03; BUG-66 residual): the pane line's new `off=`/`ins=`
/// fields, the `-debug.tabBarRestFix` knob (default leg 0), and leg 1's relink wait
/// (`TabBarRestFix.RelinkWait`). Leg 2's predicates are in `PinnedRowTopSnapTests`.
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

    private static let keys = ["y", "h", "a", "hid", "tbh", "st", "off", "ins", "sel", "trk", "sd",
                               "sdt", "m", "r"]

    /// One line with every field at its widest. `maxStampedLineLength` is quoted against a
    /// five-digit `<N>ms ` stamp, and this IS the worst case, so the two must agree exactly.
    func testComposeLineFitsThePaneAtTheExtremes() {
        let line = TabBarStateProbe.composeLine(
            minY: -9999, height: 999, alpha: 1, isHidden: true, tabBarHidden: true, state: "part",
            offset: -9999, inset: -999,
            selectedIndex: 5, tracked: "other", selectedScrolledDown: true, latchBits: "1111",
            sidebar: false, reason: "attach")
        XCTAssertEqual(("12345ms " + line).count, TabBarStateProbe.maxStampedLineLength, line)

        // Clamps keep the bound even for values UIKit should never report.
        let wild = TabBarStateProbe.composeLine(
            minY: -123_456, height: 12_345, alpha: 7, isHidden: true, tabBarHidden: true, state: "part",
            offset: -123_456, inset: -12_345,
            selectedIndex: Int.max, tracked: "other", selectedScrolledDown: true,
            latchBits: "1111", sidebar: false, reason: "relink")
        XCTAssertLessThanOrEqual(("12345ms " + wild).count, TabBarStateProbe.maxStampedLineLength, wild)
        XCTAssertTrue(wild.contains("sel=- "), wild)
    }

    func testComposeLineCarriesEveryKeyOnce() {
        let line = TabBarStateProbe.composeLine(
            minY: 46, height: 140, alpha: 1, isHidden: false, tabBarHidden: false, state: "exp",
            offset: 12, inset: 0,
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

    // MARK: - T1: off= / ins=

    /// The two new fields sit right after `st=`, rounded to whole points — the decision table
    /// reads `st=part off≈13 ins=0` straight off a photo.
    func testComposeLineCarriesOffsetAndInset() {
        let line = TabBarStateProbe.composeLine(
            minY: -13, height: 140, alpha: 1, isHidden: false, tabBarHidden: false, state: "part",
            offset: 13.4, inset: -0.25,
            selectedIndex: 0, tracked: "rows", selectedScrolledDown: false, latchBits: "0---",
            sidebar: false, reason: "tick")
        XCTAssertTrue(line.contains(" st=part off=13 ins=0 sel=0 "), line)
    }

    /// Home's rows not linked (another tab, a pushed page, sidebar mode): both fields read `-`.
    func testComposeLineDashesWithoutRows() {
        let line = TabBarStateProbe.composeLine(
            minY: 46, height: 140, alpha: 1, isHidden: false, tabBarHidden: false, state: "exp",
            offset: nil, inset: nil,
            selectedIndex: 1, tracked: "other", selectedScrolledDown: false, latchBits: "0---",
            sidebar: false, reason: "tab2")
        XCTAssertTrue(line.contains(" st=exp off=- ins=- sel=1 "), line)
    }

    func testComposeLineClamps() {
        XCTAssertEqual(TabBarStateProbe.clampedField(50_000, limit: 9999), "9999")
        XCTAssertEqual(TabBarStateProbe.clampedField(-50_000, limit: 9999), "-9999")
        XCTAssertEqual(TabBarStateProbe.clampedField(5000, limit: 999), "999")
        XCTAssertEqual(TabBarStateProbe.clampedField(-5000, limit: 999), "-999")
        XCTAssertEqual(TabBarStateProbe.clampedField(1431.6, limit: 9999), "1432")
        XCTAssertEqual(TabBarStateProbe.clampedField(nil, limit: 9999), "-")
        // A reading no UIKit build should produce still cannot trap the Int conversion.
        XCTAssertEqual(TabBarStateProbe.clampedField(.nan, limit: 9999), "-")
        XCTAssertEqual(TabBarStateProbe.clampedField(.infinity, limit: 999), "-")

        let line = TabBarStateProbe.composeLine(
            minY: 0, height: 140, alpha: 1, isHidden: false, tabBarHidden: false, state: "exp",
            offset: 123_456, inset: -5000,
            selectedIndex: 0, tracked: "rows", selectedScrolledDown: false, latchBits: "----",
            sidebar: false, reason: "tick")
        XCTAssertTrue(line.contains(" off=9999 ins=-999 "), line)
    }

    // MARK: - T1: the -debug.tabBarRestFix knob

    func testRestFixLegDefaultsToZero() {
        XCTAssertEqual(TabBarRestFix.resolveLeg(freshDefaults()), 0)
    }

    /// The launch argument lands as a String in the argument domain; `integer(forKey:)` converts it.
    func testRestFixLegReadsLaunchArgumentStrings() {
        let d = freshDefaults()
        d.set("1", forKey: TabBarRestFix.defaultsKey)
        XCTAssertEqual(TabBarRestFix.resolveLeg(d), 1)
        d.set("2", forKey: TabBarRestFix.defaultsKey)
        XCTAssertEqual(TabBarRestFix.resolveLeg(d), 2)
        d.set(2, forKey: TabBarRestFix.defaultsKey)
        XCTAssertEqual(TabBarRestFix.resolveLeg(d), 2)
    }

    /// A typo never enables a leg.
    func testRestFixLegOutOfRangeIsZero() {
        let d = freshDefaults()
        for raw in ["3", "-1", "abc", "0"] {
            d.set(raw, forKey: TabBarRestFix.defaultsKey)
            XCTAssertEqual(TabBarRestFix.resolveLeg(d), 0, raw)
        }
    }

    // MARK: - T1 leg 1: the relink wait

    private let dt = TabBarRestFix.pollInterval

    func testRelinkWaitsForFocusFirst() {
        var gate = TabBarRestFix.RelinkWait()
        for _ in 0..<5 {
            XCTAssertEqual(gate.poll(focused: false, restPending: false, dt: dt), .wait)
        }
        XCTAssertFalse(gate.focusSeen)
    }

    /// The poll that first sees focus is not a rest poll; the next two quiet ones relink.
    func testRelinkAfterFocusThenTwoQuietPolls() {
        var gate = TabBarRestFix.RelinkWait()
        XCTAssertEqual(gate.poll(focused: true, restPending: false, dt: dt), .wait)
        XCTAssertEqual(gate.poll(focused: true, restPending: false, dt: dt), .wait)
        XCTAssertEqual(gate.poll(focused: true, restPending: false, dt: dt), .relink(reason: "firstRest"))
    }

    func testRelinkQuietCountResetsWhileARestIsPending() {
        var gate = TabBarRestFix.RelinkWait()
        XCTAssertEqual(gate.poll(focused: true, restPending: true, dt: dt), .wait)
        XCTAssertEqual(gate.poll(focused: true, restPending: false, dt: dt), .wait)
        XCTAssertEqual(gate.poll(focused: true, restPending: true, dt: dt), .wait)
        XCTAssertEqual(gate.poll(focused: true, restPending: false, dt: dt), .wait)
        XCTAssertEqual(gate.poll(focused: true, restPending: false, dt: dt), .relink(reason: "firstRest"))
    }

    /// A corrector that stays busy for the whole 6 s ceiling still gets its relink, named.
    func testRelinkTimesOutWhileTheRestStaysPending() {
        var gate = TabBarRestFix.RelinkWait()
        XCTAssertEqual(gate.poll(focused: true, restPending: true, dt: dt), .wait)
        let restPolls = Int((TabBarRestFix.restWaitCap / dt).rounded())  // 24, exact in binary
        for _ in 1..<restPolls {
            XCTAssertEqual(gate.poll(focused: true, restPending: true, dt: dt), .wait)
        }
        XCTAssertEqual(gate.poll(focused: true, restPending: true, dt: dt), .relink(reason: "restTimeout"))
    }

    /// No focus within the cap: the wait moves on and says so in the reason.
    func testRelinkFocusCapFallsThrough() {
        var gate = TabBarRestFix.RelinkWait()
        let focusPolls = Int((TabBarRestFix.focusWaitCap / dt).rounded())  // 16
        for _ in 0..<focusPolls {
            XCTAssertEqual(gate.poll(focused: false, restPending: false, dt: dt), .wait)
        }
        XCTAssertTrue(gate.focusSeen)
        XCTAssertTrue(gate.focusTimedOut)
        XCTAssertEqual(gate.poll(focused: false, restPending: false, dt: dt), .wait)
        XCTAssertEqual(gate.poll(focused: false, restPending: false, dt: dt),
                       .relink(reason: "firstRestNoFocus"))
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
