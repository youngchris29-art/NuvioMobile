import SharedCore
import SwiftUI

/// A6: an optional per-add-on filter (the detail page's "Catalogs from this add-on").
nonisolated struct CatalogFilter: Equatable {
    let keys: Set<String>
    let addonTitle: String
}

/// Add-ons hub v2, A6: the catalogs page on the native Settings row kit. Switch each Home catalog
/// on or off and set the order of the Home rows. Used by the hub's Catalogs section and, per D3,
/// pushed from the Home Screen settings pane's "Catalogs" link row (same page, same model).
///
/// A native `List` of `Button` rows in `SettingsRowChrome`, like `InstalledAddonsPane`. Select
/// toggles the catalog; the long-press context menu carries Turn On/Off and the reorder. In the
/// hub (`allowsMoveMode`) reordering is A4's Move mode (Move, Up/Down, Select, Menu cancels); in
/// the Settings host the menu offers direct "Move up" / "Move down".
///
/// "Match add-ons order" is a ONE-SHOT action, not a switch: the shared
/// `HomeCatalogSettingsRepository` has no such preference (order is stored per catalog and SYNCED),
/// so the action reorders once through `moveByIndex`, collections kept in place, after a
/// confirmation (the order syncs to every device on the profile).
///
/// The page lists EVERY Home row in its true order, collections included. A collection pinned to
/// the top of Home cannot move: the repository re-pins it, so a move would change nothing.
///
/// Identifiers address rows by POSITION in the visible list (`addons_hub_catalog_<i>`, `_value`);
/// the focus keys are `matchKey`, `clearFilterKey`, `emptyKey` and `rowKey(catalogKey)`.
struct CatalogOrderView: View {
    @ObservedObject var model: SettingsViewModel
    /// The hub's shared content focus (keys below); nil in the Settings host (the view then uses
    /// its own private FocusState).
    var focus: FocusState<String?>.Binding? = nil
    /// Hub only: rows a hand-off is about to focus are scrolled into view first (lazy List).
    var scrollTarget: Binding<String?>? = nil
    /// Hub only: Move mode (A4's reducer). In the Settings host it is false and the context menu
    /// offers direct "Move up" / "Move down" instead.
    var allowsMoveMode = false
    var filter: CatalogFilter? = nil
    var onClearFilter: () -> Void = {}
    /// Hub only: tells the hub when Move mode starts/ends, so it can lock the sidebar, the tab
    /// bar and the rail like A4 does for Installed.
    var onMovingChange: (Bool) -> Void = { _ in }

    @FocusState private var ownFocus: String?
    @State private var toast: String?
    @State private var toastSerial = 0
    @State private var confirmingMatch = false
    @State private var moveMode = AddonMoveMode()
    @State private var moveDidStep = false

    nonisolated static let matchKey = "catalogs:match"
    nonisolated static let clearFilterKey = "catalogs:clearFilter"
    nonisolated static let emptyKey = "catalogs:empty"
    nonisolated static func rowKey(_ key: String) -> String { "catalog:" + key }

    // MARK: - Pure rules

    nonisolated enum RowAction: Hashable {
        /// `move` starts Move mode (hub); `moveUp`/`moveDown` are the Settings host's direct moves
        /// in the menu and VoiceOver's actions everywhere.
        case toggle(turnOn: Bool), move, moveUp, moveDown
    }

    /// The rows to show: everything, or (filtered) only the add-on's own catalogs in page order.
    nonisolated static func visibleRows(_ items: [HomeCatalogSettingsItem], filter: CatalogFilter?) -> [HomeCatalogSettingsItem] {
        guard let filter else { return items }
        return items.filter { !$0.isCollection && filter.keys.contains($0.key) }
    }

