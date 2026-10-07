import XCTest
@testable import NuvioTV

final class ChapterListParsingTests: XCTestCase {
    private let fiveJSON = """
    [{"title":"Opening","time":0},{"title":"Act One","time":90.0},{"title":"Act Two","time":240},
     {"title":"Act Three","time":390.5},{"title":"Credits","time":540}]
    """

    func testFiveChaptersParseSorted() {
        let c = PlayerChapters.parse(json: fiveJSON)
        XCTAssertEqual(c.map(\.sec), [0, 90, 240, 390.5, 540])
        XCTAssertEqual(c.map(\.title), ["Opening", "Act One", "Act Two", "Act Three", "Credits"])
    }

    func testUnsortedAndDuplicateTimes() {
        let c = PlayerChapters.parse(json: #"[{"title":"B","time":90},{"title":"A","time":0},{"title":"B2","time":90}]"#)
        XCTAssertEqual(c, [TransportChapter(title: "A", sec: 0), TransportChapter(title: "B", sec: 90)])
    }

    func testEmptyAndMalformed() {
        XCTAssertEqual(PlayerChapters.parse(json: "[]"), [])
        XCTAssertEqual(PlayerChapters.parse(json: "not json"), [])
        XCTAssertEqual(PlayerChapters.parse(json: #"{"time":0}"#), [])
        XCTAssertEqual(PlayerChapters.parse(json: ""), [])
    }

    func testInvalidTimesDropped() {
        let c = PlayerChapters.parse(json: #"[{"title":"x","time":-1.5},{"title":"y"},{"title":"z","time":"5"},{"title":"b","time":true},{"title":"ok","time":5}]"#)
        XCTAssertEqual(c, [TransportChapter(title: "ok", sec: 5)])
    }

    /// What mpv printed for the fixture on the simulator: times shifted by the container start.
    func testMpvStartOffsetClampsFirstChapter() {
        let raw = #"[{"title":"Opening","time":-0.023000},{"title":"Act One","time":89.977000},{"title":"Act Two","time":239.977000},{"title":"Act Three","time":389.977000},{"title":"Credits","time":539.977000}]"#
        let c = PlayerChapters.parse(json: raw)
        XCTAssertEqual(c.count, 5)
        XCTAssertEqual(c.first, TransportChapter(title: "Opening", sec: 0))
        XCTAssertEqual(PlayerChapters.title(at: 1, in: c), "Opening")
        let indexed = PlayerChapters.parseIndexed(count: 2, title: { _ in "" }, time: { [-0.02, 90][$0] })
        XCTAssertEqual(indexed.map(\.sec), [0, 90])
    }

    func testMissingTitleAndDisplayTitle() {
        let c = PlayerChapters.parse(json: #"[{"title":"Intro","time":0},{"time":60},{"title":"  ","time":120}]"#)
        XCTAssertEqual(c.map(\.title), ["Intro", "", ""])
        XCTAssertEqual(PlayerChapters.displayTitle(c[0], index: 0), "Intro")
        XCTAssertEqual(PlayerChapters.displayTitle(c[1], index: 1), "Chapter 2")
        XCTAssertEqual(PlayerChapters.displayTitle(c[2], index: 2), "Chapter 3")
    }

    func testIndexedFallback() {
        let titles = ["Opening", nil, "Credits"]
        let times = [0.0, 90, 540]
        let c = PlayerChapters.parseIndexed(count: 3, title: { titles[$0] }, time: { times[$0] })
        XCTAssertEqual(c, [TransportChapter(title: "Opening", sec: 0), TransportChapter(title: "", sec: 90),
                           TransportChapter(title: "Credits", sec: 540)])
        XCTAssertEqual(PlayerChapters.parseIndexed(count: 0, title: { _ in nil }, time: { _ in 0 }), [])
    }

    func testTitleAt() {
        let c = PlayerChapters.parse(json: fiveJSON)
        XCTAssertEqual(PlayerChapters.title(at: 100, in: c), "Act One")
        XCTAssertEqual(PlayerChapters.title(at: 240, in: c), "Act Two")           // on a boundary
        XCTAssertEqual(PlayerChapters.title(at: 239.995, in: c), "Act Two")       // within 0.01 s
        XCTAssertEqual(PlayerChapters.title(at: 239.98, in: c), "Act One")
        XCTAssertEqual(PlayerChapters.title(at: 599, in: c), "Credits")
        let late = [TransportChapter(title: "First", sec: 30), TransportChapter(title: "", sec: 60)]
        XCTAssertNil(PlayerChapters.title(at: 10, in: late))                       // before the first
        XCTAssertNil(PlayerChapters.title(at: 70, in: late))                       // untitled
        XCTAssertNil(PlayerChapters.title(at: 10, in: []))
    }

    @MainActor func testModelChapterTitleUsesTheRule() {
        let m = TransportBarModel()
        m.chapters = PlayerChapters.parse(json: fiveJSON)
        XCTAssertEqual(m.chapterTitle(at: 400), "Act Three")
        m.chapters = [TransportChapter(title: "", sec: 0)]
        XCTAssertNil(m.chapterTitle(at: 5))
    }
    // MARK: End markers (review r1 P2 #2)

    func testMarkerAtOrPastTheEndIsDropped() {
        let c = PlayerChapters.parse(json: #"[{"title":"A","time":0},{"title":"B","time":300},{"title":"End","time":600},{"title":"Past","time":700}]"#)
        XCTAssertEqual(PlayerChapters.trimmed(c, durationSec: 600).map(\.sec), [0, 300])
        // Within the 1 s slack of the end counts as the end; a second earlier is kept.
        XCTAssertEqual(PlayerChapters.trimmed(c, durationSec: 600.8).map(\.sec), [0, 300])
        XCTAssertEqual(PlayerChapters.trimmed(c, durationSec: 601.5).map(\.sec), [0, 300, 600])
    }

    /// Review r2 P3 #5: the published list is re-derived from the untrimmed one, so a duration
    /// that grows past a late chapter brings it back.
    func testGrowingDurationBringsLateChaptersBack() {
        let raw = PlayerChapters.parse(json: #"[{"title":"A","time":0},{"title":"B","time":300},{"title":"C","time":600}]"#)
        var published = PlayerChapters.trimmed(raw, durationSec: 0)
        XCTAssertEqual(published.map(\.sec), [0, 300, 600], "unknown duration keeps the list")
        // An early estimate puts C inside the end slack: dropped.
        published = PlayerChapters.republished(raw: raw, published: published, durationSec: 600.5) ?? published
        XCTAssertEqual(published.map(\.sec), [0, 300])
        XCTAssertNil(PlayerChapters.republished(raw: raw, published: published, durationSec: 600.7),
                     "nothing to publish while the list is already right")
        // The duration grows past C + slack: C is back.
        published = PlayerChapters.republished(raw: raw, published: published, durationSec: 900) ?? published
        XCTAssertEqual(published.map(\.sec), [0, 300, 600])
        XCTAssertNil(PlayerChapters.republished(raw: raw, published: published, durationSec: 1200))
    }

    func testUnknownDurationKeepsTheList() {
        let c = PlayerChapters.parse(json: fiveJSON)
        XCTAssertEqual(PlayerChapters.trimmed(c, durationSec: 0), c)
        XCTAssertEqual(PlayerChapters.trimmed(c, durationSec: .nan), c)
    }

    func testChapterSeekClampsInsideTheFile() {
        XCTAssertEqual(PlayerChapters.clampedSeek(600, durationSec: 600), 599.5)
        XCTAssertEqual(PlayerChapters.clampedSeek(700, durationSec: 600), 599.5)
        XCTAssertEqual(PlayerChapters.clampedSeek(240, durationSec: 600), 240)
        XCTAssertEqual(PlayerChapters.clampedSeek(700, durationSec: 0), 700, "unknown duration: no clamp")
        XCTAssertEqual(PlayerChapters.clampedSeek(-2, durationSec: 600), 0)
    }

    /// A Right click from the last real chapter with an end marker left in: the resolver still
    /// picks the marker, and the controller's clamp keeps the seek short of EOF.
    func testEdgeClickToAnEndMarkerIsClamped() {
        let c = [TransportChapter(title: "A", sec: 0), TransportChapter(title: "B", sec: 300),
                 TransportChapter(title: "End", sec: 600)]
        guard case .absolute(let t) = PlayerChapters.edgeClick(mode: .chapter, direction: 1, baseSec: 320, chapters: c) else {
            return XCTFail("expected an absolute chapter seek")
        }
        XCTAssertEqual(PlayerChapters.clampedSeek(t, durationSec: 600), 599.5)
        // Trimmed first (the duration known at FILE_LOADED), the same click is a plain +10 s.
        XCTAssertEqual(PlayerChapters.edgeClick(mode: .chapter, direction: 1, baseSec: 320,
                                                chapters: PlayerChapters.trimmed(c, durationSec: 600)), .relative(10))
    }
}
