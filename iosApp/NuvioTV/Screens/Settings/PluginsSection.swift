import SwiftUI
import SharedCore

/// The Plugins section body (master switch, per-scraper toggles, repository entry), moved out of
/// `SourcesSettingsPane` so the Add-ons hub can host it too. The pane wraps it in
/// `SettingsSection("Plugins")`.
struct PluginsSection: View {
    @ObservedObject var plugins: PluginsViewModel
    /// The viewer's own open/closed choice per plugin repository, by manifest URL (absent = the
    /// default rule, `PluginsViewModel.isRepositoryExpanded`: collapsed, except a lone repository).
    /// Stored as the choice itself, never as a flip of the default, so installing or removing
    /// another repository cannot invert it; never set in `onAppear`, which a lazy List re-fires.
    @State private var pluginRepoExpanded: [String: Bool] = [:]
    /// Drives the "Remove repository?" confirmation.
    @State private var pendingPluginRepoRemoval: PluginRepositoryItem?
    /// W3-2 (c): the manifest URL of a repository whose removal was just confirmed. Once it leaves
    /// `plugins.repositories` the manifest field takes focus (the Remove row it came from is gone).
    @State private var pendingFocusAfterRemoval: String?
    @FocusState private var manifestFieldFocused: Bool

    /// The Plugins section body: master switch + per-scraper toggles. Repos are managed on the
    /// phone and arrive via cloud sync (sync-only v1) — reflected in the empty-state copy.
    /// Review r1 P2-1 / r2 P2-1: whatever removed a repository (the alert, a sync), both pending
    /// values clear once its URL has left the list, and focus moves to the manifest field.
    private func reconcilePendingRemoval(_ urls: [String]) {
        if let pending = pendingPluginRepoRemoval, !urls.contains(pending.manifestUrl) {
            pendingPluginRepoRemoval = nil
        }
        if let removed = pendingFocusAfterRemoval, !urls.contains(removed) {
            pendingFocusAfterRemoval = nil
            // Focus moves at once. If the device pass shows the List winning the race with the
            // dismissing alert, the device pass decides on a delay instead:
            // Task { try? await Task.sleep(for: .milliseconds(350)); manifestFieldFocused = true }
            manifestFieldFocused = true
        }
    }

