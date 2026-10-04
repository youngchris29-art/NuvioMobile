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

/// beta.19-rc1 verdict (review r2, P3-1): the title-logo path. Home hero logos (`HeroArtResolver.present`,
/// the launch head's `ArtworkStoreHeroFetcher.cachedLogo`) and the first-play overlay's logo are looked
/// up at a slot-sized `.points` request, not `.legacy`: the legacy floor is 1920 px for a URL that was
/// never decoded itself, so a `w500` logo refused the `original` Detail had already decoded for its
/// slot (the overlay faded DOWN to `w500`; the hero had to fetch `w500` inside its 400 ms deadline or
/// commit the text wordmark). A slot lookup on a never-decoded URL reads the picture's aspect from a
/// family member's recorded source, so any decode that covers the slot is a hit. Every URL is unique
/// to its test.
@MainActor
final class ArtworkSlotLogoLookupTests: XCTestCase {

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
    }

    /// A TMDB `w500` logo URL and its `original` sibling, unique to the caller.
    private func tmdbLogo() -> (w500: URL, original: URL) {
        let file = "\(UUID().uuidString).png"
        return (URL(string: "https://image.tmdb.org/t/p/w500/\(file)")!,
                URL(string: "https://image.tmdb.org/t/p/original/\(file)")!)
    }

    /// Detail's Cinematic logo slot (600 × 180 pt, fit, `upgrade: .logo`) at scale 2, and the bucket a
    /// decode of `source` for it is stored under.
    private func detailBucket(_ source: CGSize) -> Int {
        let detailSlot = ArtworkDecodeRequest(size: .points(width: 600, height: 180), fill: false, scale: 2).normalized
        return ArtworkDecodeMath.storeBucket(needed: ArtworkDecodeMath.neededLongSide(detailSlot, source: source),
                                             sourceLongSide: max(source.width, source.height))
    }

    /// The reviewer's scenario on the Home hero: a 2:1 wordmark whose `original` Detail decoded at 768
    /// (720 px drawn). The hero's slot draws it 600 px wide at scale 2, so that decode covers it.
    func testHeroLogoLookupTakesTheOriginalDetailDecoded() {
        let urls = tmdbLogo()
        let source = CGSize(width: 2000, height: 1000)
        XCTAssertEqual(detailBucket(source), 768)
        let original = image()
        ArtworkStore.storeForTesting(original, url: urls.original, bucket: 768, sourceSize: source)

        XCTAssertNil(ArtworkStore.cached(urls.w500, decode: .legacy),
                     "the legacy floor (1920 for a URL never decoded) refuses it: the old miss")
        XCTAssertTrue(ArtworkStore.cached(urls.w500, decode: HeroSharpen.logoRequest(scale: 2)) === original,
                      "the hero's slot request accepts any family decode that covers the slot")
        XCTAssertTrue(ArtworkStore.cached(urls.w500, decode: HeroSharpen.logoRequest(scale: 1)) === original)
    }

    /// The launch head goes through the same slot lookup for its logo; its backdrop keeps the legacy
    /// floor (review r1, B P2-1).
    func testLaunchHeadLooksUpTheLogoAtTheSlotRequest() {
        let urls = tmdbLogo()
        let source = CGSize(width: 2000, height: 1000)
        let original = image()
        ArtworkStore.storeForTesting(original, url: urls.original, bucket: detailBucket(source), sourceSize: source)
        let fetcher = ArtworkStoreHeroFetcher()
        XCTAssertTrue(fetcher.cachedLogo(urls.w500) === original)
        XCTAssertNil(fetcher.cachedImage(urls.w500), "the backdrop form keeps the legacy floor")
        XCTAssertNil(fetcher.cachedLogo(nil))
    }

    /// The first-play overlay asks for the upgraded `original` at the stream picker header's request:
    /// Detail's decode of that file is a final hit (no fetch, no fade down to `w500`).
    func testFirstPlayOverlayLogoTakesTheOriginalDetailDecoded() {
        XCTAssertEqual(FirstPlayAutoPlayOverlay.logoDecodeSize, .points(width: 600, height: 120))
        let urls = tmdbLogo()
        let source = CGSize(width: 2000, height: 1000)
        let original = image()
        ArtworkStore.storeForTesting(original, url: urls.original, bucket: detailBucket(source), sourceSize: source)
        let overlay = ArtworkDecodeRequest(size: FirstPlayAutoPlayOverlay.logoDecodeSize, fill: false, scale: 2).normalized
        XCTAssertTrue(ArtworkStore.cached(urls.original, decode: overlay) === original)
        XCTAssertTrue(ArtworkStore.cached(urls.w500, decode: overlay) === original, "and the w500 fallback's lookup too")
    }

    /// No source recorded anywhere in the family: nothing to read an aspect from, so the slot's own
    /// long side stays the floor (520 pt × 2 = 1040 → the 1280 bucket).
    func testSlotLookupWithNoRecordedSourceKeepsTheSlotFloor() {
        let urls = tmdbLogo()
        ArtworkStore.storeForTesting(image(), url: urls.original, bucket: 768, sourceSize: nil)
        XCTAssertNil(ArtworkStore.cached(urls.w500, decode: HeroSharpen.logoRequest(scale: 2)))
        let covering = image()
        ArtworkStore.storeForTesting(covering, url: urls.original, bucket: 1280, sourceSize: nil)
        XCTAssertTrue(ArtworkStore.cached(urls.w500, decode: HeroSharpen.logoRequest(scale: 2)) === covering)
    }

    /// A fill request (a card) is never relaxed by the family aspect: it keeps the floor it had. A
    /// square 400 pt slot over a 2:3 poster would need 1200 px by aspect; the no-source floor (800 →
    /// 896) stays the answer, so the card's existing 896 hit is unchanged.
    func testFillLookupsKeepTheirFloor() {
        let file = "\(UUID().uuidString).jpg"
        let w500 = URL(string: "https://image.tmdb.org/t/p/w500/\(file)")!
        let w780 = URL(string: "https://image.tmdb.org/t/p/w780/\(file)")!
        let card = image()
        ArtworkStore.storeForTesting(card, url: w780, bucket: 896, sourceSize: CGSize(width: 780, height: 1170))
        let square = ArtworkDecodeRequest(size: .points(width: 400, height: 400), fill: true, scale: 2).normalized
        XCTAssertTrue(ArtworkStore.cached(w500, decode: square) === card)
        let larger = ArtworkDecodeRequest(size: .points(width: 600, height: 600), fill: true, scale: 2).normalized
        XCTAssertNil(ArtworkStore.cached(w500, decode: larger), "a 1200 px slot still needs the 1280 bucket")
    }

    /// A fetch joins work already in flight for the same URL at its own bucket or a larger one (whose
    /// decode covers it), never a smaller one.
    func testInflightKeysJoinTheSameOrALargerBucket() {
        XCTAssertEqual(ArtworkStore.inflightKeys(identity: "u", neededBucket: 1280),
                       ["1280|u", "1536|u", "1920|u", "2560|u", "3072|u", "3840|u"])
        XCTAssertEqual(ArtworkStore.inflightKeys(identity: "u", neededBucket: 3840), ["3840|u"])
        XCTAssertEqual(ArtworkStore.inflightKeys(identity: "u", neededBucket: 128).first, "128|u")
    }

    // MARK: beta.19-rc1 verdict (review r3, P3 #2): a joined fetch is checked against the joiner's need

    /// A `width` × `height` px bitmap at scale 1.
    private func pixels(_ width: CGFloat, _ height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in }
    }

    private func longSide(_ image: UIImage) -> Int {
        image.cgImage.map { max($0.width, $0.height) } ?? 0
    }

    /// A 2000 × 1000 PNG wordmark as a `data:` URL: `ArtworkStore.fetch` decodes it locally, with no
    /// network. The fill colour is random, so the URL is unique to the caller.
    private func dataLogo() -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let size = CGSize(width: 2000, height: 1000)
        let png = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
        return URL(string: "data:image/png;base64,\(png.base64EncodedString())")!
    }

    /// Detail's Cinematic logo slot (600 × 180 pt, fit) at scale 2.
    private var detailSlot: ArtworkDecodeRequest {
        ArtworkDecodeRequest(size: .points(width: 600, height: 180), fill: false, scale: 2).normalized
    }

    /// Review r3's numbers: for a 2:1 wordmark the hero's slot decodes 640 px and Detail's needs 768,
    /// yet with no recorded source both key their in-flight work at the slot's long side (1280), so
    /// one joins the other.
    func testHeroAndDetailLogoFetchesShareAKeyButNotADecodeSize() {
        let source = CGSize(width: 2000, height: 1000)
        let hero = HeroSharpen.logoRequest(scale: 2)
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: ArtworkDecodeMath.neededLongSide(hero, source: nil)), 1280)
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: ArtworkDecodeMath.neededLongSide(detailSlot, source: nil)), 1280)
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: ArtworkDecodeMath.neededLongSide(hero, source: source)), 640)
        XCTAssertEqual(ArtworkDecodeMath.bucket(for: ArtworkDecodeMath.neededLongSide(detailSlot, source: source)), 768)
    }

    /// The pure check a joiner runs once the owner has landed (and recorded the source): the owner's
    /// bitmap is kept only when it covers the joiner's OWN floor.
    func testJoinedDecodeIsCheckedAgainstTheJoinersOwnNeed() {
        let urls = tmdbLogo()
        let heroDecode = pixels(640, 320)
        ArtworkStore.storeForTesting(heroDecode, url: urls.original, bucket: 640, sourceSize: CGSize(width: 2000, height: 1000))

        XCTAssertFalse(ArtworkStore.covers(heroDecode, url: urls.original, decode: detailSlot),
                       "Detail draws the wordmark 720 px wide: a 640 px decode is short")
        XCTAssertNil(ArtworkStore.cached(urls.original, decode: detailSlot), "and its own lookup misses")
        XCTAssertTrue(ArtworkStore.covers(heroDecode, url: urls.original, decode: HeroSharpen.logoRequest(scale: 2)))
        XCTAssertTrue(ArtworkStore.covers(pixels(768, 384), url: urls.original, decode: detailSlot))
        XCTAssertFalse(ArtworkStore.covers(heroDecode, url: urls.original, decode: .legacy),
                       "a legacy caller needs min(1920, source)")
    }

    /// A fetch also waits on SMALLER in-flight work of the same URL, for its bytes, largest first.
    /// The launch case: the `.legacy` row prefetch (1920) and the slot-sized carousel prefetch of a
    /// never-decoded logo (1280), which the covering keys alone never join.
    func testByteShareKeysAreTheSmallerBuckets() {
        XCTAssertEqual(ArtworkStore.inflightByteShareKeys(identity: "u", neededBucket: 1920),
                       ["1536|u", "1280|u", "1024|u", "896|u", "768|u", "640|u", "512|u", "384|u", "256|u", "128|u"])
        XCTAssertEqual(ArtworkStore.inflightByteShareKeys(identity: "u", neededBucket: 128), [])
        let slot = ArtworkDecodeMath.bucket(
            for: ArtworkDecodeMath.neededLongSide(HeroSharpen.logoRequest(scale: 2), source: nil))
        let legacy = ArtworkDecodeMath.bucket(for: ArtworkDecodeMath.neededLongSide(.legacy, source: nil))
        XCTAssertFalse(ArtworkStore.inflightKeys(identity: "u", neededBucket: legacy).contains("\(slot)|u"))
        XCTAssertTrue(ArtworkStore.inflightByteShareKeys(identity: "u", neededBucket: legacy).contains("\(slot)|u"))
    }

    /// End to end (a `data:` URL, decoded locally): Detail's fetch joins the hero's in-flight logo
    /// fetch, finds its 640 px decode short, and decodes its own 768 px from the same bytes. Before
    /// review r3 it kept the 640 px bitmap and drew it 12 % upscaled.
    func testDetailJoiningTheHeroLogoFetchDecodesItsOwnSize() async throws {
        let url = dataLogo()
        let identity = ArtworkMemory.identity(url)
        var started: [String] = []
        ArtworkStore.onFetchWorkStartForTesting = { key in
            if key.hasSuffix("|\(identity)") { started.append(key) }
        }
        defer { ArtworkStore.onFetchWorkStartForTesting = nil }

        let hero = HeroSharpen.logoRequest(scale: 2)
        let detail = detailSlot
        let heroFetch = Task { try await ArtworkStore.fetch(url, decode: hero) }
        await Task.yield()   // the hero's fetch registers its in-flight work first
        let detailFetch = Task { try await ArtworkStore.fetch(url, decode: detail) }
        let heroImage = try await heroFetch.value
        let detailImage = try await detailFetch.value

        XCTAssertEqual(longSide(heroImage), 640)
        XCTAssertEqual(longSide(detailImage), 768, "Detail decodes its own size instead of keeping the hero's")
        XCTAssertEqual(started, ["1280|\(identity)", "768|\(identity)"],
                       "the joined work under the slot's key, then Detail's own decode at its real bucket")
    }

    /// End to end: the `.legacy` row prefetch issued while the slot-sized logo prefetch is still in
    /// flight waits for it, then decodes its own 1920 px from those bytes. Its own work starts only
    /// once the slot decode has landed (before review r3 both ran at once: two downloads).
    func testLegacyPrefetchWaitsForTheSmallerSlotFetch() async throws {
        let url = dataLogo()
        let identity = ArtworkMemory.identity(url)
        let slot = HeroSharpen.logoRequest(scale: 2)
        var started: [String] = []
        var slotLandedWhenLegacyStarted: Bool?
        ArtworkStore.onFetchWorkStartForTesting = { key in
            guard key.hasSuffix("|\(identity)") else { return }
            started.append(key)
            if key.hasPrefix("1920|") {
                slotLandedWhenLegacyStarted = ArtworkStore.cached(url, decode: slot) != nil
            }
        }
        defer { ArtworkStore.onFetchWorkStartForTesting = nil }

        let slotFetch = Task { try await ArtworkStore.fetch(url, decode: slot) }
        await Task.yield()   // the slot fetch registers its in-flight work first
        let legacyFetch = Task { try await ArtworkStore.fetch(url) }
        let slotImage = try await slotFetch.value
        let legacyImage = try await legacyFetch.value

        XCTAssertEqual(longSide(slotImage), 640)
        XCTAssertEqual(longSide(legacyImage), 1920)
        XCTAssertEqual(started, ["1280|\(identity)", "1920|\(identity)"])
        XCTAssertEqual(slotLandedWhenLegacyStarted, true,
                       "the legacy decode starts after the slot fetch landed, from its bytes")
    }
}
