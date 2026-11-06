import XCTest
@testable import NuvioTV

final class DetailTrailerPartitionTests: XCTestCase {
    private struct Clip: Equatable {
        let id: Int
        let type: String?
        let name: String?
    }

    private func split(_ clips: [Clip]) -> (trailers: [Clip], bonus: [Clip]) {
        DetailTrailerPartition.split(clips, type: { $0.type }, name: { $0.name })
    }

    func testTrailerAndTeaserGoToTrailersCaseInsensitive() {
        let r = split([
            Clip(id: 1, type: "Trailer", name: "x"),
            Clip(id: 2, type: "teaser", name: "x"),
            Clip(id: 3, type: " TRAILER ", name: "x"),
        ])
        XCTAssertEqual(r.trailers.map(\.id), [1, 2, 3])
        XCTAssertTrue(r.bonus.isEmpty)
    }

    func testOtherTypesGoToBonusEvenWhenNameSaysTrailer() {
        let r = split([
            Clip(id: 1, type: "Clip", name: "a"),
            Clip(id: 2, type: "Featurette", name: "a"),
            Clip(id: 3, type: "Behind the Scenes", name: "a"),
            Clip(id: 4, type: "Bloopers", name: "a"),
            Clip(id: 5, type: "Opening Credits", name: "a"),
            Clip(id: 6, type: "Whatever", name: "Official Trailer"),
        ])
        XCTAssertTrue(r.trailers.isEmpty)
        XCTAssertEqual(r.bonus.map(\.id), [1, 2, 3, 4, 5, 6])
    }

    func testFallbackByNameWhenTypeMissingOrBlank() {
        let r = split([
            Clip(id: 1, type: nil, name: "Official TRAILER 2"),
            Clip(id: 2, type: "", name: "Teaser"),
            Clip(id: 3, type: nil, name: "Making of"),
            Clip(id: 4, type: nil, name: nil),
        ])
        XCTAssertEqual(r.trailers.map(\.id), [1, 2])
        XCTAssertEqual(r.bonus.map(\.id), [3, 4])
    }

    func testOrderKeptWithinEachGroup() {
        let r = split([
            Clip(id: 1, type: "Clip", name: nil),
            Clip(id: 2, type: "Trailer", name: nil),
            Clip(id: 3, type: "Featurette", name: nil),
            Clip(id: 4, type: "Teaser", name: nil),
        ])
        XCTAssertEqual(r.trailers.map(\.id), [2, 4])
        XCTAssertEqual(r.bonus.map(\.id), [1, 3])
    }

    func testCapAppliesPerGroupAfterSplit() {
        XCTAssertEqual(DetailTrailerPartition.perRowCap, 10)
        var clips: [Clip] = []
        for i in 0..<15 { clips.append(Clip(id: i, type: "Trailer", name: nil)) }
        for i in 100..<115 { clips.append(Clip(id: i, type: "Clip", name: nil)) }
        let r = split(clips)
        XCTAssertEqual(r.trailers.map(\.id), Array(0..<10))
        XCTAssertEqual(r.bonus.map(\.id), Array(100..<110))
    }

    func testEmptyTrailersGroupDoesNotPromoteBonus() {
        let r = split([Clip(id: 1, type: "Clip", name: nil)])
        XCTAssertTrue(r.trailers.isEmpty)
        XCTAssertEqual(r.bonus.map(\.id), [1])
    }

    func testEmptyInput() {
        let r = split([])
        XCTAssertTrue(r.trailers.isEmpty)
        XCTAssertTrue(r.bonus.isEmpty)
    }
}
