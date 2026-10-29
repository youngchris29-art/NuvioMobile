import SwiftUI
import SharedCore

/// The Stream Badges section body (Appearance category): toggles + placement + imported
/// badge-pack management, all backed by the shared `StreamBadgeSettingsRepository` (syncs across
/// devices). Extracted from SettingsView.swift (Phase 2 HIG revamp file split) — logic and wiring
/// preserved verbatim.
///
/// beta.15 §C (C3a): the three toggles bind straight to the view-model instead of the legacy
/// value+action shim.
///
/// BUG-213 (GitHub #10): the per-pack row (name/filter-count + Active-or-"Set Active" + delete)
/// and `BadgeUrlEntryRow` used to be one List row each holding two controls, and a tvOS List row
/// is one focus target (the BUG-197 diagnosis), so the controls highlighted as one block. Each is
/// now two List rows built from the settings kit: a pack row that sets the pack active and a
/// separate Delete row; a URL field row and a separate Import row.
///
/// Review r1 P3-7: Delete Badge Pack takes its focused row and its pack row out together, so it
/// hands focus on, one runloop late as `ClaimsFocusAfterSwap` does: to the next pack's row (it
/// slides into the vacated slot), else to the URL field below. Not `ClaimsFocusAfterSwap` itself:
/// that claims from `onAppear`, and both targets are already on screen.
struct StreamBadgesSection: View {
    @ObservedObject var badges: BadgeSettingsViewModel
    @FocusState private var focusedPack: String?
    @FocusState private var urlFieldFocused: Bool

    /// The pack row that takes focus when `url`'s pack is deleted: the next one down; nil for the
    /// last pack (and an unknown url), whose hand-off goes to the URL field.
    nonisolated static func packFocusAfterDeleting(_ url: String, in urls: [String]) -> String? {
        guard let index = urls.firstIndex(of: url), index + 1 < urls.count else { return nil }
        return urls[index + 1]
    }

