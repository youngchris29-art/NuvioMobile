import XCTest
import SharedCore
@testable import NuvioTV

/// BUG-244: `DetailCommentsList` is equatable on the comment ids and the expanded set only, so a
/// page body pass that changes neither skips the eight cards' body (invariant I7).
@MainActor
final class DetailCommentsListTests: XCTestCase {
    private func comment(_ id: Int64, text: String = "text") -> TraktCommentReview {
        TraktCommentReview(id: id, authorDisplayName: "Author \(id)", authorUsername: nil, comment: text,
                           spoiler: false, containsInlineSpoilers: false, review: false, likes: 3,
                           rating: nil, createdAt: nil, updatedAt: nil)
    }

    func testEqualForTheSameIdsAndExpandedSetWhateverTheClosure() {
        var firstCalls = 0
        var secondCalls = 0
        let a = DetailCommentsList(comments: [comment(1), comment(2)], expanded: [2], onToggle: { _ in firstCalls += 1 })
        let b = DetailCommentsList(comments: [comment(1), comment(2)], expanded: [2], onToggle: { _ in secondCalls += 1 })
        XCTAssertEqual(a, b)
        XCTAssertEqual(firstCalls + secondCalls, 0)
    }

    func testEqualWhenOnlyTheTextOfACommentDiffers() {
        let a = DetailCommentsList(comments: [comment(1, text: "a")], expanded: [], onToggle: { _ in })
        let b = DetailCommentsList(comments: [comment(1, text: "b")], expanded: [], onToggle: { _ in })
        XCTAssertEqual(a, b)
    }

    func testNotEqualWhenAnIdOrTheOrderDiffers() {
        let a = DetailCommentsList(comments: [comment(1), comment(2)], expanded: [], onToggle: { _ in })
        XCTAssertNotEqual(a, DetailCommentsList(comments: [comment(1), comment(3)], expanded: [], onToggle: { _ in }))
        XCTAssertNotEqual(a, DetailCommentsList(comments: [comment(2), comment(1)], expanded: [], onToggle: { _ in }))
        XCTAssertNotEqual(a, DetailCommentsList(comments: [comment(1)], expanded: [], onToggle: { _ in }))
    }

    func testNotEqualWhenTheExpandedSetDiffers() {
        let a = DetailCommentsList(comments: [comment(1)], expanded: [], onToggle: { _ in })
        XCTAssertNotEqual(a, DetailCommentsList(comments: [comment(1)], expanded: [1], onToggle: { _ in }))
    }
}
