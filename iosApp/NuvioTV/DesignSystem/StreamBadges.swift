import SwiftUI
import SharedCore
import ImageIO

/// 10-ft renditions of the shared `StreamBadge` model, mirroring mobile's `StreamBadgeChip.kt`:
///
/// - Badges carrying an `imageURL` (the community "badge pack" visuals for quality / HDR /
///   audio channels etc.) render as image chips. `tagStyle == "filled"` paints `tagColor`
///   behind the image; a non-empty `borderColor` draws a thin outline. Mobile's 20pt chip is
///   scaled ~2x for the living-room viewing distance.
/// - Badges without an image fall back to a text chip in the badge's own colors (today's
///   behavior, kept so text-only packs still render).
/// - `StreamFileSizeChip` is the "2.3 GB" companion chip (mobile `StreamFileSizeBadge`); polish
///   D1 moved the size to the row's headline line, so the view has no call site now (its
///   `label(for:)` formatter is what the row uses).
enum StreamBadgeMetrics {
    // Polish D2: 34 / 26 / 150 (were 40 / 30 / 180) so a badge row sits under the fact lines
    // instead of out-shouting them.
    static let containerHeight: CGFloat = 34
    static let imageHeight: CGFloat = 26
    static let minImageWidth: CGFloat = 60
    static let maxImageWidth: CGFloat = 150
    static let cornerRadius: CGFloat = 8
    /// D2 outline chip: letter-spacing in points (not a font size; the token is untouched).
    static let outlineTracking: CGFloat = 0.4
    /// D2 outline chip: stroke opacity (white) at rest.
    static let outlineStrokeOpacity: Double = 0.18
}

/// W3-16 (F1): a plain-Swift copy of the shared `StreamBadge` (a Kotlin data class), so a stream
/// row's value model compares with synthesized `==` — no Kotlin `isEqual` crossing per chip — and
/// the model stays free of Kotlin objects. Same six fields, same names.
nonisolated struct StreamBadgeInfo: Equatable {
    let name: String
    let imageURL: String
    let tagColor: String
    let tagStyle: String
    let textColor: String
    let borderColor: String

    init(name: String, imageURL: String = "", tagColor: String = "", tagStyle: String = "",
         textColor: String = "", borderColor: String = "") {
        self.name = name
        self.imageURL = imageURL
        self.tagColor = tagColor
        self.tagStyle = tagStyle
        self.textColor = textColor
        self.borderColor = borderColor
    }

    init(_ badge: StreamBadge) {
        self.init(name: badge.name, imageURL: badge.imageURL, tagColor: badge.tagColor,
                  tagStyle: badge.tagStyle, textColor: badge.textColor, borderColor: badge.borderColor)
    }
}

struct StreamBadgeChipView: View {
    let badge: StreamBadgeInfo

    // BUG-28: `.settingsRow`-styled rows force `.environment(\.colorScheme, .light)` while
    // focused (see FlatControlStyles.swift), which flips SEMANTIC colors (`Theme.Palette
    // .textPrimary`/`.textSecondary`) but leaves FIXED pack-supplied hex colors untouched.
    // This environment value propagates into button labels (proven by `RowAccentTint` in
    // FlatControlStyles.swift), so reading it here tells the chip it sits on the near-white
    // focus platter (GitHub #25: it then recreates the dark surface under itself and stops
    // using semantic colours; it no longer drops the pack's own colours).
    @Environment(\.isFocused) private var isFocused
    /// BUG-65: like `RowTextColor`, the chip also reads the row style's focus key.
    @Environment(\.settingsRowIsFocused) private var rowFocused
    /// The row's platter is showing. Either source counts (BUG-65: `\.isFocused` is the read that
    /// can fail on hardware, and the row style paints its platter from both). Both are false in
    /// the player's info views, which hold nothing focusable.
    private var onPlatter: Bool { isFocused || rowFocused }

