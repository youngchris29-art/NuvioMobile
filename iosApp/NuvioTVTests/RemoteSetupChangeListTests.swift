import XCTest
@testable import NuvioTV

/// Add-ons hub v2 C3: the confirm dialog's one-line-per-change list.
final class RemoteSetupChangeListTests: XCTestCase {
    private typealias List = RemoteSetupChangeList
    private let keyed = "https://torrentio.strem.fun/torbox=SECRET/manifest.json"

    private func item(_ id: String, _ title: String, on: Bool = true) -> List.Item { .init(id: id, title: title, enabled: on) }
    private func kept(_ id: String, _ title: String, on: Bool? = nil) -> List.ProposedAddon { .init(id: id, title: title, enabled: on, isNew: false) }

    private func lines(
        addons: [List.Item] = [], proposed: [List.ProposedAddon]? = nil,
        rows: [List.Item] = [], rowOrder: [String]? = nil, disabled: Set<String>? = nil,
        key: Bool = false, pattern: String? = nil, badges: Int = 0
    ) -> [List.Line] {
        List.lines(addons: addons, proposedAddons: proposed, rows: rows, rowOrder: rowOrder, disabledRows: disabled,
                   setsMdbListKey: key, posterPattern: pattern,
                   posterPatternValid: { $0.hasPrefix("https://") }, badgePackCount: badges)
    }

    func testNothingChangedGivesNoLines() {
        let addons = [item("a", "Cinemeta"), item("b", "Torrentio")]
        let rows = [item("r1", "Popular"), item("r2", "Trending")]
        XCTAssertEqual(lines(addons: addons, proposed: [kept("a", "Cinemeta"), kept("b", "Torrentio")],
                             rows: rows, rowOrder: ["r1", "r2"], disabled: []), [])
    }

    func testInstallRemoveAndFlags() {
        let addons = [item("a", "Cinemeta"), item(keyed, "Torrentio"), item("c", "OpenSubtitles", on: false)]
        let out = lines(addons: addons, proposed: [
            kept("a", "Cinemeta", on: false),
            kept("c", "OpenSubtitles", on: true),
            .init(id: "https://new.example.com/manifest.json", title: "new.example.com", enabled: true, isNew: true),
        ])
        XCTAssertEqual(out.map(\.kind), [.remove, .install, .turnOff, .turnOn])
        XCTAssertEqual(out[0].text, "Remove add-on Torrentio")
        XCTAssertEqual(out[1].text, "Install add-on new.example.com")
        XCTAssertFalse(out.contains { $0.text.contains("SECRET") || $0.text.contains("://") }, "no URL reaches the dialog")
    }

    /// Moving one item lists that item only, at its new position.
    func testAMoveListsOnlyTheItemThatMoved() {
        let addons = ["a", "b", "c", "d"].map { item($0, $0.uppercased()) }
        let out = lines(addons: addons, proposed: ["d", "a", "b", "c"].map { kept($0, $0.uppercased()) })
        XCTAssertEqual(out, [.init(kind: .move, text: "Move add-on D to position 1", subject: "d")])
    }

    func testRowsMoveAndToggle() {
        let rows = [item("r1", "Popular"), item("r2", "Trending"), item("r3", "Top Rated", on: false)]
        let out = lines(rows: rows, rowOrder: ["r2", "r1", "r3"], disabled: ["r1"])
        XCTAssertEqual(out.map(\.kind), [.move, .turnOff, .turnOn], "toggles follow the row order")
        XCTAssertEqual(out[0].text, "Move Home row Trending to position 1")
        XCTAssertTrue(out.contains { $0.text == "Turn off Home row Popular" })
        XCTAssertTrue(out.contains { $0.text == "Turn on Home row Top Rated" })
    }

