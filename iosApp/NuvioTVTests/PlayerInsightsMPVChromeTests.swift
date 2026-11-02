import SharedCore
import XCTest
@testable import NuvioTV

/// Insights (2026-11-01): the mpv route's Rivulet / AVKit layout — the text pill row, its
/// popovers and shelves, and the remote rules that drive them.
@MainActor
final class PlayerInsightsMPVChromeTests: XCTestCase {
    private let canvas = CGSize(width: 1920, height: 1080)
    private func layout(_ pills: Int = 6) -> TransportBarLayout { TransportBarLayout(canvas: canvas, pillCount: pills) }

    private func model() -> PlayerTopPanelModel {
        let context = PlaybackContext(
            url: URL(string: "https://cdn.example.com/a.mkv")!, title: "Film", contentType: "movie",
            parentMetaId: "tt1", videoId: "tt1", season: nil, episode: nil, poster: nil,
            background: nil, providerName: nil, providerAddonId: nil,
            streamTitle: nil, streamSubtitle: nil, externalSubtitles: [])
        return PlayerTopPanelModel(info: PlayerPanelInfo(header: NativeInfoHeader(context: context)))
    }

    private let person = PlayerPanelPerson(id: 1, name: "Actor", role: "Hero", photo: nil, isCrew: false)

    // MARK: - Pill row: move / clamp

    func testInfoPillMoveStepsAndClamps() {
        let all = PlayerInfoPill.allCases
        XCTAssertEqual(PlayerInfoPill.move(from: .info, by: 1, in: all), .cast)
        XCTAssertEqual(PlayerInfoPill.move(from: .cast, by: -1, in: all), .info)
        XCTAssertEqual(PlayerInfoPill.move(from: .info, by: -1, in: all), .info)        // no wrap left
        XCTAssertEqual(PlayerInfoPill.move(from: .upNext, by: 1, in: all), .upNext)     // no wrap right
        XCTAssertEqual(PlayerInfoPill.move(from: .info, by: 9, in: all), .upNext)
    }

    func testInfoPillMoveOffRowLandsOnFirstAndEmptyRowIsNil() {
        XCTAssertEqual(PlayerInfoPill.move(from: .cast, by: 1, in: [.info, .chapters]), .info)
        XCTAssertNil(PlayerInfoPill.move(from: .info, by: 1, in: []))
    }

    func testReconcileKeepsFocusOnARemainingPill() {
        let r = PlayerInfoPill.reconcile(focused: .chapters, open: .chapters,
                                         old: [.info, .chapters], new: [.info, .cast, .chapters])
        XCTAssertEqual(r.focused, .chapters)
        XCTAssertEqual(r.open, .chapters)
    }

    func testReconcileMovesFocusFromAGonePillAndClosesItsShelf() {
        // Up Next went away (the next episode cleared) while its shelf was open.
        let r = PlayerInfoPill.reconcile(focused: .upNext, open: .upNext,
                                         old: [.info, .chapters, .upNext], new: [.info, .chapters])
        XCTAssertEqual(r.focused, .chapters)        // the old place, clamped
        XCTAssertNil(r.open)
        let empty = PlayerInfoPill.reconcile(focused: .cast, open: nil, old: [.info, .cast], new: [])
        XCTAssertNil(empty.focused)
    }

    // MARK: - Visible pill set

    func testVisiblePillsInfoOnlyByDefault() {
        let m = model()
        m.castEnabled = true
        XCTAssertEqual(PlayerInfoPill.visible(for: m), [.info])
    }

    func testVisiblePillsAllInDisplayOrder() {
        let m = model()
        m.castEnabled = true
        m.people = [person]
        m.chapters = [PlayerPanelChapter(id: 0, title: "One", sec: 0, isCurrent: true)]
        m.upNext = PlayerPanelUpNext(title: "Next", subtitle: "S1 · E2", still: nil)
        XCTAssertEqual(PlayerInfoPill.visible(for: m), [.info, .cast, .chapters, .upNext])
    }

