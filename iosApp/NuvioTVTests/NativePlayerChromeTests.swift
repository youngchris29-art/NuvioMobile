import XCTest
@testable import NuvioTV
import SharedCore

/// Insights wave 1c: the native route's Rivulet / AVKit chrome rules (`NativeChromeRules.swift`)
/// — which text pills the screen hosts, the subtitle Timing button's step and clamp, the Cast
/// pill's Menu decision — and the Up Next card the native adapter builds.
@MainActor
final class NativePlayerChromeTests: XCTestCase {

    private func model() -> PlayerTopPanelModel {
        let context = PlaybackContext(
            url: URL(string: "https://cdn.example.com/a.mkv")!, title: "Show", contentType: "series",
            parentMetaId: "tt1", videoId: "tt1:1:4", season: 1, episode: 4, poster: nil,
            background: nil, providerName: nil, providerAddonId: nil,
            streamTitle: nil, streamSubtitle: nil, externalSubtitles: [])
        return PlayerTopPanelModel(info: PlayerPanelInfo(header: NativeInfoHeader(context: context)))
    }

    private func person(_ id: Int) -> PlayerPanelPerson {
        PlayerPanelPerson(id: id, name: "Person \(id)", role: "Role", photo: nil, isCrew: false)
    }

    private func video(season: Int32?, episode: Int32?, thumbnail: String?) -> MetaVideo {
        MetaVideo(
            id: "tt1:5", title: "The Next One", released: nil, available: true,
            thumbnail: thumbnail, seasonPoster: nil,
            season: season.map { KotlinInt(int: $0) }, episode: episode.map { KotlinInt(int: $0) },
            overview: nil, runtime: nil, rating: nil, streams: []
        )
    }

    // MARK: Pill set

    func testInfoAloneWhenNothingElseIsKnown() {
        let m = model()
        m.castEnabled = true
        XCTAssertEqual(NativePillPlan.pills(visible: PlayerInfoPill.visible(for: m)), [.info])
    }

    func testCastNeedsTheSettingAndPeople() {
        let m = model()
        m.castEnabled = false
        m.people = [person(1)]
        XCTAssertEqual(NativePillPlan.pills(visible: PlayerInfoPill.visible(for: m)), [.info])
        m.castEnabled = true
        XCTAssertEqual(NativePillPlan.pills(visible: PlayerInfoPill.visible(for: m)), [.info, .cast])
    }

    func testSystemChapterPillDropsTheCustomOne() {
        let m = model()
        m.castEnabled = true
        m.people = [person(1)]
        m.chapters = [PlayerPanelChapter(id: 0, title: "Opening", sec: 0, isCurrent: true)]
        m.upNext = PlayerPanelUpNext(title: "Next", subtitle: "S1 · E5", still: nil)
        let visible = PlayerInfoPill.visible(for: m)
        XCTAssertEqual(visible, [.info, .cast, .chapters, .upNext])
        XCTAssertEqual(NativePillPlan.pills(visible: visible, systemChapterPill: true), [.info, .cast, .upNext])
        XCTAssertEqual(NativePillPlan.pills(visible: visible, systemChapterPill: false), [.info, .cast, .chapters, .upNext])
    }

    func testNativeDefaultTrustsTheSystemChapterPill() {
        XCTAssertTrue(NativePillPlan.systemDrawsChapterPill)
        XCTAssertEqual(NativePillPlan.pills(visible: [.info, .chapters]), [.info])
    }

    func testUpNextPillFollowsTheCard() {
        let m = model()
        m.upNext = PlayerPanelUpNext(title: "Next", subtitle: nil, still: nil)
        XCTAssertEqual(NativePillPlan.pills(visible: PlayerInfoPill.visible(for: m)), [.info, .upNext])
        m.upNext = nil
        XCTAssertEqual(NativePillPlan.pills(visible: PlayerInfoPill.visible(for: m)), [.info])
    }

    // MARK: Timing