    /// How a text chip is drawn (polish D2).
    enum TextChipStyle: Equatable {
        /// No fill, a hairline capsule stroke, the row's own text colour.
        case outline
        /// The pack's own colours (BUG-28 / BUG-43 logic in `effectiveTextChipColors`).
        case packColors
    }

    /// D2: a pack that sets a parseable `tagColor` keeps its colours; with none, the monochrome
    /// outline chip. The pack's `textColor` / `borderColor` are ignored on the outline chip: a
    /// `textColor` with no `tagColor` was authored for a fill this chip does not draw.
    static func textChipStyle(tagColorHex: String) -> TextChipStyle {
        Theme.Palette.luminance(fromHexString: tagColorHex) == nil ? .outline : .packColors
    }

    var body: some View {
        if badge.imageURL.isEmpty {
            textChip
        } else {
            imageChip
        }
    }

    private var imageChip: some View {
        let shape = RoundedRectangle(cornerRadius: StreamBadgeMetrics.cornerRadius)
        let filled = Self.isFilled(tagStyle: badge.tagStyle)
        // Badge art is authored to sit on a dark surface: transparent PNGs, and since the tinted
        // packs (GitHub #25) translucent fills too. On the white focus platter both wash out, so
        // the chip recreates that dark surface while focused (`imageChipSurface`).
        let surface = Self.imageChipSurface(filled: filled, tagColorHex: badge.tagColor, isFocused: onPlatter)
        let fill: Color = surface.drawsPackFill ? (Color(hexString: badge.tagColor) ?? .clear) : .clear
        let textHex = Self.packHex(badge.textColor)
        let border = Color(hexString: Self.packHex(badge.borderColor))
            ?? (Self.needsPlatterEdge(drawsPackFill: surface.drawsPackFill, darkBase: surface.darkBase,
                                      tagColorHex: badge.tagColor, isFocused: onPlatter)
                    ? Theme.Palette.onFocusPlatter.opacity(Self.platterEdgeOpacity) : nil)
        // BUG-43 (beta.12): the fallback text sits on the background THIS chip actually draws —
        // the pack fill only when `filled`; otherwise the clear/dark row (empty hex routes the
        // decision through its dark semantic default). Computing against `tagColor` regardless
        // gave a non-filled badge with a light `tagColor` near-black fallback text on a dark
        // row — invisible in the opposite direction from the reported defect.
        let effectiveBgHex = surface.drawsPackFill ? badge.tagColor : ""
        let fallbackDecision = Self.effectiveTextChipColors(
            textColorHex: textHex,
            tagColorHex: effectiveBgHex,
            isFocused: onPlatter
        )
        let fallbackForeground = Self.resolvedForeground(
            fallbackDecision,
            textColorHex: textHex,
            tagColorHex: effectiveBgHex
        )

        return BadgeImageView(url: badge.imageURL) {
            // Broken/unreachable image → readable text stand-in.
            Text(badge.name)
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(fallbackForeground)
                .lineLimit(1)
        }
        .frame(height: StreamBadgeMetrics.imageHeight)
        .frame(minWidth: StreamBadgeMetrics.minImageWidth, maxWidth: StreamBadgeMetrics.maxImageWidth)
        .padding(.horizontal, 6)
        .frame(height: StreamBadgeMetrics.containerHeight)
        .background(fill, in: shape)
        .background(surface.darkBase ? Self.chipBase : .clear, in: shape)
        .overlay(shape.stroke(border ?? .clear, lineWidth: border == nil ? 0 : 1))
        .clipShape(shape)
    }

    // MARK: - GitHub #25: the chip's surface on the focus platter

    /// What an image chip paints behind its artwork.
    struct ImageChipSurface: Equatable {
        /// The opaque base (`chipBase`, the row's resting card colour) under everything else.
        var darkBase: Bool
        /// The pack's `tagColor` fill, over the dark base when both are set.
        var drawsPackFill: Bool
    }

