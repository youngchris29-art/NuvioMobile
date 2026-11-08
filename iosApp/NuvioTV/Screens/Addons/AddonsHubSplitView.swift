import Combine
import SharedCore
import SwiftUI

/// Add-ons hub v2, A2: the two-column Add-ons page that replaced v1's card hub (deleted in A7) as the body of
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
    @Binding var pendingRemoval: ManagedAddon?
    @Binding var removal: RemovalIntent?

    /// The section shown on the right, restored per launch (A1 `HubSection.resolved`).
    @SceneStorage("addons.section") private var storedSection = HubSection.installed.rawValue
    @State private var selected: HubSection = .installed
    @State private var didRestoreSection = false
    @FocusState private var sidebarFocus: HubSection?
    /// C5: whether the Add-ons tab is selected (requested sections wait for it).
    @ObservedObject private var tabActivity = AddonsTabActivity.shared
    /// Shared by every pane that takes part in focus memory; keys are pane-defined strings
    /// (`InstalledAddonsPane.rowKey` for the Installed rows, `CatalogOrderView`'s keys for Catalogs, `InstallAddonPane.fieldKey` for Install).
    @FocusState private var contentFocus: String?
    @State private var lastContentFocus: [HubSection: String] = [:]
    /// A focus write this view made on purpose (after a move, an install, a removal, a Select on
    /// a sidebar row): the landing corrections must let it through, not treat it as a geometric
    /// entry (review r1).
    @State private var deliberateContent: String?
    @State private var deliberateSidebar: HubSection?
    /// The Installed row about to be focused (A3-r1): the pane scrolls it into view first.
    @State private var installedScrollTarget: String?
    /// A4: the Installed pane's Move mode.
    @State private var moveMode = AddonMoveMode()
    /// A4 review r2: when the last move ended (uptime), for the sidebar-grab check.
    @State private var moveEndedAt: TimeInterval?
    /// A4: the sidebar's default focus is suppressed while moving and for a moment after, so
    /// re-enabling the sidebar does not pull focus off the row (seen on the box).
    @State private var suppressSidebarDefaultFocus = false
    /// A6: the focus key a move ended on (an Installed row or a Catalogs row), handed back if the
    /// re-enabled sidebar grabs focus inside `sidebarGrabWindow`.
    @State private var lastMovedKey: String?
    /// Review A4-r4: whether a step of the current move actually moved the add-on; a cancel with
    /// no step restores nothing (a sync may have reordered the list meanwhile).
    @State private var moveDidStep = false
    @State private var dwell: Task<Void, Never>?
    @Environment(\.navigationChrome) private var navigationChrome

    // Toasts, the Catalogs filter and install/removal bookkeeping.
    /// A6: the Catalogs section's per-add-on filter (the detail page's "Catalogs from this
    /// add-on"); cleared on leaving the section or with the pane's "Show all" row.
    /// Review A6-r3: the filter holds the add-on's URL; its keys and title are derived on every
    /// render (`catalogFilter`), so a refresh or an ownership change never leaves it stale.
    @State private var catalogFilterUrl: String?
    /// A6: the Catalogs pane has a row lifted in Move mode (it owns the mode; the hub adds the
    /// sidebar, tab bar and rail locks).
    @State private var catalogsMoving = false
    @State private var catalogsScrollTarget: String?
    /// Stage A review: the Install pane's URL draft lives here, so leaving the section (the pane
    /// is rebuilt per section) does not drop a half-typed keyed URL. Cleared after an install.
    @State private var installDraft = ""
    /// The content column's stack (D2): an add-on's detail page is pushed here, not a sheet.
    @State private var contentPath: [HubAddonRoute] = []
    /// A5 device check: the next pop is the hub's own (Move, Remove, a section change, a removed
    /// add-on), not the user's Menu, so it does not reclaim the pushing row.
    @State private var programmaticPop = false
    /// A5 device check: the row a user's Menu pop returns to, and when the pop happened (a sidebar
    /// landing inside `popGrabWindow` is the engine's fallback, handed back to the row).
    @State private var popReturnUrl: String?
    @State private var poppedAt: TimeInterval?
    /// Review A5-r3: the add-on the detail page's Move will lift once the pop settles; any push,
    /// section change, focus on the sidebar or leaving the hub in between cancels it.
    @State private var pendingLiftUrl: String?
    @State private var installHandledSerial: Int?
    @State private var toast: String?
    @State private var toastSerial = 0
    @State private var debridDisconnectId: String?

    /// A4 review r2: a sidebar landing within this long after a move ends is the sidebar's own
    /// re-enable grab, not a user's Left (a person cannot press that fast after Select / Menu).
    nonisolated static let sidebarGrabWindow: TimeInterval = 0.12

    /// The Add-ons tab's selection value (`MainTabView`, the rail's per-tab scroll map).
    static let railTabIndex = 3
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
                    .disabled(isMovingAny)
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
        // A4: in Tabs mode the visible tab bar is the one focus target left while an add-on is
        // lifted; lock it so Up stays a move command.
        .background { TabBarFocusLock(active: isMovingAny).frame(width: 0, height: 0) }
        .onChange(of: model.addons.map(\.manifestUrl)) { _, urls in
            // The lifted add-on went away (sync, another device): end the mode.
            if let url = moveMode.movingUrl, !urls.contains(url) { endMoveBecauseRemoved() }
        }
        .onAppear {
            restoreSection(visible: visible)
            showRequestedSection(visible: visible)
        }
        // C2: a request while the hub is mounted (Settings' "Manage from phone" row).
        .onReceive(NotificationCenter.default.publisher(for: AddonsHubRequests.notification)) { _ in
            showRequestedSection(visible: visible)
        }
        // C5 device note: the request arrives while the Settings tab is still on screen, so focus
        // set then is dropped and the tab switch leaves it on the rail. Hand it to the section's
        // sidebar row once the Add-ons tab is the selected one.
        .onReceive(tabActivity.$isActive.removeDuplicates()) { active in
            // `$isActive` publishes before the stored value changes, so pass the new value.
            guard active else { return }
            showRequestedSection(visible: visible, tabActive: true)
        }
        // Review A5-r3: leaving the hub cancels a detail page's pending Move lift.
        .onDisappear {
            pendingLiftUrl = nil
            HubAccessibility.invalidatePending()
        }
        .onChange(of: visible) { _, now in
            // A section that disappears (Plugins switched off) falls back to Installed.
            if !now.contains(selected) { select(.installed) }
        }
        .onChange(of: sidebarFocus) { old, new in sidebarFocusChanged(from: old, to: new) }
        .onChange(of: contentPath) { old, new in contentPathChanged(from: old, to: new) }
        .onChange(of: contentFocus) { old, new in contentFocusChanged(from: old, to: new) }
        .onChange(of: model.refreshOutcomeSerial) { _, _ in
            guard let outcome = model.lastRefreshOutcome else { return }
            showToast(outcome.failed == 0
                ? String(localized: "Refreshed \(outcome.succeeded).")
                : String(localized: "Refreshed \(outcome.succeeded), \(outcome.failed) failed."))
        }
        .onChange(of: model.installOutcome) { _, outcome in
            guard let outcome else { return }
            // A6: the inline Install pane shows its own status modal (and its Done lands on the new
            // row); a result that arrives while another section is showing is toasted here.
            // Stage A review: a landed install clears the draft even when the pane is not showing.
            if case .installed = outcome { installDraft = "" }
            if selected == .install { return }
            installHandledSerial = InstallFlow.serial(of: outcome)
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
            // A4: while an add-on is lifted a Left must not arm the rail (Left is swallowed).
            // A8 device check: with the default hand-off (`restore` false) the rail's own focus write
            // came after the hub's landing correction and left focus on the TOP sidebar row
            // (Installed) while another section was selected. The hub now restores focus onto the
            // selected section's row itself; the rail verifies 0.5 s later and falls back to its
            // default hand-off only if focus never left it.
            RailReturnRoute(name: "addons", capture: {}, restore: {
                handOffSidebar(selected)
                return true
            }, vetoesLeftArm: { isMovingAny })
        }
    }

    // MARK: - Sidebar

    private func sidebar(visible: [HubSection], summary: AddonsViewModel.HubSummary) -> some View {
        List {
            ForEach(visible, id: \.self) { section in
                if section == .refresh {
                    // Review VO-r1: the refresh row's spoken label carries the relative stamp, so it
                    // is rebuilt on the same 30 s timeline as the visible stamp.
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        sidebarRow(section, summary: summary)
                    }
                } else {
                    sidebarRow(section, summary: summary)
                }
            }
        }
        .defaultFocus($sidebarFocus, suppressSidebarDefaultFocus ? nil : selected)
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

    /// One sidebar row (a `Button` on the row kit).
    private func sidebarRow(_ section: HubSection, summary: AddonsViewModel.HubSummary) -> some View {
        Button {
            activate(section)
        } label: {
            SettingsRowChrome {
                if section == .refresh {
                    refreshRowLabel(section)
                } else {
                    SettingsRowLabel(title: section.title, systemImage: section.systemImage)
                }
            } trailing: {
                sidebarTrailing(section, summary: summary)
            }
        }
        .focused($sidebarFocus, equals: section)
        .listRowBackground(selectedMarker(section))
        // Christian's VoiceOver check (2026-11-08): the value and the selected trait were not
        // spoken, so the label carries them (the value stays for the UI legs).
        .accessibilityLabel(Text(HubAccessibility.sidebarLabel(
            title: section.title,
            value: sidebarAccessibilityValue(section, summary: summary),
            isSelected: section == selected
        )))
        .accessibilityValue(Text(sidebarAccessibilityValue(section, summary: summary)))
        .accessibilityAddTraits(section == selected ? .isSelected : [])
        .accessibilityIdentifier("addons_sidebar_\(section.rawValue)")
    }

    /// A7 device check (German): "Alle aktualisieren" and "Noch nicht aktualisiert" do not fit
    /// side by side in the 560 pt sidebar (the title hyphenated, the stamp truncated). The stamp
    /// stays trailing when it fits (English) and drops under the title when it does not. While
    /// refreshing there is no stamp, only the trailing spinner.
    @ViewBuilder
    private func refreshRowLabel(_ section: HubSection) -> some View {
        if model.isRefreshingAny {
            SettingsRowLabel(title: section.title, systemImage: section.systemImage)
        } else {
            // The named relative stamp does not tick by itself (v1 note): a 30 s timeline.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                let stamp = model.lastRefreshedAt != nil ? refreshStamp : String(localized: "Not refreshed yet")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.md) {
                        SettingsRowLabel(title: section.title, systemImage: section.systemImage)
                            .fixedSize()
                        Spacer(minLength: Theme.Spacing.md)
                        SettingsTrailingValue(value: stamp, showsChevron: false)
                            .fixedSize()
                    }
                    SettingsRowLabel(title: section.title, subtitle: stamp, systemImage: section.systemImage)
                }
            }
        }
    }

    @ViewBuilder
    private func sidebarTrailing(_ section: HubSection, summary: AddonsViewModel.HubSummary) -> some View {
        if section == .refresh {
            if model.isRefreshingAny {
                ProgressView().controlSize(.small)
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
                    model: model, settings: settings, debrid: debrid, plugins: plugins,
                    contentFocus: $contentFocus,
                    debridDisconnectId: $debridDisconnectId,
                    onOpenAddon: { contentPath.append(HubAddonRoute(manifestUrl: $0.manifestUrl)) },
                    onConfigureAddon: { contentPath.append(HubAddonRoute(manifestUrl: $0.manifestUrl, startsInConfigure: true)) },
                    onMove: move,
                    onRemove: { requestRemoval($0, fromDetail: false) },
                    installedScrollTarget: $installedScrollTarget,
                    onShowInstall: {
                        // A3: the empty Installed pane's link row goes to the Install section.
                        select(.install)
                        DispatchQueue.main.async { handOffContent(InstallAddonPane.fieldKey) }
                    },
                    movingUrl: moveMode.movingUrl,
                    onStartMove: startMove,
                    onMoveStep: moveStep,
                    onCommitMove: commitMove,
                    catalogFilter: catalogFilter,
                    onClearCatalogFilter: clearCatalogFilter,
                    onCatalogsMovingChange: catalogsMovingChanged,
                    catalogsScrollTarget: $catalogsScrollTarget,
                    installHandledSerial: $installHandledSerial,
                    installDraft: $installDraft,
                    onInstalled: focusNewestCard
                )
                // A second child: a one-child stack forwarded its identifier to the pane's
                // ScrollView (A2 probe), so the column needs to be a real container.
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
            // D6: Menu at the column root goes to the sidebar first. Pushed pages are stack
            // destinations, not descendants of this view, so Menu on them still pops.
            .onExitCommand {
                // A3 device check: the Menu press that closes a row's context menu also reached
                // this handler and threw focus onto the sidebar. Route to the sidebar only while
                // focus is actually on a content control (nil while the menu holds it) or on an
                // untagged pane (the interim hosts: contentFocus stays nil there too, so allow it
                // when no Installed row is the remembered target).
                Self.logFocus("menu at content root; focus=\(contentFocus.map(Self.kind(of:)) ?? "nil")")
                // A4: Menu cancels a move (back to where it started) before anything else.
                if moveMode.isMoving { cancelMove(); return }
                // A6: the Catalogs pane cancels its own move (its Menu handler exists only then).
                if catalogsMoving { return }
                if contentFocus != nil || selected != .installed { handOffSidebar(selected) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("addons_content_\(selected.rawValue)")
            .navigationDestination(for: HubAddonRoute.self) { route in
                // A5: the add-on's detail page on the row kit. It reads the add-on live and keeps
                // a focusable row in every state (BUG-47 rule: Refresh/Retry is always there).
                if let addon = model.addons.first(where: { $0.manifestUrl == route.manifestUrl }) {
                    AddonDetailPane(
                        model: model, settings: settings, snapshot: addon,
                        startsInConfigure: route.startsInConfigure,
                        onMove: moveFromDetail,
                        onShowCatalogs: showCatalogsFromDetail,
                        onRemove: { requestRemoval($0, fromDetail: true) }
                    )
                    .accessibilityIdentifier("addons_detail_root")
                } else {
                    // Removed elsewhere (sync) while open: nothing to show, go back.
                    Color.clear.onAppear { popProgrammatically() }
                }
            }
        }
        // A new section starts the column over: a fresh stack (anything pushed is dropped, value
        // links included) and fresh pane state.
        .id(selected)
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
        guard restored != selected else { return }
        selected = restored
        // A8 device check: re-entering the hub (rail or tab) with a stored section other than
        // Installed left focus on the Installed row: the engine had already landed on the
        // sidebar's initial default before this ran, so the landing correction never saw the
        // restored section. Hand the sidebar's focus to the restored row.
        if sidebarFocus != nil {
            DispatchQueue.main.async { handOffSidebar(restored) }
        }
    }

    /// C2: shows a section another screen asked for (`AddonsHubRequests`) and puts focus on its
    /// sidebar row, so Right enters it. A request for a hidden section is dropped.
    private func showRequestedSection(visible: [HubSection], tabActive: Bool? = nil) {
        // C5: keep the request until the Add-ons tab is showing; focus set on a hidden tab is lost.
        guard tabActive ?? tabActivity.isActive else { return }
        guard let section = AddonsHubRequests.take(), visible.contains(section), !section.isAction else { return }
        if moveMode.isMoving { cancelMove() }
        select(section)
        DispatchQueue.main.async { handOffSidebar(section) }
        // The tab switch settles focus on the rail a moment later; claim it again once it has,
        // but only while focus is still outside the hub (review r1: a quick press to another
        // sidebar row, Refresh all included, must not be pulled back).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard selected == section, sidebarFocus == nil, contentFocus == nil else { return }
            handOffSidebar(section)
        }
    }

    private func select(_ section: HubSection) {
        dwell?.cancel()
        dwell = nil
        guard !section.isAction, section != selected else { return }
        pendingLiftUrl = nil
        catalogFilterUrl = nil
        // Review A6-r1: a programmatic switch away from Catalogs mid-move (an install landing)
        // must not leave the hub locked; the pane also ends its mode when torn down.
        if catalogsMoving {
            catalogsMoving = false
            suppressSidebarDefaultFocus = false
        }
        popProgrammatically()
        // Review r4: the Installed list reports its scroll to the rail (Hide While Browsing); the
        // list is torn down on a section change without scrolling back, so clear its latch.
        if selected == .installed, NavigationChrome.isRail() {
            navigationChrome.setScrolledDown(tab: Self.railTabIndex, false)
        }
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
        if pendingLiftUrl != nil {
            // Review A5-r4: focus visited the sidebar before the detail page's Move could lift
            // its row; the lift is off even if focus comes back before it would have fired.
            Self.logFocus("sidebar focus cancels the pending lift")
            pendingLiftUrl = nil
        }
        if old == nil, new == selected, new != deliberateSidebar, let at = poppedAt, let url = popReturnUrl,
           ProcessInfo.processInfo.systemUptime - at < Self.popGrabWindow {
            // A5: the Menu pop from a detail page dropped focus onto the sidebar (on the box the
            // engine falls back there once the page's focused row is gone): back to the row.
            Self.logFocus("sidebar grab \(Int((ProcessInfo.processInfo.systemUptime - at) * 1000)) ms after pop -> row")
            poppedAt = nil
            reclaimRow(url)
            return
        }
        if old == nil, new == selected, let ended = moveEndedAt,
           ProcessInfo.processInfo.systemUptime - ended < Self.sidebarGrabWindow,
           let key = lastMovedKey {
            // A4: the re-enabled sidebar took focus right as a move ended (faster than anyone can
            // press Left): give it back to the row. A later sidebar landing is the user's own.
            Self.logFocus("sidebar grab \(Int((ProcessInfo.processInfo.systemUptime - ended) * 1000)) ms after move end -> row")
            moveEndedAt = nil
            handOffContent(key)
            return
        }
        if new == deliberateSidebar {
            deliberateSidebar = nil
            if !new.isAction, new != selected { select(new) }
            return
        }
        if old == nil, new != selected {
            // Entering from outside (content column, tab bar, rail): land on the selected row.
            // The transient landing row never starts a selection. A8 device check: a rail return
            // to a hub showing Catalogs stayed on the Installed row; the write made inside the
            // same focus update is dropped on the box (as on the content side), so it is made one
            // turn later, as a deliberate hand-off.
            Self.logFocus("sidebar landed \(new.rawValue) -> correcting to \(selected.rawValue)")
            let target = selected
            DispatchQueue.main.async {
                if sidebarFocus == new { handOffSidebar(target) }
            }
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
        // Review A5-r3: pop recovery ends as soon as the row has focus, however it got there (the
        // engine can land it before the queued reclaim writes it).
        if let url = popReturnUrl, new == InstalledAddonsPane.rowKey(url) { poppedAt = nil }
        if new == deliberateContent {
            deliberateContent = nil
            lastContentFocus[selected] = new
            return
        }
        if old == nil, let target = contentLandingTarget(for: selected), target != new {
            // Entering from outside (the sidebar, the tab bar): land on the remembered row. On the
            // Living Room box (A2 device check, Tabs mode) a write made inside this same focus
            // update was dropped and focus stayed on the geometric landing (a card's toggle), so
            // the correction runs on the next turn, and only if focus is still where it landed.
            Self.logFocus("content landed \(Self.kind(of: new)) -> correcting to \(Self.kind(of: target))")
            let landed = new
            DispatchQueue.main.async {
                guard contentFocus == landed else { return }
                handOffContent(target)
            }
            return
        }
        lastContentFocus[selected] = new
    }

    /// A no-op write (focus already there) fires no change, so it must not leave a stale flag.
    private func handOffContent(_ key: String) {
        guard contentFocus != key else { return }
        if selected == .installed, key.hasPrefix("row:") || key == InstalledAddonsPane.checkNowKey {
            // Review A3-r1: the native List realizes rows lazily; scroll the row into view, then
            // focus it on the next turn.
            installedScrollTarget = key
            DispatchQueue.main.async {
                deliberateContent = key
                contentFocus = key
            }
            return
        }
        if selected == .catalogs, key.hasPrefix("catalog:") {
            // A6: the Catalogs List is lazy too.
            catalogsScrollTarget = key
            DispatchQueue.main.async {
                deliberateContent = key
                contentFocus = key
            }
            return
        }
        deliberateContent = key
        contentFocus = key
    }

    private func handOffSidebar(_ section: HubSection) {
        // Review A5-r2: a deliberate move to the sidebar (Menu at the content root, a removal's
        // empty list) ends any pending pop recovery, so the sidebar keeps it.
        poppedAt = nil
        guard sidebarFocus != section else { return }
        deliberateSidebar = section
        sidebarFocus = section
    }

    /// `[HubFocus]` lines for device checks: the KIND of control only (the key's prefix), never the
    /// manifest URL (it can carry a debrid key).
    private static func logFocus(_ message: String) {
        NSLog("[HubFocus] %@", message)
    }

    private static func kind(of key: String) -> String {
        key.split(separator: ":", maxSplits: 1).first.map(String.init) ?? key
    }

    /// Where focus should land when it enters `section`'s content: the row last focused there if
    /// it still exists, else the pane's first row; nil for panes that do not take part.
    private func contentLandingTarget(for section: HubSection) -> String? {
        let keys = contentKeys(for: section)
        if let remembered = lastContentFocus[section], keys.contains(remembered) { return remembered }
        if section == .catalogs { return firstCatalogsKey() }
        return Self.firstContentKey(section: section, addons: model.addons)
    }

    /// A6: where Catalogs lands with nothing remembered: the first catalog of a filtered view,
    /// else the Match row, else the empty row.
    private func firstCatalogsKey() -> String {
        if settings.catalogs.isEmpty { return CatalogOrderView.emptyKey }
        if catalogFilter != nil {
            let visible = CatalogOrderView.visibleRows(settings.catalogs, filter: catalogFilter)
            return visible.first.map { CatalogOrderView.rowKey($0.key) } ?? CatalogOrderView.clearFilterKey
        }
        return CatalogOrderView.matchKey
    }

    /// A6: the live filter for `catalogFilterUrl` (nil once that add-on is gone).
    private var catalogFilter: CatalogFilter? { Self.catalogFilter(for: catalogFilterUrl, addons: model.addons) }

    /// Review A6-r3: the filter for `url` from the CURRENT add-on list: the catalogs it owns now
    /// (Home's ownership rule) and its title now; nil when `url` is nil or no longer installed.
    nonisolated static func catalogFilter(for url: String?, addons: [ManagedAddon]) -> CatalogFilter? {
        guard let url, let addon = addons.first(where: { $0.manifestUrl == url }) else { return nil }
        return CatalogFilter(
            keys: AddonDetailPane.catalogKeys(ownedBy: url, in: addons),
            addonTitle: AddonsViewModel.displayTitle(addon)
        )
    }

    /// A4 + A6: a row is lifted in Installed or in Catalogs; the sidebar, tab bar and rail lock.
    private var isMovingAny: Bool { moveMode.isMoving || catalogsMoving }

    /// Every focus key the pane for `section` can hold right now (Installed: one row per add-on,
    /// A3; Install: its row).
    private func contentKeys(for section: HubSection) -> Set<String> {
        switch section {
        case .install: return [InstallAddonPane.fieldKey, InstallAddonPane.buttonKey]
        case .phone: return [ManageFromPhonePane.primaryKey]
        case .catalogs:
            let visible = CatalogOrderView.visibleRows(settings.catalogs, filter: catalogFilter)
            var keys = Set(visible.map { CatalogOrderView.rowKey($0.key) })
            if catalogFilter != nil { keys.insert(CatalogOrderView.clearFilterKey) }
            if catalogFilter == nil && !settings.catalogs.isEmpty { keys.insert(CatalogOrderView.matchKey) }
            if settings.catalogs.isEmpty { keys.insert(CatalogOrderView.emptyKey) }
            return keys
        case .installed:
            if model.isInitialized && model.addons.isEmpty { return [InstalledAddonsPane.emptyKey] }
            return Self.installedFocusKeys(urls: model.addons.map(\.manifestUrl))
                .union([InstalledAddonsPane.checkNowKey])
        default: return []
        }
    }

    /// The Installed pane's focusable keys: one row per add-on (A3: actions live in the row's
    /// context menu, so a row is always focusable, read-only profiles included).
    nonisolated static func installedFocusKeys(urls: [String]) -> Set<String> {
        Set(urls.map(InstalledAddonsPane.rowKey))
    }

    /// The Install pane's one row.

    /// The first row of a taking-part pane (Installed: the first card; Install: its row), else nil.
    nonisolated static func firstContentKey(section: HubSection, addons: [ManagedAddon]) -> String? {
        switch section {
        case .installed: return addons.first.map { InstalledAddonsPane.rowKey($0.manifestUrl) } ?? InstalledAddonsPane.emptyKey
        case .install: return InstallAddonPane.fieldKey
        case .phone: return ManageFromPhonePane.primaryKey
        default: return nil
        }
    }

    // MARK: - Reorder, removal and install (v1 logic, keyed on `contentFocus`)

    /// Moves the add-on one place and keeps focus on its row (A3: the row moves with it). A4's
    /// Move mode replaces the context menu's Move up / Move down with this as its step.
    private func move(_ addon: ManagedAddon, index: Int, by delta: Int) {
        let count = model.addons.count
        guard AddonsViewModel.moveTarget(index: index, by: delta, count: count) != nil else { return }
        // Stage A review: VoiceOver's direct moves go through the URL-keyed atomic step (A4), so
        // a sync landing between the read and the write never moves a different add-on.
        guard model.moveStep(manifestUrl: addon.manifestUrl, by: delta) else { return }
        DispatchQueue.main.async { handOffContent(InstalledAddonsPane.rowKey(addon.manifestUrl)) }
    }

    // MARK: - Pops (A5)

    /// Empties the content stack for the hub's own reasons; the pop does not reclaim a row.
    private func popProgrammatically() {
        guard !contentPath.isEmpty else { return }
        programmaticPop = true
        contentPath.removeAll()
    }

    /// A5 device check: the user's Menu pop from a detail page lands focus on the pushing row (the
    /// box dropped it onto the sidebar; the simulator did not).
    private func contentPathChanged(from old: [HubAddonRoute], to new: [HubAddonRoute]) {
        // Review A5-r3: a push (another detail page) cancels a pending lift.
        if new.count > old.count { pendingLiftUrl = nil }
        guard new.isEmpty, let route = old.last else { return }
        if programmaticPop {
            programmaticPop = false
            return
        }
        guard selected == .installed,
              model.addons.contains(where: { $0.manifestUrl == route.manifestUrl }) else { return }
        popReturnUrl = route.manifestUrl
        poppedAt = ProcessInfo.processInfo.systemUptime
        Self.logFocus("detail popped -> row")
        DispatchQueue.main.async { reclaimRow(route.manifestUrl) }
    }

    /// Focus onto an Installed row after a pop: scrolled into view first (the List is lazy), the
    /// write one turn later, even when `contentFocus` still names it from before the push.
    private func reclaimRow(_ url: String) {
        let key = InstalledAddonsPane.rowKey(url)
        installedScrollTarget = key
        DispatchQueue.main.async {
            // Review A5-r3: already there (the engine got it first): nothing to write, and no
            // deliberate flag left behind on a no-op.
            if contentFocus == key {
                poppedAt = nil
                return
            }
            deliberateContent = key
            contentFocus = key
        }
    }

    /// How long after a pop a sidebar landing still counts as the engine's fallback.
    nonisolated static let popGrabWindow: TimeInterval = 0.8

    // MARK: - Detail page actions (A5)

    /// The detail page's Move: pop back to Installed, then lift this add-on's row (A4 Move mode).
    /// The lift waits for the pop to settle, so the stack's own focus return (onto the pushing
    /// row) cannot land after Move mode's hand-off.
    private func moveFromDetail(_ addon: ManagedAddon) {
        pendingLiftUrl = addon.manifestUrl
        popProgrammatically()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.popSettle) {
            guard pendingLiftUrl == addon.manifestUrl else { return }
            pendingLiftUrl = nil
            guard selected == .installed, contentPath.isEmpty, !moveMode.isMoving,
                  let index = model.addons.firstIndex(where: { $0.manifestUrl == addon.manifestUrl }),
                  model.addons.count > 1 else { return }
            startMove(addon, index: index)
        }
    }

    /// The detail page's "Catalogs from this add-on": the Catalogs section, focus on its sidebar
    /// row (the interim v1 Catalogs host has no focus keys until A6 re-hosts it; Right enters it).
    private func showCatalogsFromDetail() {
        // Captured before the pop: the detail page's add-on and the catalogs it owns (Home's
        // ownership rule, the same set its row counted).
        let route = contentPath.last
        let addon = route.flatMap { r in model.addons.first { $0.manifestUrl == r.manifestUrl } }
        select(.catalogs)
        if let addon {
            catalogFilterUrl = addon.manifestUrl
            lastContentFocus[.catalogs] = nil
        }
        DispatchQueue.main.async { handOffContent(firstCatalogsKey()) }
    }

    /// The Catalogs pane's "Show all" row: drop the filter, land on the Match row.
    private func clearCatalogFilter() {
        catalogFilterUrl = nil
        lastContentFocus[.catalogs] = nil
        DispatchQueue.main.async { handOffContent(firstCatalogsKey()) }
    }

    /// How long a NavigationStack pop takes to hand focus back on the box (A5 device check).
    static let popSettle: TimeInterval = 0.45

    // MARK: - Move mode (A4)

    /// A move announcement for the Installed row `url`, spoken only if, when it fires, focus is
    /// still on that row with no page pushed, and the row is still lifted (`.started`) or no
    /// longer lifted (the results).
    private func announceMove(_ event: HubAccessibility.MoveEvent, url: String) {
        let key = InstalledAddonsPane.rowKey(url)
        HubAccessibility.announceWhenSettled(event) {
            HubAccessibility.isMoveAnnouncementCurrent(
                event, key: url, rowKey: key, focusedKey: contentFocus, liftedKey: moveMode.movingUrl,
                pageOpen: !contentPath.isEmpty, inSection: selected == .installed
            )
        }
    }

    private func startMove(_ addon: ManagedAddon, index: Int) {
        guard !model.isReadOnly else { return }
        suppressSidebarDefaultFocus = true
        moveDidStep = false
        let order = model.liveOrder()
        moveMode.start(manifestUrl: addon.manifestUrl, index: order.firstIndex(of: addon.manifestUrl) ?? index, order: order)
        Self.logFocus("move start at \(index)")
        DispatchQueue.main.async { handOffContent(InstalledAddonsPane.rowKey(addon.manifestUrl)) }
        // VoiceOver check (2026-11-08): the badge alone was never spoken. Said once the hand-off
        // has settled, only while this row is still the lifted, focused one. Covers the context
        // menu's Move and the add-on page's Move (it lifts the row through here).
        announceMove(.started, url: addon.manifestUrl)
    }



    /// One Up/Down press while moving: the reducer decides (ends, 112 ms throttle); the add-on
    /// moves one place and focus stays on its row.
    private func moveStep(_ direction: AddonMoveMode.Direction) {
        let order = model.liveOrder()
        guard let url = moveMode.movingUrl,
              let current = order.firstIndex(of: url),
              let target = moveMode.step(direction, currentIndex: current, count: order.count,
                                         now: ProcessInfo.processInfo.systemUptime) else { return }
        // Review r3: the reducer only gates the press (ends, throttle); the repository resolves the
        // add-on and its destination by URL in one atomic update.
        if model.moveStep(manifestUrl: url, by: target - current) { moveDidStep = true }
        DispatchQueue.main.async { handOffContent(InstalledAddonsPane.rowKey(url)) }
    }

    private func commitMove() {
        guard let url = moveMode.commit() else { return }
        Self.logFocus("move commit")
        announceMove(.committed, url: url)
        refocusRowAfterMove(url)
    }

    /// A4: after a move ends, keep focus on the row. The sidebar re-enables here; its default
    /// focus stays suppressed for a moment, and a grab inside `sidebarGrabWindow` is handed back
    /// in `sidebarFocusChanged`. No timer, so nothing overrides the user's next press (review r2).
    private func refocusRowAfterMove(_ url: String) {
        installedScrollTarget = InstalledAddonsPane.rowKey(url)
        refocusAfterMove(InstalledAddonsPane.rowKey(url))
    }

    /// The shared tail of a move's end (Installed or Catalogs): focus back on `key`, the sidebar's
    /// default focus suppressed for a moment, a grab inside the window handed back.
    private func refocusAfterMove(_ key: String) {
        lastMovedKey = key
        moveEndedAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async {
            deliberateContent = key
            contentFocus = key
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { suppressSidebarDefaultFocus = false }
    }

    /// A6: the Catalogs pane starts or ends a move. Start: the sidebar's default focus is held off
    /// (it re-enables when the move ends). End (device check: the cancel's Menu left focus on the
    /// sidebar): A4's tail, onto the catalog the pane had focused, unless the pane went away.
    private func catalogsMovingChanged(_ moving: Bool) {
        if moving {
            suppressSidebarDefaultFocus = true
            catalogsMoving = true
            return
        }
        catalogsMoving = false
        if selected == .catalogs, let key = contentFocus ?? lastContentFocus[.catalogs], key.hasPrefix("catalog:") {
            refocusAfterMove(key)
        } else {
            suppressSidebarDefaultFocus = false
        }
    }

    /// Review A4-r7: the lifted add-on went away (sync, another device). End the mode with the
    /// same cleanup as Select/Menu (sidebar default focus back, no pending step) and put focus on
    /// a surviving row, else the Install row.
    private func endMoveBecauseRemoved() {
        moveMode.commit()
        moveDidStep = false
        suppressSidebarDefaultFocus = false
        moveEndedAt = nil
        Self.logFocus("move ended: lifted add-on removed")
        DispatchQueue.main.async {
            if let first = model.addons.first {
                handOffContent(InstalledAddonsPane.rowKey(first.manifestUrl))
            } else {
                handOffSidebar(.install)
            }
        }
    }

    /// Menu while moving: back to the index the move started from.
    private func cancelMove() {
        // Review r3: restored by URL relative to the surviving neighbours, inside the
        // repository's atomic update.
        let predecessors = moveMode.predecessors
        guard let (url, origin) = moveMode.cancel(currentOrder: model.liveOrder()) else { return }
        if moveDidStep { model.restore(manifestUrl: url, after: predecessors) }
        moveDidStep = false
        Self.logFocus("move cancel back to \(origin)")
        announceMove(.cancelled, url: url)
        refocusRowAfterMove(url)
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
        if fromDetail { popProgrammatically() }
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
                handOffContent(InstalledAddonsPane.rowKey(target))
            } else {
                handOffSidebar(.install)
            }
        }
    }

    /// After an install: the Installed section, focus on the new card (else the last card).
    private func focusNewestCard() {
        // Stage A review: a lifted row (Installed or Catalogs) keeps focus; the toast announces
        // the install. A pushed detail page pops first, so the new row exists to take focus.
        if isMovingAny { return }
        let popped = !contentPath.isEmpty
        popProgrammatically()
        select(.installed)
        DispatchQueue.main.asyncAfter(deadline: .now() + (popped ? Self.popSettle : 0)) {
            let installed = model.lastInstalledManifestUrl.flatMap { url in
                model.addons.first { AddonManifestURL.isSameManifest($0.manifestUrl, url) }
            }
            if let card = installed ?? model.addons.last {
                handOffContent(InstalledAddonsPane.rowKey(card.manifestUrl))
            } else {
                handOffSidebar(.install)
            }
        }
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastView: some View {
        if let toast { HubToast(text: toast) }
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

/// A3: the hub's capsule toast (v1's), its own view so the split view only owns the text and timer.
struct HubToast: View {
    let text: String

    var body: some View {
        Text(text)
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

// MARK: - Content column

/// A pushed add-on detail page in the content column (D2).
struct HubAddonRoute: Hashable {
    let manifestUrl: String
    /// A3 review r2: opened from the row's Configure (the configure QR starts open).
    var startsInConfigure = false
}

/// The right column's root for one section. Installed is A3's native pane; A5 (detail) and A6
/// (Catalogs, Debrid, Plugins, Install) replace the remaining v1 hosts.
private struct HubContentColumn: View {
    let section: HubSection
    @ObservedObject var model: AddonsViewModel
    @ObservedObject var settings: SettingsViewModel
    @ObservedObject var debrid: DebridViewModel
    @ObservedObject var plugins: PluginsViewModel
    let contentFocus: FocusState<String?>.Binding
    @Binding var debridDisconnectId: String?
    let onOpenAddon: (ManagedAddon) -> Void
    let onConfigureAddon: (ManagedAddon) -> Void
    let onMove: (ManagedAddon, Int, Int) -> Void
    let onRemove: (ManagedAddon) -> Void
    @Binding var installedScrollTarget: String?
    let onShowInstall: () -> Void
    let movingUrl: String?
    let onStartMove: (ManagedAddon, Int) -> Void
    let onMoveStep: (AddonMoveMode.Direction) -> Void
    let onCommitMove: () -> Void
    let catalogFilter: CatalogFilter?
    let onClearCatalogFilter: () -> Void
    let onCatalogsMovingChange: (Bool) -> Void
    @Binding var catalogsScrollTarget: String?
    @Binding var installHandledSerial: Int?
    @Binding var installDraft: String
    let onInstalled: () -> Void

    var body: some View {
        switch section {
        case .installed:
            installed
        case .catalogs:
            // A6: Catalogs on the row kit, Move mode and the per-add-on filter.
            CatalogOrderView(
                model: settings,
                focus: contentFocus,
                scrollTarget: $catalogsScrollTarget,
                allowsMoveMode: true,
                filter: catalogFilter,
                onClearFilter: onClearCatalogFilter,
                onMovingChange: onCatalogsMovingChange
            )
        case .debrid:
            // A6 (D4): the debrid providers only (Services keeps Trakt/Simkl/MDBList).
            kitList {
                SettingsSection(String(localized: "Debrid")) {
                    DebridProvidersSection(debrid: debrid, debridDisconnectId: $debridDisconnectId)
                }
            }
        case .plugins:
            kitList {
                SettingsSection(String(localized: "Plugins")) {
                    PluginsSection(plugins: plugins)
                }
            }
        case .install:
            // A6: the inline Install pane (field, Install, status modal).
            InstallAddonPane(
                model: model, focus: contentFocus,
                handledSerial: $installHandledSerial,
                url: $installDraft,
                onInstalled: onInstalled
            )
        case .phone:
            // C2: Remote Setup's home; it starts shortly after the section opens and stops on leaving.
            ManageFromPhonePane(focus: contentFocus)
        case .refresh:
            // An action row; never the content section (`HubSection.resolved` and `select`).
            Color.clear
        }
    }

    private func kitList<Rows: View>(@ViewBuilder _ rows: () -> Rows) -> some View {
        List { rows() }
            .scrollClipDisabled()
            .environment(\.settingsUsesNativeList, true)
    }

    /// A3: the Installed pane on the native kit (rows, context menu), focus keys shared with the
    /// split view's memory.
    private var installed: some View {
        InstalledAddonsPane(
            model: model,
            focus: contentFocus,
            onOpen: onOpenAddon,
            onConfigure: onConfigureAddon,
            onMove: onMove,
            onRemove: onRemove,
            onShowInstall: onShowInstall,
            scrollTarget: $installedScrollTarget,
            movingUrl: movingUrl,
            onStartMove: onStartMove,
            onMoveStep: onMoveStep,
            onCommitMove: onCommitMove
        )
        // Review r4: Hide While Browsing follows the Installed list, as it followed v1's hub.
        .reportsScrollToTabBar(tab: "Add-ons")
    }
}

// MARK: - Sidebar surface

/// D5: Liquid Glass on the sidebar container only; the content column stays flat (HIG Materials:
/// glass is for the control layer). Christian kept the glass next to the rail as built (A2 device
/// check, 2026-11-07), so there is no flat variant.
private struct HubSidebarSurface: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 36, style: .continuous)
        shape.fill(Color.clear).glassEffect(.regular, in: shape)
    }
}
