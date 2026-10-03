import XCTest
@testable import NuvioTV

/// beta.19-rc1 verdict (I1, BUG-134): the one pure place that decides "ask the CDN for a bigger file"
/// and tells the cache which URLs are one picture.
final class ArtworkURLUpgradeTests: XCTestCase {

    private func tmdb(_ size: String, _ file: String = "abc123.jpg") -> String {
        "https://image.tmdb.org/t/p/\(size)/\(file)"
    }

    private func metahub(_ kind: String, _ size: String, _ id: String = "tt0111161") -> String {
        "https://images.metahub.space/\(kind)/\(size)/\(id)/img"
    }

    // MARK: TMDB posters

    func testTmdbPosterW500ToW780() {
        XCTAssertEqual(ArtworkURLUpgrade.upgraded(tmdb("w500"), role: .poster), tmdb("w780"))
        XCTAssertEqual(ArtworkURLUpgrade.upgraded(tmdb("w342"), role: .poster), tmdb("w780"))
        XCTAssertEqual(ArtworkURLUpgrade.upgraded(tmdb("w92"), role: .poster), tmdb("w780"))
        // The URL overload gives the same answer.
        XCTAssertEqual(
            ArtworkURLUpgrade.upgraded(URL(string: tmdb("w500"))!, role: .poster),
            URL(string: tmdb("w780"))!)
    }

    func testTmdbPosterW780Unchanged() {
        XCTAssertNil(ArtworkURLUpgrade.upgraded(tmdb("w780"), role: .poster))
        XCTAssertNil(ArtworkURLUpgrade.upgraded(tmdb("original"), role: .poster))
        // A backdrop-sized URL is not a poster size.
        XCTAssertNil(ArtworkURLUpgrade.upgraded(tmdb("w1280"), role: .poster))
    }

    func testTmdbPosterLargeToOriginal() {
        XCTAssertEqual(ArtworkURLUpgrade.upgraded(tmdb("w500"), role: .posterLarge), tmdb("original"))
        XCTAssertEqual(ArtworkURLUpgrade.upgraded(tmdb("w780"), role: .posterLarge), tmdb("original"))
        XCTAssertNil(ArtworkURLUpgrade.upgraded(tmdb("original"), role: .posterLarge))
    }

    // MARK: TMDB backdrops and logos

    func testTmdbBackdropW1280ToOriginal() {
        XCTAssertEqual(ArtworkURLUpgrade.upgraded(tmdb("w1280"), role: .backdrop), tmdb("original"))
        XCTAssertEqual(ArtworkURLUpgrade.upgraded(tmdb("w780"), role: .backdrop), tmdb("original"))
        XCTAssertEqual(ArtworkURLUpgrade.upgraded(tmdb("w300"), role: .backdrop), tmdb("original"))
        XCTAssertNil(ArtworkURLUpgrade.upgraded(tmdb("original"), role: .backdrop))
    }

    func testTmdbLogoPngToOriginal() {
        XCTAssertEqual(ArtworkURLUpgrade.upgraded(tmdb("w500", "logo.png"), role: .logo), tmdb("original", "logo.png"))
        XCTAssertEqual(ArtworkURLUpgrade.upgraded(tmdb("w300", "logo.png"), role: .logo), tmdb("original", "logo.png"))
        XCTAssertNil(ArtworkURLUpgrade.upgraded(tmdb("original", "logo.png"), role: .logo))
    }

    func testTmdbLogoSvgUnchanged() {
        // ImageIO cannot decode SVG, so the w500 path is kept and nothing regresses.
        XCTAssertNil(ArtworkURLUpgrade.upgraded(tmdb("w500", "logo.svg"), role: .logo))
        XCTAssertNil(ArtworkURLUpgrade.upgraded(tmdb("w500", "LOGO.SVG?v=2"), role: .logo))
        // An SVG is its own family, so the cache never looks for an `original/…svg` that cannot exist.
        let svg = URL(string: tmdb("w500", "logo.svg"))!
        XCTAssertEqual(ArtworkURLUpgrade.family(svg), [svg])
    }

    // MARK: metahub

    func testMetahubPosterSmallAndMediumToLarge() {
        XCTAssertEqual(ArtworkURLUpgrade.upgraded(metahub("poster", "small"), role: .poster), metahub("poster", "large"))
        XCTAssertEqual(ArtworkURLUpgrade.upgraded(metahub("poster", "medium"), role: .poster), metahub("poster", "large"))
        XCTAssertEqual(ArtworkURLUpgrade.upgraded(metahub("poster", "medium"), role: .posterLarge), metahub("poster", "large"))
    }

    func testMetahubPosterLargeUnchanged() {
        XCTAssertNil(ArtworkURLUpgrade.upgraded(metahub("poster", "large"), role: .poster))
        XCTAssertNil(ArtworkURLUpgrade.upgraded(metahub("poster", "large"), role: .posterLarge))
    }

