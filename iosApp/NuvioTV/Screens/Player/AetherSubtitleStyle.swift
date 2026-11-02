import CoreGraphics
import SharedCore
import SwiftUI

/// Aether (Phase 1), plan section 5: the app's subtitle style (Settings › Subtitles, the shared
/// `SubtitleStyleState`) mapped onto the text style `AetherSubtitleOverlay` draws. Pure, so it unit-tests
/// without a player (`AetherSubtitleStyleTests`).
///
/// It builds on `NativeSubtitleStyle` rather than copying it: the text colour, background, outline switch,
/// bold and size come through `NativeSubtitleStyle.Input`, and the size goes through the same
/// `NativeSubtitleStyle.relativeSize(sp:)` clamp (65…222 %). Because this overlay draws the text itself,
/// the three values CMTextMarkup has no key for apply here too: the outline colour, the outline width and
/// the bottom offset.
///
/// Mapping, for a drawing area `height` points tall (the full player view, 1080 on Apple TV):
/// - font: mpv's base `sub-font-size` 55 on its 720-line scale, times the relative size, so 18 sp at
///   1080 is 82.5 pt, the size the mpv route draws (mpv clamps 36…122 on that scale, which is the same
///   65…222 % band);
/// - outline: mpv's `sub-outline-size` (`max(1, Int(width × 1.5))` on the 720 scale, truncated as the
///   Android and tvOS mpv routes do), 0 when the outline is off, in `outlineARGB`;
/// - background: a box behind each cue whenever its alpha is not 0, outline on or off (the native
///   route's per-glyph box and the Android overlay's caption background; mpv's libass only boxes with the
///   outline off);
/// - bottom offset: the Android overlay rule (`PlayerEngine.android` `applySubtitleStyle`): a base
///   padding of 8 % × 2/3 of the height plus `bottomOffset / 1000` clamped to 0…0.2, the sum clamped to
///   0…0.4, and never less than the safe-area bottom inset. (The tvOS mpv route places the line with
///   `sub-pos` instead, about 20 pt lower at the default offset; the overlay follows the phone's own
///   overlay rule on purpose, and the safe-area floor dominates at small offsets on both.)
nonisolated struct AetherSubtitleStyle: Equatable, Sendable {
    /// The settings the overlay needs: the native input plus what only a self-drawn overlay can apply.
    struct Input: Equatable, Sendable {
        var base: NativeSubtitleStyle.Input
        var outlineARGB: Int64
        var outlineWidth: Int
        var bottomOffset: Int

        static let `default` = Input(base: .default, outlineARGB: 0xFF00_0000, outlineWidth: 2, bottomOffset: 20)
    }

    /// mpv's `sub-font-size` default on its 720-line scale.
    static let mpvBaseFontSize: Double = 55
    /// mpv's scale: subtitle sizes are given for a 720-line window.
    static let mpvScaleHeight: Double = 720
    /// `MPV_SUBTITLE_OUTLINE_SIZE_SCALE` (Android) and `MPVPlayerView.subtitleOutlineSize`.
    static let outlineWidthScale: Double = 1.5
    /// ExoPlayer's `SubtitleView.DEFAULT_BOTTOM_PADDING_FRACTION` (0.08) × 2/3, as the Android overlay.
    static let baseBottomPaddingFraction: Double = 0.08 * 2.0 / 3.0
    static let maxOffsetFraction: Double = 0.2
    static let maxBottomPaddingFraction: Double = 0.4

    var textARGB: Int64
    var backgroundARGB: Int64
    var outlineARGB: Int64
    var bold: Bool
    var fontPoints: CGFloat
    /// 0 = no outline.
    var outlinePoints: CGFloat
    /// From the bottom of the drawing area to the bottom of the lowest text cue.
    var bottomPadding: CGFloat

    var showsBackground: Bool { Self.alpha(backgroundARGB) != 0 }

    static func input(from s: SubtitleStyleState) -> Input {
        Input(base: NativeSubtitleStyle.input(from: s), outlineARGB: s.outlineColor,
              outlineWidth: Int(s.outlineWidth), bottomOffset: Int(s.bottomOffset))
    }

    static func resolve(_ i: Input, height: CGFloat, safeAreaBottom: CGFloat = 0) -> AetherSubtitleStyle {
        let h = max(0, Double(height))
        return AetherSubtitleStyle(
            textARGB: i.base.textARGB,
            backgroundARGB: i.base.backgroundARGB,
            outlineARGB: i.outlineARGB,
            bold: i.base.bold,
            fontPoints: CGFloat(fontPoints(sp: i.base.fontSizeSp, height: h)),
            outlinePoints: CGFloat(outlinePoints(enabled: i.base.outlineEnabled, width: i.outlineWidth, height: h)),
            bottomPadding: max(max(0, safeAreaBottom), CGFloat(bottomPaddingFraction(bottomOffset: i.bottomOffset) * h))
        )
    }

    /// Font size in points: 55 / 720 × height × the native relative size (65…222 %).
    static func fontPoints(sp: Int, height: Double) -> Double {
        mpvBaseFontSize / mpvScaleHeight * height * NativeSubtitleStyle.relativeSize(sp: sp) / 100
    }

    /// Outline width in points, 0 when off: mpv's truncated `max(1, Int(width × 1.5))` on the 720 scale.
    static func outlinePoints(enabled: Bool, width: Int, height: Double) -> Double {
        guard enabled else { return 0 }
        let mpvSize = Double(max(1, Int(Double(max(0, width)) * outlineWidthScale)))
        return mpvSize / mpvScaleHeight * height
    }

    /// The Android overlay's bottom padding fraction for a `bottomOffset` (0…200 on the phone).
    static func bottomPaddingFraction(bottomOffset: Int) -> Double {
        let offset = min(maxOffsetFraction, max(0, Double(bottomOffset) / 1000))
        return min(maxBottomPaddingFraction, max(0, baseBottomPaddingFraction + offset))
    }

    /// The offsets at which the outline copies of a glyph run are drawn: a ring at `width` points, dense
    /// enough that neighbouring copies sit at most about 1.5 pt apart (8 to 24 copies). Empty at width 0.
    static func outlineOffsets(width: CGFloat) -> [CGSize] {
        guard width > 0, width.isFinite else { return [] }
        let count = min(24, max(8, Int((2 * Double.pi * Double(width) / 1.5).rounded(.up))))
        return (0..<count).map { k in
            let angle = 2 * Double.pi * Double(k) / Double(count)
            return CGSize(width: Double(width) * cos(angle), height: Double(width) * sin(angle))
        }
    }

    static func alpha(_ argb: Int64) -> Int64 { (argb >> 24) & 0xFF }

    /// A SwiftUI colour from a `SubtitleColor` ARGB long, in sRGB.
    static func color(_ argb: Int64) -> Color {
        let c = NativeSubtitleStyle.argbComponents(argb)
        return Color(.sRGB, red: c[1], green: c[2], blue: c[3], opacity: c[0])
    }

    var textColor: Color { Self.color(textARGB) }
    var backgroundColor: Color { Self.color(backgroundARGB) }
    var outlineColor: Color { Self.color(outlineARGB) }
    /// The outline colour at full opacity; the ring's copies overlap, so the alpha is applied once to the
    /// composited ring (`outlineOpacity`), not to each copy.
    var opaqueOutlineColor: Color { Self.color(outlineARGB | 0xFF00_0000) }
    var outlineOpacity: Double { Double(Self.alpha(outlineARGB)) / 255 }
}

