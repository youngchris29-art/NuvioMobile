import SwiftUI
import SharedCore

/// Add-ons manager. Paste a Stremio-compatible manifest URL (e.g. your TorBox or Torrentio addon URL
/// with your debrid key embedded) to install a streaming source, then manage installed addons.
struct AddonsView: View {
    @StateObject private var model = AddonsViewModel()
    @State private var newUrl = ""

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 40) {
                    installSection
                    installedSection
                }
                .padding(60)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Add-ons")
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install from manifest URL").font(.title2).bold()
            Text("Paste the manifest URL from your streaming addon's config page (e.g. your TorBox or Torrentio URL with your API key). It ends in /manifest.json.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: 1200, alignment: .leading)

            HStack(spacing: 16) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("https://\u{2026}/manifest.json", text: $newUrl)
                    .textFieldStyle(.plain)
                    .font(.title3)
            }
            .padding(20)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

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

                if DebugConfig.hasManifestURL {
                    Button {
                        model.install(DebugConfig.manifestURL)
                    } label: {
                        Label("Quick install (from DebugConfig)", systemImage: "wrench.and.screwdriver")
                            .padding(.horizontal, 16).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isInstalling)
                }

                if model.isInstalling { ProgressView() }
                if let status = model.statusMessage {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Installed").font(.title2).bold()

            if model.addons.isEmpty {
                Text("No addons installed yet.").foregroundStyle(.secondary)
            }

            ForEach(Array(model.addons.enumerated()), id: \.offset) { _, addon in
                AddonRow(
                    title: model.displayName(addon),
                    subtitle: addon.manifestUrl,
                    enabled: addon.enabled,
                    onToggle: { model.setEnabled(addon, !addon.enabled) },
                    onRemove: { model.remove(addon) }
                )
            }
        }
    }
}

private struct AddonRow: View {
    let title: String
    let subtitle: String
    let enabled: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)

            Button(action: onToggle) {
                Label(enabled ? "Enabled" : "Disabled",
                      systemImage: enabled ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.bordered)

            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
