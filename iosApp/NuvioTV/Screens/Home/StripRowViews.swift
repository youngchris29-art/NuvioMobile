import SharedCore
import SwiftUI

// Home Stage & Strip: the non-focusable strip rows (P2 spec §2.3), moved verbatim out of
// `FolderRowsPage.swift` so every strip page draws its loading and message rows the same way.
// The skeleton cards keep fixed frames (never `.aspectRatio(.fill)` in a flexible frame: a fill
// reports the FILL size and widens its ancestors, the OLED grey-bar lesson).

// MARK: - Non-focusable rows (§2.3)

/// A row heading, as `CatalogRowView` draws it outside pinned Home.
struct StripRowHeading: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.sectionTitle)
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(1)
    }
}

/// A source still loading: its heading over skeleton cards at the row's card size, laid out like a
/// loaded row so its posters land where the real ones will. Nothing here is focusable.
struct StripLoadingRow: View {
    let heading: String
    @Environment(\.posterStyle) private var style

    var body: some View {
        let width = style.landscapeCatalogRows ? Theme.Size.landscapeWidth : style.width
        let height = style.landscapeCatalogRows ? Theme.Size.landscapeHeight : style.height
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            StripRowHeading(text: heading)
            HStack(spacing: Theme.Spacing.rowGap) {
                ForEach(0..<StripRowsPlan.skeletonCount, id: \.self) { _ in
                    ShimmerView()
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
                }
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A settled source with nothing to show: its heading and one line.
struct StripMessageRow: View {
    let heading: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            StripRowHeading(text: heading)
            Text(message)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.vertical, Theme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