    func testMetahubBackgroundAndLogoUnchanged() {
        // Measured 2026-10-03: large serves the same bytes as medium for backgrounds and logos.
        XCTAssertNil(ArtworkURLUpgrade.upgraded(metahub("background", "medium"), role: .backdrop))
        XCTAssertNil(ArtworkURLUpgrade.upgraded(metahub("background", "medium"), role: .poster))
        XCTAssertNil(ArtworkURLUpgrade.upgraded(metahub("logo", "medium"), role: .logo))
        XCTAssertNil(ArtworkURLUpgrade.upgraded(metahub("poster", "medium"), role: .backdrop))
        XCTAssertNil(ArtworkURLUpgrade.upgraded(metahub("poster", "medium"), role: .logo))
    }

    // MARK: Other hosts, query strings, families

    func testOtherHostsUnchanged() {
        // A custom poster service, a GitHub-hosted collection cover, and a host that only mentions a CDN
        // in its path must all stay as they are, whatever the role.
        let urls = [
            "https://posters.example/t/p/w500/tt1.jpg",
            "https://raw.githubusercontent.com/user/repo/main/covers/w500/a.png",
            "https://evil.example/image.tmdb.org/t/p/w500/x.jpg",
            "https://evil.example/images.metahub.space/poster/medium/tt1/img",
            "https://image.tmdb.org.evil.example/t/p/w500/x.jpg",
        ]
        for url in urls {
            for role in [ArtworkURLUpgrade.Role.poster, .posterLarge, .backdrop, .logo] {
                XCTAssertNil(ArtworkURLUpgrade.upgraded(url, role: role), "\(url) \(role)")
            }
            XCTAssertEqual(ArtworkURLUpgrade.family(URL(string: url)!), [URL(string: url)!])
        }
        XCTAssertNil(ArtworkURLUpgrade.upgraded("", role: .poster))
        XCTAssertNil(ArtworkURLUpgrade.upgraded("not a url", role: .poster))
    }

    func testQueryStringKept() {
        XCTAssertEqual(
            ArtworkURLUpgrade.upgraded("https://image.tmdb.org/t/p/w500/p.jpg?lang=en&v=3", role: .poster),
            "https://image.tmdb.org/t/p/w780/p.jpg?lang=en&v=3")
        XCTAssertEqual(
            ArtworkURLUpgrade.upgraded("https://images.metahub.space/poster/medium/tt0111161/img?x=1", role: .poster),
            "https://images.metahub.space/poster/large/tt0111161/img?x=1")
    }

    func testFamilyLargestFirstAndDeduped() {
        let w500 = URL(string: tmdb("w500", "x.png"))!
        XCTAssertEqual(
            ArtworkURLUpgrade.family(w500),
            [URL(string: tmdb("original", "x.png"))!, URL(string: tmdb("w780", "x.png"))!, w500])
        // A w780 poster's family has no w500 member: only renditions at least as large.
        let w780 = URL(string: tmdb("w780", "x.png"))!
        XCTAssertEqual(ArtworkURLUpgrade.family(w780), [URL(string: tmdb("original", "x.png"))!, w780])
        // The largest rendition is its own family.
        let original = URL(string: tmdb("original", "x.png"))!
        XCTAssertEqual(ArtworkURLUpgrade.family(original), [original])
        // A TMDB backdrop: original, then itself (no poster rule applies to w1280).
        let w1280 = URL(string: tmdb("w1280", "b.jpg"))!
        XCTAssertEqual(ArtworkURLUpgrade.family(w1280), [URL(string: tmdb("original", "b.jpg"))!, w1280])
        // metahub: large, then the URL asked with; a large URL is its own family.
        let medium = URL(string: metahub("poster", "medium"))!
        XCTAssertEqual(ArtworkURLUpgrade.family(medium), [URL(string: metahub("poster", "large"))!, medium])
        let large = URL(string: metahub("poster", "large"))!
        XCTAssertEqual(ArtworkURLUpgrade.family(large), [large])
    }

    func testSizeSegmentForProbe() {
        XCTAssertEqual(ArtworkURLUpgrade.sizeSegment(URL(string: tmdb("w780"))!), "w780")
        XCTAssertEqual(ArtworkURLUpgrade.sizeSegment(URL(string: tmdb("original"))!), "original")
        XCTAssertEqual(ArtworkURLUpgrade.sizeSegment(URL(string: metahub("poster", "large"))!), "poster/large")
        XCTAssertEqual(ArtworkURLUpgrade.sizeSegment(URL(string: metahub("background", "medium"))!), "background/medium")
        XCTAssertEqual(ArtworkURLUpgrade.sizeSegment(URL(string: "https://example.com/a.jpg")!), "-")
    }
}
