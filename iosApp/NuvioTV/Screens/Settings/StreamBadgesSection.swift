import SwiftUI
import SharedCore

/// The Stream Badges section body (Appearance category): toggles + placement + imported
/// badge-pack management, all backed by the shared `StreamBadgeSettingsRepository` (syncs across
/// devices). Extracted from SettingsView.swift (Phase 2 HIG revamp file split) — logic and wiring
/// preserved verbatim.
struct StreamBadgesSection: View {
    @ObservedObject var badges: BadgeSettingsViewModel

    var body: some View {
        Text("Badge packs add quality / HDR / audio-channel chips to stream results. Import a pack by its JSON URL \u{2014} packs imported on the Nuvio mobile app sync here automatically. Tip: Remote Setup (Advanced) lets you paste the URL from a phone browser.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        SettingsToggleRow(
            title: String(localized: "File Size Badges"),
            subtitle: String(localized: "Show the video size (GB/MB) as a chip on stream results."),
            isOn: badges.showFileSizeBadges
        ) {
            badges.setShowFileSizeBadges(!badges.showFileSizeBadges)
        }
        SettingsToggleRow(
            title: String(localized: "Show Add-on Logo"),
            subtitle: String(localized: "Show each result's add-on logo and name on the right of the row."),
            isOn: badges.showAddonLogo
        ) {
            badges.setShowAddonLogo(!badges.showAddonLogo)
        }
        SettingsToggleRow(
            title: String(localized: "Badges Above Title"),
            subtitle: badges.badgesOnTop
                ? String(localized: "Badge chips render above the stream name.")
                : String(localized: "Badge chips render below the stream description."),
            isOn: badges.badgesOnTop
        ) {
            badges.setBadgesOnTop(!badges.badgesOnTop)
        }

        if badges.imports.isEmpty {
            Text("No badge packs imported yet.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else {
            ForEach(badges.imports, id: \.sourceUrl) { pack in
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(BadgeSettingsViewModel.packLabel(pack.sourceUrl))
                            .font(Theme.Font.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        Text(pack.enabledFilterCount == 1 ? String(localized: "1 filter \u{00B7} \(pack.sourceUrl)") : String(localized: "\(pack.enabledFilterCount) filters \u{00B7} \(pack.sourceUrl)"))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if pack.isActive {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(Theme.Font.meta)
                            .foregroundStyle(Theme.Palette.accent)
                    } else {
                        Button("Set Active") { badges.setActive(pack.sourceUrl) }
                            .buttonStyle(.chip)
                            .font(Theme.Font.meta)
                    }
                    Button {
                        badges.deletePack(pack.sourceUrl)
                    } label: {
                        Image(systemName: "trash")
                            .font(Theme.Font.caption)
                    }
                    .buttonStyle(.chip)
                }
            }
        }

        BadgeUrlEntryRow(isImporting: badges.isImporting) { badges.importPack(url: $0) }

        if let status = badges.statusMessage {
            Text(status)
                .font(Theme.Font.caption)
                .foregroundStyle(status.hasPrefix("Imported") ? Theme.Palette.textSecondary : .red)
        }
    }
}

/// URL entry + import button for a stream badge pack (mirrors `PluginRepoEntryRow`).
private struct BadgeUrlEntryRow: View {
    let isImporting: Bool
    let onImport: (String) -> Void
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "tag")
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextField("Badge pack JSON URL", text: $url)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .padding(Theme.Spacing.lg)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

            Button {
                if !url.isEmpty {
                    onImport(url)
                    url = ""
                }
            } label: {
                if isImporting {
                    ProgressView()
                } else {
                    Label("Import Badge Pack", systemImage: "plus")
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xxs + 2)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting)
        }
    }
}
