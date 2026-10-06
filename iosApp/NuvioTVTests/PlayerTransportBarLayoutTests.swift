import XCTest
@testable import NuvioTV

final class PlayerTransportBarLayoutTests: XCTestCase {
    private let canvas = CGSize(width: 1920, height: 1080)
    private func layout(_ pills: Int = 6) -> TransportBarLayout { TransportBarLayout(canvas: canvas, pillCount: pills) }

    func testTrackCentreIs95FromBottomOn1080Canvas() {
        XCTAssertEqual(layout().trackCentreY, 985)
        XCTAssertEqual(canvas.height - layout().trackCentreY, 95)
        XCTAssertEqual(layout().timesTop, 1003)
        XCTAssertEqual(layout().titleFrameBottom, 925)
    }

    func testTrackInsetsAre86() {
        XCTAssertEqual(layout().trackMinX, 86)
        XCTAssertEqual(layout().trackMaxX, 1834)
        XCTAssertEqual(layout().trackWidth, 1748)
    }

    func testFractionToXMapsAndClamps() {
        let l = layout()
        XCTAssertEqual(l.x(forSec: 0, durationSec: 100), 86)
        XCTAssertEqual(l.x(forSec: 50, durationSec: 100), 960)
        XCTAssertEqual(l.x(forSec: 100, durationSec: 100), 1834)
        XCTAssertEqual(l.x(forSec: -20, durationSec: 100), 86)
        XCTAssertEqual(l.x(forSec: 130, durationSec: 100), 1834)
        XCTAssertEqual(l.x(forSec: 50, durationSec: 0), 86)
    }

    func testPillRowWidthSixPillsIs497() {
        XCTAssertEqual(layout(6).pillRowWidth, 497)
        XCTAssertEqual(layout(6).lockupWidth, 1211)
        XCTAssertEqual(layout(6).pillRowFrame.maxX, 1834)
        XCTAssertEqual(layout(6).pillRowFrame.midY, 898.5)
    }

    func testLockupWidthShrinksWithPillCount() {
        XCTAssertGreaterThan(layout(4).lockupWidth, layout(6).lockupWidth)
        XCTAssertEqual(layout(0).lockupWidth, 1748)
    }

    func testElapsedFormat() {
        XCTAssertEqual(TransportTimeFormat.elapsed(59), "0:59")
        XCTAssertEqual(TransportTimeFormat.elapsed(3600), "1:00:00")
        XCTAssertEqual(TransportTimeFormat.elapsed(.nan), "0:00")
    }

    func testRemainingFormat() {
        XCTAssertEqual(TransportTimeFormat.remaining(position: 0, duration: 3723), "-1:02:03")
        XCTAssertEqual(TransportTimeFormat.remaining(position: 100, duration: 90), "-0:00")
    }

    func testRemainingUnknownDuration() {
        XCTAssertEqual(TransportTimeFormat.remaining(position: 10, duration: 0), "--:--")
    }

    func testEndClockDividesBySpeed() {
        let now = Date(timeIntervalSince1970: 0)
        let utc = TimeZone(identifier: "UTC")!
        let loc = Locale(identifier: "en_US_POSIX")
        // 3600 s remaining: 1 h at 1x, 30 min at 2x.
        let a = TransportTimeFormat.endClock(now: now, position: 0, duration: 3600, speed: 1, locale: loc, timeZone: utc)
        let b = TransportTimeFormat.endClock(now: now, position: 0, duration: 3600, speed: 2, locale: loc, timeZone: utc)
        XCTAssertEqual(a?.replacingOccurrences(of: "\u{202F}", with: " "), "1:00 AM")
        XCTAssertEqual(b?.replacingOccurrences(of: "\u{202F}", with: " "), "12:30 AM")
    }

    func testEndClockNilWithoutDuration() {
        XCTAssertNil(TransportTimeFormat.endClock(now: Date(), position: 0, duration: 0, speed: 1))
    }

    func testTargetLabelClampedToTrack() {
        let l = layout()
        XCTAssertEqual(l.targetLabelFrame(centreX: 0, width: 100).minX, 86)
        XCTAssertEqual(l.targetLabelFrame(centreX: 1920, width: 100).maxX, 1834)
        XCTAssertEqual(l.targetLabelFrame(centreX: 960, width: 100).midX, 960)
        XCTAssertEqual(l.targetLabelFrame(centreX: 960, width: 100).minY, l.timesTop)
    }