    /// At rest the chip draws only what the pack asked for: its fill when `filled` and the colour
    /// parses, nothing otherwise (the dark row shows through). On the focus platter a chip with no
    /// fill, or with a translucent one, also gets the dark base, so the artwork and a tint sit on
    /// the surface they were authored for instead of on white. An opaque fill needs no base.
    static func imageChipSurface(filled: Bool, tagColorHex: String, isFocused: Bool) -> ImageChipSurface {
        let alpha = filled ? Theme.Palette.alpha(fromHexString: tagColorHex) : nil
        guard let alpha else { return ImageChipSurface(darkBase: isFocused, drawsPackFill: false) }
        return ImageChipSurface(darkBase: isFocused && alpha < 1, drawsPackFill: true)
    }

    /// Stroke opacity of the hairline `needsPlatterEdge` asks for.
    static let platterEdgeOpacity: Double = 0.18

    /// A near-white opaque fill (the "mono white" packs) has no edge on the near-white platter.
    /// When the pack sets no border of its own, the chip gets a hairline so it still reads as a
    /// chip. Only on the platter, only for a light fill the chip actually draws without a base.
    static func needsPlatterEdge(drawsPackFill: Bool, darkBase: Bool, tagColorHex: String, isFocused: Bool) -> Bool {
        guard isFocused, drawsPackFill, !darkBase,
              let luminance = Theme.Palette.luminance(fromHexString: tagColorHex) else { return false }
        return luminance > 0.8
    }

    @ViewBuilder
    private var textChip: some View {
        switch Self.textChipStyle(tagColorHex: badge.tagColor) {
        case .outline: outlineChip
        case .packColors: packTextChip
        }
    }