    var body: some View {
        Text("Badge packs add quality / HDR / audio-channel chips to stream results. Import a pack by its JSON URL \u{2014} packs imported on the Nuvio mobile app sync here automatically. Tip: Remote Setup (Account & Profiles) lets you paste the URL from a phone browser.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.Palette.textSecondary)
            .frame(maxWidth: 1100, alignment: .leading)

        SettingsToggleRow(
            title: String(localized: "File Size Badges"),
            subtitle: String(localized: "Shows each stream's file size, such as 4.2 GB, at the end of its first line."),
            isOn: Binding(get: { badges.showFileSizeBadges }, set: { badges.setShowFileSizeBadges($0) }),
            descriptionID: .appearanceBadgesFileSize
        )
        SettingsToggleRow(
            title: String(localized: "Show Add-on Logo"),
            subtitle: String(localized: "Shows the add-on's logo next to each source. The add-on name always shows on rows with a quality headline."),
            isOn: Binding(get: { badges.showAddonLogo }, set: { badges.setShowAddonLogo($0) }),
            descriptionID: .appearanceBadgesAddonLogo
        )
        SettingsToggleRow(
            title: String(localized: "Badges Above Title"),
            subtitle: badges.badgesOnTop
                ? String(localized: "Badge chips render above the quality line.")
                : String(localized: "Badge chips render at the bottom of the row."),
            isOn: Binding(get: { badges.badgesOnTop }, set: { badges.setBadgesOnTop($0) }),
            descriptionID: .appearanceBadgesAboveTitle
        )
        // Upstream 344117e73 / 83e528f00: badges for what is playing, in the player's top panel
        // (Info tab, under the title). Off by default; the pack row appears once it is on and a
        // pack is imported, and defaults to the stream list's pack.
        SettingsToggleRow(
            title: String(localized: "Show Badges in Player"),
            subtitle: String(localized: "Shows badges for the video and audio that is playing under the title in the player's Info tab."),
            isOn: Binding(get: { badges.showInPlayer }, set: { badges.setShowInPlayer($0) }),
            descriptionID: .appearanceBadgesInPlayer
        )
        if badges.showInPlayer, !badges.imports.isEmpty {
            SettingsPickerRow(
                title: String(localized: "Player Badge Pack"),
                selection: Binding(get: { badges.playerBadgeSource }, set: { badges.setPlayerBadgeSource($0) }),
                options: [""] + badges.imports.map(\.sourceUrl),
                descriptionID: .appearancePlayerBadgePack,
                label: { $0.isEmpty ? String(localized: "Same as Streams") : BadgeSettingsViewModel.packLabel($0) }
            )
        }

        if badges.imports.isEmpty {
            Text("No badge packs imported yet.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
        } else {
            ForEach(badges.imports, id: \.sourceUrl) { pack in
                // Two List rows per pack, not one: the Set Active button and the Delete button
                // used to share a row, which the tvOS List treats as ONE focus target.
                Button {
                    // The active pack already is what a press would set; nothing to do.
                    if !pack.isActive { badges.setActive(pack.sourceUrl) }
                } label: {
                    SettingsRowChrome {
                        SettingsRowLabel(
                            title: BadgeSettingsViewModel.packLabel(pack.sourceUrl),
                            subtitle: pack.enabledFilterCount == 1 ? String(localized: "1 filter \u{00B7} \(pack.sourceUrl)") : String(localized: "\(pack.enabledFilterCount) filters \u{00B7} \(pack.sourceUrl)"),
                            systemImage: pack.isActive ? "checkmark.circle.fill" : "checkmark.circle",
                            descriptionID: .appearanceBadgePack
                        )
                        .lineLimit(1)
                    } trailing: {
                        SettingsTrailingValue(
                            value: pack.isActive ? String(localized: "Active") : String(localized: "Set Active"),
                            showsChevron: false
                        )
                    }
                }
                .focused($focusedPack, equals: pack.sourceUrl)
                SettingsDestructiveRow(
                    title: String(localized: "Delete Badge Pack"),
                    systemImage: "trash",
                    descriptionID: .appearanceBadgePack
                ) {
                    let next = Self.packFocusAfterDeleting(pack.sourceUrl, in: badges.imports.map(\.sourceUrl))
                    badges.deletePack(pack.sourceUrl)
                    DispatchQueue.main.async {
                        if let next { focusedPack = next } else { urlFieldFocused = true }
                    }
                }
            }
        }

        BadgeUrlEntryRow(isImporting: badges.isImporting, fieldFocused: $urlFieldFocused) { badges.importPack(url: $0) }

        if let status = badges.statusMessage {
            Text(status)
                .font(Theme.Font.caption)
                .foregroundStyle(status.hasPrefix("Imported") ? Theme.Palette.textSecondary : .red)
        }
    }
}

/// URL entry + import button for a stream badge pack (mirrors `PluginRepoEntryRow`). BUG-213: the
/// `Group` body yields TWO List rows, the URL field row (rest platter follows the field's
/// `@FocusState`, a `TextField` has no label to read `\.isFocused` from) and an Import kit row,
/// so each is its own focus target. `@State url` stays owned by this struct. No in-content glass
/// (HIG hybrid contract: glass is floating chrome).
private struct BadgeUrlEntryRow: View {
    let isImporting: Bool
    /// Owned by `StreamBadgesSection`, which hands focus here after the last pack is deleted.
    var fieldFocused: FocusState<Bool>.Binding
    let onImport: (String) -> Void
    @State private var url = ""

    var body: some View {
        Group {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "tag")
                    .font(SettingsRowFont.title)
                    .foregroundStyle(.secondary)
                TextField("Badge pack JSON URL", text: $url)
                    .textFieldStyle(.plain)
                    .font(SettingsRowFont.title)
                    .focused(fieldFocused)
            }
            .modifier(SettingsRestPlatter(explicitFocus: fieldFocused.wrappedValue))
            .settingsDescription(.appearanceBadgeImport, title: String(localized: "Badge pack JSON URL"), systemImage: "tag", focused: fieldFocused.wrappedValue)

            // Not `.disabled(isImporting)`: the pressed button lost focus. Guarded in the action,
            // and the label stays the same row while importing (the spinner rides in `trailing`).
            Button {
                if !url.isEmpty, !isImporting {
                    onImport(url)
                    url = ""
                }
            } label: {
                SettingsRowChrome {
                    SettingsRowLabel(
                        title: String(localized: "Import Badge Pack"),
                        systemImage: "plus",
                        descriptionID: .appearanceBadgeImport
                    )
                } trailing: {
                    if isImporting {
                        ProgressView().scaleEffect(0.6)
                    }
                }
            }
        }
    }
}
