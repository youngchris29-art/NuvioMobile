import SharedCore
import SwiftUI

/// Add-ons hub v2, A3: the Installed pane on the native Settings row kit.
///
/// A native `List` of `Button` rows, each wrapped in `SettingsRowChrome` (the HIG-hybrid
/// contract: rows are Buttons inside a List, no custom row spread). Select opens the add-on's
/// detail page; the long-press context menu carries Enable/Disable, Move up/down, Refresh/Retry,
/// Configure and Remove. Every state keeps one focusable control: the empty state is a link row
/// to the Install section, so a pushed or selected pane never strands focus.
///
/// Focus keys are `rowKey(url)` (`"row:" + manifestUrl`) on the shared content `FocusState`.
struct InstalledAddonsPane: View {
    @ObservedObject var model: AddonsViewModel
    let focus: FocusState<String?>.Binding
    let onOpen: (ManagedAddon) -> Void
    let onMove: (ManagedAddon, Int, Int) -> Void
    let onRemove: (ManagedAddon) -> Void
    let onShowInstall: () -> Void

    nonisolated static func rowKey(_ manifestUrl: String) -> String { "row:" + manifestUrl }

    // MARK: Pure rules

    nonisolated enum RowAction: Hashable {
        case toggle(enable: Bool), moveUp, moveDown, refresh, retry, configure, remove
    }

    /// The trailing status word of a row.
    nonisolated static func trailingText(_ status: AddonsViewModel.AddonStatus) -> String {
        switch status {
        case .active: return String(localized: "On")
        case .disabled: return String(localized: "Off")
        case .refreshing: return String(localized: "Refreshing…")
        case .stalled: return String(localized: "Still refreshing…")
        case .unavailable: return String(localized: "Unavailable")
        }
    }

    /// The context menu's actions, in order. Read-only profiles may only refresh (or retry a
    /// stalled refresh); otherwise toggle, moves, refresh/retry, configure, remove.
    nonisolated static func menuActions(
        enabled: Bool, configurable: Bool, index: Int, count: Int,
        isReadOnly: Bool, status: AddonsViewModel.AddonStatus
    ) -> [RowAction] {
        let refreshAction: RowAction = status == .stalled ? .retry : .refresh
        if isReadOnly { return [refreshAction] }
        var actions: [RowAction] = [.toggle(enable: !enabled)]
        if index > 0 { actions.append(.moveUp) }
        if index < count - 1 { actions.append(.moveDown) }
        actions.append(refreshAction)
        if configurable { actions.append(.configure) }
        actions.append(.remove)
        return actions
    }

    // MARK: Body

    var body: some View {
        List {
            if model.isReadOnly {
                Text("This profile uses the primary profile's add-ons. Manage them there.")
                    .font(SettingsRowFont.subtitle)
                    .foregroundStyle(.secondary)
                    .focusable(false)
                    .accessibilityIdentifier("addons_hub_readonly")
            }
            if !model.isInitialized {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .accessibilityIdentifier("addons_installed_loading")
            } else if model.addons.isEmpty {
                Button(action: onShowInstall) {
                    SettingsRowChrome {
                        SettingsRowLabel(
                            title: String(localized: "Install add-on"),
                            subtitle: String(localized: "No add-ons installed. Install one to get started.")
                        )
                    } trailing: {
                        SettingsTrailingValue(value: nil)
                    }
                }
                .accessibilityIdentifier("addons_hub_empty")
            }
            ForEach(Array(model.addons.enumerated()), id: \.element.manifestUrl) { index, addon in
                AddonRow(
                    addon: addon, index: index, count: model.addons.count,
                    isReadOnly: model.isReadOnly,
                    status: AddonsViewModel.status(of: addon, stalled: model.stalledUrls),
                    model: model, focus: focus,
                    onOpen: onOpen, onMove: onMove, onRemove: onRemove
                )
            }
        }
        .environment(\.settingsUsesNativeList, true)
        .scrollClipDisabled()
        .accessibilityIdentifier("addons_installed_list")
    }
}

// MARK: - Row

private struct AddonRow: View {
    let addon: ManagedAddon
    let index: Int
    let count: Int
    let isReadOnly: Bool
    let status: AddonsViewModel.AddonStatus
    let model: AddonsViewModel
    let focus: FocusState<String?>.Binding
    let onOpen: (ManagedAddon) -> Void
    let onMove: (ManagedAddon, Int, Int) -> Void
    let onRemove: (ManagedAddon) -> Void