    /// D2 outline chip. Reads BOTH focus sources (BUG-65): the stroke flips on the white platter,
    /// where a white 0.18 stroke would vanish; the text follows `rowTextColor`.
    private var outlineChip: some View {
        let focused = onPlatter
        return Text(badge.name)
            .font(Theme.Font.caption.weight(.semibold))
            .tracking(StreamBadgeMetrics.outlineTracking)
            .rowTextColor()
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: StreamBadgeMetrics.containerHeight)
            .overlay(
                Capsule().strokeBorder(
                    focused ? Theme.Palette.onFocusPlatter.opacity(0.3)
                            : Color.white.opacity(StreamBadgeMetrics.outlineStrokeOpacity),
                    lineWidth: 1)
            )
    }

    /// The pre-D2 text chip, kept intact for packs with a `tagColor` (BUG-28 / BUG-43).
    private var packTextChip: some View {
        let textHex = Self.packHex(badge.textColor)
        let decision = Self.effectiveTextChipColors(
            textColorHex: textHex,
            tagColorHex: badge.tagColor,
            isFocused: onPlatter
        )
        let foreground = Self.resolvedForeground(decision, textColorHex: textHex, tagColorHex: badge.tagColor)
        let background = Self.resolvedBackground(decision, tagColorHex: badge.tagColor)
        let border = Color(hexString: Self.packHex(badge.borderColor))
            ?? (Self.needsPlatterEdge(drawsPackFill: decision.bg == .pack, darkBase: decision.darkBase,
                                      tagColorHex: badge.tagColor, isFocused: onPlatter)
                    ? Theme.Palette.onFocusPlatter.opacity(Self.platterEdgeOpacity) : nil)

        return Text(badge.name)
            .font(Theme.Font.caption)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .frame(height: StreamBadgeMetrics.containerHeight)
            .background(background, in: Capsule())
            .background(decision.darkBase ? Self.chipBase : .clear, in: Capsule())
            .overlay(
                Capsule().stroke(border ?? .clear, lineWidth: border == nil ? 0 : 1)
            )
    }

    // MARK: - BUG-28 pure color decision logic

    /// Where a text chip's foreground should come from. Kept as a plain enum (no `Color`) so the
    /// decision is testable with simple `==` — see `StreamBadgeColorTests`.
    enum ChipFgSource: Equatable {
        /// `Theme.Palette.textPrimary` — semantic. At rest only: on the focus platter it would
        /// flip dark, so `fixedLight` takes its place there.
        case semantic
        /// The pack's own `textColor` hex.
        case pack
        /// The pack guard triggered on a LIGHT background: fixed near-black text. (On a dark
        /// background the guard answers with the light text, `semantic` or `fixedLight`.)
        case computedOnBg
        /// A fixed near-white, standing in for `semantic` while the row's focus platter is
        /// showing: the platter flips semantic colours dark, and this text sits on a dark chip.
        case fixedLight
    }

    /// Where a text chip's background should come from.
    enum ChipBgSource: Equatable {
        /// `chipBase` — the row's resting card colour, the fixed-dark default.
        case semantic
        /// The pack's own `tagColor` hex.
        case pack
    }

    struct ChipColorDecision: Equatable {
        var fg: ChipFgSource
        var bg: ChipBgSource
        /// Whether the pack's `borderColor` is drawn. Always true since GitHub #25 (a focused
        /// chip used to drop it); kept so the decision value still states it.
        var showBorder: Bool
        /// GitHub #25: paint the opaque dark surface under a translucent pack fill while the row's
        /// focus platter is showing (see `imageChipSurface`).
        var darkBase: Bool = false
    }

    /// The source row's resting card colour (`Theme.Palette.surface`, `StreamRowView` full and
    /// compact rows). The base under a chip on the focus platter is painted in it, so a badge looks
    /// the same inside its chip at rest and focused (GitHub #25 follow-up), and it is the colour
    /// the contrast guard judges text against when the pack supplies no (or an unparseable)
    /// `tagColor`. Keep `chipBaseHex` and `chipBase` the same colour.
    static let chipBaseHex = "1A1A1A"
    static let chipBase = Theme.Palette.surface

    /// Whether a `tagStyle` fills the chip with `tagColor`: exactly "filled", ignoring case and
    /// surrounding whitespace. Parity with `StreamBadgeChip.kt` (composeApp) and upstream
    /// `cmp-rewrite`, which compare with `equals("filled", ignoreCase = true)`; compound styles
    /// such as "filled and bordered" are not filled on any platform.
    static func isFilled(tagStyle: String) -> Bool {
        tagStyle.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("filled") == .orderedSame
    }

    /// A pack colour with alpha 0 means "none" (packs write `#00000000` for unset colours): returns
    /// "" for it so callers treat it as missing. Anything else, parseable or not, comes back as is.
    static func packHex(_ hex: String) -> String {
        Theme.Palette.alpha(fromHexString: hex) == 0 ? "" : hex
    }

    /// Approximate luminance of `Theme.Palette.textPrimary` (`Color.primary`) as it actually
    /// renders in this app: near-white, since the app pins a dark color scheme (see that
    /// property's doc comment). `Color.primary` has no hex to measure outside a live SwiftUI
    /// environment, so this mirrors the literal value `textPrimary` was hard-coded to before it
    /// became semantic (`0xF5F7F8`) — close enough for the contrast guard below, which only
    /// needs to know "this resolves light."
    private static let semanticFgApproxHex = "F5F7F8"

    /// Pure decision function for a text chip's colors — see BUG-28, BUG-43 and GitHub #25.
    ///
    /// The chip draws its own background, so its colours are judged against THAT, focused or not.
    /// The background's luminance is the pack's `tagColor` blended over the dark surface by its
    /// alpha (`effectiveBackgroundLuminance`): a 12 % tint is a dark chip, whatever its hue.
    ///
    /// `textColor` present: keep the pack's colors. But if the pack's `textColor` and the
    /// effective background are both light or both dark — luminance difference under 0.3 — the
    /// pair is illegible (BUG-28's reported white-on-white case), so replace the foreground with a
    /// computed dark/light pick against that background.
    ///
    /// `textColor` missing/unparseable (BUG-43): mobile never renders a text chip at all
    /// (`StreamBadgeChip.kt` only draws `imageURL`), so plenty of imported packs set `tagColor`
    /// alone and leave `textColor` blank — nothing on mobile ever needed it. Naively defaulting to
    /// the semantic foreground here ignores what it will actually sit on: `Theme.Palette
    /// .textPrimary` (`Color.primary`) resolves near-white in this app's pinned dark scheme, and
    /// pairing that with a LIGHT pack `tagColor` (a language badge's flag-style fill, say)
    /// produces a near-invisible near-white-on-light chip. So this path runs the identical
    /// luminance guard, using `semanticFgApproxHex` to stand in for the un-measurable
    /// `Color.primary`: a light effective background swaps in the same `.computedOnBg` dark-text
    /// pick the explicit-`textColor` path already uses; a dark/default background keeps the
    /// near-white text.
    ///
    /// FOCUSED (GitHub #25): the same decision, with two changes. Until beta 22 a focused chip
    /// dropped the pack entirely for a fixed 8 % black fill and dark text, which turned every
    /// coloured badge on the highlighted row into the same grey. Now (1) a translucent pack fill
    /// gets the opaque dark base under it (`darkBase`), so it looks as it does at rest instead of
    /// tinting the white platter; and (2) the semantic near-white becomes `.fixedLight`, because
    /// the focused row flips semantic colours dark (BUG-28) while this chip's background stays
    /// dark.
    static func effectiveTextChipColors(
        textColorHex rawTextColorHex: String,
        tagColorHex: String,
        isFocused: Bool
    ) -> ChipColorDecision {
        let textColorHex = packHex(rawTextColorHex)
        let packAlpha = Theme.Palette.alpha(fromHexString: tagColorHex)
        let bgSource: ChipBgSource = packAlpha != nil ? .pack : .semantic
        let effectiveBgLum = effectiveBackgroundLuminance(tagColorHex: tagColorHex)
        let darkBase = isFocused && (packAlpha.map { $0 < 1 } ?? false)
        let lightText: ChipFgSource = isFocused ? .fixedLight : .semantic

        // The guard's answer: near-black on a light background, the light text on a dark one.
        // The light text stays SEMANTIC at rest, so a chip that draws no background of its own
        // (an image chip's text stand-in) still follows whatever surface it is shown on.
        let guarded: ChipFgSource = effectiveBgLum > 0.5 ? .computedOnBg : lightText

        guard let fgLum = Theme.Palette.luminance(fromHexString: textColorHex) else {
            let assumedSemanticFgLum = Theme.Palette.luminance(fromHexString: semanticFgApproxHex)!
            let fg = abs(assumedSemanticFgLum - effectiveBgLum) < 0.3 ? guarded : lightText
            return ChipColorDecision(fg: fg, bg: bgSource, showBorder: true, darkBase: darkBase)
        }

        let fg = abs(fgLum - effectiveBgLum) < 0.3 ? guarded : .pack
        return ChipColorDecision(fg: fg, bg: bgSource, showBorder: true, darkBase: darkBase)
    }

    /// The luminance of what a chip's text sits on: the pack's `tagColor` blended by its alpha over
    /// the chip base (the row's resting card, and the base under the chip on the platter), or that
    /// base alone when the pack has no parseable `tagColor`.
    static func effectiveBackgroundLuminance(tagColorHex: String) -> Double {
        let baseLum = Theme.Palette.luminance(fromHexString: chipBaseHex)!
        guard let lum = Theme.Palette.luminance(fromHexString: tagColorHex),
              let alpha = Theme.Palette.alpha(fromHexString: tagColorHex) else { return baseLum }
        return alpha * lum + (1 - alpha) * baseLum
    }

    /// Maps a `ChipColorDecision.fg` to an actual `Color`. Split from `effectiveTextChipColors`
    /// so the pure decision stays `Color`-free while callers (text chip, image-chip fallback
    /// text) share this mapping.
    static func resolvedForeground(
        _ decision: ChipColorDecision,
        textColorHex: String,
        tagColorHex: String
    ) -> Color {
        switch decision.fg {
        case .semantic:
            return Theme.Palette.textPrimary
        case .pack:
            return Color(hexString: textColorHex) ?? Theme.Palette.textPrimary
        case .fixedLight:
            return fixedLightText
        case .computedOnBg:
            // Fixed: this text sits on the chip's own light background, which does not flip
            // with the focused row's colour scheme the way `textPrimary` does.
            return computedDarkText
        }
    }

    /// `semanticFgApproxHex` as a colour: the near-white `textPrimary` resolves to in the app's
    /// dark scheme, fixed so the focused row's light scheme cannot flip it.
    static let fixedLightText = Color(hex: 0xF5F7F8)
    /// The guard's near-black, for text on a light chip.
    static let computedDarkText = Color(hex: 0x0D0D0D)

    /// Maps a `ChipColorDecision.bg` to an actual `Color`.
    static func resolvedBackground(_ decision: ChipColorDecision, tagColorHex: String) -> Color {
        switch decision.bg {
        case .pack:
            return Color(hexString: tagColorHex) ?? chipBase
        case .semantic:
            return chipBase
        }
    }
}

