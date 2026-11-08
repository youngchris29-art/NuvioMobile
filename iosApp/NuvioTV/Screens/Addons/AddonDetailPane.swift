import SharedCore
import SwiftUI

/// Add-ons hub v2, A5: the add-on detail page, pushed from the Installed pane (v1's detail sheet
/// was deleted in A7).
///
/// A native `List` like the Installed pane: a non-focusable header (logo, name, version · host ·
/// stream position, description, resource chips), then `SettingsRowKit` rows in `rows(…)` order,
/// then the location line. Reads the add-on LIVE from `model` by URL and falls back to the
/// snapshot it was pushed with, so the page never blanks mid-removal. Move, Catalogs and Remove
/// hand back to the split view (which pops this page first: an alert never sits on a pushed
/// page). Menu pops the NavigationStack (system behaviour); there is no `onExitCommand` here.
struct AddonDetailPane: View {
    @ObservedObject var model: AddonsViewModel
    @ObservedObject var settings: SettingsViewModel
    /// The add-on as it was when pushed; the page reads the LIVE add-on from `model` by URL and
    /// falls back to this, so it never blanks mid-removal.
    let snapshot: ManagedAddon
    /// Opened from the row's Configure (A3 review r2/r3): the QR starts open and comes first.
    let startsInConfigure: Bool
    /// Move: the split view pops to Installed and lifts this add-on's row (A4 Move mode).
    let onMove: (ManagedAddon) -> Void
    /// Catalogs from this add-on: the split view switches to the Catalogs section.
    let onShowCatalogs: () -> Void
    /// Remove: the split view pops and raises its confirm alert (an alert never sits on a pushed page).
    let onRemove: (ManagedAddon) -> Void

    /// Seeded from `startsInConfigure` in `init` (device check: flipping it on appear re-ordered
    /// the rows after the first render).
    @State private var showsConfigure: Bool
    init(
        model: AddonsViewModel, settings: SettingsViewModel, snapshot: ManagedAddon,
        startsInConfigure: Bool = false,
        onMove: @escaping (ManagedAddon) -> Void,
        onShowCatalogs: @escaping () -> Void,
        onRemove: @escaping (ManagedAddon) -> Void
    ) {
        self.model = model
        self.settings = settings
        self.snapshot = snapshot
        self.startsInConfigure = startsInConfigure
        self.onMove = onMove
        self.onShowCatalogs = onShowCatalogs
        self.onRemove = onRemove
        _showsConfigure = State(initialValue: startsInConfigure)
    }

    /// The rendered QR and the URL it was built for; rebuilt only when that URL changes.
    @State private var qrImage: UIImage?
    @State private var qrFor: String?
    @State private var didClaimFocus = false
    @FocusState private var focus: DetailRow?

    // MARK: Pure rules

    /// The manifest's own description text (never the bridged object's `description`).
    /// H5 device finding: Kotlin's `description` bridges as `description_`; plain `.description`
    /// is NSObject's, i.e. the data class's toString with the keyed transportUrl in it (seen on
    /// the box 2026-10-26).
    nonisolated static func blurb(of manifest: AddonManifest) -> String { manifest.description_ }

    /// Where the add-on lives, without its key. Debrid keys live in the PATH of most add-on URLs
    /// (`/torbox=KEY/manifest.json`) as well as the query, so the path is never shown: the file
    /// name appears only when it is exactly `manifest.json`, otherwise just "host/…". "(key
    /// hidden)" is appended whenever anything was dropped (path segments, query or userinfo). A
    /// `#fragment` is stripped first; a bare host renders as the host alone.
    nonisolated static func locationLine(_ manifestUrl: String) -> String {
        let host = AddonsViewModel.host(of: manifestUrl)
        let noFragment = manifestUrl.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? manifestUrl
        let hasQuery = noFragment.contains("?")
        let withoutQuery = noFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? noFragment
        var rest = Substring(withoutQuery)
        if let sep = rest.range(of: "://"), sep.lowerBound < (rest.firstIndex(of: "/") ?? rest.endIndex) {
            rest = rest[sep.upperBound...]
        }
        let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        let hasUserinfo = rest[..<authorityEnd].contains("@")
        let segments = rest[authorityEnd...].split(separator: "/").map(String.init)
        let hidden = hasQuery || hasUserinfo || segments.count > 1
            || (segments.count == 1 && segments[0] != "manifest.json")
        let base: String
        if segments.isEmpty {
            base = host
        } else if segments.last == "manifest.json" {
            base = segments.count == 1 ? "\(host)/manifest.json" : "\(host)/…/manifest.json"
        } else {
            base = "\(host)/…"
        }
        return hidden ? base + " " + String(localized: "(key hidden)") : base
    }

