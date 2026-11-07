import SharedCore
import SwiftUI

/// Add-ons hub v2, A2: the two-column Add-ons page that replaced `SourcesHubView` as the body of
/// `AddonsView`. Left: a `List` of sidebar `Button` rows (`HubSection`), on a Liquid Glass
/// container (D5). Right: the content column, with its own `NavigationStack` (D2), rebuilt per
/// section. One title, "Add-ons", above both columns (HIG Split views). `AddonsView` owns every
/// store (started and stopped on its stack) and the remove confirmation; this view observes them.
///
/// Layout is A0's variant (a): an `HStack` of two `.focusSection()`s. `NavigationSplitView`
/// collapses to one column inside the app's TabView on tvOS 27 (A0 spike, FA87 and the Living Room
/// box), so it is not used.
///
/// ## Focus graph (written before the code, per the tvOS skill's workflow)
///
/// **Entering the tab.** Default focus is the selected section's sidebar row
/// (`.defaultFocus($sidebarFocus, selected)`).
///
/// **Sidebar.** Up / Down walk the rows. Focus resting on a row for `selectionDwell` selects its
/// section (the tvOS Settings behaviour, no Select needed); a fast swipe through the list rebuilds
/// the content column once, at the end. `HubSection.refresh` is an action row: Select runs it,
/// focus never selects it. Right enters the content column.
///
/// **Focus memory (A0 finding 1).** The engine moves between the two columns geometrically: Left
/// from content row 3 landed on whatever sidebar row sat at that height and, because selection
/// follows focus, switched the section; Right from a sidebar row landed on the content row at that
/// height. Both columns therefore correct their LANDING, once, the way `SettingsRootView` does:
/// - focus arriving in the sidebar from outside it (content, tab bar, rail) lands on the SELECTED
///   section's row (`sidebarFocus` going nil → row X with X ≠ selected is rewritten to selected,
///   and that transient X never starts a selection);
/// - focus arriving in the content column from outside it lands on the row last focused in that
///   section (`lastContentFocus`), else the pane's first row (`firstContentKey`). Only panes that
///   tag their rows with `contentFocus` take part (today the Installed cards; the A6 panes join as
///   they move onto the kit). Untagged panes keep the engine's geometric landing.
///
/// **Push and Menu (A0 finding 3, D6).** A push inside the content column keeps focus in it; Menu
/// on a pushed page pops (the stack's own behaviour; A0 proved the return lands on the pushing
/// row in Tabs mode, and in Rail mode once `HiddenTabBarFocusBlocker` stopped re-resolving focus
/// on the push, A0 finding 2). Menu at the content column's ROOT moves focus to the selected
/// sidebar row (`.onExitCommand` on the column root: pushed pages are stack destinations, not
/// descendants, so their Menu still pops). Menu in the sidebar leaves the page: the tab bar in
/// Tabs mode (no handler), the rail in Rail mode (the sidebar's own `.railMenuReveal()`; on the
/// whole view it caught Menu on pushed pages, which are descendants of it).
struct AddonsHubSplitView: View {
    @ObservedObject var model: AddonsViewModel
    @ObservedObject var settings: SettingsViewModel
    @ObservedObject var debrid: DebridViewModel
    @ObservedObject var plugins: PluginsViewModel
    @ObservedObject var badges: BadgeSettingsViewModel
    @ObservedObject var trakt: TraktViewModel
    @ObservedObject var simkl: SimklViewModel
    @Binding var pendingRemoval: ManagedAddon?
    @Binding var removal: RemovalIntent?

    /// The section shown on the right, restored per launch (A1 `HubSection.resolved`).
    @SceneStorage("addons.section") private var storedSection = HubSection.installed.rawValue
    @State private var selected: HubSection = .installed
    @State private var didRestoreSection = false
    @FocusState private var sidebarFocus: HubSection?
    /// Shared by every pane that takes part in focus memory; keys are pane-defined strings
    /// (`card:<url>`, `toggle:<url>`, … for the Installed cards).
    @FocusState private var contentFocus: String?
    @State private var lastContentFocus: [HubSection: String] = [:]
    /// A focus write this view made on purpose (after a move, an install, a removal, a Select on
    /// a sidebar row): the landing corrections must let it through, not treat it as a geometric
    /// entry (review r1).
    @State private var deliberateContent: String?
    @State private var deliberateSidebar: HubSection?
    @State private var dwell: Task<Void, Never>?

