import XCTest
@testable import NuvioTV
import SharedCore

/// Insights wave 1c: the native route's Rivulet / AVKit chrome rules (`NativeChromeRules.swift`)
/// — which text pills the screen hosts and their titles, the subtitle Timing button's step and
/// clamp, the Cast pill's Menu decision — the eager tool menus (`NativeTransportMenus`) and the
/// Up Next card the native adapter builds.
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

    // MARK: Pill titles (no "Info · Info")

    func testNativeInfoPillIsStreamInfoBesideTheSystemInfoPill() {
        XCTAssertTrue(NativePillPlan.systemDrawsInfoPill)
        XCTAssertEqual(NativePillPlan.title(for: .info), String(localized: "Stream Info"))
        XCTAssertEqual(NativePillPlan.title(for: .cast), PlayerInfoPill.cast.title)
        XCTAssertEqual(NativePillPlan.title(for: .info, systemInfoPill: false), PlayerInfoPill.info.title)
        let row = NativePillPlan.rowTitles(custom: [.info, .cast, .upNext])
        XCTAssertEqual(row, [PlayerInfoPill.info.title, String(localized: "Stream Info"),
                             PlayerInfoPill.cast.title, PlayerInfoPill.upNext.title])
        XCTAssertEqual(Set(row).count, row.count, "no duplicate pill title")
    }

    func testEveryPillSharesOneFixedHeight() {
        XCTAssertEqual(NativePillPlan.contentHeight, 420)
        let m = model()
        for pill in PlayerInfoPill.allCases {
            let vc = NativeInfoPillController(pill: pill, model: m)
            XCTAssertEqual(vc.preferredContentSize.height, NativePillPlan.contentHeight, pill.rawValue)
            XCTAssertEqual(vc.title, NativePillPlan.title(for: pill))
        }
    }

    // MARK: Tool menus (eager, no deferred elements)

    private func inputs(episodes: [NativeTransportMenus.EpisodeRow] = [],
                        sources: NativeTransportMenus.SourcesState = .loading,
                        canSwitch: Bool = true, timing: Bool = false, delayMs: Int = 0,
                        syncLine: Bool = false, rememberAvailable: Bool = false,
                        remember: Bool = false) -> NativeTransportMenus.Inputs {
        NativeTransportMenus.Inputs(canSwitchStreams: canSwitch, episodes: episodes, sources: sources,
                                    timing: timing, delayMs: delayMs, syncLine: syncLine,
                                    rememberAvailable: rememberAvailable, remember: remember)
    }

    private func menu(_ items: [UIMenuElement], _ item: NativeTransportMenus.Item) -> UIMenu? {
        items.compactMap { $0 as? UIMenu }.first { $0.identifier == NativeTransportMenus.identifier(item) }
    }

    /// Only `UIAction` and `UIMenu` reach AVKit, a `UIMenu` holds only `UIAction`s (one level).
    private func assertEager(_ items: [UIMenuElement], file: StaticString = #filePath, line: UInt = #line) {
        for item in items {
            if let menu = item as? UIMenu {
                XCTAssertFalse(menu.children.isEmpty, "\(menu.title) has rows", file: file, line: line)
                XCTAssertTrue(menu.children.allSatisfy { $0 is UIAction }, "\(menu.title): actions only", file: file, line: line)
            } else {
                XCTAssertTrue(item is UIAction, "top level is UIAction/UIMenu", file: file, line: line)
            }
            XCTAssertFalse(item is UIDeferredMenuElement, file: file, line: line)
        }
    }

    private let rows = [
        NativeTransportMenus.EpisodeRow(key: "tt1:1:1", title: "S1E1 · A", isCurrent: false),
        NativeTransportMenus.EpisodeRow(key: "tt1:1:2", title: "S1E2 · B", isCurrent: true),
    ]

    func testEpisodesAndSourcesAreDrawnWhenTheirInputsExist() throws {
        let sources = NativeTransportMenus.SourcesState.rows([
            .init(key: "0|a", title: "1080p WEB", subtitle: "Torrentio", isCurrent: true),
            .init(key: "1|b", title: "2160p DV", subtitle: "Comet · YouTube", isCurrent: false),
        ])
        var picked: [String] = []
        var actions = NativeTransportMenus.Actions()
        actions.onEpisode = { picked.append("e:" + $0) }
        actions.onSource = { picked.append("s:" + $0) }
        let items = NativeTransportMenus.build(inputs(episodes: rows, sources: sources), actions: actions)
        assertEager(items)
        let episodes = try XCTUnwrap(menu(items, .episodes))
        XCTAssertEqual(episodes.children.map(\.title), ["S1E1 · A", "S1E2 · B"])
        XCTAssertEqual((episodes.children[1] as? UIAction)?.state, .on)
        let src = try XCTUnwrap(menu(items, .sources))
        XCTAssertEqual(src.children.map(\.title), ["1080p WEB", "2160p DV"])
        XCTAssertEqual(src.children.map(\.subtitle), ["Torrentio", "Comet · YouTube"])
        XCTAssertEqual((src.children[0] as? UIAction)?.state, .on)
        // Taps resolve by key; the playing row is inert.
        (episodes.children[0] as? UIAction).map { $0.performWithSender(nil, target: nil) }
        (episodes.children[1] as? UIAction).map { $0.performWithSender(nil, target: nil) }
        (src.children[1] as? UIAction).map { $0.performWithSender(nil, target: nil) }
        XCTAssertEqual(picked, ["e:tt1:1:1", "s:1|b"])
    }

    func testSourcesWhileLoadingOrBlockedStillDrawsTheButton() {
        for state in [NativeTransportMenus.SourcesState.loading, .blocked(jump: false), .blocked(jump: true), .empty] {
            let items = NativeTransportMenus.build(inputs(sources: state), actions: .init())
            assertEager(items)
            XCTAssertEqual(menu(items, .sources)?.children.count, 1, "one note row for \(state)")
        }
        XCTAssertEqual(menu(NativeTransportMenus.build(inputs(sources: .loading), actions: .init()), .sources)?
            .children.first?.title, String(localized: "Loading sources…"))
    }

    /// Review r3: every round button carries its localized name as its VoiceOver label (they draw
    /// image-only on the transport bar).
    func testEveryToolButtonHasAnAccessibilityLabel() {
        let all = inputs(episodes: rows, sources: .empty, timing: true, syncLine: true,
                         rememberAvailable: true)
        let items = NativeTransportMenus.build(all, actions: .init())
        XCTAssertEqual(items.count, 5, "Episodes, Sources, Timing, Sync Line, Remember")
        for item in items {
            let label = item.accessibilityLabel ?? ""
            XCTAssertFalse(label.isEmpty, "no accessibilityLabel on \(item.title)")
            XCTAssertEqual(label, item.title, "label and title differ on \(item.title)")
        }
        XCTAssertEqual(menu(items, .sources)?.accessibilityLabel, NativeTransportMenus.Item.sources.title)
        XCTAssertEqual(menu(items, .timing)?.accessibilityLabel, String(localized: "Subtitle Timing"))
        XCTAssertEqual(items.compactMap { $0 as? UIAction }.first?.accessibilityLabel, String(localized: "Sync Line"))
        for item in NativeTransportMenus.Item.allCases {
            XCTAssertFalse(item.title.isEmpty, item.rawValue)
        }
    }

    /// C2: the button set (what AVKit counts positions by) changes only with the kinds drawn;
    /// a content change (more sources, a new delay) keeps it.
    func testItemKindsFollowTheDrawnButtons() {
        let base = inputs(episodes: rows, sources: .loading, rememberAvailable: true)
        XCTAssertEqual(NativeTransportMenus.itemKinds(base), [.episodes, .sources, .rememberSpeed])
        var subsOn = base
        subsOn.timing = true
        subsOn.syncLine = true
        XCTAssertEqual(NativeTransportMenus.itemKinds(subsOn), [.episodes, .sources, .timing, .syncLine, .rememberSpeed])
        var moreRows = base
        moreRows.sources = .rows([.init(key: "0|a", title: "A", subtitle: nil, isCurrent: false)])
        moreRows.delayMs = 500
        XCTAssertEqual(NativeTransportMenus.itemKinds(moreRows), NativeTransportMenus.itemKinds(base))
        for kinds in [base, subsOn, moreRows] {
            let built = NativeTransportMenus.build(kinds, actions: .init())
            XCTAssertEqual(built.map(\.title), NativeTransportMenus.itemKinds(kinds).map(\.title))
        }
    }

    /// C1: every other Menu recogniser waits for the Cast pill's actor-view Menu tap.
    func testOnlyMenuRecognizersWaitForTheActorMenuTap() {
        XCTAssertTrue(NativePillMenuRecognizer.takesMenu([UIPress.PressType.menu.rawValue]))
        XCTAssertTrue(NativePillMenuRecognizer.takesMenu([UIPress.PressType.select.rawValue, UIPress.PressType.menu.rawValue]))
        XCTAssertFalse(NativePillMenuRecognizer.takesMenu([UIPress.PressType.select.rawValue]))
        XCTAssertFalse(NativePillMenuRecognizer.takesMenu([]))
    }

    func testCancelReportsAPendingConsumedPress() {
        var router = NativePillMenuRouter()
        XCTAssertFalse(router.menuCancelled())
        XCTAssertTrue(router.menuBegan(pill: .cast, actorViewOpen: true))
        XCTAssertTrue(router.menuCancelled(), "a consumed press was pending")
        XCTAssertFalse(router.menuCancelled(), "forgotten after one cancel")
        XCTAssertEqual(router.menuEnded(), .passOn)
    }

    func testNoEpisodesOrSourcesWithoutAStreamSwitcher() {
        let items = NativeTransportMenus.build(inputs(episodes: rows, sources: .empty, canSwitch: false), actions: .init())
        XCTAssertNil(menu(items, .episodes))
        XCTAssertNil(menu(items, .sources))
        XCTAssertNil(menu(NativeTransportMenus.build(inputs(episodes: []), actions: .init()), .episodes),
                     "no Episodes button before the list is known")
    }

    func testEpisodeRowsFromTheEngineList() {
        func ep(_ s: Int32, _ e: Int32) -> MetaVideo {
            MetaVideo(id: "tt1:\(s):\(e)", title: "T\(s)\(e)", released: nil, available: true,
                      thumbnail: nil, seasonPoster: nil, season: KotlinInt(int: s), episode: KotlinInt(int: e),
                      overview: nil, runtime: nil, rating: nil, streams: [])
        }
        let rows = NativeTransportMenus.episodeRows([ep(1, 1), ep(1, 2), ep(2, 1)], currentSeason: 1, currentEpisode: 2)
        XCTAssertEqual(rows.map(\.title), ["S1E1 · T11", "S1E2 · T12", "S2E1 · T21"])
        XCTAssertEqual(rows.map(\.key), ["tt1:1:1", "tt1:1:2", "tt1:2:1"])
        XCTAssertEqual(rows.map(\.isCurrent), [false, true, false])
        let items = NativeTransportMenus.episodeItems(rows) { _ in }
        XCTAssertTrue(items.allSatisfy { $0 is UIAction }, "flat: no nested UIMenu")
    }

    func testTimingShowsTheCurrentDelayFirst() throws {
        let items = NativeTransportMenus.build(inputs(timing: true, delayMs: 1500), actions: .init())
        assertEager(items)
        let timing = try XCTUnwrap(menu(items, .timing))
        XCTAssertEqual(timing.children.map(\.title), [
            String(format: String(localized: "Delay %@"), "+1.5 s"),
            "\u{2212}0.5 s", "+0.5 s", String(localized: "Reset"),
        ])
        XCTAssertEqual(timing.subtitle, "+1.5 s")
        XCTAssertNil(menu(NativeTransportMenus.build(inputs(timing: false), actions: .init()), .timing))
    }

    func testTimingRowsReportTheirSteps() throws {
        var steps: [Int?] = []
        var actions = NativeTransportMenus.Actions()
        actions.onDelayStep = { steps.append($0) }
        let timing = try XCTUnwrap(menu(NativeTransportMenus.build(inputs(timing: true), actions: actions), .timing))
        for child in timing.children { (child as? UIAction)?.performWithSender(nil, target: nil) }
        XCTAssertEqual(steps, [-500, 500, nil], "the delay row is inert; −, +, Reset")
    }

    func testTimingRebuildsWithTheNewDelay() {
        // The installer compares inputs: a delay change is a different menu (rebuilt, reassigned).
        XCTAssertNotEqual(inputs(timing: true, delayMs: 0), inputs(timing: true, delayMs: -500))
        let rebuilt = menu(NativeTransportMenus.build(inputs(timing: true, delayMs: -500), actions: .init()), .timing)
        XCTAssertEqual(rebuilt?.children.first?.title, String(format: String(localized: "Delay %@"), "\u{2212}0.5 s"))
    }

    func testRememberSpeedShowsItsState() throws {
        var picked: [Bool] = []
        var actions = NativeTransportMenus.Actions()
        actions.onRemember = { picked.append($0) }
        let on = try XCTUnwrap(menu(NativeTransportMenus.build(inputs(rememberAvailable: true, remember: true), actions: actions), .rememberSpeed))
        XCTAssertEqual(on.children.map(\.title), [String(localized: "On"), String(localized: "Off")])
        XCTAssertEqual(on.children.compactMap { ($0 as? UIAction)?.state }, [.on, .off])
        let off = try XCTUnwrap(menu(NativeTransportMenus.build(inputs(rememberAvailable: true, remember: false), actions: actions), .rememberSpeed))
        XCTAssertEqual(off.children.compactMap { ($0 as? UIAction)?.state }, [.off, .on])
        XCTAssertNotEqual(on.image, off.image, "the button itself shows the state")
        for child in on.children + off.children { (child as? UIAction)?.performWithSender(nil, target: nil) }
        XCTAssertEqual(picked, [false, true], "only the row that changes the state reports")
        XCTAssertNil(menu(NativeTransportMenus.build(inputs(rememberAvailable: false), actions: .init()), .rememberSpeed))
    }

    // MARK: Cast card identity

    func testCastAndCrewEntriesOfOnePersonGetDistinctCardKeys() {
        let cast = PlayerPanelPerson(id: 9, name: "A", role: "Lead", photo: nil, isCrew: false)
        let crew = PlayerPanelPerson(id: 9, name: "A", role: "Director", photo: nil, isCrew: true)
        XCTAssertNotEqual(cast.cardKey, crew.cardKey)
        let m = model()
        m.people = [cast, crew]
        XCTAssertEqual(Set(m.people.map(\.cardKey)).count, 2)
        m.openPerson(crew)
        XCTAssertEqual(m.lastOpenedCardKey, crew.cardKey)
    }

    // MARK: Cast pill Menu

    func testOnlyTheCastPillWithTheActorViewOpenTakesMenu() {
        XCTAssertTrue(NativePillMenuRouter.intercepts(pill: .cast, actorViewOpen: true))
        XCTAssertFalse(NativePillMenuRouter.intercepts(pill: .cast, actorViewOpen: false))
        for pill in PlayerInfoPill.allCases where pill != .cast {
            XCTAssertFalse(NativePillMenuRouter.intercepts(pill: pill, actorViewOpen: true), pill.rawValue)
        }
    }

    func testMenuWithTheActorViewOpenIsConsumedBothWaysAndBacksOutOnRelease() {
        let m = model()
        m.openPerson(person(7))
        var router = NativePillMenuRouter()
        XCTAssertTrue(router.menuBegan(pill: .cast, actorViewOpen: m.actorView != nil))
        XCTAssertNotNil(m.actorView, "nothing changes on the way down")
        XCTAssertEqual(router.menuEnded(), .consumeAndBack, "the release is consumed and backs out")
        XCTAssertTrue(m.menuBack())
        XCTAssertNil(m.actorView, "back to the card row")
        XCTAssertEqual(m.lastOpenedCardKey, person(7).cardKey, "focus returns to the card that was opened")
    }

    func testMenuOnTheCardRowPassesOn() {
        let m = model()
        var router = NativePillMenuRouter()
        XCTAssertFalse(router.menuBegan(pill: .cast, actorViewOpen: m.actorView != nil))
        XCTAssertEqual(router.menuEnded(), .passOn, "AVKit gets the whole press and closes the pill")
    }

    func testOneLevelPerPress() {
        let m = model()
        m.openPerson(person(3))
        var router = NativePillMenuRouter()
        XCTAssertTrue(router.menuBegan(pill: .cast, actorViewOpen: m.actorView != nil))
        if router.menuEnded() == .consumeAndBack { m.menuBack() }
        XCTAssertFalse(router.menuBegan(pill: .cast, actorViewOpen: m.actorView != nil))
        XCTAssertEqual(router.menuEnded(), .passOn)
    }

    func testCancelledPressForgetsThePendingSwallow() {
        let m = model()
        m.openPerson(person(3))
        var router = NativePillMenuRouter()
        XCTAssertTrue(router.menuBegan(pill: .cast, actorViewOpen: true))
        router.menuCancelled()
        XCTAssertEqual(router.menuEnded(), .passOn)
        XCTAssertNotNil(m.actorView, "a cancelled press changes nothing")
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
