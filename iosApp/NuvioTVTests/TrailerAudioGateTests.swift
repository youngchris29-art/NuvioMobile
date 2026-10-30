import XCTest
@testable import NuvioTV

/// BUG-226 (GitHub #13): no trailer sound while the letterbox probe keeps the surface concealed.
final class TrailerAudioGateTests: XCTestCase {
    func testMuteTable() {
        // (preferredMuted, surfaceRevealed) → player.isMuted
        let table: [(Bool, Bool, Bool)] = [
            (true, false, true),
            (true, true, true),
            (false, false, true),   // the bug: sound on, still artwork showing
            (false, true, false),
        ]
        for (preferred, revealed, expected) in table {
            XCTAssertEqual(
                TrailerAudioGate.isMuted(preferredMuted: preferred, surfaceRevealed: revealed), expected,
                "preferredMuted=\(preferred) revealed=\(revealed)")
        }
    }
}