    func testCastHiddenWhenSettingOffOrNobodyKnown() {
        let m = model()
        m.castEnabled = false
        m.people = [person]
        XCTAssertEqual(PlayerInfoPill.visible(for: m), [.info])
        m.castEnabled = true
        m.people = []
        XCTAssertEqual(PlayerInfoPill.visible(for: m), [.info])
    }

    func testUpNextCardFromEpisode() {
        let ep = MetaVideo(id: "tt1:1:2", title: "Second", released: nil, available: true,
                           thumbnail: "https://img.example/still.jpg", seasonPoster: nil,
                           season: KotlinInt(int: 1), episode: KotlinInt(int: 2), overview: nil,
                           runtime: nil, rating: nil, streams: [])
        let card = MPVPlayerPanelAdapter.upNextCard(ep)
        XCTAssertEqual(card, PlayerPanelUpNext(title: "Second", subtitle: "S1 · E2",
                                               still: URL(string: "https://img.example/still.jpg")))
    }

    // MARK: - Transport model

    func testOverlayOpenIsPopoverOrShelf() {
        let t = TransportBarModel()
        XCTAssertFalse(t.overlayOpen)
        t.openPopover = .subtitles
        XCTAssertTrue(t.overlayOpen)
        t.openPopover = nil
        t.openInfoPill = .info
        XCTAssertTrue(t.overlayOpen)
    }

    func testOnlyToolDiscsWithListsOpenPopovers() {
        XCTAssertNil(PillKind.aspect.popoverSize)       // cycles in place
        XCTAssertNil(PillKind.more.popoverSize)         // opens the Info shelf
        for kind in [PillKind.subtitles, .audio, .speed, .sources, .episodes] {
            XCTAssertNotNil(kind.popoverSize, "\(kind)")
        }
    }

    // MARK: - Layout

    func testInfoPillRowSitsUnderTheTimesRow() {
        let l = layout()
        XCTAssertEqual(l.infoPillRowFrame, CGRect(x: 86, y: 991, width: 1748, height: 46))
        XCTAssertEqual(l.infoPillRowFrame.minY, l.timesRowFrame.maxY + TransportBarLayout.infoPillGap)
        XCTAssertEqual(canvas.height - l.infoPillRowFrame.maxY, 43)    // the old times-row margin
    }

    func testDiscFramesFollowTheRow() {
        let l = layout(6)
        XCTAssertEqual(l.discFrame(index: 0), CGRect(x: 1337, y: 807.5, width: 62, height: 62))
        XCTAssertEqual(l.discFrame(index: 5).maxX, 1834)
    }

    func testPopoverAnchorsAboveItsDiscAndClamps() {
        let l = layout(6)
        let first = l.popoverFrame(discIndex: 0, size: CGSize(width: 820, height: 560))
        XCTAssertEqual(first, CGRect(x: 958, y: 223.5, width: 820, height: 560))
        XCTAssertEqual(first.maxY, l.pillRowFrame.minY - TransportBarLayout.popoverGap)
        // The last disc's popover is held inside the track's right end.
        XCTAssertEqual(l.popoverFrame(discIndex: 5, size: CGSize(width: 820, height: 560)).maxX, 1834)
        // Height capped.
        XCTAssertEqual(l.popoverFrame(discIndex: 0, size: CGSize(width: 820, height: 900)).height, 600)
    }

    func testShelfSpansTheTrackAboveTheLockup() {
        let l = layout()
        XCTAssertEqual(l.shelfFrame, CGRect(x: 86, y: 368, width: 1748, height: 420))
        XCTAssertEqual(l.shelfFrame.maxY, l.lockupFrame.minY - TransportBarLayout.shelfGap)
    }

    func testHideBlockedWhileOverlayOpen() {
        // The controller passes `holdsBar(...)` as `pillFocused`.
        XCTAssertFalse(TransportHideRule.mayHide(pillFocused: true, modeActive: false))
    }

