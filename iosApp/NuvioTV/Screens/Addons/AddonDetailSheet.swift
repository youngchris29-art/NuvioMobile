import SharedCore
import SwiftUI

/// Add-ons hub C, H2: the sheet opened by pressing an add-on's name area. Reads the add-on LIVE
/// from `model` (a refresh started here updates the sheet in place) and falls back to the
/// snapshot it was opened with, so the sheet never blanks mid-removal. Remove hands back to the
/// hub, which dismisses the sheet before it raises the confirm alert (an alert cannot present
/// over a sheet).
struct AddonDetailSheet: View {
    @ObservedObject var model: AddonsViewModel
    let snapshot: ManagedAddon
    let isReadOnly: Bool
    let onRemove: () -> Void
    /// A3 review r2: the Installed row's Configure opens this page with the configure QR showing.
    var startsInConfigure = false

    @State private var showsConfigure = false
    @State private var appliedStartsInConfigure = false
    /// The rendered QR and the URL it was built for; rebuilt only when that URL changes.
    @State private var qrImage: UIImage?
    @State private var qrFor: String?

    private var addon: ManagedAddon {
        model.addons.first { $0.manifestUrl == snapshot.manifestUrl } ?? snapshot
    }

    var body: some View {
        let addon = addon
        // A3 review r3: opened through Configure, the actions and the QR come first, so the code
        // is on screen however long the description and catalog list are.
        let configureFirst = startsInConfigure && showsConfigure && addon.manifest?.behaviorHints.configurable == true
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text(AddonsViewModel.displayTitle(addon)).font(Theme.Font.screenTitle)
                if configureFirst {
                    buttons(addon)
                    configureSection(addon)
                }
                if let manifest = addon.manifest {
                    // Kotlin's `description` bridges as `description_`; plain `.description` is
                    // NSObject's, i.e. the data class's toString with the keyed transportUrl in it
                    // (seen on the box 2026-10-26).
                    let blurb = AddonDetailPane.blurb(of: manifest)
                    if !blurb.isEmpty {
                        Text(blurb).font(Theme.Font.body).lineLimit(6)
                    }
                    Text(versionLine(manifest)).font(Theme.Font.meta)
                    Text(AddonsViewModel.resourceLabels(of: manifest).joined(separator: " · ")).font(Theme.Font.meta)
                    catalogList(manifest)
                } else {
                    Text("Loading…").font(Theme.Font.meta).foregroundStyle(Theme.Palette.textSecondary)
                }
                Text(AddonDetailPane.locationLine(addon.manifestUrl))
                    .font(Theme.Font.caption).foregroundStyle(Theme.Palette.textSecondary)
                    .accessibilityIdentifier("addons_hub_detail_location")
                if !configureFirst {
                    buttons(addon)
                    if showsConfigure, addon.manifest?.behaviorHints.configurable == true {
                        configureSection(addon)
                    }
                }
            }
            .padding(Theme.Spacing.screen)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("addons_hub_detail_sheet")
        .onAppear {
            guard !appliedStartsInConfigure else { return }
            appliedStartsInConfigure = true
            if startsInConfigure { showsConfigure = true }
        }
        .task(id: qrKey(addon)) {
            let key = qrKey(addon)
            guard !key.isEmpty, key != qrFor else { return }
            qrImage = AddonDetailPane.makeQR(key)
            qrFor = key
        }
    }

    /// The configure URL while the QR is wanted, else "" (nothing to build).
    private func qrKey(_ addon: ManagedAddon) -> String {
        showsConfigure && addon.manifest?.behaviorHints.configurable == true
            ? AddonDetailPane.configureUrl(addon.manifestUrl) : ""
    }

    private func versionLine(_ manifest: AddonManifest) -> String {
        String(localized: "Version \(manifest.version)") + " · " + manifest.types.joined(separator: ", ")
    }

    @ViewBuilder
    private func catalogList(_ manifest: AddonManifest) -> some View {
        if !manifest.catalogs.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text("Catalogs").font(Theme.Font.cardTitle)
                ForEach(Array(manifest.catalogs.prefix(12).enumerated()), id: \.offset) { _, catalog in
                    Text(catalog.name).font(Theme.Font.caption)
                }
                if manifest.catalogs.count > 12 {
                    Text("+\(manifest.catalogs.count - 12) more")
                        .font(Theme.Font.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
    }

    private func buttons(_ addon: ManagedAddon) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                // A1/A2 review r1: on a stalled refresh, Refresh restarts the stuck request.
                if model.stalledUrls.contains(addon.manifestUrl) {
                    model.retryRefresh(manifestUrl: addon.manifestUrl)
                } else {
                    model.refresh(manifestUrl: addon.manifestUrl)
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise").padding(.horizontal, Theme.Spacing.sm)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("addons_hub_detail_refresh")

            Button(action: onRemove) {
                Label("Remove", systemImage: "trash").padding(.horizontal, Theme.Spacing.sm)
            }
            .buttonStyle(.bordered)
            .disabled(isReadOnly)
            .accessibilityIdentifier("addons_hub_detail_remove")

            if addon.manifest?.behaviorHints.configurable == true {
                Button {
                    showsConfigure.toggle()
                } label: {
                    Label("Configure", systemImage: "qrcode").padding(.horizontal, Theme.Spacing.sm)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("addons_hub_detail_configure")
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private func configureSection(_ addon: ManagedAddon) -> some View {
        let url = AddonDetailPane.configureUrl(addon.manifestUrl)
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
                .font(Theme.Font.caption).foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}