    /// The context menu's actions, in order: toggle first, then (only on the unfiltered page, for a
    /// row that is not pinned) Move mode when the hub allows it and the row can move at least one
    /// way, else the Settings host's direct moves per `canMove`. A filtered page shows a subset,
    /// so a position there means nothing.
    nonisolated static func menuActions(
        item enabled: Bool, isPinned: Bool, index: Int, orderedKeys: [String], pinnedKeys: Set<String>,
        allowsMoveMode: Bool, filtered: Bool
    ) -> [RowAction] {
        var actions: [RowAction] = [.toggle(turnOn: !enabled)]
        guard !filtered, !isPinned else { return actions }
        let up = canMove(index: index, direction: -1, orderedKeys: orderedKeys, pinnedKeys: pinnedKeys)
        let down = canMove(index: index, direction: 1, orderedKeys: orderedKeys, pinnedKeys: pinnedKeys)
        if allowsMoveMode {
            if up || down { actions.append(.move) }
        } else {
            if up { actions.append(.moveUp) }
            if down { actions.append(.moveDown) }
        }
        return actions
    }

    /// The VoiceOver reorder actions a row offers (none on a filtered page).
    nonisolated static func voiceOverMoves(
        index: Int, orderedKeys: [String], pinnedKeys: Set<String>, filtered: Bool
    ) -> [RowAction] {
        guard !filtered else { return [] }
        var moves: [RowAction] = []
        if canMove(index: index, direction: -1, orderedKeys: orderedKeys, pinnedKeys: pinnedKeys) { moves.append(.moveUp) }
        if canMove(index: index, direction: 1, orderedKeys: orderedKeys, pinnedKeys: pinnedKeys) { moves.append(.moveDown) }
        return moves
    }

    /// The caption: the add-on for a catalog, "Pinned collection" / "Collection" for a collection.
    nonisolated static func subtitle(of item: HomeCatalogSettingsItem) -> String {
        if item.isCollection {
            return item.isPinnedToTop ? String(localized: "Pinned collection") : String(localized: "Collection")
        }
        return item.addonName
    }

    /// The filter row's title.
    nonisolated static func filterLine(_ filter: CatalogFilter, count: Int) -> String {
        String(localized: "\(count) catalogs from \(filter.addonTitle)")
    }

    /// Whether the row at `index` can move one step in `direction` and change what the page shows:
    /// the neighbour must exist and must not be pinned to the top (the repository re-pins pinned
    /// collections), and a pinned row itself never moves.
    nonisolated static func canMove(index: Int, direction: Int, orderedKeys: [String], pinnedKeys: Set<String>) -> Bool {
        guard orderedKeys.indices.contains(index), !pinnedKeys.contains(orderedKeys[index]) else { return false }
        let target = index + direction
        guard orderedKeys.indices.contains(target) else { return false }
        return !pinnedKeys.contains(orderedKeys[target])
    }

    /// The focus key to restore after `key` moved by `direction`, from the list AFTER the move
    /// (the v1 chip layout; the row layout keeps one focus key per row, so the view no longer
    /// calls this).
    nonisolated static func moveLanding(key: String, direction: Int, orderedKeys: [String], pinnedKeys: Set<String>) -> String {
        guard let index = orderedKeys.firstIndex(of: key),
              canMove(index: index, direction: direction, orderedKeys: orderedKeys, pinnedKeys: pinnedKeys)
        else { return "card:\(key)" }
        return "\(direction < 0 ? "up" : "down"):\(key)"
    }

    // MARK: - Live state

    private var focusBinding: FocusState<String?>.Binding { focus ?? $ownFocus }

    /// The repository's current items, else this model's (as `moveUp`/`moveDown` read them).
    private func liveItems() -> [HomeCatalogSettingsItem] {
        let repoItems = (HomeCatalogSettingsRepository.shared.uiState.value_ as? HomeCatalogSettingsUiState)?.items ?? []
        return repoItems.isEmpty ? model.catalogs : repoItems
    }

    private func liveKeys() -> [String] { liveItems().map(\.key) }