/// Downsampled-at-decode badge artwork, replacing AsyncImage. AsyncImage decodes every chip's image
/// at FULL native resolution and each chip holds its own copy — community badge packs ship large
/// PNGs, and a picker with dozens of rows × 8 chips held hundreds of full-size bitmaps: the process
/// blew through the ~2 GB per-process jetsam limit on device (two JetsamEvent kills, 2026-07-16).
/// Badge packs reuse a small set of images across every row, so decode-once + downsample-to-chip-size
/// + cache collapses that to a few dozen thumbnails.
private struct BadgeImageView<Fallback: View>: View {
    let url: String
    @ViewBuilder let fallback: Fallback
    @State private var image: UIImage?
    @State private var failed = false

    /// W3-16 (F3): seeded from a synchronous peek at the decoded-thumbnail cache. A badge pack
    /// repeats a small set of images on every row, so a row that scrolls in finds them already
    /// decoded and draws them on its FIRST frame. Before, every new row's chips were empty
    /// (`Color.clear`) for a frame and then swapped to the image: a second layout pass through the
    /// `ViewThatFits` ladder per new row, in the middle of a scroll.
    init(url: String, @ViewBuilder fallback: () -> Fallback) {
        self.url = url
        self.fallback = fallback()
        _image = State(initialValue: BadgeImageMemory.peek(url))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                fallback
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            if let hit = BadgeImageMemory.peek(url) {
                if image !== hit { image = hit }
                return
            }
            if let loaded = await BadgeImageCache.shared.image(for: url) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

/// W3-16 (F3): the decoded badge thumbnails, readable WITHOUT hopping onto `BadgeImageCache`'s actor
/// so a view's `init` can peek. `NSCache` is thread-safe; nothing else touches it.
private enum BadgeImageMemory {
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    nonisolated static func peek(_ url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    nonisolated static func store(_ image: UIImage, for url: String) {
        cache.setObject(image, forKey: url as NSString)
    }
}

/// Process-wide badge-art cache: one fetch + one downsampled decode per unique URL, concurrent
/// requests for the same URL coalesced onto one task. NSCache (`BadgeImageMemory`) so the (already
/// small) decoded thumbnails still evict under memory pressure.
private actor BadgeImageCache {
    static let shared = BadgeImageCache()

    /// Longest decoded side in pixels: chip max width (150 pt) at the 4K UI scale (2x), rounded up.
    /// Keeps every thumbnail ≤ ~0.6 MB regardless of the source PNG's size.
    private static let maxPixelSize: CGFloat = 400

    private var inflight: [String: Task<UIImage?, Never>] = [:]

    func image(for url: String) async -> UIImage? {
        if let hit = BadgeImageMemory.peek(url) { return hit }
        if let running = inflight[url] { return await running.value }
        let task = Task<UIImage?, Never> {
            guard let parsed = URL(string: url),
                  let (data, response) = try? await URLSession.shared.data(from: parsed),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else { return nil }
            return BadgeImageDecoder.decodeThumbnail(data: data, maxPixel: Self.maxPixelSize)
        }
        inflight[url] = task
        let result = await task.value
        inflight[url] = nil
        if let result { BadgeImageMemory.store(result, for: url) }
        return result
    }
}

/// CGImageSource thumbnail decode: never materializes the full-resolution bitmap. ImageIO on tvOS
/// has no SVG decoder, so SVG artwork returns nil (the chip then shows the badge name as text).
enum BadgeImageDecoder {
    nonisolated static func decodeThumbnail(data: Data, maxPixel: CGFloat) -> UIImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// "2.3 GB" / "740 MB" chip from `behaviorHints.videoSize` (mobile `StreamFileSizeBadge`). No call
/// site since polish D1 (rows draw the size as plain text via `label(for:)`); the view is kept for
/// Direction C's best-pick card.
struct StreamFileSizeChip: View {
    let bytes: Int64

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: StreamBadgeMetrics.cornerRadius)
        Text(Self.label(for: bytes))
            .font(Theme.Font.caption.weight(.bold))
            // BUG-28: fixed (not semantic) foreground — this chip's background is a fixed dark
            // fill that does NOT flip with the row's focus colorScheme, so a semantic foreground
            // (which does flip) could end up dark-on-dark once focused. Fixed/fixed keeps the
            // pair legible in both states; the resulting light-on-dark chip reads fine sitting on
            // the white focus platter too.
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: StreamBadgeMetrics.containerHeight)
            .background(Theme.Palette.surfaceElevated, in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    static func label(for bytes: Int64) -> String {
        let gib = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        if gib >= 1.0 {
            // Localized format so locales can rename units (French: "Go"/"Mo").
            return String(format: String(localized: "%.1f GB"), (gib * 10.0).rounded() / 10.0)
        }
        let mib = Double(bytes) / (1024.0 * 1024.0)
        return String(format: String(localized: "%d MB"), Int(mib.rounded()))
    }
}

/// BUG-16: "+N" overflow indicator shown by `StreamPickerView.badgeRow`'s `ViewThatFits` ladder
/// when the row doesn't have room for every badge. Deliberately plain text in a muted capsule
/// (not a button) — it's a static count, not a focusable element — and shares
/// `StreamBadgeMetrics.containerHeight` with the other chips so swapping candidates in/out never
/// changes the badge row's height.
struct BadgeOverflowChip: View {
    let count: Int
    @Environment(\.isFocused) private var isFocused
    @Environment(\.settingsRowIsFocused) private var rowFocused

    var body: some View {
        let shape = Capsule()
        // GitHub #25 (review r1): on the white focus platter the 60 % fill composited to a mid
        // grey under 70 % white text. Like the other chips, it gets the opaque dark base there.
        let onPlatter = isFocused || rowFocused
        Text("+\(count)")
            .font(Theme.Font.caption.weight(.semibold))
            // BUG-28: fixed (not semantic) foreground for the same reason as StreamFileSizeChip
            // above — this chip's background is fixed-dark and doesn't flip with focus.
            .foregroundStyle(Color.white.opacity(0.7))
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: StreamBadgeMetrics.containerHeight)
            // On the platter: 0x202020, what the 60 % fill composites to over the resting card
            // (0x1A1A1A), so "+N" matches rest.
            .background(onPlatter ? Color(hex: 0x202020) : Theme.Palette.surfaceElevated.opacity(0.6), in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}
