import XCTest
@testable import NuvioTV

/// Return from background, section 7: the identity write guard (pure).
final class PlaybackWriteGuardTests: XCTestCase {

    private let owner = PlaybackIdentity(accountKey: "user-1", profileId: 3)

    func testEqualIdentityIsAllowed() {
        XCTAssertTrue(PlaybackWriteGuard.allows(owner: owner, current: PlaybackIdentity(accountKey: "user-1", profileId: 3)))
    }

    func testAccountChangedIsRefused() {
        XCTAssertFalse(PlaybackWriteGuard.allows(owner: owner, current: PlaybackIdentity(accountKey: "user-2", profileId: 3)))
    }

    func testProfileChangedIsRefused() {
        XCTAssertFalse(PlaybackWriteGuard.allows(owner: owner, current: PlaybackIdentity(accountKey: "user-1", profileId: 4)))
    }

    func testSignedOutIsRefused() {
        XCTAssertFalse(PlaybackWriteGuard.allows(owner: owner, current: PlaybackIdentity(accountKey: "signed-out", profileId: 3)))
    }

    func testNilOwnerAlwaysAllows() {
        XCTAssertTrue(PlaybackWriteGuard.allows(owner: nil, current: owner))
        XCTAssertTrue(PlaybackWriteGuard.allows(owner: nil, current: PlaybackIdentity(accountKey: "signed-out", profileId: 0)))
    }
}