    var body: some View {
        Group {
            Text("JS plugin providers add extra stream sources. Install a repository by its manifest URL \u{2014} it syncs to your other Nuvio devices automatically.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)

            SettingsToggleRow(
                title: String(localized: "Enable Plugins"),
                subtitle: String(localized: "Run enabled plugin providers when loading streams."),
                isOn: Binding(
                    get: { plugins.pluginsEnabled },
                    set: { plugins.setPluginsEnabled($0) }
                ),
                descriptionID: .sourcesPluginsEnabled
            )

            SettingsToggleRow(
                title: String(localized: "Group by Repository"),
                subtitle: String(localized: "In the streams list, show one group per repository instead of one per provider."),
                isOn: Binding(
                    get: { plugins.groupStreamsByRepository },
                    set: { plugins.setGroupStreamsByRepository($0) }
                ),
                descriptionID: .sourcesPluginsGroupByRepository
            )

            PluginRepoEntryRow(isInstalling: plugins.isInstalling, fieldFocused: $manifestFieldFocused) { plugins.addRepository($0) }
                // The repositories observer lives on the entry row because it is ALWAYS present: inside
                // the list's `else` branch it was torn down in the same update that removed the LAST
                // repository, so focus never moved and the pending values stayed set (review r1 P2-1).
                // Whatever removed the URL (the alert, a sync), both pending values clear here.
                // Wave 3 review r2 (P2-1): the entry row is a LAZY List row. With a long provider list
                // expanded it is off screen when Remove is confirmed, and an off-screen row runs no
                // `onChange`; so the same reconcile also runs when the row (re)appears.
                .onChange(of: plugins.repositories.map(\.manifestUrl)) { _, urls in
                    reconcilePendingRemoval(urls)
                }
                .onAppear { reconcilePendingRemoval(plugins.repositories.map(\.manifestUrl)) }

            if let status = plugins.statusMessage {
                Text(status)
                    .font(Theme.Font.caption)
                    .foregroundStyle(status.hasPrefix("Installed") ? Theme.Palette.textSecondary : .red)
            }

            if plugins.repositories.isEmpty {
                Text("No plugin repositories installed yet.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                // Each repository yields SEPARATE List rows (one focusable row each): a header that
                // collapses/expands it, an optional error caption, and, while expanded, one row per
                // provider plus a Remove row. Wrapping them in one VStack made the List treat the
                // whole block as a single focusable row, so one click flipped every provider at once.
                // Repositories start collapsed so a long provider list doesn't bury the next repo.
                ForEach(plugins.repositories, id: \.manifestUrl) { repo in
                    let isExpanded = PluginsViewModel.isRepositoryExpanded(stored: pluginRepoExpanded[repo.manifestUrl],
                                                                           repositoryCount: plugins.repositories.count)
                    // Providers listed A–Z (Finder-style: case-insensitive, "Provider 2" before "Provider 10").
                    let repoScrapers = PluginsViewModel.sortedScrapers(plugins.scrapers(in: repo))
                    let enabledCount: Int = repoScrapers.filter { $0.enabled }.count
                    Button {
                        pluginRepoExpanded[repo.manifestUrl] = !isExpanded
                    } label: {
                        SettingsRowChrome {
                            SettingsRowLabel(
                                title: repo.name,
                                // Review r1 P3 (plural): one key per grammatical number, so every
                                // language gets a real singular instead of "1 of 1 providers on".
                                subtitle: repoScrapers.count == 1
                                    ? String(localized: "\(enabledCount) of 1 provider on")
                                    : String(localized: "\(enabledCount) of \(repoScrapers.count) providers on"),
                                systemImage: isExpanded ? "chevron.down" : "chevron.right",
                                descriptionID: .sourcesPluginRepoHeader
                            )
                        } trailing: {
                            if repo.isRefreshing {
                                ProgressView().scaleEffect(0.6)
                            }
                        }
                    }
                    .accessibilityHint(isExpanded ? String(localized: "Collapses the provider list.") : String(localized: "Shows the provider list."))
                    if let error = repo.errorMessage, !error.isEmpty {
                        Text(error)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.red)
                    }
                    if isExpanded {
                        // One switch for the whole repository, above its providers.
                        if repoScrapers.count > 1 {
                            SettingsToggleRow(
                                title: String(localized: "All Providers"),
                                subtitle: String(localized: "Turn every provider in \(repo.name) on or off."),
                                isOn: Binding(
                                    get: { PluginsViewModel.isRepositoryOn(repoScrapers) },
                                    set: { plugins.setRepositoryEnabled(repo, $0) }
                                ),
                                descriptionID: .sourcesPluginRepoAll
                            )
                        }
                        ForEach(repoScrapers, id: \.id) { scraper in
                            SettingsToggleRow(
                                title: scraper.name,
                                subtitle: scraper.description_.isEmpty
                                    ? String(localized: "v\(scraper.version)")
                                    : String(localized: "\(scraper.description_) \u{00B7} v\(scraper.version)"),
                                isOn: Binding(
                                    get: { scraper.enabled },
                                    set: { plugins.toggleScraper(scraper, $0) }
                                ),
                                descriptionID: .sourcesPluginScraper
                            )
                        }
                        SettingsDestructiveRow(
                            title: String(localized: "Remove Repository"),
                            subtitle: String(localized: "Removes \(repo.name) and its providers."),
                            systemImage: "trash",
                            descriptionID: .sourcesPluginRepo
                        ) {
                            pendingPluginRepoRemoval = repo
                        }
                        // Review r1 P2-5: the alert lives on the Remove row itself (one presenter, on the
                        // row that is focused when pressed), not on the Section.
                        .alert(
                            String(localized: "Remove repository?"),
                            isPresented: Binding(
                                get: { pendingPluginRepoRemoval?.manifestUrl == repo.manifestUrl },
                                set: { if !$0 { pendingPluginRepoRemoval = nil } }
                            )
                        ) {
                            Button(String(localized: "Remove"), role: .destructive) {
                                pluginRepoExpanded[repo.manifestUrl] = nil
                                // Review r2 (P3-3): cleared here too, so a row that leaves while the
                                // alert is up (a sync removal) cannot leave the request pending.
                                pendingPluginRepoRemoval = nil
                                pendingFocusAfterRemoval = repo.manifestUrl
                                plugins.removeRepository(repo)
                            }
                            Button(String(localized: "Cancel"), role: .cancel) {}
                        } message: {
                            Text("\(repo.name) and its providers will be removed from this Apple TV.")
                        }
                    }
                }
                SettingsActionRow(
                    title: String(localized: "Refresh Plugins"),
                    subtitle: String(localized: "Re-download provider code from every repository."),
                    systemImage: "arrow.clockwise",
                    descriptionID: .sourcesPluginsRefresh
                ) {
                    plugins.refreshAll()
                }
            }
        }
    }
}

/// Manifest-URL entry for installing a plugin repository from the TV (mirrors the addon install
/// row; the shared repo normalizes the URL and appends /manifest.json).
///
/// BUG-213 (GitHub #10): this used to be ONE List row holding the field and the Install button,
/// and a tvOS List row is one focus target (the BUG-197 diagnosis), so the two highlighted as one
/// block and Select did not reach the field. The `Group` body now yields TWO List rows, the same
/// split `MdbListActivationCard` uses: the manifest field row (its rest platter follows the
/// field's `@FocusState`, a `TextField` has no label to read `\.isFocused` from) and an Install
/// kit row. `@State url` stays owned by this struct, so both rows share it. The in-content
/// `.glassEffect` is gone: glass belongs to floating chrome (HIG hybrid contract), and the List
/// row already has the system's background and focus treatment.
private struct PluginRepoEntryRow: View {
    let isInstalling: Bool
    var fieldFocused: FocusState<Bool>.Binding
    let onInstall: (String) -> Void
    @State private var url = ""

    var body: some View {
        Group {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "puzzlepiece.extension")
                    .font(SettingsRowFont.title)
                    .foregroundStyle(.secondary)
                TextField("Repository manifest URL", text: $url)
                    .textFieldStyle(.plain)
                    .font(SettingsRowFont.title)
                    .focused(fieldFocused)
            }
            .modifier(SettingsRestPlatter(explicitFocus: fieldFocused.wrappedValue))
            .settingsDescription(.sourcesPluginRepoAdd, title: String(localized: "Repository manifest URL"), systemImage: "puzzlepiece.extension", focused: fieldFocused.wrappedValue)

            // Not `.disabled(isInstalling)`: the pressed button lost focus. Guarded in the action,
            // and the label stays the same row while installing (the spinner rides in `trailing`).
            Button {
                if !url.isEmpty, !isInstalling {
                    onInstall(url)
                    url = ""
                }
            } label: {
                SettingsRowChrome {
                    SettingsRowLabel(
                        title: String(localized: "Install Repository"),
                        systemImage: "plus",
                        descriptionID: .sourcesPluginRepoAdd
                    )
                } trailing: {
                    if isInstalling {
                        ProgressView().scaleEffect(0.6)
                    }
                }
            }
        }
    }
}