    private func focusRowSoon(_ key: String) {
        DispatchQueue.main.async { focusBinding.wrappedValue = Self.rowKey(key) }
    }

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            list
                // Review A6-r1: torn down mid-move (a programmatic section change, an install
                // landing): the hub must not stay locked.
                .onDisappear {
                    if moveMode.isMoving {
                        moveMode.commit()
                        onMovingChange(false)
                    }
                    // Review VO-r2: also after a move has ended, its "Moved" / "Move cancelled" may
                    // still be waiting; it must not play over whatever replaces this pane.
                    HubAccessibility.invalidatePending()
                }
                .onChange(of: scrollTarget?.wrappedValue) { _, target in
                    guard let target, target.hasPrefix("catalog:") else { return }
                    proxy.scrollTo(String(target.dropFirst("catalog:".count)), anchor: .center)
                    scrollTarget?.wrappedValue = nil
                }
        }
    }

    private var list: some View {
        let items = model.catalogs
        let orderedKeys = items.map(\.key)
        let pinnedKeys = Set(items.filter(\.isPinnedToTop).map(\.key))
        let visible = Self.visibleRows(items, filter: filter)
        let moving = moveMode.isMoving
        return List {
            header
            if let filter {
                filterRow(filter, count: visible.count)
            }
            if filter == nil && !items.isEmpty {
                SettingsActionRow(
                    title: String(localized: "Match add-ons order"),
                    subtitle: String(localized: "Reorder Home rows to follow your add-ons")
                ) { confirmingMatch = true }
                    .focused(focusBinding, equals: Self.matchKey)
                    .disabled(moving)
                    .accessibilityIdentifier("addons_hub_catalogs_match")
            }
            if items.isEmpty {
                SettingsValueRow(
                    title: String(localized: "No catalogs yet"),
                    value: "",
                    subtitle: String(localized: "Install an add-on with catalogs first."),
                    focusable: true
                )
                .focused(focusBinding, equals: Self.emptyKey)
                .accessibilityIdentifier("addons_hub_catalogs_empty")
            }
            ForEach(Array(visible.enumerated()), id: \.element.key) { index, item in
                let fullIndex = orderedKeys.firstIndex(of: item.key) ?? index
                let isMoving = moveMode.isMoving(item.key)
                let isLocked = moving && !isMoving
                let actions = Self.menuActions(
                    item: item.enabled, isPinned: item.isPinnedToTop, index: fullIndex,
                    orderedKeys: orderedKeys, pinnedKeys: pinnedKeys,
                    allowsMoveMode: allowsMoveMode, filtered: filter != nil
                )
                let moves = Self.voiceOverMoves(
                    index: fullIndex, orderedKeys: orderedKeys, pinnedKeys: pinnedKeys, filtered: filter != nil
                )
                CatalogRow(
                    item: item, index: index, isMoving: isMoving, isLocked: isLocked,
                    actions: isMoving || isLocked ? [] : actions,
                    voiceOverMoves: isLocked ? [] : moves,
                    focus: focusBinding,
                    onSelect: {
                        if isMoving { commitMove(item.key) } else { model.toggleCatalog(item) }
                    },
                    onToggle: { model.toggleCatalog(item) },
                    onStartMove: { startMove(item, index: fullIndex) },
                    onMoveBy: { delta in
                        if isMoving {
                            step(delta < 0 ? .up : .down)
                        } else if delta < 0 {
                            model.moveUp(item)
                        } else {
                            model.moveDown(item)
                        }
                    }
                )
            }
        }
        .environment(\.settingsUsesNativeList, true)
        .scrollClipDisabled()
        // While a row is lifted every other row (and the sidebar, and the tab bar) is out of focus
        // reach, so Up/Down have no target and arrive here as move commands. Left/Right are
        // swallowed while moving.
        .onMoveCommand { direction in
            guard moveMode.isMoving else { return }
            switch direction {
            case .up: step(.up)
            case .down: step(.down)
            default: break
            }
        }
        // Menu cancels the move, but only while moving: at rest Menu must keep reaching the hub
        // (which routes it to the sidebar).
        .onExitCommand(perform: moving ? { cancelMove() } : nil)
        .background { TabBarFocusLock(active: moveMode.isMoving).frame(width: 0, height: 0) }
        // The lifted catalog left the list (a sync): end the mode.
        .onChange(of: model.catalogs.map(\.key)) { _, keys in
            if let key = moveMode.movingUrl, !keys.contains(key), !liveKeys().contains(key) {
                moveMode.commit()
                onMovingChange(false)
                HubAccessibility.invalidatePending()
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .alert("Match add-ons order?", isPresented: $confirmingMatch) {
            Button("Match") {
                let moves = model.matchCatalogsToAddonOrder()
                showToast(moves > 0
                    ? String(localized: "Catalogs now follow your add-ons order.")
                    : String(localized: "Already in add-ons order."))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Home rows will be reordered to follow your add-ons, on every device signed in to this profile.")
        }
        .accessibilityIdentifier("addons_hub_catalogs_root")
    }

    // MARK: - Header and filter

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Catalogs")
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .accessibilityIdentifier("addons_hub_catalogs_title")
            Text("Switch each catalog on or off and set the order of your Home rows. Collections appear where Home shows them.")
                .font(SettingsRowFont.subtitle)
                .foregroundStyle(.secondary)
        }
        .focusable(false)
    }

    private func filterRow(_ filter: CatalogFilter, count: Int) -> some View {
        Button(action: onClearFilter) {
            SettingsRowChrome {
                SettingsRowLabel(
                    title: Self.filterLine(filter, count: count),
                    subtitle: String(localized: "Show all catalogs")
                )
            } trailing: {
                SettingsTrailingValue(value: nil)
            }
        }
        .focused(focusBinding, equals: Self.clearFilterKey)
        .disabled(moveMode.isMoving)
        .accessibilityIdentifier("addons_hub_catalogs_filter")
    }

    // MARK: - Move mode

    private func startMove(_ item: HomeCatalogSettingsItem, index: Int) {
        guard allowsMoveMode else { return }
        let order = liveKeys()
        moveMode.start(manifestUrl: item.key, index: order.firstIndex(of: item.key) ?? index, order: order)
        moveDidStep = false
        onMovingChange(true)
        focusRowSoon(item.key)
        HubAccessibility.announceSoon(.started)
    }

    private func step(_ direction: AddonMoveMode.Direction) {
        guard let key = moveMode.movingUrl else { return }
        let items = liveItems()
        let order = items.map(\.key)
        let pinned = Set(items.filter(\.isPinnedToTop).map(\.key))
        guard let current = order.firstIndex(of: key),
              let target = moveMode.step(direction, currentIndex: current, count: order.count,
                                         now: ProcessInfo.processInfo.systemUptime),
              Self.canMove(index: current, direction: target - current, orderedKeys: order, pinnedKeys: pinned)
        else { return }
        let item = items[current]
        // Stage A review: only a step the repository actually applied counts, so a cancel never
        // "restores" over an order a sync changed underneath a rejected step.
        let stepped = target < current ? model.moveUp(item) : model.moveDown(item)
        if stepped { moveDidStep = true }
        focusRowSoon(key)
    }

    private func commitMove(_ key: String) {
        moveMode.commit()
        onMovingChange(false)
        focusRowSoon(key)
        HubAccessibility.announceSoon(.committed)
    }

    /// Menu while moving: puts the catalog back where it started (relative to the survivors), in
    /// one `moveByIndex`, only when a step actually happened.
    private func cancelMove() {
        let predecessors = moveMode.predecessors
        if let (key, _) = moveMode.cancel(currentOrder: liveKeys()) {
            // Stage A review: resolved by key inside the repository's atomic update (pinned rows
            // and a row pinned during its own move handled there).
            if moveDidStep { model.restoreCatalog(key: key, after: predecessors) }
            onMovingChange(false)
            focusRowSoon(key)
            HubAccessibility.announceSoon(.cancelled)
        }
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .background(Theme.Surface.overlay, in: Capsule())
                .padding(.bottom, Theme.Spacing.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("addons_hub_catalogs_toast")
        }
    }

    private func showToast(_ message: String) {
        toastSerial += 1
        let serial = toastSerial
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toastSerial == serial { withAnimation { toast = nil } }
        }
    }
}