    // Sheets, toasts and install/removal bookkeeping, carried over from v1's `SourcesHubView`
    // until A3–A6 move them onto the panes.
    @State private var showInstall = false
    /// The content column's stack (D2): an add-on's detail page is pushed here, not a sheet.
    @State private var contentPath: [HubAddonRoute] = []
    @State private var focusNewCardAfterInstall = false
    @State private var installHandledSerial: Int?
    @State private var toast: String?
    @State private var toastSerial = 0
    @State private var confirmingTraktDisconnect = false
    @State private var confirmingSimklDisconnect = false
    @State private var debridDisconnectId: String?

    /// How long focus must rest on a sidebar row before its section is selected.
    static let selectionDwell: Duration = .milliseconds(150)
    /// Fixed sidebar width (≈ 1/3 of the 1920 pt screen, padding included).
    static let sidebarWidth: CGFloat = 560

    struct RemovalIntent {
        let url: String
        let name: String
        let nextUrl: String?
        let previousUrl: String?
    }

    private var summary: AddonsViewModel.HubSummary {
        AddonsViewModel.summary(
            addons: model.addons,
            catalogs: settings.catalogs,
            debridConnectedNames: debrid.providers.filter { debrid.isConnected($0.id) }.map(\.displayName),
            pluginsEnabled: plugins.pluginsEnabled,
            pluginRepositories: plugins.repositories.count,
            pluginProviders: plugins.scrapers.count
        )
    }

