import SharedCore
import SwiftUI

/// Add-ons hub C, H2: one installed add-on on the Sources hub. A single focus section: Left/Right
/// stay inside the card (name area, On/Off, Up, Down, Remove), Up/Down move between cards.
/// Identifiers address the card by POSITION only; the focus keys (`card:`, `toggle:`, `up:`,
/// `down:`, `remove:` plus the manifest URL) are internal `@FocusState` values and never exposed.
struct AddonCardView: View {
    let addon: ManagedAddon
    let index: Int
    let count: Int
    let isReadOnly: Bool
    let focus: FocusState<String?>.Binding
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            nameArea
            Spacer(minLength: Theme.Spacing.md)
            controls
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .focusSection()
    }

    private var nameArea: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.lg) {
                // The component's `failure:` builder (BUG-41) supplies the puzzle-piece fallback
                // for a missing or broken logo.
                CachedAsyncImage(string: addon.manifest?.logoUrl) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(Theme.Font.body)
                        .rowTextColor(secondary: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.Palette.surfaceElevated)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(AddonsViewModel.displayTitle(addon))
                        .font(Theme.Font.sectionTitle).rowTextColor().lineLimit(1)
                    Text(metaLine)
                        .font(Theme.Font.meta).rowTextColor(secondary: true).lineLimit(1)
                    Text(AddonsViewModel.host(of: addon.manifestUrl))
                        .font(Theme.Font.caption).rowTextColor(secondary: true).lineLimit(1)
                    if let manifest = addon.manifest {
                        Text("Catalogs: \(manifest.catalogs.count)")
                            .font(Theme.Font.caption).rowTextColor(secondary: true)
                    }
                }
                Spacer(minLength: Theme.Spacing.md)
                AddonStatusPill(status: AddonsViewModel.status(of: addon))
                    .accessibilityIdentifier("addons_hub_status_\(index)")
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.settingsRow)
        .focused(focus, equals: "card:\(addon.manifestUrl)")
        .accessibilityIdentifier("addons_hub_card_\(index)")
    }

    /// "v1.2.3 · Streams · Catalogs", or "Loading…" until the manifest arrives.
    private var metaLine: String {
        guard let manifest = addon.manifest else { return String(localized: "Loading…") }
        let labels = AddonsViewModel.resourceLabels(of: manifest)
        return (["v\(manifest.version)"] + labels).joined(separator: " · ")
    }

    private var controls: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button(action: onToggle) {
                SettingsSwitchGlyph(isOn: addon.enabled)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
            .buttonStyle(.chip)
            .focused(focus, equals: "toggle:\(addon.manifestUrl)")
            .accessibilityLabel(addon.enabled ? Text("On") : Text("Off"))
            .accessibilityValue(addon.enabled ? "enabled" : "disabled")
            .accessibilityIdentifier("addons_hub_card_\(index)_toggle")

            glyphButton("chevron.up", key: "up", label: "Move up", id: "up", disabled: index == 0, action: onMoveUp)
            glyphButton("chevron.down", key: "down", label: "Move down", id: "down", disabled: index == count - 1, action: onMoveDown)

            Button(action: onRemove) {
                ErrorGlyph(systemName: "trash")
                    .padding(.horizontal, Theme.Spacing.sm)
            }
            .buttonStyle(.chip)
            .focused(focus, equals: "remove:\(addon.manifestUrl)")
            .accessibilityLabel("Remove")
            .accessibilityIdentifier("addons_hub_card_\(index)_remove")
        }
        .disabled(isReadOnly)
    }

    private func glyphButton(
        _ symbol: String, key: String, label: LocalizedStringKey, id: String,
        disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.Font.body)
                .padding(.horizontal, Theme.Spacing.sm)
        }
        .buttonStyle(.chip)
        .disabled(disabled)
        .focused(focus, equals: "\(key):\(addon.manifestUrl)")
        .accessibilityLabel(label)
        .accessibilityIdentifier("addons_hub_card_\(index)_\(id)")
    }
}

/// The card's state pill: "Active", "Disabled", "Refreshing" (with a spinner) or "Unavailable".
/// Inside the name button, so on focus it sits on the near-white platter: the resting dark pill
/// swaps to a light-grey one then (read from `settingsRowIsFocused`, the kit's focus signal).
private struct AddonStatusPill: View {
    let status: AddonsViewModel.AddonStatus
    @Environment(\.settingsRowIsFocused) private var onPlatter

    private var word: String {
        switch status {
        case .active: return String(localized: "Active")
        case .disabled: return String(localized: "Disabled")
        case .refreshing: return String(localized: "Refreshing")
        case .stalled: return String(localized: "Still refreshing…")
        case .unavailable: return String(localized: "Unavailable")
        }
    }

    private var fill: Color {
        if status == .unavailable { return Theme.Palette.error.opacity(0.18) }
        return onPlatter ? Color.black.opacity(0.1) : Theme.Palette.surfaceElevated
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if status == .refreshing || status == .stalled { ProgressView().controlSize(.small) }
            Text(word).font(Theme.Font.caption).rowTextColor()
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(Capsule().fill(fill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(word)
    }
}

/// A glyph in the error tint at rest that joins the platter's dark label colour on focus (an
/// explicit tint would stay red-on-white; the kit's `rowAccentTint` is accent-only).
private struct ErrorGlyph: View {
    let systemName: String
    @Environment(\.settingsRowIsFocused) private var focused

    var body: some View {
        Image(systemName: systemName)
            .font(Theme.Font.body)
            .foregroundStyle(focused ? Theme.Palette.onFocusPlatter : Theme.Palette.error)
    }
}
