import XCTest

/// W5 item 4: in Cinematic, Play and the icon-only action buttons are the same height in every corner style
/// (Rounded, Round, Square). Read from the DEBUG probe `debug_action_heights` (`-debug.detailActionGeometry YES`),
/// which reports each button's LAID-OUT height from `onGeometryChange`, never an accessibility frame (those carry
/// the focus lift). The fixture's series has no watch progress, so the "with progress" row of the title matrix is
/// not covered here.
final class DetailActionRowGeometryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func heights(_ app: XCUIApplication) -> [String: Int] {
        let probe = app.descendants(matching: .any)["debug_action_heights"]
        guard probe.waitForExistence(timeout: 20) else { return [:] }
        // The probe fills as each button lays out; give the row a moment to settle.
        Thread.sleep(forTimeInterval: 2)
        var out: [String: Int] = [:]
        for part in probe.label.split(separator: " ").dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, let value = Int(kv[1]) { out[kv[0]] = value }
        }
        return out
    }

    func testPlayAndIconButtonsShareOneHeightInEveryCornerStyle() throws {
        for corners in ["rounded", "round", "square"] {
            let app = DetailEntryRoute.launchToDetail(self, arguments: [
                "-home_layout", "classic", "-detail_layout", "cinematic",
                "-debug.posterCornersOverride", corners, "-debug.detailActionGeometry", "YES"])
            XCTAssertTrue(app.buttons["detail_action_play"].waitForExistence(timeout: 20), "Play never appeared (\(corners))")
            let h = heights(app)
            print("[ActionGeometry] \(corners): \(h.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
            let play = try XCTUnwrap(h["play"], "no Play height in the probe (\(corners)): \(h)")
            let icons = h.filter { $0.key != "play" }
            XCTAssertFalse(icons.isEmpty, "no icon button heights in the probe (\(corners)): \(h)")
            for (id, value) in icons {
                XCTAssertEqual(Double(value), Double(play), accuracy: 1, "\(id) is \(value) pt, Play is \(play) pt (\(corners))")
            }
            app.terminate()
        }
    }
}
