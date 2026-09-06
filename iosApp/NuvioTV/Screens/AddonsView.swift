import SwiftUI
import SharedCore

/// Add-ons manager. Paste a Stremio-compatible manifest URL (e.g. your TorBox or Torrentio addon URL
/// with your debrid key embedded) to install a streaming source, then manage installed addons.
struct AddonsView: View {
    @StateObject private var model = AddonsViewModel()
    @State private var newUrl = ""
    /// Addon pending a remove confirmation (drives the alert below).
    @State private var addonPendingRemoval: ManagedAddon?

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 40) {
                    installSection
                        .focusSection()
                    installedSection
                        .focusSection()
                }
                .padding(60)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .reportsScrollToTabBar(tab: "Add-ons")
            // FEAT-30: Menu summons the sidebar in sidebar mode (a second Menu, with focus in the
            // sidebar, exits as before). No modifier at all in tabs mode.
            .sidebarMenuReveal()
            .navigationTitle("Add-ons")
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .alert(
            "Remove \(addonPendingRemoval.map { model.displayName($0) } ?? "")?",
            isPresented: Binding(
                get: { addonPendingRemoval != nil },
                set: { if !$0 { addonPendingRemoval = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let addon = addonPendingRemoval { model.remove(addon) }
                addonPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its catalogs and streams will no longer appear.")
        }
    }

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install from manifest URL").font(Theme.Font.screenTitle)
            Text("Paste the manifest URL from your streaming addon's config page (e.g. your TorBox or Torrentio URL with your API key). It ends in /manifest.json.")
                .font(Theme.Font.body).foregroundStyle(.secondary)
                .frame(maxWidth: 1200, alignment: .leading)

            HStack(spacing: 16) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("https://\u{2026}/manifest.json", text: $newUrl)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.screenTitle.weight(.regular))
            }
            .padding(20)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 20) {
                Button {
                    model.install(newUrl)
                    newUrl = ""
                } label: {
                    Label("Install", systemImage: "plus.circle.fill")
                        .padding(.horizontal, 16).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isInstalling)

                #if DEBUG
                if DebugConfig.hasManifestURL {
                    Button {
                        model.install(DebugConfig.manifestURL)
                    } label: {
                        Label("Quick install (from DebugConfig)", systemImage: "wrench.and.screwdriver")
                            .padding(.horizontal, 16).padding(.vertical, 6)
                    }
                    .buttonStyle(.chip)
                    .disabled(model.isInstalling)
                }
                #endif

                if model.isInstalling { ProgressView() }
                if let status = model.statusMessage {
                    Text(status).font(Theme.Font.body).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Installed").font(Theme.Font.screenTitle)

            if model.addons.isEmpty {
                Text("No addons installed yet.").foregroundStyle(.secondary)
            }

            ForEach(Array(model.addons.enumerated()), id: \.offset) { _, addon in
                AddonRow(
                    title: model.displayName(addon),
                    subtitle: addon.manifestUrl,
                    enabled: addon.enabled,
                    onToggle: { model.setEnabled(addon, !addon.enabled) },
                    onRemove: { addonPendingRemoval = addon }
                )
            }
        }
    }
}

/// A focusable add-on card. Select toggles enabled/disabled; long-press (context menu) removes.
private struct AddonRow: View {
    let title: String
    let subtitle: String
    let enabled: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 24) {
                Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    .font(Theme.Font.body)
                    .rowAccentTint(enabled)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.Font.sectionTitle).lineLimit(1)
                    Text(subtitle).font(Theme.Font.caption).rowTextColor(secondary: true).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(enabled ? String(localized: "Enabled") : String(localized: "Disabled"))
                    .font(Theme.Font.body)
                    .rowTextColor(secondary: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.settingsRow)
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label("Remove Add-on", systemImage: "trash")
            }
        }
    }
}
