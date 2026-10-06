import SwiftUI

// MARK: - Shared filter pills
//
// The shared pills and chips for filter rows. They started as LibraryView's private control-row
// pieces (Library L1, 2026-10-04) and moved here for the Search & Discover batch (2026-10-06) so
// Library, Search and Discover draw one control row. The look is Library's, unchanged: the List and
// Sort pills are stock `Menu { Picker }` buttons (the same control Settings uses for its choice
// rows), not the folder band's `.menuStyle(.button).buttonStyle(.bordered)` pills.
//
// Hosting rows should put these in a horizontal `ScrollView` with `.scrollClipDisabled()` (the stock
// Menu button lifts on focus; don't crop the lift) and `.focusSection()`.

/// The label shared by the pills: leading SF Symbol, the title, and (for menus) a small chevron.
struct PillLabel: View {
    let title: String
    let systemImage: String
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: systemImage)
            Text(title)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(Theme.Font.caption)
            }
        }
        .font(Theme.Font.meta)
        .padding(.horizontal, Theme.Spacing.xs)
    }
}

/// A shared menu pill: a stock `Menu { Picker }` whose label is a `PillLabel` showing `title`
/// (normally the current choice's label). `pickerTitle` names the Picker (defaults to `title`);
/// `id` is the accessibility identifier.
struct PillMenu<Selection: Hashable>: View {
    let title: String
    let systemImage: String
    @Binding var selection: Selection
    let options: [Selection]
    let id: String
    var pickerTitle: String? = nil
    let label: (Selection) -> String

    init(
        title: String,
        systemImage: String,
        selection: Binding<Selection>,
        options: [Selection],
        id: String,
        pickerTitle: String? = nil,
        label: @escaping (Selection) -> String
    ) {
        self.title = title
        self.systemImage = systemImage
        self._selection = selection
        self.options = options
        self.id = id
        self.pickerTitle = pickerTitle
        self.label = label
    }

    var body: some View {
        Menu {
            Picker(pickerTitle ?? title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
        } label: {
            PillLabel(title: title, systemImage: systemImage)
        }
        .accessibilityIdentifier(id)
    }
}

/// A shared action pill: the `PillLabel` shape without the chevron, on the system button platter
/// (the same platter a stock `Menu` label gets), so it sits beside `PillMenu` without a seam.
struct PillButton: View {
    let title: String
    let systemImage: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PillLabel(title: title, systemImage: systemImage, showsChevron: false)
        }
        .accessibilityIdentifier(id)
    }
}

/// A shared toggle chip (Library's type chips, smart filters and Saved / Debrid Cloud switcher).
/// Active shows a leading checkmark and the `.chip(selected:)` fill; inactive shows `systemImage`
/// when one is given.
struct FilterChip: View {
    let title: String
    var systemImage: String? = nil
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(Theme.Font.meta)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
        }
        .buttonStyle(.chip(selected: isActive))
    }
}

/// A shared header count line: the count text in `Theme.Font.meta` plus an optional stroked source
/// badge (e.g. "TRAKT"). Renders nothing when both are empty. Place it in a
/// `.firstTextBaseline` `HStack` beside the screen title.
struct CountLine: View {
    let text: String?
    let badge: String?
    var badgeAccessibilityLabel: String? = nil

    var body: some View {
        let countText = (text?.isEmpty == false) ? text : nil
        if countText != nil || badge != nil {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                if let countText {
                    Text(countText)
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                if let badge {
                    Text(badge)
                        .font(Theme.Font.caption)
                        .tracking(2)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .padding(.vertical, Theme.Spacing.xxs)
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                                .stroke(Theme.Palette.textSecondary, lineWidth: 1)
                        }
                        .accessibilityLabel(Text(badgeAccessibilityLabel ?? badge))
                }
            }
        }
    }
}
