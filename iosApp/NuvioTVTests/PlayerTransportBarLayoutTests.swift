import XCTest
@testable import NuvioTV

final class PlayerTransportBarLayoutTests: XCTestCase {
    private let canvas = CGSize(width: 1920, height: 1080)
    private func layout(_ pills: Int = 6) -> TransportBarLayout { TransportBarLayout(canvas: canvas, pillCount: pills) }

    /// Insights (2026-11-01): 95 + the info pill row (46) and its gap (14).
    func testTrackCentreIs155FromBottomOn1080Canvas() {
        XCTAssertEqual(layout().trackCentreY, 925)
        XCTAssertEqual(canvas.height - layout().trackCentreY, 155)
        XCTAssertEqual(layout().timesTop, 943)
        XCTAssertEqual(layout().titleFrameBottom, 865)
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
        XCTAssertEqual(layout(6).pillRowFrame.midY, 838.5)
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
        XCTAssertTrue(TransportHideRule.mayHide(pillFocused: false, chromeCompact: false))
        XCTAssertFalse(TransportHideRule.mayHide(pillFocused: true, chromeCompact: false))
        XCTAssertFalse(TransportHideRule.mayHide(pillFocused: false, chromeCompact: true))
    }

    func testPillVisibilityAndTabs() {
        XCTAssertEqual(PillKind.visible(isSeries: false, canSwitchStreams: false, hasEpisodes: false),
                       [.subtitles, .audio, .speed, .aspect, .more])
        XCTAssertEqual(PillKind.visible(isSeries: true, canSwitchStreams: true, hasEpisodes: true),
                       [.subtitles, .audio, .speed, .aspect, .sources, .episodes, .more])
        XCTAssertEqual(PillKind.visible(isSeries: false, canSwitchStreams: true, hasEpisodes: false),
                       [.subtitles, .audio, .speed, .aspect, .sources, .more])
        XCTAssertEqual(PillKind.visible(isSeries: true, canSwitchStreams: false, hasEpisodes: true),
                       [.subtitles, .audio, .speed, .aspect, .more])
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

    func testPreviewCardSitsAboveTheTrackAndClamps() {
        let l = layout()
        let mid = l.previewCardFrame(centreX: 960)
        XCTAssertEqual(mid, CGRect(x: 760, y: 663, width: 400, height: 225))
        XCTAssertEqual(mid.maxY, 888)
        XCTAssertEqual(l.previewCardFrame(centreX: 100).minX, 86)
        XCTAssertEqual(l.previewCardFrame(centreX: 1900).maxX, 1834)
    }

    func testChapterLabelAboveTheCardInOnePosition() {
        let l = layout()
        let withCard = l.chapterLabelFrame(centreX: 960, width: 200, cardShown: true)
        let noCard = l.chapterLabelFrame(centreX: 960, width: 200, cardShown: false)
        XCTAssertEqual(withCard, noCard)
        XCTAssertEqual(withCard, CGRect(x: 860, y: 621, width: 200, height: 34))
        XCTAssertEqual(l.chapterLabelFrame(centreX: 90, width: 300, cardShown: true).minX, 86)
        XCTAssertEqual(l.chapterLabelFrame(centreX: 1830, width: 300, cardShown: true).maxX, 1834)
    }

    // MARK: Compact chrome (GitHub #33 review r6)

    private static let image: CGImage = {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()

    private static let modes: [TransportPreview.Mode] = [
        .idle, .stepping(direction: 1, accumulatedSec: 0, ticks: 0),
        .stepping(direction: -1, accumulatedSec: 20, ticks: 3), .scanning(rate: 2), .scrubbing(targetSec: 300),
    ]
    private enum Body: CaseIterable { case frame, frameNoImage, placeholder, timeOnly, none }
    private static let kinds: [SeekPreviewRender.Kind] = [.none, .hold, .scrub, .landing]

    private func render(_ kind: SeekPreviewRender.Kind, _ body: Body, target: Double? = 300) -> SeekPreviewRender {
        let content: SeekPreviewPlan.Content
        switch body {
        case .frame, .frameNoImage: content = .frame
        case .placeholder: content = .placeholder
        case .timeOnly: content = .timeOnly
        case .none: content = .none
        }
        return SeekPreviewRender(cardTargetSec: target, content: content, image: body == .frame ? Self.image : nil,
                                 frameSec: body == .frame ? target : nil, capabilityAny: true, kind: kind, episode: 1)
    }

    /// The card slot holds a body only for a drawn picture or the placeholder, at a target.
    func testCardOccupiesSlotOnlyForAPictureOrPlaceholder() {
        for kind in Self.kinds {
            XCTAssertTrue(TransportChromeRule.cardOccupiesSlot(render(kind, .frame)), "\(kind)")
            XCTAssertTrue(TransportChromeRule.cardOccupiesSlot(render(kind, .placeholder)), "\(kind)")
            XCTAssertFalse(TransportChromeRule.cardOccupiesSlot(render(kind, .frameNoImage)), "\(kind): nothing drawn")
            XCTAssertFalse(TransportChromeRule.cardOccupiesSlot(render(kind, .timeOnly)), "\(kind): label only")
            XCTAssertFalse(TransportChromeRule.cardOccupiesSlot(render(kind, .none)), "\(kind)")
            for body in Body.allCases {
                XCTAssertFalse(TransportChromeRule.cardOccupiesSlot(render(kind, body, target: nil)), "\(kind) \(body): no target")
            }
        }
        XCTAssertFalse(TransportChromeRule.cardOccupiesSlot(.none))
    }

    /// Mode × render kind × card content: any active mode is compact (today's hold / scan / scrub
    /// rule); idle is compact exactly while a card body is in the slot, so a click's picture or
    /// placeholder card after the release hides the lockup and pills, and a time-only click card
    /// (previews Off, no capability) leaves the chrome as it is.
    func testCompactChromeOverModeKindAndContent() {
        for mode in Self.modes {
            for kind in Self.kinds {
                for body in Body.allCases {
                    for target: Double? in [300, nil] {
                        let r = render(kind, body, target: target)
                        let expected = mode != .idle || (target != nil && (body == .frame || body == .placeholder))
                        XCTAssertEqual(TransportChromeRule.compact(mode: mode, render: r), expected,
                                       "mode=\(mode) kind=\(kind) body=\(body) target=\(String(describing: target))")
                    }
                }
            }
            XCTAssertEqual(TransportChromeRule.compact(mode: mode, render: .none), mode != .idle, "\(mode)")
        }
        // The click dwell itself: idle with the landing card up.
        XCTAssertTrue(TransportChromeRule.compact(mode: .idle, render: render(.landing, .placeholder)))
        XCTAssertTrue(TransportChromeRule.compact(mode: .idle, render: render(.landing, .frame)))
        XCTAssertFalse(TransportChromeRule.compact(mode: .idle, render: render(.landing, .timeOnly)))
    }

    /// The model's value is the rule over its own `mode` and `previewRender`.
    @MainActor
    func testModelChromeCompactDerivesFromModeAndRender() {
        let m = TransportBarModel()
        XCTAssertFalse(m.chromeCompact)
        m.previewRender = render(.landing, .placeholder)
        XCTAssertTrue(m.chromeCompact, "a click's placeholder card after the release")
        m.previewRender = render(.landing, .timeOnly)
        XCTAssertFalse(m.chromeCompact, "a time-only click card keeps the chrome")
        m.mode = .stepping(direction: 1, accumulatedSec: 0, ticks: 0)
        XCTAssertTrue(m.chromeCompact, "the press itself")
        m.mode = .idle
        m.previewRender = .none
        XCTAssertFalse(m.chromeCompact)
    }

    /// The hide timer is held for the whole dwell and free again once the card goes.
    func testHideHeldWhileTheClickCardIsUp() {
        let up = TransportChromeRule.compact(mode: .idle, render: render(.landing, .frame))
        XCTAssertFalse(TransportHideRule.mayHide(pillFocused: false, chromeCompact: up))
        let gone = TransportChromeRule.compact(mode: .idle, render: .none)
        XCTAssertTrue(TransportHideRule.mayHide(pillFocused: false, chromeCompact: gone))
    }

    /// Geometry (1080p canvas): in every state where the card body and the lockup or disc row are
    /// both laid out visibly, their rects never meet. The card does cover them when they show (the
    /// rule is load-bearing), and a time-only card's chapter title above the slot clears them.
    func testCardNeverOverlapsTheLockupOrPillsWhileTheyShow() {
        var coveredSomewhere = false
        for pills in [0, 4, 6, 7] {
            let l = layout(pills)
            let duration = 1380.0
            for mode in Self.modes {
                for kind in Self.kinds {
                    for body in Body.allCases {
                        for target in stride(from: 0.0, through: duration, by: 23) {
                            let r = render(kind, body, target: target)
                            let compact = TransportChromeRule.compact(mode: mode, render: r)
                            let card = l.previewCardFrame(centreX: l.x(forSec: target, durationSec: duration))
                            let hitsChrome = card.intersects(l.lockupFrame) || (pills > 0 && card.intersects(l.pillRowFrame))
                            if hitsChrome { coveredSomewhere = true }
                            if TransportChromeRule.cardOccupiesSlot(r) {
                                XCTAssertFalse(!compact && hitsChrome,
                                               "card \(card) over the chrome: pills=\(pills) mode=\(mode) kind=\(kind) body=\(body)")
                            } else if !compact {
                                // No body: only the chapter title sits above the slot.
                                let title = l.chapterLabelFrame(centreX: l.x(forSec: target, durationSec: duration),
                                                                width: TransportBarLayout.cardSize.width, cardShown: false)
                                XCTAssertFalse(title.intersects(l.lockupFrame), "pills=\(pills) t=\(target)")
                                XCTAssertFalse(pills > 0 && title.intersects(l.pillRowFrame), "pills=\(pills) t=\(target)")
                            }
                        }
                    }
                }
            }
        }
        XCTAssertTrue(coveredSomewhere, "the card slot overlaps the lockup or pills at some target")
        // Near the start of a file the click card sits over the title; near the end over the pills.
        let l = layout(6)
        XCTAssertTrue(l.previewCardFrame(centreX: l.x(forSec: 12, durationSec: 1380)).intersects(l.lockupFrame))
        XCTAssertTrue(l.previewCardFrame(centreX: l.x(forSec: 1370, durationSec: 1380)).intersects(l.pillRowFrame))
    }
}
