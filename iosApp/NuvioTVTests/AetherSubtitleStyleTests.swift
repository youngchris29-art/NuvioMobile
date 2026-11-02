import CoreGraphics
import XCTest
import SharedCore
@testable import NuvioTV

/// Aether (Phase 1), plan section 5: the subtitle style mapped onto the overlay's text style
/// (`AetherSubtitleStyle`) and the overlay geometry (`AetherSubtitleLayout`).
final class AetherSubtitleStyleTests: XCTestCase {

    private func input(text: Int64 = 0xFFFF_FFFF, bg: Int64 = 0, outline: Bool = true, bold: Bool = false,
                       sp: Int = 18, outlineARGB: Int64 = 0xFF00_0000, outlineWidth: Int = 2,
                       bottomOffset: Int = 20) -> AetherSubtitleStyle.Input {
        .init(base: .init(textARGB: text, backgroundARGB: bg, outlineEnabled: outline, bold: bold, fontSizeSp: sp),
              outlineARGB: outlineARGB, outlineWidth: outlineWidth, bottomOffset: bottomOffset)
    }

    // MARK: Mapping

    func testInputFromSharedStateCarriesEveryField() {
        let s = SubtitleStyleState(textColor: 0xFFFF_FF00, backgroundColor: 0x8000_0000, outlineColor: 0xFF11_2233,
                                   outlineEnabled: false, outlineWidth: 4, bold: true, fontSizeSp: 24,
                                   bottomOffset: 120, stripSdh: false, useForcedSubtitles: false,
                                   showOnlyPreferredLanguages: false)
        let i = AetherSubtitleStyle.input(from: s)
        XCTAssertEqual(i.base, NativeSubtitleStyle.input(from: s), "the native input is reused as is")
        XCTAssertEqual(i.outlineARGB, 0xFF11_2233)
        XCTAssertEqual(i.outlineWidth, 4)
        XCTAssertEqual(i.bottomOffset, 120)
        XCTAssertEqual(AetherSubtitleStyle.input(from: SubtitleStyleState.companion.DEFAULT), .default)
    }

    func testDefaultsAt1080() {
        let s = AetherSubtitleStyle.resolve(.default, height: 1080)
        XCTAssertEqual(s.fontPoints, 82.5, accuracy: 0.001, "55 / 720 x 1080 at 100 %")
        XCTAssertEqual(s.outlinePoints, 4.5, accuracy: 0.001, "2 x 1.5 = 3 on the 720 scale")
        XCTAssertEqual(s.bottomPadding, (0.08 * 2 / 3 + 0.02) * 1080, accuracy: 0.001)
        XCTAssertEqual(s.textARGB, 0xFFFF_FFFF)
        XCTAssertEqual(s.outlineARGB, 0xFF00_0000)
        XCTAssertFalse(s.showsBackground)
        XCTAssertFalse(s.bold)
    }

    func testSizeUsesTheNativeClamp() {
        XCTAssertEqual(AetherSubtitleStyle.fontPoints(sp: 30, height: 720), 55 * NativeSubtitleStyle.relativeSize(sp: 30) / 100,
                       accuracy: 0.001)
        XCTAssertEqual(AetherSubtitleStyle.fontPoints(sp: 1, height: 720), 55 * 0.65, accuracy: 0.001, "65 % floor")
        XCTAssertEqual(AetherSubtitleStyle.fontPoints(sp: 200, height: 720), 55 * 2.22, accuracy: 0.001, "222 % ceiling")
        XCTAssertEqual(AetherSubtitleStyle.fontPoints(sp: 18, height: 2160), 165, accuracy: 0.001, "scales with height")
    }

    func testOutlineColourAndWidthApply() {
        let wide = AetherSubtitleStyle.resolve(input(outlineARGB: 0x8033_6699, outlineWidth: 5), height: 720)
        XCTAssertEqual(wide.outlinePoints, 7, accuracy: 0.001, "Int(5 x 1.5) = 7, truncated as mpv")
        XCTAssertEqual(AetherSubtitleStyle.resolve(input(outlineWidth: 3), height: 720).outlinePoints, 4,
                       accuracy: 0.001)
        XCTAssertEqual(wide.outlineOpacity, 128.0 / 255, accuracy: 0.0001, "alpha applied once to the ring")
        XCTAssertEqual(wide.outlineARGB, 0x8033_6699)
        XCTAssertEqual(AetherSubtitleStyle.resolve(input(outlineWidth: 0), height: 720).outlinePoints, 1,
                       accuracy: 0.001, "mpv's minimum of 1 while the outline is on")
        XCTAssertEqual(AetherSubtitleStyle.resolve(input(outline: false, outlineWidth: 5), height: 720).outlinePoints, 0,
                       "off draws no outline")
    }

    func testOutlineOffsetsRingAtTheWidth() {
        XCTAssertTrue(AetherSubtitleStyle.outlineOffsets(width: 0).isEmpty)
        XCTAssertTrue(AetherSubtitleStyle.outlineOffsets(width: .nan).isEmpty)
        let thin = AetherSubtitleStyle.outlineOffsets(width: 1)
        XCTAssertEqual(thin.count, 8, "at least eight copies")
        let wide = AetherSubtitleStyle.outlineOffsets(width: 20)
        XCTAssertEqual(wide.count, 24, "at most twenty-four")
        for o in AetherSubtitleStyle.outlineOffsets(width: 4.5) {
            XCTAssertEqual(hypot(o.width, o.height), 4.5, accuracy: 0.0001)
        }
    }

