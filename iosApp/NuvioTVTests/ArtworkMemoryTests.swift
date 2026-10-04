import UIKit
import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (I1, BUG-134): the two-pool decoded-image memory behind `ArtworkStore`. Each
/// test builds its own `ArtworkMemory`, so nothing touches the process-wide store.
final class ArtworkMemoryTests: XCTestCase {

    private func makeMemory() -> ArtworkMemory {
        ArtworkMemory(smallLimitBytes: 192 * 1024 * 1024, largeLimitBytes: 192 * 1024 * 1024)
    }

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
    }

    private let w500 = URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg")!
    private let w780 = URL(string: "https://image.tmdb.org/t/p/w780/poster.jpg")!
    private let original = URL(string: "https://image.tmdb.org/t/p/original/poster.jpg")!

    private let megabyte = 1024 * 1024

    func testLargestPrefersTheLargestBucketAcrossTheFamily() {
        let memory = makeMemory()
        let small = image()
        let big = image()
        memory.store(image: small, url: w500, bucket: 896, cost: megabyte)
        memory.store(image: big, url: w780, bucket: 1280, cost: 2 * megabyte)
        // Asked with the original w500 URL, the card's w780 decode is the answer.
        XCTAssertTrue(memory.largest(in: ArtworkURLUpgrade.family(w500)) === big)
        // Asked with the w780 URL, its family has no w500 member: only the larger decode.
        XCTAssertTrue(memory.largest(in: ArtworkURLUpgrade.family(w780)) === big)
        XCTAssertNil(memory.largest(in: ArtworkURLUpgrade.family(original)))
    }

    func testServingNeedsAtLeastTheRequestedBucket() {
        let memory = makeMemory()
        let stored = image()
        memory.store(image: stored, url: w780, bucket: 896, cost: megabyte)
        XCTAssertTrue(memory.serving(in: [w780], atLeast: 896) === stored)
        XCTAssertTrue(memory.serving(in: [w780], atLeast: 512) === stored)
        XCTAssertNil(memory.serving(in: [w780], atLeast: 1024))
        // A request made with the original w500 URL is served by its larger w780 sibling.
        XCTAssertTrue(memory.serving(in: ArtworkURLUpgrade.family(w500), atLeast: 896) === stored)
    }

    /// beta.19-rc1 verdict (review r1, B P2-1): the `.legacy` lookup's memory half — the largest
    /// decode of the family, but only among decodes at the floor or larger.
    func testLargestAtLeastRefusesDecodesUnderTheFloor() {
        let memory = makeMemory()
        let card = image()
        memory.store(image: card, url: w780, bucket: 768, cost: megabyte)
        XCTAssertNil(memory.largest(in: ArtworkURLUpgrade.family(w780), atLeast: 1280),
                     "a card-sized decode is not a legacy hit")
        XCTAssertTrue(memory.largest(in: ArtworkURLUpgrade.family(w780), atLeast: 768) === card)
        XCTAssertTrue(memory.largest(in: ArtworkURLUpgrade.family(w780)) === card, "the unfloored form is unchanged")

        let legacy = image()
        memory.store(image: legacy, url: w780, bucket: 1280, cost: 4 * megabyte)
        XCTAssertTrue(memory.largest(in: ArtworkURLUpgrade.family(w780), atLeast: 1280) === legacy)

        // A sharper rendition at a larger bucket wins over the legacy decode beside it.
        let sharp = image()
        memory.store(image: sharp, url: original, bucket: 3072, cost: 21 * megabyte)
        XCTAssertTrue(memory.largest(in: ArtworkURLUpgrade.family(w780), atLeast: 1280) === sharp)
    }

    func testPlaceholderFindsSmallerAndLargerDecodes() {
        let memory = makeMemory()
        let smaller = image()
        memory.store(image: smaller, url: w500, bucket: 384, cost: megabyte)
        // Nothing at 1280 or above, but the 384 decode is a placeholder.
        XCTAssertNil(memory.serving(in: [w500], atLeast: 1280))
        XCTAssertTrue(memory.placeholder(in: [w500], for: 1280) === smaller)
        // A larger decode of the same URL is preferred over a smaller one.
        let larger = image()
        memory.store(image: larger, url: w500, bucket: 1536, cost: 3 * megabyte)
        XCTAssertTrue(memory.placeholder(in: [w500], for: 1280) === larger)
        // Nothing for an unrelated URL.
        XCTAssertNil(memory.placeholder(in: [URL(string: "https://example.com/a.jpg")!], for: 1280))
    }

    func testPoolIsChosenByDecodedCost() {
        let memory = makeMemory()
        memory.store(image: image(), url: w500, bucket: 896, cost: 2 * megabyte)
        var totals = memory.totals()
        XCTAssertEqual(totals.smallCount, 1)
        XCTAssertEqual(totals.smallBytes, 2 * megabyte)
        XCTAssertEqual(totals.largeCount, 0)

        memory.store(image: image(), url: w780, bucket: 1920, cost: 8 * megabyte)
        totals = memory.totals()
        XCTAssertEqual(totals.smallCount, 1)
        XCTAssertEqual(totals.largeCount, 1)
        XCTAssertEqual(totals.largeBytes, 8 * megabyte)
        // Exactly the threshold goes to the large pool.
        memory.store(image: image(), url: original, bucket: 1536, cost: ArtworkDecodeMath.largePoolThreshold)
        XCTAssertEqual(memory.totals().largeCount, 2)
    }

    func testStoringTheSameKeyTwiceDoesNotDoubleCount() {
        let memory = makeMemory()
        let first = image()
        let second = image()
        memory.store(image: first, url: w500, bucket: 896, cost: megabyte)
        memory.store(image: second, url: w500, bucket: 896, cost: megabyte)
        let totals = memory.totals()
        XCTAssertEqual(totals.smallCount, 1)
        XCTAssertEqual(totals.smallBytes, megabyte)
        XCTAssertTrue(memory.largest(in: [w500]) === second)
    }

    func testClearLargeEmptiesOnlyTheLargePool() {
        let memory = makeMemory()
        let poster = image()
        memory.store(image: poster, url: w500, bucket: 896, cost: 2 * megabyte)
        memory.store(image: image(), url: w780, bucket: 3840, cost: 33 * megabyte)
        XCTAssertEqual(memory.totals().largeCount, 1)
        memory.clearLarge()
        let totals = memory.totals()
        XCTAssertEqual(totals.largeCount, 0)
        XCTAssertEqual(totals.largeBytes, 0)
        XCTAssertEqual(totals.smallCount, 1)
        XCTAssertNil(memory.serving(in: [w780], atLeast: 128))
        XCTAssertTrue(memory.largest(in: [w500]) === poster)
        // The large pool takes new entries again, counted from zero.
        memory.store(image: image(), url: w780, bucket: 3840, cost: 33 * megabyte)
        XCTAssertEqual(memory.totals().largeCount, 1)
    }

    func testDataURLIdentityStaysShort() {
        let payload = String(repeating: "A", count: 100_000)
        let url = URL(string: "data:image/png;base64,\(payload)")!
        XCTAssertLessThan(ArtworkMemory.identity(url).count, 64)
        // Short strings are their own identity.
        XCTAssertEqual(ArtworkMemory.identity(w500), w500.absoluteString)
        // The same payload gets the same identity, a different one a different identity.
        XCTAssertEqual(ArtworkMemory.identity(url), ArtworkMemory.identity(URL(string: "data:image/png;base64,\(payload)")!))
        let other = URL(string: "data:image/png;base64,\(String(repeating: "B", count: 100_000))")!
        XCTAssertNotEqual(ArtworkMemory.identity(url), ArtworkMemory.identity(other))
    }
}