    private var actions: [InstalledAddonsPane.RowAction] {
        InstalledAddonsPane.menuActions(
            enabled: addon.enabled,
            configurable: addon.manifest?.behaviorHints.configurable == true,
            index: index, count: count, isReadOnly: isReadOnly, status: status
        )
    }

    private var title: String { AddonsViewModel.displayTitle(addon) }
    private var statusText: String { InstalledAddonsPane.trailingText(status) }

    var body: some View {
        let allowed = actions
        Button { onOpen(addon) } label: {
            SettingsRowChrome {
                leading
            } trailing: {
                trailing
            }
        }
        .focused(focus, equals: InstalledAddonsPane.rowKey(addon.manifestUrl))
        .contextMenu {
            ForEach(allowed, id: \.self) { action in
                menuButton(action)
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(statusText)
        .accessibilityIdentifier("addons_row_\(index)")
        .modifier(MoveActions(allowed: allowed) { delta in onMove(addon, index, delta) })
    }

    private var leading: some View {
        HStack(spacing: Theme.Spacing.lg) {
            CachedAsyncImage(string: addon.manifest?.logoUrl) {
                Image(systemName: "puzzlepiece.extension")
                    .font(Theme.Font.body)
                    .rowTextColor(secondary: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Palette.surfaceElevated)
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .font(SettingsRowFont.title)
                    .lineLimit(1)
                Text(metaLine)
                    .font(SettingsRowFont.subtitle)
                    .rowTextColor(secondary: true)
                    .lineLimit(1)
            }
        }
    }

    private var trailing: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if status == .refreshing || status == .stalled {
                ProgressView().controlSize(.small)
            }
            AddonRowValue(text: statusText, isError: status == .unavailable)
                .accessibilityIdentifier("addons_row_\(index)_value")
        }
    }

    /// "v2.4.1 · Streams · Subtitles", or "Loading…" until the manifest arrives.
    private var metaLine: String {
        guard let manifest = addon.manifest else { return String(localized: "Loading…") }
        let labels = AddonsViewModel.resourceLabels(of: manifest)
        return (["v\(manifest.version)"] + labels).joined(separator: " · ")
    }

    @ViewBuilder
    private func menuButton(_ action: InstalledAddonsPane.RowAction) -> some View {
        switch action {
        case .toggle(let enable):
            Button(enable ? "Enable" : "Disable") { model.setEnabled(addon, enable) }
        // A4: replaced by the Move mode (pick up, Up/Down, Select to drop); these two stay as the
        // interim reorder path until then.
        case .moveUp:
            Button("Move up") { onMove(addon, index, -1) }
        case .moveDown:
            Button("Move down") { onMove(addon, index, 1) }
        case .refresh:
            Button("Refresh") { model.refresh(manifestUrl: addon.manifestUrl) }
        case .retry:
            Button("Retry") { model.retryRefresh(manifestUrl: addon.manifestUrl) }
        case .configure:
            Button("Configure") { onOpen(addon) }
        case .remove:
            Button("Remove", role: .destructive) { onRemove(addon) }
        }
    }
}

/// The trailing status word. `SettingsTrailingValue` paints `.secondary`; an unavailable add-on
/// takes the error tint at rest and the platter's dark colour on focus.
private struct AddonRowValue: View {
    let text: String
    let isError: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.settingsRowIsFocused) private var rowFocused

    var body: some View {
        let value = SettingsTrailingValue(value: text, showsChevron: true)
        if isError {
            value.foregroundStyle(isFocused || rowFocused ? Theme.Palette.onFocusPlatter : Theme.Palette.error)
        } else {
            value
        }
    }
}

/// VoiceOver "Move up" / "Move down" actions, present only when `menuActions` allows them.
private struct MoveActions: ViewModifier {
    let allowed: [InstalledAddonsPane.RowAction]
    let move: (Int) -> Void

    func body(content: Content) -> some View {
        // Only the allowed moves exist as actions (no dead "Move up" on the first row).
        content.accessibilityActions {
            if allowed.contains(.moveUp) { Button("Move up") { move(-1) } }
            if allowed.contains(.moveDown) { Button("Move down") { move(1) } }
        }
    }
}
