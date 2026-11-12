import XCTest
@testable import NuvioTV

/// `DetailCoverStates`: every presentation `DetailView` can raise turns `detailCoverPresented` on.
final class DetailCoverStatesTests: XCTestCase {

    /// One entry per presentation flag. The Mirror check below fails when a flag is added to the
    /// struct without a line here.
    private let flags: [(String, WritableKeyPath<DetailCoverStates, Bool>)] = [
        ("streams", \.streams),
        ("seriesPlay", \.seriesPlay),
        ("trailerPlayback", \.trailerPlayback),
        ("presentedTrailer", \.presentedTrailer),
        ("synopsisSheet", \.synopsisSheet),
        ("aboutOverviewSheet", \.aboutOverviewSheet),
        ("shuffleSheet", \.shuffleSheet),
        ("libraryAlert", \.libraryAlert),
    ]

    func testNothingPresentedIsOff() {
        XCTAssertFalse(DetailCoverStates().isPresented)
    }

    func testEveryPresentationAloneTurnsItOn() {
        for (name, path) in flags {
            var states = DetailCoverStates()
            states[keyPath: path] = true
            XCTAssertTrue(states.isPresented, "\(name) must stop the format probe")
            states[keyPath: path] = false
            XCTAssertFalse(states.isPresented, "dismissing \(name) restarts it")
        }
    }

    func testTheTestListCoversEveryFlag() {
        let declared = Mirror(reflecting: DetailCoverStates()).children.compactMap(\.label)
        XCTAssertEqual(Set(declared), Set(flags.map(\.0)),
                       "a presentation flag was added without a test entry (or the reverse)")
    }

    func testSynopsisCoversAreIncluded() {
        XCTAssertTrue(DetailCoverStates(synopsisSheet: true).isPresented)
        XCTAssertTrue(DetailCoverStates(aboutOverviewSheet: true).isPresented)
    }
}