    func testAFocusedTextPillHoldsTheBar() {
        // Device pass 2026-11-01: the bar hid under a focused text pill after 4–5 s, paused too.
        XCTAssertTrue(TransportHideRule.holdsBar(discFocused: false, infoPillFocused: true, overlayOpen: false))
        XCTAssertTrue(TransportHideRule.holdsBar(discFocused: true, infoPillFocused: false, overlayOpen: false))
        XCTAssertTrue(TransportHideRule.holdsBar(discFocused: false, infoPillFocused: false, overlayOpen: true))
        XCTAssertFalse(TransportHideRule.holdsBar(discFocused: false, infoPillFocused: false, overlayOpen: false))
    }

    // MARK: - Info content fits its host's height

    func testInfoRowsShowOnlyTheWholeRowsThatFit() {
        let cells: [CGFloat] = Array(repeating: 40, count: 9)   // 5 rows of 2
        // 3 rows = 40 + 8 + 40 + 8 + 40 = 136
        XCTAssertEqual(PlayerInfoFitGridLayout.fittingRows(cellHeights: cells, columns: 2, spacing: 8, maxHeight: 140),
                       [40, 40, 40])
        XCTAssertEqual(PlayerInfoFitGridLayout.fittingRows(cellHeights: cells, columns: 2, spacing: 8, maxHeight: 39),
                       [])
        XCTAssertEqual(PlayerInfoFitGridLayout.fittingRows(cellHeights: cells, columns: 2, spacing: 8, maxHeight: nil).count,
                       5)
    }

    func testInfoRowHeightIsItsTallestCell() {
        XCTAssertEqual(PlayerInfoFitGridLayout.fittingRows(cellHeights: [30, 50, 20], columns: 2, spacing: 0,
                                                           maxHeight: nil), [50, 20])
    }

    func testSubtitlesAndAudioPopoversFitTheirRows() {
        // Device pass 2026-11-01: the Subtitles rows ran past an 820 pt popover.
        XCTAssertEqual(PillKind.subtitles.popoverSize?.width, 1180)
        XCTAssertEqual(PillKind.audio.popoverSize?.width, 1180)
        XCTAssertLessThanOrEqual(layout().popoverFrame(discIndex: 0, size: PillKind.subtitles.popoverSize!).maxX,
                                 layout().trackMaxX)
    }

    // MARK: - MenuPrecedence, the new levels

    private func menu(panel: Bool = false, actor: Bool = false, overlay: Bool = false, mode: Bool = false,
                      upNext: Bool = false, pill: Bool = false, infoPill: Bool = false,
                      bar: Bool = false) -> MenuPrecedence.Action {
        MenuPrecedence.resolve(panelOpen: panel, actorViewOpen: actor, overlayOpen: overlay, modeActive: mode,
                               upNextShowing: upNext, pillFocused: pill, infoPillFocused: infoPill, barUp: bar)
    }

    func testPresentedControllerStillWinsOverEverything() {
        XCTAssertEqual(menu(panel: true, actor: true, overlay: true, mode: true, upNext: true, pill: true,
                            infoPill: true, bar: true), .panel)
    }

    func testActorViewBacksOutFirstInsideTheShelf() {
        XCTAssertEqual(menu(actor: true, overlay: true, upNext: true, infoPill: true, bar: true), .actorBack)
    }

    func testActorViewWithoutAnOpenShelfIsIgnored() {
        // A stale actor view never takes Menu once its shelf is closed.
        XCTAssertEqual(menu(actor: true, infoPill: true, bar: true), .unfocusInfoPill)
    }

    func testOverlayClosesBeforeUpNextChipAndPills() {
        XCTAssertEqual(menu(overlay: true, upNext: true, pill: true, infoPill: true, bar: true), .closeOverlay)
        XCTAssertEqual(menu(overlay: true, mode: true, bar: true), .closeOverlay)
    }

    func testUpNextChipBeatsTheTextPillRow() {
        XCTAssertEqual(menu(upNext: true, infoPill: true, bar: true), .dismissUpNext)
    }