/// Where the overlay draws, in the overlay's own coordinates. Pure geometry, unit-tested with the style.
nonisolated enum AetherSubtitleLayout {
    /// The rect the picture occupies in a `container` for the picture shape `presentationSize`
    /// (`AetherDiagnostics.presentationSize`, already pixel-aspect corrected) under the Aspect mode:
    /// fit letterboxes, fill crops (the rect overflows the container), zoom sits halfway between (mpv's
    /// `panscan` 0.5), stretch fills the container. An unknown or degenerate shape is the container.
    static func videoRect(container: CGRect, presentationSize: CGSize?, mode: PlayerAspectMode) -> CGRect {
        guard let p = presentationSize, p.width > 0, p.height > 0, p.width.isFinite, p.height.isFinite,
              container.width > 0, container.height > 0 else { return container }
        let fit = min(container.width / p.width, container.height / p.height)
        let fill = max(container.width / p.width, container.height / p.height)
        let scale: CGFloat
        switch mode {
        case .stretch: return container
        case .fit: scale = fit
        case .fill: scale = fill
        case .zoom: scale = fit + (fill - fit) * 0.5
        }
        let w = p.width * scale, h = p.height * scale
        return CGRect(x: container.midX - w / 2, y: container.midY - h / 2, width: w, height: h)
    }

    /// The on-screen rect of a bitmap cue. The cue's `normalizedRect` is [0, 1] against `canvasSize`, the
    /// PGS/DVB composition canvas, mapped width-aligned and centre-anchored onto `videoRect` (W2-A
    /// hand-over); a zero or degenerate canvas means canvas == video. When the picture overflows the
    /// container (fill, zoom), the cue is shifted back inside `container` if it fits, never scaled.
    static func bitmapRect(normalizedRect n: CGRect, canvasSize: CGSize, videoRect v: CGRect,
                           container: CGRect) -> CGRect {
        let canvasRect: CGRect
        if canvasSize.width > 0, canvasSize.height > 0, canvasSize.width.isFinite, canvasSize.height.isFinite {
            let scale = v.width / canvasSize.width
            let h = canvasSize.height * scale
            canvasRect = CGRect(x: v.minX, y: v.midY - h / 2, width: v.width, height: h)
        } else {
            canvasRect = v
        }
        var r = CGRect(x: canvasRect.minX + n.minX * canvasRect.width,
                       y: canvasRect.minY + n.minY * canvasRect.height,
                       width: n.width * canvasRect.width,
                       height: n.height * canvasRect.height)
        if r.width <= container.width {
            if r.minX < container.minX { r.origin.x = container.minX }
            if r.maxX > container.maxX { r.origin.x = container.maxX - r.width }
        }
        if r.height <= container.height {
            if r.minY < container.minY { r.origin.y = container.minY }
            if r.maxY > container.maxY { r.origin.y = container.maxY - r.height }
        }
        return r
    }
}