/// beta.19-rc1 verdict (review r1, B P2-1): the lookup contract end to end through `ArtworkStore`'s
/// process-wide memory (`ArtworkStore.storeForTesting`, DEBUG). Cards decode at their drawn size, so
/// one URL can be resident only as a card's 768 px decode; the `.legacy` lookup (the Home hero, the
/// launch head, every call site that has not opted into a size) must refuse it, while the seed,
/// placeholder and colour lookups keep answering with it. Every URL is unique to its test.
@MainActor
final class ArtworkLegacyLookupTests: XCTestCase {

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
    }

    /// A TMDB `w1280` backdrop URL and its `original` sibling, unique to the caller.
    private func tmdbBackdrop() -> (w1280: URL, original: URL) {
        let file = "\(UUID().uuidString).jpg"
        return (URL(string: "https://image.tmdb.org/t/p/w1280/\(file)")!,
                URL(string: "https://image.tmdb.org/t/p/original/\(file)")!)
    }

    private func otherHost() -> URL {
        URL(string: "https://artwork.example.com/\(UUID().uuidString).jpg")!
    }

    /// Review r1's scenario: a Continue Watching card (`LandscapeCard`, 360 × 203 pt) decoded the
    /// entry's backdrop at 768 px. The hero's legacy lookup misses (so its fetch re-decodes from the
    /// URLCache bytes); the card's own request, the seed, the placeholder and colour sampling still
    /// find the card's bitmap.
    func testLegacyLookupRefusesACardSizedDecode() {
        let url = tmdbBackdrop().w1280
        let source = CGSize(width: 1280, height: 720)
        let card = image()
        ArtworkStore.storeForTesting(card, url: url, bucket: 768, sourceSize: source)

        XCTAssertNil(ArtworkStore.cached(url, decode: .legacy), "a card decode must not become the hero's bitmap")
        XCTAssertTrue(ArtworkStore.cached(url) === card, "the first-frame seed still finds it")
        XCTAssertTrue(ArtworkStore.cachedLargest(url) === card)
        XCTAssertTrue(ArtworkStore.cachedImage(for: url) === card, "colour sampling still finds it")
        XCTAssertTrue(ArtworkStore.cachedPlaceholder(url, decode: .legacy) === card, "and it is the placeholder")
        let cardRequest = ArtworkDecodeRequest(size: .points(width: 360, height: 203), fill: true, scale: 2).normalized
        XCTAssertTrue(ArtworkStore.cached(url, decode: cardRequest) === card, "the card's own request is unchanged")

        // The legacy decode (min(1920, 1280) = 1280 px, stored at 1280) is the hit once it lands.
        let legacy = image()
        ArtworkStore.storeForTesting(legacy, url: url, bucket: 1280, sourceSize: source)
        XCTAssertTrue(ArtworkStore.cached(url, decode: .legacy) === legacy)
    }

    /// The hero sharpen's `original` decode serves the `w1280` URL's legacy lookup, ahead of the
    /// legacy decode beside it, so a re-presented hero commits sharp.
    func testLegacyLookupTakesTheLargestAdequateRendition() {
        let urls = tmdbBackdrop()
        ArtworkStore.storeForTesting(image(), url: urls.w1280, bucket: 768, sourceSize: CGSize(width: 1280, height: 720))
        let sharp = image()
        ArtworkStore.storeForTesting(sharp, url: urls.original, bucket: 3072, sourceSize: CGSize(width: 3840, height: 2160))
        XCTAssertTrue(ArtworkStore.cached(urls.w1280, decode: .legacy) === sharp)

        ArtworkStore.storeForTesting(image(), url: urls.w1280, bucket: 1280, sourceSize: CGSize(width: 1280, height: 720))
        XCTAssertTrue(ArtworkStore.cached(urls.w1280, decode: .legacy) === sharp, "largest adequate first")
    }

    /// No recorded source: the floor is the full 1920 bucket.
    func testLegacyLookupWithAnUnknownSourceNeeds1920() {
        let url = otherHost()
        ArtworkStore.storeForTesting(image(), url: url, bucket: 1536, sourceSize: nil)
        XCTAssertNil(ArtworkStore.cached(url, decode: .legacy))
        let legacy = image()
        ArtworkStore.storeForTesting(legacy, url: url, bucket: 1920, sourceSize: nil)
        XCTAssertTrue(ArtworkStore.cached(url, decode: .legacy) === legacy)
    }

    /// A source smaller than 1920: the legacy decode is the whole source, stored at the source's own
    /// bucket, and a card decode that already holds the whole source is just as good.
    func testLegacyLookupForASmallSourceAcceptsTheWholeSource() {
        let whole = otherHost()
        let poster = CGSize(width: 500, height: 750)
        let full = image()
        ArtworkStore.storeForTesting(full, url: whole, bucket: 768, sourceSize: poster)
        XCTAssertTrue(ArtworkStore.cached(whole, decode: .legacy) === full)

        let partial = otherHost()
        ArtworkStore.storeForTesting(image(), url: partial, bucket: 640, sourceSize: poster)
        XCTAssertNil(ArtworkStore.cached(partial, decode: .legacy), "640 px of a 750 px source is short")
    }

    /// The launch head (`HeroCommitCoordinator.prepare`) looks up through the same legacy floor.
    func testHeroFetcherUsesTheLegacyLookup() {
        let url = tmdbBackdrop().w1280
        let source = CGSize(width: 1280, height: 720)
        let fetcher = ArtworkStoreHeroFetcher()
        ArtworkStore.storeForTesting(image(), url: url, bucket: 768, sourceSize: source)
        XCTAssertNil(fetcher.cachedImage(url), "the head must not commit a card decode")
        let legacy = image()
        ArtworkStore.storeForTesting(legacy, url: url, bucket: 1280, sourceSize: source)
        XCTAssertTrue(fetcher.cachedImage(url) === legacy)
        XCTAssertNil(fetcher.cachedImage(nil))
    }
}