    /// The manifest URL with a trailing `/manifest.json` (before any query) swapped for
    /// `/configure`, query kept. A URL without that suffix gets `/configure` appended to its path.
    nonisolated static func configureUrl(_ manifestUrl: String) -> String {
        let split = manifestUrl.firstIndex(of: "?")
        let path = split.map { String(manifestUrl[..<$0]) } ?? manifestUrl
        let query = split.map { String(manifestUrl[$0...]) } ?? ""
        let trimmed: String
        if path.hasSuffix("/manifest.json") {
            trimmed = String(path.dropLast("/manifest.json".count))
        } else {
            trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return trimmed + "/configure" + query
    }

    /// Review r1: the module count comes from a scale-1 render; the final scale is the largest
    /// whole number that fits 320 pt (minimum 1), so every module lands on whole pixels.
    static func makeQR(_ url: String) -> UIImage? {
        guard let raw = QRCode.image(for: url, scale: 1), let width = raw.cgImage?.width, width > 0 else { return nil }
        return QRCode.image(for: url, scale: CGFloat(max(1, 320 / width)))
    }

    /// 1-based position among the add-ons the stream picker asks, in list order (enabled and
    /// declaring a `stream` resource). Nil when this add-on is not one of them: disabled, no
    /// manifest yet, or no stream resource.
    nonisolated static func streamPosition(of manifestUrl: String, in addons: [ManagedAddon]) -> Int? {
        let asked = addons.filter { addon in
            addon.enabled && (addon.manifest?.resources.contains { $0.name == "stream" } ?? false)
        }
        return asked.firstIndex { $0.manifestUrl == manifestUrl }.map { $0 + 1 }
    }

    /// "1st", "2nd", "3rd", "11th" in the current locale; the bare number if the formatter has none.
    nonisolated static func ordinal(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = Locale.current
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "Version 0.0.15 · torrentio.strem.fun · 2nd in stream order": the version part is left out
    /// until the manifest is loaded, the position part when the add-on is not asked for streams.
    nonisolated static func headerLine(version: String?, host: String, streamPosition: Int?) -> String {
        var parts: [String] = []
        if let version, !version.isEmpty { parts.append(String(localized: "Version \(version)")) }
        parts.append(host)
        if let streamPosition {
            let place = ordinal(streamPosition)
            parts.append(String(localized: "\(place) in stream order"))
        }
        return parts.joined(separator: " · ")
    }

    /// The Home-settings keys of the catalogs this add-on OWNS: `manifestId:type:catalogId`,
    /// exactly as `buildHomeCatalogDefinitions` (shared) builds them, with its ownership rule:
    /// enabled add-ons in list order, catalogs with a required extra skipped, the first add-on to
    /// produce a key keeps it. Review A5-r1: never the name (a rename changes it, two installs can
    /// share it); A5-r2: a mirror install at another URL owns nothing its twin already claimed.
    nonisolated static func catalogKeys(ownedBy manifestUrl: String, in addons: [ManagedAddon]) -> Set<String> {
        var claimed = Set<String>()
        var owned = Set<String>()
        for addon in addons where addon.enabled {
            guard let manifest = addon.manifest else { continue }
            for catalog in manifest.catalogs where !catalog.extra.contains(where: { $0.isRequired }) {
                let key = "\(manifest.id):\(catalog.type):\(catalog.id)"
                guard claimed.insert(key).inserted else { continue }
                if addon.manifestUrl == manifestUrl { owned.insert(key) }
            }
        }
        return owned
    }

    /// The add-on's catalogs in Home settings, matched by key; collections are not add-on catalogs.
    nonisolated static func catalogCounts(
        keys: Set<String>, catalogs: [HomeCatalogSettingsItem]
    ) -> (on: Int, total: Int) {
        guard !keys.isEmpty else { return (0, 0) }
        let mine = catalogs.filter { !$0.isCollection && keys.contains($0.key) }
        return (mine.filter(\.enabled).count, mine.count)
    }

    nonisolated static func catalogsValue(on: Int, total: Int) -> String {
        String(localized: "\(on) of \(total) on")
    }

    nonisolated enum DetailRow: Hashable {
        case enabled, configure, refresh, retry, move, catalogs, remove
    }

    /// The rows, in order. Read-only profiles can only refresh (or retry a stalled refresh) and
    /// browse the catalogs: same as A3's context menu. Otherwise Enabled, Configure (when the
    /// manifest is configurable), refresh/retry, Move (more than one add-on), Catalogs (when it
    /// has any) and Remove. Opened through Configure, Configure comes first.
    nonisolated static func rows(
        configurable: Bool, isReadOnly: Bool, addonCount: Int,
        status: AddonsViewModel.AddonStatus, catalogTotal: Int, configureFirst: Bool
    ) -> [DetailRow] {
        let refreshRow: DetailRow = status == .stalled ? .retry : .refresh
        if isReadOnly {
            // Stage A review: a profile on the primary profile's add-ons cannot toggle, move or
            // remove, but may still show a configurable add-on's configure QR (v1's sheet did).
            var rows: [DetailRow] = [refreshRow]
            if configurable { rows.insert(.configure, at: configureFirst ? 0 : 1) }
            if catalogTotal > 0 { rows.append(.catalogs) }
            return rows
        }
        var rows: [DetailRow] = [.enabled]
        if configurable { rows.append(.configure) }
        rows.append(refreshRow)
        if addonCount > 1 { rows.append(.move) }
        if catalogTotal > 0 { rows.append(.catalogs) }
        rows.append(.remove)
        if configureFirst, configurable, let at = rows.firstIndex(of: .configure) {
            rows.remove(at: at)
            rows.insert(.configure, at: 0)
        }
        return rows
    }

    /// Where focus lands on push: Configure when the page was opened through it, else Enabled,
    /// One List item: a row, or the configure QR block (which sits right below the Configure row).
    nonisolated enum PageItem: Hashable {
        case row(DetailRow)
        case code
    }

    /// The rows as List items, with the QR block after Configure while the code is showing.
    nonisolated static func pageItems(_ rows: [DetailRow], showsCode: Bool) -> [PageItem] {
        rows.flatMap { row -> [PageItem] in
            row == .configure && showsCode ? [.row(row), .code] : [.row(row)]
        }
    }

    /// else whatever comes first (read-only pages have no Enabled row).
    nonisolated static func defaultRow(_ rows: [DetailRow], configureFirst: Bool) -> DetailRow? {
        if configureFirst, rows.contains(.configure) { return .configure }
        if rows.contains(.enabled) { return .enabled }
        return rows.first
    }

    // MARK: Live state

    private var addon: ManagedAddon {
        model.addons.first { $0.manifestUrl == snapshot.manifestUrl } ?? snapshot
    }

    private var configurable: Bool { addon.manifest?.behaviorHints.configurable == true }

    private var configureFirst: Bool { startsInConfigure && showsConfigure && configurable }

    private var status: AddonsViewModel.AddonStatus {
        AddonsViewModel.status(of: addon, stalled: model.stalledUrls)
    }

    private var currentRows: [DetailRow] {
        Self.rows(
            configurable: configurable, isReadOnly: model.isReadOnly, addonCount: model.addons.count,
            status: status,
            catalogTotal: Self.catalogCounts(keys: Self.catalogKeys(ownedBy: addon.manifestUrl, in: model.addons), catalogs: settings.catalogs).total,
            configureFirst: configureFirst
        )
    }

    // MARK: Body

    var body: some View {
        let rows = currentRows
        let addon = addon
        let defaultRow = Self.defaultRow(rows, configureFirst: configureFirst)
        List {
            header(addon)
            // Device check: one List item per id. A ForEach element that yielded the row AND the
            // QR block gave both the row's id, and the List drew Configure twice on a reorder.
            ForEach(Self.pageItems(rows, showsCode: showsConfigure && configurable), id: \.self) { item in
                switch item {
                case .row(let row): rowView(row, addon: addon)
                case .code: configureSection(addon)
                }
            }
            if configureFirst { details(addon) }
            Text(Self.locationLine(addon.manifestUrl))
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .focusable(false)
                .accessibilityIdentifier("addons_hub_detail_location")
        }
        .environment(\.settingsUsesNativeList, true)
        .scrollClipDisabled()
        .defaultFocus($focus, defaultRow)
        .onChange(of: rows) { _, now in
            // The focused row left the page (Configure on a manifest reload, Move when the list
            // drops to one add-on): fall back to the default instead of dropping focus.
            if let focus, !now.contains(focus) {
                self.focus = Self.defaultRow(now, configureFirst: configureFirst)
            }
        }
        .onAppear {
            // The push transition can hand focus elsewhere, so claim the default row one runloop
            // late, once per push (same pattern as `SettingsListPickerPage`).
            guard !didClaimFocus else { return }
            didClaimFocus = true
            DispatchQueue.main.async {
                focus = Self.defaultRow(currentRows, configureFirst: configureFirst)
            }
        }
        .task(id: qrKey(addon)) {
            let key = qrKey(addon)
            guard !key.isEmpty, key != qrFor else { return }
            qrImage = Self.makeQR(key)
            qrFor = key
        }
        .accessibilityIdentifier("addons_detail_list")
    }

    /// The configure URL while the QR is wanted, else "" (nothing to build).
    private func qrKey(_ addon: ManagedAddon) -> String {
        showsConfigure && addon.manifest?.behaviorHints.configurable == true
            ? Self.configureUrl(addon.manifestUrl) : ""
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ addon: ManagedAddon) -> some View {
        let manifest = addon.manifest
        let position = Self.streamPosition(of: addon.manifestUrl, in: model.addons)
        let line = Self.headerLine(
            version: manifest?.version, host: AddonsViewModel.host(of: addon.manifestUrl),
            streamPosition: position
        )
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.lg) {
                CachedAsyncImage(string: manifest?.logoUrl) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.Palette.surfaceElevated)
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(AddonsViewModel.displayTitle(addon))
                        .font(Theme.Font.sectionTitle)
                        .lineLimit(2)
                    HStack(spacing: Theme.Spacing.sm) {
                        if manifest == nil {
                            Text("Loading…")
                                .font(SettingsRowFont.subtitle)
                                .foregroundStyle(.secondary)
                            ProgressView().controlSize(.small)
                        }
                        Text(line)
                            .font(SettingsRowFont.subtitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if !configureFirst { descriptionAndChips(manifest) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusable(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("addons_detail_header")
    }

    /// Configure-first pages put these after the rows, so the QR sits right under the name.
    @ViewBuilder
    private func details(_ addon: ManagedAddon) -> some View {
        if addon.manifest != nil {
            descriptionAndChips(addon.manifest)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusable(false)
                .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func descriptionAndChips(_ manifest: AddonManifest?) -> some View {
        if let manifest {
            // Never `.description` (see `blurb(of:)`).
            let blurb = Self.blurb(of: manifest)
            if !blurb.isEmpty {
                Text(blurb).font(Theme.Font.body).lineLimit(4)
            }
            let labels = AddonsViewModel.resourceLabels(of: manifest)
            if !labels.isEmpty {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(labels, id: \.self) { label in
                        Text(label)
                            .font(Theme.Font.caption)
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, Theme.Spacing.xxs)
                            .background(Capsule().fill(Theme.Palette.surfaceElevated))
                    }
                }
                .accessibilityIdentifier("addons_detail_chips")
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: DetailRow, addon: ManagedAddon) -> some View {
        switch row {
        case .enabled:
            SettingsToggleRow(
                title: String(localized: "Enabled"),
                isOn: Binding(get: { addon.enabled }, set: { model.setEnabled(addon, $0) })
            )
            .focused($focus, equals: .enabled)
            .accessibilityIdentifier("addons_detail_enabled")
        case .configure:
            Button {
                showsConfigure.toggle()
            } label: {
                SettingsRowChrome {
                    SettingsRowLabel(
                        title: String(localized: "Configure"),
                        subtitle: String(localized: "Scan a code to change this add-on's settings on your phone")
                    )
                } trailing: {
                    SettingsTrailingValue(
                        value: showsConfigure ? String(localized: "Hide code") : String(localized: "Show code"),
                        showsChevron: false
                    )
                }
            }
            .focused($focus, equals: .configure)
            .accessibilityIdentifier("addons_hub_detail_configure")
        case .refresh:
            SettingsActionRow(
                title: String(localized: "Refresh"), subtitle: refreshSubtitle
            ) { model.refresh(manifestUrl: addon.manifestUrl) }
            .focused($focus, equals: .refresh)
            .accessibilityIdentifier("addons_hub_detail_refresh")
        case .retry:
            SettingsActionRow(
                title: String(localized: "Retry"), subtitle: refreshSubtitle
            ) { model.retryRefresh(manifestUrl: addon.manifestUrl) }
            .focused($focus, equals: .retry)
            .accessibilityIdentifier("addons_hub_detail_refresh")
        case .move:
            SettingsActionRow(
                title: String(localized: "Move"),
                subtitle: String(localized: "Change where this add-on sits in stream order")
            ) { onMove(addon) }
            .focused($focus, equals: .move)
            .accessibilityIdentifier("addons_detail_move")
        case .catalogs:
            let counts = Self.catalogCounts(keys: Self.catalogKeys(ownedBy: addon.manifestUrl, in: model.addons), catalogs: settings.catalogs)
            Button(action: onShowCatalogs) {
                SettingsRowChrome {
                    SettingsRowLabel(title: String(localized: "Catalogs from this add-on"))
                } trailing: {
                    SettingsTrailingValue(
                        value: Self.catalogsValue(on: counts.on, total: counts.total), showsChevron: true
                    )
                }
            }
            .focused($focus, equals: .catalogs)
            .accessibilityIdentifier("addons_detail_catalogs")
        case .remove:
            SettingsDestructiveRow(title: String(localized: "Remove")) { onRemove(addon) }
                .focused($focus, equals: .remove)
                .accessibilityIdentifier("addons_hub_detail_remove")
        }
    }

    private var refreshSubtitle: String {
        switch status {
        case .refreshing: return String(localized: "Refreshing…")
        case .stalled: return String(localized: "Still refreshing…")
        case .unavailable: return String(localized: "Unavailable — Retry to load it again")
        case .active, .disabled: return ""
        }
    }

    @ViewBuilder
    private func configureSection(_ addon: ManagedAddon) -> some View {
        let url = Self.configureUrl(addon.manifestUrl)
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Scan to configure this add-on on your phone.").font(Theme.Font.body)
            if qrFor == url, let image = qrImage {
                // The frame is the image's own whole-pixel size (at most 320 pt): no resampling.
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: image.size.width, height: image.size.height)
                    .accessibilityIdentifier("addons_hub_detail_qr")
            }
            // The QR carries the full URL (that is its job); the caption shows the host only, the
            // key stays off the screen.
            Text(AddonsViewModel.host(of: url) + "/…/configure")
                .font(Theme.Font.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusable(false)
    }
}
