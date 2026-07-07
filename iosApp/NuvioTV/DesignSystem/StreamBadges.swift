import SwiftUI
import SharedCore

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

        return AsyncImage(url: URL(string: badge.imageURL)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            case .failure:
                // Broken/unreachable image → readable text stand-in.
                Text(badge.name)
                    .font(Theme.Font.caption.weight(.semibold))
                    .foregroundStyle(Color(hexString: badge.textColor) ?? Theme.Palette.textPrimary)
                    .lineLimit(1)
            default:
                Color.clear
            }
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
            return String(format: "%.1f GB", (gib * 10.0).rounded() / 10.0)
        }
        let mib = Double(bytes) / (1024.0 * 1024.0)
        return "\(Int(mib.rounded())) MB"
    }
}
