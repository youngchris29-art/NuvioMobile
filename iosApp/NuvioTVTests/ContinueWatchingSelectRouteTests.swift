import XCTest
@testable import NuvioTV
import SharedCore

/// W3 (upstream 37e8a5c0e): the Continue Watching On Select picker keys round-trip with the shared
/// enum. The entry rule itself is covered in Kotlin (`ContinueWatchingClickActionTest`).
final class ContinueWatchingSelectRouteTests: XCTestCase {

    private let actions: [ContinueWatchingClickAction] = [
        ContinueWatchingClickAction.stream,
        ContinueWatchingClickAction.details,
        ContinueWatchingClickAction.detailsForUpcoming,
    ]

    func testPickerOffersPlayAndDetailsOnly() {
        XCTAssertEqual(ContinueWatchingSelectRoute.keys, ["stream", "details"])
    }

    func testKeysRoundTripThroughTheSharedEnum() {
        for action in [ContinueWatchingClickAction.stream, ContinueWatchingClickAction.details] {
            XCTAssertEqual(ContinueWatchingSelectRoute.action(forKey: ContinueWatchingSelectRoute.key(action)), action)
        }
        XCTAssertEqual(ContinueWatchingSelectRoute.keys.map { ContinueWatchingSelectRoute.key(ContinueWatchingSelectRoute.action(forKey: $0)) },
                       ContinueWatchingSelectRoute.keys)
    }

    func testDetailsForUpcomingDisplaysAsPlayWithoutBeingRewritten() {
        // A phone-set Details for Upcoming shows under the Play key; the picker never writes it.
        XCTAssertEqual(ContinueWatchingSelectRoute.key(ContinueWatchingClickAction.detailsForUpcoming), "stream")
        XCTAssertTrue(actions.contains(ContinueWatchingClickAction.detailsForUpcoming))
        for key in ContinueWatchingSelectRoute.keys {
            XCTAssertNotEqual(ContinueWatchingSelectRoute.action(forKey: key), ContinueWatchingClickAction.detailsForUpcoming)
        }
    }

    func testAnUnknownKeyReadsAsPlay() {
        XCTAssertEqual(ContinueWatchingSelectRoute.action(forKey: "bogus"), ContinueWatchingClickAction.stream)
        XCTAssertEqual(ContinueWatchingSelectRoute.action(forKey: ""), ContinueWatchingClickAction.stream)
    }

    func testEveryKeyHasANonEmptyLabel() {
        for key in ContinueWatchingSelectRoute.keys {
            XCTAssertFalse(ContinueWatchingSelectRoute.label(forKey: key).isEmpty)
        }
    }
}