    var body: some View {
        let summary = summary
        let visible = HubSection.visible(summary: summary, phoneEnabled: DebugConfig.showsPhoneManagement)
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Add-ons")
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Spacing.screen)
                .padding(.top, Theme.Spacing.lg)
                .accessibilityIdentifier("addons_hub_title")
            HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                sidebar(visible: visible, summary: summary)
                    .frame(width: Self.sidebarWidth)
                    .padding(.leading, HubRailClearance.extraLeading)
                    .focusSection()
                contentColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .focusSection()
            }
            .padding(.leading, Theme.Spacing.screen)
            .padding(.trailing, Theme.Spacing.lg)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("addons_split_root")
        .overlay(alignment: .bottom) { toastView }
        .onAppear { restoreSection(visible: visible) }
        .onChange(of: visible) { _, now in
            // A section that disappears (Plugins switched off) falls back to Installed.
            if !now.contains(selected) { select(.installed) }
        }
        .onChange(of: sidebarFocus) { old, new in sidebarFocusChanged(from: old, to: new) }
        .onChange(of: contentFocus) { old, new in contentFocusChanged(from: old, to: new) }
        .sheet(isPresented: $showInstall, onDismiss: focusAfterInstall) {
            AddonInstallSheet(model: model, handledSerial: installHandledSerial)
        }
        .onChange(of: model.refreshOutcomeSerial) { _, _ in
            guard let outcome = model.lastRefreshOutcome else { return }
            showToast(outcome.failed == 0
                ? String(localized: "Refreshed \(outcome.succeeded).")
                : String(localized: "Refreshed \(outcome.succeeded), \(outcome.failed) failed."))
        }
        .onChange(of: model.installOutcome) { _, outcome in
            guard let outcome else { return }
            installHandledSerial = AddonInstallSheet.serial(of: outcome)
            if showInstall {
                if case .installed = outcome { focusNewCardAfterInstall = true }
                return
            }
            switch outcome {
            case .installed(let name, _):
                showToast(String(localized: "Installed \(name)."))
                focusNewestCard()
            case .failed: showToast(String(localized: "Couldn't install that add-on."))
            }
        }
        .onChange(of: model.addons.map(\.manifestUrl)) { _, urls in handleRemoval(urls) }
        // H9 (P4 §2.5): a rail exit back to the hub takes the default hand-off; the sidebar's
        // landing correction then puts focus on the selected section's row.
        .railReturnRoute {
            RailReturnRoute(name: "addons", capture: {}, restore: { false }, vetoesLeftArm: { false })
        }
    }

    // MARK: - Sidebar

    private func sidebar(visible: [HubSection], summary: AddonsViewModel.HubSummary) -> some View {
        List {
            ForEach(visible, id: \.self) { section in
                Button {
                    activate(section)
                } label: {
                    SettingsRowChrome {
                        SettingsRowLabel(title: section.title, systemImage: section.systemImage)
                    } trailing: {
                        sidebarTrailing(section, summary: summary)
                    }
                }
                .focused($sidebarFocus, equals: section)
                .listRowBackground(selectedMarker(section))
                .accessibilityLabel(Text(section.title))
                .accessibilityValue(Text(sidebarAccessibilityValue(section, summary: summary)))
                .accessibilityAddTraits(section == selected ? .isSelected : [])
                .accessibilityIdentifier("addons_sidebar_\(section.rawValue)")
            }
        }
        .defaultFocus($sidebarFocus, selected)
        // D6: Menu in the sidebar opens the rail in Rail mode (nothing in Tabs mode: the system
        // takes focus to the tab bar). Here and not on `AddonsView`: pushed pages in the content
        // column are descendants of that view, and must pop on Menu.
        .railMenuReveal()
        .scrollClipDisabled()
        .environment(\.settingsUsesNativeList, true)
        .padding(.vertical, Theme.Spacing.md)
        .padding(.horizontal, Theme.Spacing.xs)
        .background { HubSidebarSurface() }
    }

    @ViewBuilder
    private func sidebarTrailing(_ section: HubSection, summary: AddonsViewModel.HubSummary) -> some View {
        if section == .refresh {
            if model.isRefreshingAny {
                ProgressView().controlSize(.small)
            } else if model.lastRefreshedAt != nil {
                // The named relative stamp does not tick by itself (v1 note): a 30 s timeline.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    SettingsTrailingValue(value: refreshStamp, showsChevron: false)
                }
            } else {
                SettingsTrailingValue(value: String(localized: "Not refreshed yet"), showsChevron: false)
            }
        } else {
            SettingsTrailingValue(value: section.trailingValue(summary: summary), showsChevron: false)
        }
    }

    /// The row's value for VoiceOver and the legs; the refresh row reads its live state.
    private func sidebarAccessibilityValue(_ section: HubSection, summary: AddonsViewModel.HubSummary) -> String {
        guard section == .refresh else { return section.trailingValue(summary: summary) ?? "" }
        if model.isRefreshingAny { return String(localized: "Refreshing…") }
        return refreshStamp ?? String(localized: "Not refreshed yet")
    }

    private var refreshStamp: String? {
        model.lastRefreshedAt.map { String(localized: "Updated \($0.formatted(.relative(presentation: .named)))") }
    }

    /// The selected section's row keeps a faint platter while focus is elsewhere, so the sidebar
    /// says which section the right column shows.
    @ViewBuilder
    private func selectedMarker(_ section: HubSection) -> some View {
        if section == selected && sidebarFocus == nil {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Palette.textPrimary.opacity(0.10))
        } else {
            Color.clear
        }
    }

    // MARK: - Content column

    private var contentColumn: some View {
        NavigationStack(path: $contentPath) {
            // A container stack, so the column's identifier never overwrites the pane's own root
            // identifier (`addons_hub_catalogs_root` was lost, A2 leg).
            VStack(spacing: 0) {
                HubContentColumn(
                    section: selected,
                    model: model, settings: settings, debrid: debrid, plugins: plugins, badges: badges,
                    trakt: trakt, simkl: simkl,
                    contentFocus: $contentFocus,
                    confirmingTraktDisconnect: $confirmingTraktDisconnect,
                    confirmingSimklDisconnect: $confirmingSimklDisconnect,
                    debridDisconnectId: $debridDisconnectId,
                    onOpenAddon: { contentPath.append(HubAddonRoute(manifestUrl: $0.manifestUrl)) },
                    onMove: move,
                    onRemove: { requestRemoval($0, fromDetail: false) },
                    onInstall: { showInstall = true }
                )
                // A second child: a one-child stack forwarded its identifier to the pane's
                // ScrollView (A2 probe), so the column needs to be a real container.
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
            // D6: Menu at the column root goes to the sidebar first. Pushed pages are stack
            // destinations, not descendants of this view, so Menu on them still pops.
            .onExitCommand { handOffSidebar(selected) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("addons_content_\(selected.rawValue)")
            .navigationDestination(for: HubAddonRoute.self) { route in
                // v1's detail view as a pushed page until A5's `AddonDetailPane`; it reads the
                // add-on live and keeps a focusable Refresh button in every state (BUG-47 rule).
                if let addon = model.addons.first(where: { $0.manifestUrl == route.manifestUrl }) {
                    AddonDetailSheet(model: model, snapshot: addon, isReadOnly: model.isReadOnly) {
                        requestRemoval(addon, fromDetail: true)
                    }
                    .accessibilityIdentifier("addons_detail_root")
                } else {
                    // Removed elsewhere (sync) while open: nothing to show, go back.
                    Color.clear.onAppear { contentPath.removeAll() }
                }
            }
        }
        // A new section starts the column over: a fresh stack (anything pushed is dropped, value
        // links included) and fresh pane state.
        .id(selected)
        .alert("Disconnect Trakt?", isPresented: $confirmingTraktDisconnect) {
            Button("Disconnect", role: .destructive) { trakt.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scrobbling stops and this Apple TV's Trakt access token is revoked. Your Trakt history is untouched.")
        }
        .alert("Disconnect Simkl?", isPresented: $confirmingSimklDisconnect) {
            Button("Disconnect", role: .destructive) { simkl.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scrobbling stops and this Apple TV's Simkl authorization is cleared. Your Simkl history is untouched.")
        }
        .alert(
            "Disconnect debrid provider?",
            isPresented: Binding(get: { debridDisconnectId != nil }, set: { if !$0 { debridDisconnectId = nil } })
        ) {
            Button("Disconnect", role: .destructive) {
                if let id = debridDisconnectId { debrid.disconnect(id) }
                debridDisconnectId = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this provider's key from this profile. Streams will no longer resolve through it.")
        }
    }

    // MARK: - Selection and focus memory

    private func restoreSection(visible: [HubSection]) {
        guard !didRestoreSection else { return }
        didRestoreSection = true
        let restored = HubSection.resolved(raw: storedSection, visible: visible)
        if restored != selected { selected = restored }
    }

    private func select(_ section: HubSection) {
        dwell?.cancel()
        dwell = nil
        guard !section.isAction, section != selected else { return }
        contentPath.removeAll()
        selected = section
        storedSection = section.rawValue
    }

    /// Select on a sidebar row: an action row runs; a section row selects at once (no dwell) and
    /// moves focus into its content.
    private func activate(_ section: HubSection) {
        switch section {
        case .refresh:
            let enabled = model.addons.filter { $0.enabled }.count
            showToast(enabled == 0
                ? String(localized: "Nothing to refresh.")
                : String(localized: "Refreshing add-ons (\(enabled))…"))
            model.refreshAll()
        default:
            select(section)
            // Panes that take part in focus memory get focus handed over; the interim Catalogs,
            // Debrid and Plugins hosts join when A6 moves them onto the kit (Right enters them).
            if let key = contentLandingTarget(for: section) {
                DispatchQueue.main.async { handOffContent(key) }
            }
        }
    }

    private func sidebarFocusChanged(from old: HubSection?, to new: HubSection?) {
        guard let new else {
            // Focus left the sidebar: a pending selection must not fire after the fact.
            dwell?.cancel()
            dwell = nil
            return
        }
        if new == deliberateSidebar {
            deliberateSidebar = nil
            if !new.isAction, new != selected { select(new) }
            return
        }
        if old == nil, new != selected {
            // Entering from outside (content column, tab bar, rail): land on the selected row.
            // The transient landing row never starts a selection.
            sidebarFocus = selected
            return
        }
        guard !new.isAction, new != selected else {
            dwell?.cancel()
            dwell = nil
            return
        }
        dwell?.cancel()
        dwell = Task { @MainActor in
            try? await Task.sleep(for: Self.selectionDwell)
            guard !Task.isCancelled, sidebarFocus == new else { return }
            select(new)
        }
    }

    private func contentFocusChanged(from old: String?, to new: String?) {
        guard let new else { return }
        if new == deliberateContent {
            deliberateContent = nil
            lastContentFocus[selected] = new
            return
        }
        if old == nil, let target = contentLandingTarget(for: selected), target != new {
            // Entering from outside (the sidebar, the tab bar): land on the remembered row.
            contentFocus = target
            return
        }
        lastContentFocus[selected] = new
    }

    /// A no-op write (focus already there) fires no change, so it must not leave a stale flag.
    private func handOffContent(_ key: String) {
        guard contentFocus != key else { return }
        deliberateContent = key
        contentFocus = key
    }

    private func handOffSidebar(_ section: HubSection) {
        guard sidebarFocus != section else { return }
        deliberateSidebar = section
        sidebarFocus = section
    }

    /// Where focus should land when it enters `section`'s content: the row last focused there if
    /// it still exists, else the pane's first row; nil for panes that do not take part.
    private func contentLandingTarget(for section: HubSection) -> String? {
        let keys = contentKeys(for: section)
        if let remembered = lastContentFocus[section] {
            if keys.contains(remembered) { return remembered }
            // Review r2: a remembered control that is now disabled (moved to an end, or read-only)
            // falls back to that add-on's card while the add-on is still listed.
            if let url = remembered.split(separator: ":", maxSplits: 1).last.map(String.init),
               keys.contains("card:" + url) {
                return "card:" + url
            }
        }
        return Self.firstContentKey(section: section, addons: model.addons)
    }

    /// Every focus key the pane for `section` can hold right now (Installed: each card's ENABLED
    /// controls, by the card's own rules; Install: its row).
    private func contentKeys(for section: HubSection) -> Set<String> {
        switch section {
        case .install: return [Self.installOpenKey]
        case .installed: return Self.installedFocusKeys(urls: model.addons.map(\.manifestUrl), isReadOnly: model.isReadOnly)
        default: return []
        }
    }

    /// The Installed cards' focusable keys: every card's name area; with editing allowed, its
    /// toggle and Remove, Up except on the first card and Down except on the last
    /// (`AddonCardView`'s disabled rules).
    nonisolated static func installedFocusKeys(urls: [String], isReadOnly: Bool) -> Set<String> {
        var keys = Set<String>()
        for (index, url) in urls.enumerated() {
            keys.insert("card:" + url)
            guard !isReadOnly else { continue }
            keys.insert("toggle:" + url)
            keys.insert("remove:" + url)
            if index > 0 { keys.insert("up:" + url) }
            if index < urls.count - 1 { keys.insert("down:" + url) }
        }
        return keys
    }

    /// The Install pane's one row.
    nonisolated static let installOpenKey = "install:open"

    /// The first row of a taking-part pane (Installed: the first card; Install: its row), else nil.
    nonisolated static func firstContentKey(section: HubSection, addons: [ManagedAddon]) -> String? {
        switch section {
        case .installed: return addons.first.map { "card:" + $0.manifestUrl }
        case .install: return installOpenKey
        default: return nil
        }
    }

    // MARK: - Reorder, removal and install (v1 logic, keyed on `contentFocus`)

    /// Moves the card, then puts focus back on the same control of the moved card; at an end the
    /// control is disabled, so focus goes to the card's name area (v1 `SourcesHubView.move`).
    private func move(_ addon: ManagedAddon, index: Int, by delta: Int) {
        let count = model.addons.count
        guard AddonsViewModel.moveTarget(index: index, by: delta, count: count) != nil else { return }
        model.move(manifestUrl: addon.manifestUrl, by: delta)
        DispatchQueue.main.async {
            let repoList = (AddonRepository.shared.uiState.value_ as? AddonsUiState)?.addons ?? []
            let list = repoList.isEmpty ? model.addons : repoList
            let newIndex = list.firstIndex { $0.manifestUrl == addon.manifestUrl } ?? (index + delta)
            let atEnd = delta < 0 ? newIndex <= 0 : newIndex >= list.count - 1
            let key = atEnd ? "card" : (delta < 0 ? "up" : "down")
            handOffContent("\(key):\(addon.manifestUrl)")
        }
    }

    /// Raises `AddonsView`'s confirm alert. From the pushed detail page the page pops first, so
    /// focus returns to the card list the removal acts on.
    private func requestRemoval(_ addon: ManagedAddon, fromDetail: Bool) {
        let urls = model.addons.map(\.manifestUrl)
        let at = urls.firstIndex(of: addon.manifestUrl)
        removal = RemovalIntent(
            url: addon.manifestUrl,
            name: AddonsViewModel.displayTitle(addon),
            nextUrl: at.flatMap { $0 + 1 < urls.count ? urls[$0 + 1] : nil },
            previousUrl: at.flatMap { $0 > 0 ? urls[$0 - 1] : nil }
        )
        if fromDetail { contentPath.removeAll() }
        pendingRemoval = addon
    }

    /// Once a requested removal has left the list: toast it and focus the card that took its
    /// place (the previous one at the end; the Install row when the list is empty).
    private func handleRemoval(_ urls: [String]) {
        guard let intent = removal, !urls.contains(intent.url) else { return }
        removal = nil
        showToast(String(localized: "Removed \(intent.name)."))
        let target = [intent.nextUrl, intent.previousUrl].compactMap { $0 }.first(where: urls.contains)
        DispatchQueue.main.async {
            if let target {
                handOffContent("card:" + target)
            } else {
                handOffSidebar(.install)
            }
        }
    }

    private func focusAfterInstall() {
        guard focusNewCardAfterInstall else { return }
        focusNewCardAfterInstall = false
        focusNewestCard()
    }

    /// After an install: the Installed section, focus on the new card (else the last card).
    private func focusNewestCard() {
        select(.installed)
        DispatchQueue.main.async {
            let installed = model.lastInstalledManifestUrl.flatMap { url in
                model.addons.first { AddonManifestURL.isSameManifest($0.manifestUrl, url) }
            }
            if let card = installed ?? model.addons.last {
                handOffContent("card:" + card.manifestUrl)
            } else {
                handOffSidebar(.install)
            }
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
                .accessibilityIdentifier("addons_hub_toast")
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

// MARK: - Content column

/// A pushed add-on detail page in the content column (D2).
struct HubAddonRoute: Hashable {
    let manifestUrl: String
}

/// The right column's root for one section. A2 hosts the v1 pieces as interim content; A3 (the
/// Installed pane), A5 (detail) and A6 (Catalogs, Debrid, Plugins, Install) replace them.
private struct HubContentColumn: View {
    let section: HubSection
    @ObservedObject var model: AddonsViewModel
    @ObservedObject var settings: SettingsViewModel
    @ObservedObject var debrid: DebridViewModel
    @ObservedObject var plugins: PluginsViewModel
    @ObservedObject var badges: BadgeSettingsViewModel
    @ObservedObject var trakt: TraktViewModel
    @ObservedObject var simkl: SimklViewModel
    let contentFocus: FocusState<String?>.Binding
    @Binding var confirmingTraktDisconnect: Bool
    @Binding var confirmingSimklDisconnect: Bool
    @Binding var debridDisconnectId: String?
    let onOpenAddon: (ManagedAddon) -> Void
    let onMove: (ManagedAddon, Int, Int) -> Void
    let onRemove: (ManagedAddon) -> Void
    let onInstall: () -> Void

    var body: some View {
        switch section {
        case .installed:
            installed
        case .catalogs:
            CatalogOrderView(model: settings)
        case .debrid:
            kitList {
                ServicesSettingsPane(
                    trakt: trakt, simkl: simkl, debrid: debrid,
                    confirmingTraktDisconnect: $confirmingTraktDisconnect,
                    confirmingSimklDisconnect: $confirmingSimklDisconnect,
                    debridDisconnectId: $debridDisconnectId
                )
            }
        case .plugins:
            kitList { SourcesSettingsPane(model: settings, plugins: plugins, badges: badges) }
        case .install:
            kitList {
                SettingsActionRow(
                    title: String(localized: "Install add-on"),
                    subtitle: String(localized: "From a manifest URL"),
                    systemImage: "plus.circle.fill",
                    action: onInstall
                )
                .focused(contentFocus, equals: AddonsHubSplitView.installOpenKey)
                .accessibilityIdentifier("addons_install_open")
            }
        case .refresh, .phone:
            kitList {
                SettingsValueRow(title: String(localized: "Manage from phone"), value: String(localized: "Coming in a later beta"), focusable: true)
            }
        }
    }

    private func kitList<Rows: View>(@ViewBuilder _ rows: () -> Rows) -> some View {
        List { rows() }
            .scrollClipDisabled()
            .environment(\.settingsUsesNativeList, true)
    }

    /// Interim Installed content: v1's cards, focus keys shared with the split view's memory.
    private var installed: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if !model.isInitialized { ProgressView() }
                if model.isInitialized && model.addons.isEmpty {
                    Text("No add-ons installed. Install one to get started.")
                        .font(Theme.Font.body).foregroundStyle(Theme.Palette.textSecondary)
                        .accessibilityIdentifier("addons_hub_empty")
                }
                if model.isReadOnly {
                    Text("This profile uses the primary profile's add-ons. Manage them there.")
                        .font(Theme.Font.body).foregroundStyle(Theme.Palette.textSecondary)
                        .accessibilityIdentifier("addons_hub_readonly")
                }
                ForEach(Array(model.addons.enumerated()), id: \.element.manifestUrl) { index, addon in
                    AddonCardView(
                        addon: addon,
                        index: index,
                        count: model.addons.count,
                        isReadOnly: model.isReadOnly,
                        focus: contentFocus,
                        onOpen: { onOpenAddon(addon) },
                        onToggle: { model.setEnabled(addon, !addon.enabled) },
                        onMoveUp: { onMove(addon, index, -1) },
                        onMoveDown: { onMove(addon, index, 1) },
                        onRemove: { onRemove(addon) },
                        stalledUrls: model.stalledUrls
                    )
                }
            }
            .padding(.vertical, Theme.Spacing.md)
            .padding(.horizontal, Theme.Spacing.lg)
        }
        .scrollClipDisabled()
    }
}

// MARK: - Sidebar surface and the rail clearance knob

/// D5: Liquid Glass on the sidebar container only; the content column stays flat (HIG Materials:
/// glass is for the control layer). `HubRailClearance` can swap it for the flat surface while the
/// rail is visible.
private struct HubSidebarSurface: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 36, style: .continuous)
        if HubRailClearance.flatSidebar {
            shape.fill(Theme.Palette.surface)
        } else {
            shape.fill(Color.clear).glassEffect(.regular, in: shape)
        }
    }
}

/// A0: with the rail Always Visible its pill sits flush against the sidebar glass. Two candidate
/// treatments are wired for Christian's pick at the A2 device check (`-debug.hubRailClearance
/// spacing|flat`, DEBUG only); the default keeps the designed layout until he chooses. Both are
/// inert outside Rail mode with a reserved width.
enum HubRailClearance {
    private static var applies: Bool { NavigationChrome.isRail() && NavigationChrome.reservesWidth() }

    private static var choice: String {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "debug.hubRailClearance") ?? ""
        #else
        return ""
        #endif
    }

    /// Extra leading space before the sidebar ("spacing").
    static var extraLeading: CGFloat { applies && choice == "spacing" ? Theme.Spacing.lg : 0 }

    /// The flat surface instead of glass ("flat").
    static var flatSidebar: Bool { applies && choice == "flat" }
}
