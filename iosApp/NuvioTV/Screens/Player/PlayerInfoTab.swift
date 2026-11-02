import SharedCore
import SwiftUI

/// One label/value row of the Info tab's stream section.
struct NativeInfoRow: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
}

/// Static what's-playing header for the Info tab, captured once from the PlaybackContext.
struct NativeInfoHeader: Equatable {
    let title: String
    /// "S1 · E4 · Episode name" for series (falls back to the stream label when the episode list
    /// doesn't carry a name), else the stream's own label (release name / addon line).
    let subtitle: String?
    let synopsis: String?
    let poster: String?
    /// True when `poster` is an episode still (16:9) rather than a 2:3 poster.
    let landscapeArtwork: Bool
    /// Release name / addon line — shown as a secondary line under the synopsis when it isn't
    /// already the subtitle.
    let streamLabel: String?

    init(context: PlaybackContext) {
        title = context.title
        var parts: [String] = []
        var usedStreamLabel = false
        if let s = context.season, let e = context.episode {
            parts.append(String(localized: "S\(s) · E\(e)"))
            let episodeName = context.episodes.first { $0.season?.value == s && $0.episode?.value == e }?.title
            if let episodeName, !episodeName.isEmpty {
                parts.append(episodeName)
            } else if let st = context.streamTitle, !st.isEmpty {
                parts.append(st); usedStreamLabel = true
            }
        } else if let st = context.streamTitle, !st.isEmpty {
            parts.append(st); usedStreamLabel = true
        }
        subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        synopsis = context.synopsis.flatMap { $0.isEmpty ? nil : $0 }
        let still = context.episodeStill.flatMap { $0.isEmpty ? nil : $0 }
        poster = still ?? context.poster.flatMap { $0.isEmpty ? nil : $0 }
        landscapeArtwork = still != nil
        streamLabel = usedStreamLabel ? nil : context.streamTitle.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Info content (mpv Info shelf, native Info pill): what's-playing header (art · title · S/E ·
/// badges · synopsis) on the left; the metadata chip row (Infuse-style: runtime · year · size ·
/// codec · resolution class · audio · bitrate · fps · genres · rating) and the live stream rows in
/// two columns on the right. Nothing here is focusable — it's read-only.
///
/// Device pass 2026-11-01: both hosts give it a fixed height (the mpv shelf, about 370 pt inside its
/// padding; the native pill, 400 pt), and the old stacked layout (header, chips, divider, rows)
/// ran past it and drew over the bar. It is now top-pinned and fills the offered height: the rows
/// show only the whole rows that fit (`PlayerInfoFitGridLayout`), and the rest is clipped.
struct PlayerInfoTab: View {
    let info: PlayerPanelInfo

    /// Header art height; poster (2:3) or episode still (16:9) scale into it.
    private static let artHeight: CGFloat = 150

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xl) {
            headerView
                .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                // Its ideal height only: a horizontal ScrollView would otherwise share the
                // column's height with the rows.
                if !info.chips.isEmpty { chipRow.fixedSize(horizontal: false, vertical: true) }
                rowsView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var headerView: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            if info.header.poster != nil {
                CachedAsyncImage(string: info.header.poster, contentMode: .fill)
                    .frame(width: info.header.landscapeArtwork ? Self.artHeight * 16 / 9 : Self.artHeight * 2 / 3,
                           height: Self.artHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(info.header.title)
                    .font(Theme.Font.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let subtitle = info.header.subtitle {
                    Text(subtitle)
                        .font(Theme.Font.sectionTitle)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                if !info.badges.isEmpty { badgeRow }
                if let synopsis = info.header.synopsis {
                    Text(synopsis)
                        .font(Theme.Font.detail)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(3)
                }
                if let label = info.header.streamLabel {
                    Text(label)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Badge-pack chips for what is playing (upstream 344117e73), under the title like upstream's
    /// player: the stream picker's `StreamBadgeChipView` at its metrics, no container behind the
    /// row. `BadgeChipRowLayout` drops chips from the end rather than wrapping or truncating one,
    /// and sizes each chip at its ideal width, so it hugs its image instead of stretching to
    /// `StreamBadgeMetrics.maxImageWidth` across a wide header.
    private var badgeRow: some View {
        BadgeChipRowLayout(spacing: Theme.Spacing.xs) {
            ForEach(Array(info.badges.enumerated()), id: \.offset) { _, badge in
                StreamBadgeChipView(badge: badge)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(info.badges.map(\.name).joined(separator: ", "))
        .accessibilityIdentifier("player.panel.badges")
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(info.chips) { chip in
                    HStack(spacing: Theme.Spacing.xxs) {
                        if let symbol = chip.symbol { Image(systemName: symbol) }
                        Text(chip.text)
                    }
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xxs + 2)
                    .background(Theme.Palette.textPrimary.opacity(0.12), in: Capsule())
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(info.chips.map(\.text).joined(separator: ", "))
    }

    /// Two columns of label/value pairs, reading order left to right; only the whole rows that fit
    /// the height left under the chips are shown.
    @ViewBuilder
    private var rowsView: some View {
        if info.rows.isEmpty {
            Text("No stream details yet.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else {
            PlayerInfoFitGridLayout(columns: 2, horizontalSpacing: Theme.Spacing.lg,
                                    verticalSpacing: Theme.Spacing.xs) {
                ForEach(info.rows) { rowView($0) }
            }
        }
    }

    private func rowView(_ row: NativeInfoRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Text(row.label)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)
            Text(row.value)
                .font(Theme.Font.meta.monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row-major grid of equal-width cells that shows only the whole rows fitting the offered height
/// (all of them when the height is unbounded). Like `BadgeChipRowLayout`, the cells that do not fit
/// are parked far above at zero size (a Layout must place every subview).
struct PlayerInfoFitGridLayout: Layout {
    var columns: Int
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let plan = plan(subviews, width: proposal.width, height: proposal.height)
        return CGSize(width: plan.width, height: plan.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = plan(subviews, width: bounds.width, height: bounds.height)
        var y = bounds.minY
        for (r, rowHeight) in plan.rowHeights.enumerated() {
            for c in 0..<columns {
                let i = r * columns + c
                guard i < subviews.count else { break }
                let x = bounds.minX + CGFloat(c) * (plan.cellWidth + horizontalSpacing)
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: plan.cellWidth, height: rowHeight))
            }
            y += rowHeight + verticalSpacing
        }
        for i in (plan.rowHeights.count * columns)..<max(subviews.count, plan.rowHeights.count * columns) {
            subviews[i].place(at: CGPoint(x: bounds.minX, y: bounds.minY - 10_000), anchor: .topLeading,
                              proposal: .zero)
        }
    }

    /// The cell width, the heights of the rows that fit, and the size they take.
    func plan(_ subviews: Subviews, width: CGFloat?, height: CGFloat?)
        -> (cellWidth: CGFloat, rowHeights: [CGFloat], width: CGFloat, height: CGFloat) {
        let cols = max(columns, 1)
        let cellWidth: CGFloat
        if let width, width.isFinite {
            cellWidth = max((width - horizontalSpacing * CGFloat(cols - 1)) / CGFloat(cols), 0)
        } else {
            cellWidth = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }
        let rows = PlayerInfoFitGridLayout.fittingRows(cellHeights: heights, columns: cols,
                                                       spacing: verticalSpacing,
                                                       maxHeight: height.flatMap { $0.isFinite ? $0 : nil })
        let used = rows.reduce(0, +) + verticalSpacing * CGFloat(max(rows.count - 1, 0))
        let totalWidth = rows.isEmpty ? 0 : cellWidth * CGFloat(cols) + horizontalSpacing * CGFloat(cols - 1)
        return (cellWidth, rows, totalWidth, used)
    }

    /// Pure: the heights of the leading rows (row-major, `columns` cells each, a row as tall as its
    /// tallest cell) whose stack, with `spacing` between rows, fits `maxHeight` (nil = all rows).
    static func fittingRows(cellHeights: [CGFloat], columns: Int, spacing: CGFloat,
                            maxHeight: CGFloat?) -> [CGFloat] {
        let cols = max(columns, 1)
        var rows: [CGFloat] = []
        var used: CGFloat = 0
        var start = 0
        while start < cellHeights.count {
            let row = cellHeights[start..<min(start + cols, cellHeights.count)].max() ?? 0
            let next = used + (rows.isEmpty ? 0 : spacing) + row
            if let maxHeight, next > maxHeight + 0.5 { break }
            rows.append(row)
            used = next
            start += cols
        }
        return rows
    }
}

/// One row of chips at their ideal sizes, left to right, keeping only the leading chips that fit
/// the offered width (one view per chip, unlike a `ViewThatFits` ladder of every prefix). A Layout
/// must place every subview, so the chips that do not fit are parked far above the row at zero
/// size; the row's accessibility label names them all anyway.
private struct BadgeChipRowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = fitted(subviews, maxWidth: proposal.width)
        let width = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(sizes.count - 1, 0))
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = fitted(subviews, maxWidth: bounds.width)
        var x = bounds.minX
        for (i, subview) in subviews.enumerated() {
            if i < sizes.count {
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + spacing
            } else {
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY - 10_000), anchor: .topLeading, proposal: .zero)
            }
        }
    }

    /// Ideal sizes of the leading subviews that fit in `maxWidth` (all of them when unbounded).
    private func fitted(_ subviews: Subviews, maxWidth: CGFloat?) -> [CGSize] {
        var sizes: [CGSize] = []
        var used: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let next = used + (sizes.isEmpty ? 0 : spacing) + size.width
            if let maxWidth, next > maxWidth + 0.5 { break }
            sizes.append(size)
            used = next
        }
        return sizes
    }
}