    func testBottomOffsetFollowsTheAndroidOverlayRuleAndTheSafeArea() {
        let base = 0.08 * 2.0 / 3.0
        XCTAssertEqual(AetherSubtitleStyle.bottomPaddingFraction(bottomOffset: 0), base, accuracy: 1e-9)
        XCTAssertEqual(AetherSubtitleStyle.bottomPaddingFraction(bottomOffset: 100), base + 0.1, accuracy: 1e-9)
        XCTAssertEqual(AetherSubtitleStyle.bottomPaddingFraction(bottomOffset: 500), base + 0.2, accuracy: 1e-9,
                       "offset clamped to 0.2")
        XCTAssertEqual(AetherSubtitleStyle.bottomPaddingFraction(bottomOffset: -50), base, accuracy: 1e-9)
        let s = AetherSubtitleStyle.resolve(input(bottomOffset: 0), height: 1080, safeAreaBottom: 90)
        XCTAssertEqual(s.bottomPadding, 90, "never inside the safe area")
        let raised = AetherSubtitleStyle.resolve(input(bottomOffset: 200), height: 1080, safeAreaBottom: 60)
        XCTAssertEqual(raised.bottomPadding, (base + 0.2) * 1080, accuracy: 0.001)
    }

    func testBackgroundBoxAndColours() {
        let semi = AetherSubtitleStyle.resolve(input(bg: 0x8000_0000), height: 1080)
        XCTAssertTrue(semi.showsBackground)
        XCTAssertTrue(AetherSubtitleStyle.resolve(input(bg: 0xFF00_0000, outline: false), height: 1080).showsBackground)
        XCTAssertFalse(AetherSubtitleStyle.resolve(input(bg: 0x00FF_FFFF), height: 1080).showsBackground,
                       "alpha 0 is no box whatever the colour")
        XCTAssertEqual(AetherSubtitleStyle.alpha(0x80FF_FFFF), 0x80)
        XCTAssertTrue(AetherSubtitleStyle.resolve(input(bold: true), height: 1080).bold)
    }

    // MARK: Geometry

    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testVideoRectPerAspectMode() {
        let scope = CGSize(width: 1920, height: 800)
        let fit = AetherSubtitleLayout.videoRect(container: screen, presentationSize: scope, mode: .fit)
        XCTAssertEqual(fit, CGRect(x: 0, y: 140, width: 1920, height: 800))
        let fill = AetherSubtitleLayout.videoRect(container: screen, presentationSize: scope, mode: .fill)
        XCTAssertEqual(fill.height, 1080, accuracy: 0.001)
        XCTAssertEqual(fill.width, 2592, accuracy: 0.001)
        XCTAssertEqual(fill.midX, 960, accuracy: 0.001)
        let zoom = AetherSubtitleLayout.videoRect(container: screen, presentationSize: scope, mode: .zoom)
        XCTAssertEqual(zoom.height, 940, accuracy: 0.001, "halfway between 800 and 1080")
        XCTAssertEqual(AetherSubtitleLayout.videoRect(container: screen, presentationSize: scope, mode: .stretch), screen)
        XCTAssertEqual(AetherSubtitleLayout.videoRect(container: screen, presentationSize: nil, mode: .fit), screen)
        XCTAssertEqual(AetherSubtitleLayout.videoRect(container: screen, presentationSize: .zero, mode: .fill), screen)
        let fourByThree = AetherSubtitleLayout.videoRect(container: screen, presentationSize: CGSize(width: 4, height: 3),
                                                         mode: .fit)
        XCTAssertEqual(fourByThree, CGRect(x: 240, y: 0, width: 1440, height: 1080), "pillarboxed")
    }

    func testBitmapRectIsWidthAlignedAndCentredOnTheVideo() {
        let video = CGRect(x: 0, y: 140, width: 1920, height: 800)
        // A 1920x1080 PGS canvas on a 1920x800 picture: the canvas overhangs it by 140 each side.
        let n = CGRect(x: 0.25, y: 0.9, width: 0.5, height: 0.05)
        let r = AetherSubtitleLayout.bitmapRect(normalizedRect: n, canvasSize: CGSize(width: 1920, height: 1080),
                                                videoRect: video, container: screen)
        XCTAssertEqual(r.minX, 480, accuracy: 0.001)
        XCTAssertEqual(r.width, 960, accuracy: 0.001)
        XCTAssertEqual(r.minY, 0 + 0.9 * 1080, accuracy: 0.001, "canvas top = 540 - 540")
        XCTAssertEqual(r.height, 54, accuracy: 0.001)
        // Unknown canvas: canvas == video.
        let u = AetherSubtitleLayout.bitmapRect(normalizedRect: n, canvasSize: .zero, videoRect: video, container: screen)
        XCTAssertEqual(u, CGRect(x: 480, y: 140 + 720, width: 960, height: 40))
        // Half-width canvas (720 wide) scales by the video width.
        let small = AetherSubtitleLayout.bitmapRect(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                    canvasSize: CGSize(width: 960, height: 400),
                                                    videoRect: video, container: screen)
        XCTAssertEqual(small, video)
    }

    func testBitmapRectStaysOnScreenWhenThePictureOverflows() {
        let fill = CGRect(x: -336, y: 0, width: 2592, height: 1080)
        let r = AetherSubtitleLayout.bitmapRect(normalizedRect: CGRect(x: 0.0, y: 0.9, width: 0.3, height: 0.05),
                                                canvasSize: .zero, videoRect: fill, container: screen)
        XCTAssertEqual(r.minX, 0, accuracy: 0.001, "shifted back inside the screen")
        XCTAssertEqual(r.width, 0.3 * 2592, accuracy: 0.001, "never scaled")
        let below = AetherSubtitleLayout.bitmapRect(normalizedRect: CGRect(x: 0.4, y: 0.98, width: 0.2, height: 0.1),
                                                    canvasSize: .zero, videoRect: fill, container: screen)
        XCTAssertEqual(below.maxY, 1080, accuracy: 0.001)
    }
}
