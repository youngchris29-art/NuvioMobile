import XCTest
@testable import NuvioTV
import SharedCore

/// FEAT-34: unit tests for `SagaCardArt`, the pure helpers behind `SagaCard`'s artwork-source and
/// logo-lookup-gating decisions (`DesignSystem/SagaCard.swift`). No view host — these exercise
/// plain functions over `MetaPreview`.
final class SagaCardTests: XCTestCase {

    private func makeItem(name: String = "Movie", poster: String? = nil, banner: String? = nil,
                          logo: String? = nil, releaseInfo: String? = nil) -> MetaPreview {
        MetaPreview(
            id: "1", type: "movie", name: name,
            poster: poster, banner: banner, logo: logo,
            posterShape: .landscape,
            description: nil, releaseInfo: releaseInfo, rawReleaseDate: nil,
            popularity: nil, voteCount: nil, imdbRating: nil,
            genres: []
        )
    }

    // MARK: - artworkURL

    func testArtworkURLPrefersBannerOverPoster() {
        let item = makeItem(poster: "https://example.com/poster.jpg", banner: "https://example.com/banner.jpg")
        XCTAssertEqual(SagaCardArt.artworkURL(for: item), "https://example.com/banner.jpg")
    }

    func testArtworkURLFallsBackToPosterWhenBannerMissing() {
        let item = makeItem(poster: "https://example.com/poster.jpg", banner: nil)
        XCTAssertEqual(SagaCardArt.artworkURL(for: item), "https://example.com/poster.jpg")
    }

    func testArtworkURLFallsBackToPosterWhenBannerEmpty() {
        let item = makeItem(poster: "https://example.com/poster.jpg", banner: "")
        XCTAssertEqual(SagaCardArt.artworkURL(for: item), "https://example.com/poster.jpg")
    }

    func testArtworkURLNilWhenBothEmpty() {
        let item = makeItem(poster: nil, banner: nil)
        XCTAssertNil(SagaCardArt.artworkURL(for: item))
    }

    func testArtworkURLNilWhenBothBlank() {
        let item = makeItem(poster: "", banner: "")
        XCTAssertNil(SagaCardArt.artworkURL(for: item))
    }

    // MARK: - needsLogoLookup

    func testNeedsLogoLookupFalseWhenLogoSet() {
        let item = makeItem(logo: "https://example.com/logo.png")
        XCTAssertFalse(SagaCardArt.needsLogoLookup(item))
    }

    func testNeedsLogoLookupTrueWhenLogoNil() {
        let item = makeItem(logo: nil)
        XCTAssertTrue(SagaCardArt.needsLogoLookup(item))
    }

    func testNeedsLogoLookupTrueWhenLogoEmpty() {
        let item = makeItem(logo: "")
        XCTAssertTrue(SagaCardArt.needsLogoLookup(item))
    }

    // MARK: - SagaLogoStore.shouldCommit

    /// Codex r2 findings 3+4: a lookup's completion must only be written to the cache when it is
    /// still the live `.pending` attempt for its key. `shouldCommit` is the pure decision behind
    /// that — no store, no dictionary, just the entry that was read for a key and the request id
    /// the completion carries.

    func testShouldCommitTrueForMatchingPending() {
        XCTAssertTrue(SagaLogoStore.shouldCommit(entry: .pending(requestId: 7), requestId: 7))
    }

    func testShouldCommitFalseForDifferentRequestId() {
        // A newer `lookupIfNeeded` call for the same key installed its own `.pending` — this
        // (older) request's completion must not clobber it.
        XCTAssertFalse(SagaLogoStore.shouldCommit(entry: .pending(requestId: 7), requestId: 3))
    }

    func testShouldCommitFalseWhenAlreadyResolved() {
        XCTAssertFalse(SagaLogoStore.shouldCommit(entry: .resolved("https://example.com/logo.png"), requestId: 7))
    }

    func testShouldCommitFalseWhenEntryMissing() {
        // The key was never populated, or its `.pending` was wiped by a capacity reset.
        XCTAssertFalse(SagaLogoStore.shouldCommit(entry: nil, requestId: 7))
    }
}