    func testTimingStepsHalfASecond() {
        XCTAssertEqual(NativeSubtitleTiming.adjusted(0, by: NativeSubtitleTiming.stepMs), 500)
        XCTAssertEqual(NativeSubtitleTiming.adjusted(500, by: -NativeSubtitleTiming.stepMs), 0)
        XCTAssertEqual(NativeSubtitleTiming.adjusted(-250, by: -NativeSubtitleTiming.stepMs), -750)
    }

    func testTimingClampsToTheSharedRange() {
        let maxMs = NativeSubtitleTiming.maxMs, minMs = NativeSubtitleTiming.minMs
        XCTAssertGreaterThan(maxMs, 0)
        XCTAssertLessThan(minMs, 0)
        XCTAssertEqual(NativeSubtitleTiming.adjusted(maxMs, by: 500), maxMs)
        XCTAssertEqual(NativeSubtitleTiming.adjusted(maxMs - 100, by: 500), maxMs)
        XCTAssertEqual(NativeSubtitleTiming.adjusted(minMs, by: -500), minMs)
        XCTAssertEqual(NativeSubtitleTiming.adjusted(900, by: 500, minMs: -1000, maxMs: 1000), 1000)
        XCTAssertEqual(NativeSubtitleTiming.adjusted(-900, by: -500, minMs: -1000, maxMs: 1000), -1000)
    }

    func testTimingLabel() {
        XCTAssertEqual(NativeSubtitleTiming.label(0), "0 s")
        XCTAssertEqual(NativeSubtitleTiming.label(500), "+0.5 s")
        XCTAssertEqual(NativeSubtitleTiming.label(-1500), "\u{2212}1.5 s")
        XCTAssertEqual(NativeSubtitleTiming.label(2000), "+2 s")
    }

    // MARK: Cast pill Menu

    func testMenuWithTheActorViewOpenIsConsumedBothWays() {
        let m = model()
        m.openPerson(person(7))
        var router = NativePillMenuRouter()
        XCTAssertTrue(router.menuBegan(menuBack: { m.menuBack() }))
        XCTAssertNil(m.actorView, "back to the card row")
        XCTAssertEqual(m.lastOpenedPersonId, 7, "focus returns to the card that was opened")
        XCTAssertTrue(router.menuEnded(), "the release is swallowed too")
    }

    func testMenuOnTheCardRowPassesOn() {
        let m = model()
        var router = NativePillMenuRouter()
        XCTAssertFalse(router.menuBegan(menuBack: { m.menuBack() }))
        XCTAssertFalse(router.menuEnded(), "AVKit gets the whole press and closes the pill")
    }

    func testOneLevelPerPress() {
        let m = model()
        m.openPerson(person(3))
        var router = NativePillMenuRouter()
        XCTAssertTrue(router.menuBegan(menuBack: { m.menuBack() }))
        XCTAssertTrue(router.menuEnded())
        XCTAssertFalse(router.menuBegan(menuBack: { m.menuBack() }))
        XCTAssertFalse(router.menuEnded())
    }

    func testCancelledPressForgetsThePendingSwallow() {
        let m = model()
        m.openPerson(person(3))
        var router = NativePillMenuRouter()
        XCTAssertTrue(router.menuBegan(menuBack: { m.menuBack() }))
        router.menuCancelled()
        XCTAssertFalse(router.menuEnded())
    }

    // MARK: Up Next card

    func testUpNextCardFromTheNextEpisode() {
        let card = NativePlayerPanelAdapter.upNextCard(video(season: 1, episode: 5, thumbnail: "https://img.example/s1e5.jpg"))
        XCTAssertEqual(card.title, "The Next One")
        XCTAssertEqual(card.subtitle, "S1 · E5")
        XCTAssertEqual(card.still, URL(string: "https://img.example/s1e5.jpg"))
    }

    func testUpNextCardWithoutNumbersOrStill() {
        let bare = NativePlayerPanelAdapter.upNextCard(video(season: nil, episode: nil, thumbnail: ""))
        XCTAssertNil(bare.subtitle)
        XCTAssertNil(bare.still)
        XCTAssertEqual(NativePlayerPanelAdapter.upNextCard(video(season: nil, episode: 3, thumbnail: nil)).subtitle, "E3")
    }
}