// MARK: - Row

/// One catalog as a `Button` row. Select toggles it (or drops a lifted row); the long-press menu
/// and VoiceOver carry the rest.
private struct CatalogRow: View {
    let item: HomeCatalogSettingsItem
    let index: Int
    let isMoving: Bool
    let isLocked: Bool
    let actions: [CatalogOrderView.RowAction]
    let voiceOverMoves: [CatalogOrderView.RowAction]
    let focus: FocusState<String?>.Binding
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onStartMove: () -> Void
    let onMoveBy: (Int) -> Void

    private var statusText: String { item.enabled ? String(localized: "On") : String(localized: "Off") }

    var body: some View {
        Button(action: onSelect) {
            SettingsRowChrome {
                leading
            } trailing: {
                if isMoving {
                    movingBadge
                } else {
                    SettingsTrailingValue(value: statusText, showsChevron: false)
                        .accessibilityIdentifier("addons_hub_catalog_\(index)_value")
                }
            }
        }
        .focused(focus, equals: CatalogOrderView.rowKey(item.key))
        .disabled(isLocked)
        .contextMenu {
            ForEach(actions, id: \.self) { action in
                menuButton(action)
            }
        }
        .accessibilityLabel(item.displayTitle)
        .accessibilityValue(HubAccessibility.rowValue("\(statusText), \(CatalogOrderView.subtitle(of: item))", isMoving: isMoving))
        .accessibilityIdentifier("addons_hub_catalog_\(index)")
        .modifier(CatalogMoveActions(allowed: voiceOverMoves, move: onMoveBy))
    }