    /// Review r1: on/off and order are applied independently, so they are listed independently.
    func testPartialRowProposalsListOnlyWhatApplies() {
        let rows = [item("r1", "Popular"), item("r2", "Trending", on: false)]
        XCTAssertEqual(lines(rows: rows, rowOrder: nil, disabled: ["r1"]).map(\.text),
                       ["Turn off Home row Popular", "Turn on Home row Trending"], "on/off without an order")
        XCTAssertEqual(lines(rows: rows, rowOrder: ["r2", "r1"], disabled: nil).map(\.kind), [.move],
                       "an order alone leaves the flags alone")
    }

    /// Review r1: a row the phone did not list (a sync added it) stays after the listed ones, as
    /// `applyRows` does, so the listed rows really move ahead of it.
    func testRowsTheProposalDidNotListFallBehind() {
        let rows = [item("x", "New Row"), item("a", "A"), item("b", "B")]
        let out = lines(rows: rows, rowOrder: ["a", "b"], disabled: nil)
        XCTAssertEqual(out, [.init(kind: .move, text: "Move Home row New Row to position 3", subject: "x")])
    }

    /// Review r2: same-titled items are told apart, and their lines never compare equal.
    func testSameTitledItemsAreToldApart() {
        let rows = [item("r1", "Popular"), item("r2", "Popular", on: false)]
        let out = lines(rows: rows, rowOrder: nil, disabled: ["r1"])
        XCTAssertEqual(out.map(\.text), ["Turn off Home row Popular (#1)", "Turn on Home row Popular (#2)"])
        XCTAssertNotEqual(List.Line(kind: .turnOff, text: "x", subject: "r1"), List.Line(kind: .turnOff, text: "x", subject: "r2"))
        XCTAssertEqual(Set(out.map(\.id)).count, out.count)
    }

    /// Review r2: a repeated row id is refused before it reaches the order simulation.
    func testRepeatedRowIdsAreRefused() {
        XCTAssertTrue(RemoteSetupViewModel.hasNoDuplicates(nil))
        XCTAssertTrue(RemoteSetupViewModel.hasNoDuplicates(["a", "b"]))
        XCTAssertFalse(RemoteSetupViewModel.hasNoDuplicates(["a", "a", "b"]))
    }

    /// Review r3: same-host new add-ons are told apart; a key on a disabled MDBList says it turns it on.
    func testSameHostInstallsAndTheMdbListSwitch() {
        let out = lines(proposed: [
            .init(id: "u1", title: "addon.example.com", enabled: true, isNew: true),
            .init(id: "u2", title: "addon.example.com", enabled: false, isNew: true),
        ])
        XCTAssertEqual(out.map(\.text), ["Install add-on addon.example.com (#1)", "Install add-on addon.example.com (#2) (turned off)"])
        let off = List.lines(addons: [], proposedAddons: nil, rows: [], rowOrder: nil, disabledRows: nil,
                             setsMdbListKey: true, mdbListEnabled: false, posterPattern: nil,
                             posterPatternValid: { _ in true }, badgePackCount: 0)
        XCTAssertEqual(off.map(\.text), ["Set the MDBList API key and turn MDBList on"])
    }

    func testKeysPatternAndBadges() {
        XCTAssertEqual(lines(key: true).map(\.kind), [.key])
        XCTAssertEqual(lines(pattern: "  ").map(\.text), ["Clear the custom poster pattern"])
        XCTAssertEqual(lines(pattern: "https://img.example.com/{id}.jpg").map(\.kind), [.pattern])
        XCTAssertEqual(lines(pattern: "ftp://x").map(\.kind), [.rejected])
        XCTAssertEqual(lines(badges: 2).map(\.text), ["Import 2 badge packs"])
    }

    func testMovedIdsKeepsTheLongestOrderedRun() {
        XCTAssertEqual(List.movedIds(before: ["a", "b", "c"], after: ["a", "b", "c"]), [])
        XCTAssertEqual(List.movedIds(before: ["a", "b", "c", "d"], after: ["b", "c", "d", "a"]), ["a"])
        XCTAssertEqual(List.movedIds(before: ["a", "b", "c"], after: ["c", "b", "a"]).count, 2)
    }
}
