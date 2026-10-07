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
        let c = PlayerChapters.parse(json: #"[{"title":"x","time":-1},{"title":"y"},{"title":"z","time":"5"},{"title":"ok","time":5}]"#)
        XCTAssertEqual(c, [TransportChapter(title: "ok", sec: 5)])
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
}