    private var leading: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(item.displayTitle)
                .font(SettingsRowFont.title)
                .lineLimit(1)
            Text(CatalogOrderView.subtitle(of: item))
                .font(SettingsRowFont.subtitle)
                .rowTextColor(secondary: true)
                .lineLimit(1)
            if !item.enabled {
                DisabledOnHomeLabel()
            }
        }
    }

    /// The lifted row's trailing badge.
    private var movingBadge: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "arrow.up.arrow.down")
            Text("Moving — Up or Down, then Select")
                .lineLimit(1)
        }
        .font(SettingsRowFont.subtitle)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("addons_move_badge")
    }

    @ViewBuilder
    private func menuButton(_ action: CatalogOrderView.RowAction) -> some View {
        switch action {
        case .toggle(let turnOn):
            Button(turnOn ? "Turn On" : "Turn Off", action: onToggle)
        case .move:
            Button("Move", action: onStartMove)
        case .moveUp:
            Button("Move up") { onMoveBy(-1) }
        case .moveDown:
            Button("Move down") { onMoveBy(1) }
        }
    }
}

/// VoiceOver "Move up" / "Move down" actions, present only when the rules allow them.
private struct CatalogMoveActions: ViewModifier {
    let allowed: [CatalogOrderView.RowAction]
    let move: (Int) -> Void

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if allowed.contains(.moveUp) { Button("Move up") { move(-1) } }
            if allowed.contains(.moveDown) { Button("Move down") { move(1) } }
        }
    }
}

/// "Disabled on Home" in the error tint at rest, joining the platter's dark label colour on focus
/// (an explicit red would stay red-on-white).
private struct DisabledOnHomeLabel: View {
    @Environment(\.settingsRowIsFocused) private var focused

    var body: some View {
        Text("Disabled on Home")
            .font(Theme.Font.caption)
            .foregroundStyle(focused ? Theme.Palette.onFocusPlatter : Theme.Palette.error)
    }
}