    func testTextPillLetsGoOfTheFocusAndTheBarStays() {
        // Device pass 2026-11-01: Menu on a focused text pill used to hide the bar too.
        XCTAssertEqual(menu(infoPill: true, bar: true), .unfocusInfoPill)
    }

    func testFocusedDiscStillHidesTheBar() {
        // Base behaviour for the disc row is unchanged.
        XCTAssertEqual(menu(pill: true, bar: true), .hidePill)
        XCTAssertEqual(menu(pill: true, infoPill: true, bar: true), .hidePill)
    }

    func testOneLevelPerPressSequence() {
        // actor view → shelf → pill row unfocused (bar stays) → bar hidden → exit
        XCTAssertEqual(menu(actor: true, overlay: true, infoPill: true, bar: true), .actorBack)
        XCTAssertEqual(menu(overlay: true, infoPill: true, bar: true), .closeOverlay)
        XCTAssertEqual(menu(infoPill: true, bar: true), .unfocusInfoPill)
        XCTAssertEqual(menu(bar: true), .hideBar)
        XCTAssertEqual(menu(), .exit)
    }

    func testPopoverSequenceFromADisc() {
        // popover → disc focused (hides the bar with it, base behaviour) → exit
        XCTAssertEqual(menu(overlay: true, pill: true, bar: true), .closeOverlay)
        XCTAssertEqual(menu(pill: true, bar: true), .hidePill)
        XCTAssertEqual(menu(), .exit)
    }

    func testOldCasesUnchangedThroughTheNewSignature() {
        XCTAssertEqual(menu(mode: true, upNext: true, pill: true, bar: true), .cancelMode)
        XCTAssertEqual(menu(upNext: true, pill: true, bar: true), .dismissUpNext)
        XCTAssertEqual(menu(pill: true, bar: true), .hidePill)
        XCTAssertEqual(menu(bar: true), .hideBar)
        XCTAssertEqual(menu(), .exit)
    }

    func testNewLevelsSwallowTheirRelease() {
        XCTAssertTrue(MenuPrecedence.swallowsRelease(.actorBack))
        XCTAssertTrue(MenuPrecedence.swallowsRelease(.closeOverlay))
        XCTAssertTrue(MenuPrecedence.swallowsRelease(.unfocusInfoPill))
    }

    // MARK: - Down-press decision table

    private func down(overlay: Bool = false, disc: Bool = false, infoPill: Bool = false, skip: Bool = false,
                      upNextPlays: Bool = false, asked: inout Bool) -> DownPressRule.Action {
        var askedLocal = false
        let action = DownPressRule.resolve(overlayOpen: overlay, discFocused: disc, infoPillFocused: infoPill,
                                           skipChip: skip, playUpNext: { askedLocal = true; return upNextPlays })
        asked = askedLocal
        return action
    }

    func testDownWithNothingElseFocusesTheTextPills() {
        var asked = false
        XCTAssertEqual(down(asked: &asked), .focusInfoPills)
        XCTAssertTrue(asked)
    }

    func testDownFromADiscGoesBackToTheTrackWithoutTouchingUpNext() {
        var asked = false
        XCTAssertEqual(down(disc: true, skip: true, upNextPlays: true, asked: &asked), .discToTrack)
        XCTAssertFalse(asked)
    }

    func testDownOnTheTextPillsStaysThere() {
        var asked = false
        XCTAssertEqual(down(infoPill: true, skip: true, upNextPlays: true, asked: &asked), .ignore)
        XCTAssertFalse(asked)
    }

    func testDownWithAnOverlayOpenDoesNothing() {
        var asked = false
        XCTAssertEqual(down(overlay: true, disc: true, upNextPlays: true, asked: &asked), .ignore)
        XCTAssertFalse(asked)
    }

    func testUpNextThenSkipKeepTheirPrecedence() {
        var asked = false
        XCTAssertEqual(down(skip: true, upNextPlays: true, asked: &asked), .playedUpNext)
        XCTAssertEqual(down(skip: true, upNextPlays: false, asked: &asked), .skip)
        XCTAssertTrue(asked)
    }
}