    func testOverlapHidesElapsed() {
        let elapsed = CGRect(x: 86, y: 0, width: 90, height: 34)
        let remaining = CGRect(x: 1700, y: 0, width: 134, height: 34)
        let near = CGRect(x: 100, y: 0, width: 90, height: 34)
        let far = CGRect(x: 600, y: 0, width: 90, height: 34)
        XCTAssertFalse(TransportBarLayout.labelVisibility(target: near, elapsed: elapsed, remaining: remaining).elapsed)
        XCTAssertTrue(TransportBarLayout.labelVisibility(target: far, elapsed: elapsed, remaining: remaining).elapsed)
    }

    func testOverlapHidesRemaining() {
        let elapsed = CGRect(x: 86, y: 0, width: 90, height: 34)
        let remaining = CGRect(x: 1700, y: 0, width: 134, height: 34)
        let near = CGRect(x: 1650, y: 0, width: 90, height: 34)
        XCTAssertFalse(TransportBarLayout.labelVisibility(target: near, elapsed: elapsed, remaining: remaining).remaining)
        XCTAssertTrue(TransportBarLayout.labelVisibility(target: CGRect(x: 900, y: 0, width: 90, height: 34),
                                                         elapsed: elapsed, remaining: remaining).remaining)
    }

    func testHideRuleDelays() {
        XCTAssertEqual(TransportHideRule.delay(isPaused: false, pauseCardEnabled: true), 4)
        XCTAssertEqual(TransportHideRule.delay(isPaused: false, pauseCardEnabled: false), 4)
        XCTAssertEqual(TransportHideRule.delay(isPaused: true, pauseCardEnabled: true), 5)
        XCTAssertNil(TransportHideRule.delay(isPaused: true, pauseCardEnabled: false))
    }

    func testHideBlockedByPillOrActiveMode() {
        XCTAssertTrue(TransportHideRule.mayHide(pillFocused: false, modeActive: false))
        XCTAssertFalse(TransportHideRule.mayHide(pillFocused: true, modeActive: false))
        XCTAssertFalse(TransportHideRule.mayHide(pillFocused: false, modeActive: true))
    }

    func testPillVisibilityAndTabs() {
        XCTAssertEqual(PillKind.visible(isSeries: false, canSwitchStreams: false, hasEpisodes: false),
                       [.subtitles, .audio, .speed, .more])
        XCTAssertEqual(PillKind.visible(isSeries: true, canSwitchStreams: true, hasEpisodes: true),
                       [.subtitles, .audio, .speed, .sources, .episodes, .more])
        XCTAssertEqual(PillKind.visible(isSeries: false, canSwitchStreams: true, hasEpisodes: false),
                       [.subtitles, .audio, .speed, .sources, .more])
        XCTAssertEqual(PillKind.visible(isSeries: true, canSwitchStreams: false, hasEpisodes: true),
                       [.subtitles, .audio, .speed, .more])
        XCTAssertEqual(PillKind.subtitles.panelTab, .subtitles)
        XCTAssertEqual(PillKind.audio.panelTab, .audio)
        XCTAssertEqual(PillKind.speed.panelTab, .playback)
        XCTAssertEqual(PillKind.sources.panelTab, .playback)
        XCTAssertEqual(PillKind.episodes.panelTab, .playback)
        XCTAssertEqual(PillKind.more.panelTab, .info)
        let all = PillKind.allCases
        XCTAssertEqual(PillKind.move(from: .subtitles, by: -1, in: all), .subtitles)
        XCTAssertEqual(PillKind.move(from: .more, by: 1, in: all), .more)
        XCTAssertEqual(PillKind.move(from: .subtitles, by: 1, in: all), .audio)
    }

    func testSkipSpanFractions() {
        let f = TransportSpanMath.fractions(TransportSpan(start: 10, end: 20, kind: "intro"), durationSec: 100)
        XCTAssertEqual(f?.start, 0.1)
        XCTAssertEqual(f?.end, 0.2)
        XCTAssertNil(TransportSpanMath.fractions(TransportSpan(start: 10, end: 20, kind: nil), durationSec: 0))
    }
}
