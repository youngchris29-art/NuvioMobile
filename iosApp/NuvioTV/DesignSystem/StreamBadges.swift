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
/// - `StreamFileSizeChip` is the "2.3 GB" companion chip (mobile `StreamFileSizeBadge`).
enum StreamBadgeMetrics {
    static let containerHeight: CGFloat = 40
    static let imageHeight: CGFloat = 30
    static let minImageWidth: CGFloat = 60
    static let maxImageWidth: CGFloat = 180
    static let cornerRadius: CGFloat = 8
}

struct StreamBadgeChipView: View {
    let badge: StreamBadge

    var body: some View {
        if badge.imageURL.isEmpty {
            textChip
        } else {
            imageChip
        }
    }

    private var imageChip: some View {
        let shape = RoundedRectangle(cornerRadius: StreamBadgeMetrics.cornerRadius)
        let filled = badge.tagStyle.caseInsensitiveCompare("filled") == .orderedSame
        let background = filled ? Color(hexString: badge.tagColor) : nil
        let border = Color(hexString: badge.borderColor)

        return BadgeImageView(url: badge.imageURL) {
            // Broken/unreachable image → readable text stand-in.
            Text(badge.name)
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Color(hexString: badge.textColor) ?? Theme.Palette.textPrimary)
                .lineLimit(1)
        }
        .frame(height: StreamBadgeMetrics.imageHeight)
        .frame(minWidth: StreamBadgeMetrics.minImageWidth, maxWidth: StreamBadgeMetrics.maxImageWidth)
        .padding(.horizontal, 6)
        .frame(height: StreamBadgeMetrics.containerHeight)
        .background(background ?? .clear, in: shape)
        .overlay(shape.stroke(border ?? .clear, lineWidth: border == nil ? 0 : 1))
        .clipShape(shape)
    }

    private var textChip: some View {
        let background = Color(hexString: badge.tagColor) ?? Theme.Palette.surfaceElevated
        let foreground = Color(hexString: badge.textColor) ?? Theme.Palette.textPrimary
        let border = Color(hexString: badge.borderColor)

        return Text(badge.name)
            .font(Theme.Font.caption)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(background, in: Capsule())
            .overlay(
                Capsule().stroke(border ?? .clear, lineWidth: border == nil ? 0 : 1)
            )
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
            if let loaded = await BadgeImageCache.shared.image(for: url) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

/// Process-wide badge-art cache: one fetch + one downsampled decode per unique URL, concurrent
/// requests for the same URL coalesced onto one task. NSCache so the (already small) decoded
/// thumbnails still evict under memory pressure.
private actor BadgeImageCache {
    static let shared = BadgeImageCache()

    /// Longest decoded side in pixels: chip max width (180 pt) at the 4K UI scale (2x), rounded up.
    /// Keeps every thumbnail ≤ ~0.6 MB regardless of the source PNG's size.
    private static let maxPixelSize: CGFloat = 400

    private let cache = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    func image(for url: String) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSString) { return hit }
        if let running = inflight[url] { return await running.value }
        let task = Task<UIImage?, Never> {
            guard let parsed = URL(string: url),
                  let (data, response) = try? await URLSession.shared.data(from: parsed),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else { return nil }
            return Self.downsample(data: data, maxPixel: Self.maxPixelSize)
        }
        inflight[url] = task
        let result = await task.value
        inflight[url] = nil
        if let result { cache.setObject(result, forKey: url as NSString) }
        return result
    }

    /// CGImageSource thumbnail decode: never materializes the full-resolution bitmap.
    private static func downsample(data: Data, maxPixel: CGFloat) -> UIImage? {
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

/// "2.3 GB" / "740 MB" chip from `behaviorHints.videoSize` (mobile `StreamFileSizeBadge`).
struct StreamFileSizeChip: View {
    let bytes: Int64

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: StreamBadgeMetrics.cornerRadius)
        Text(Self.label(for: bytes))
            .font(Theme.Font.caption.weight(.bold))
            .foregroundStyle(Theme.Palette.textPrimary)
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
