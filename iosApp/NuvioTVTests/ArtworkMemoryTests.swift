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
