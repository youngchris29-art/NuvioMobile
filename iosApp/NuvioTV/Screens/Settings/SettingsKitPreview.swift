import SwiftUI

#if DEBUG
/// THROWAWAY visual spike (beta.15 plan §C, task C0) — proves stock tvOS 26 `List` alone gives us
/// Settings.app-style rows (section headers/footers, toggles, a Menu-driven picker row, a plain
/// value row, a pushed detail row, a destructive action) with ZERO custom styling. Deliberately
/// does not reuse this app's real Settings screen (`SettingsView.swift` + `Screens/Settings/*Pane`)
/// or its custom row/button styles — this file exists only to be looked at and compared, then
/// deleted. Nothing else in the app references any type in this file.
///
/// Sim workflow (mirrors `debug.mpvSmokeURL` — see MPVSmokeTest.swift):
///   xcrun simctl spawn <dev> defaults write com.nuvio.media.NuvioTV debug.settingsKitPreview -bool true
///   xcrun simctl launch --console-pty <dev> com.nuvio.media.NuvioTV
///   xcrun simctl spawn <dev> defaults delete com.nuvio.media.NuvioTV debug.settingsKitPreview
struct SettingsKitPreview: View {
    private enum Category: String, CaseIterable, Identifiable, Hashable {
        case account, playback, appearance, sources, about

        var id: String { rawValue }

        var label: String {
            switch self {
            case .account: return "Account"
            case .playback: return "Playback"
            case .appearance: return "Appearance"
            case .sources: return "Sources"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .account: return "person.crop.circle"
            case .playback: return "play.rectangle"
            case .appearance: return "paintbrush"
            case .sources: return "puzzlepiece.extension"
            case .about: return "info.circle"
            }
        }
    }

    private let qualities = ["Auto", "1080p", "720p"]

    @State private var selectedCategory: Category? = .account
    @State private var skipIntro = true
    @State private var quality = "Auto"
    @State private var confirmingSignOut = false
    @Namespace private var categoryFocus
    @FocusState private var focusedCategory: Category?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("Settings (kit preview)")
                    .font(Theme.Font.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, Theme.Spacing.screen)
                    .padding(.top, Theme.Spacing.lg)

                HStack(spacing: 0) {
                    // LEFT: stock category list, ~1/3 of the width.
                    // Plain Label rows are NOT focusable on tvOS even inside List(selection:);
                    // the native recipe is a Button per row (system list-row platter) with
                    // activate-on-focus, like Settings.app.
                    List(selection: $selectedCategory) {
                        ForEach(Category.allCases) { category in
                            Button { selectedCategory = category } label: {
                                Label(category.label, systemImage: category.symbol)
                            }
                            .tag(category)
                            .focused($focusedCategory, equals: category)
                            .accessibilityIdentifier("kit.category.\(category.rawValue)")
                            .prefersDefaultFocus(category == .account, in: categoryFocus)
                        }
                    }
                    .focusScope(categoryFocus)
                    .onChange(of: focusedCategory) { _, new in if let new { selectedCategory = new } }
                    .frame(maxWidth: .infinity)

                    // RIGHT: stock two-section detail list.
                    List {
                        Section {
                            Toggle("Skip Intro", isOn: $skipIntro)
                                .accessibilityIdentifier("kit.toggle")

                            Menu {
                                Picker("Quality", selection: $quality) {
                                    ForEach(qualities, id: \.self) { option in
                                        Text(option).tag(option)
                                    }
                                }
                            } label: {
                                LabeledContent("Quality", value: quality)
                            }
                            .accessibilityIdentifier("kit.picker")

                            LabeledContent("Version", value: "0.3.0")
                                .accessibilityIdentifier("kit.version")
                        } header: {
                            Text("Playback")
                        } footer: {
                            Text("Stock List section header/footer, straight from tvOS 26 — no custom row style applied anywhere on this screen.")
                        }

                        Section {
                            NavigationLink("Server") {
                                SettingsKitPreviewSubPage()
                            }
                            .accessibilityIdentifier("kit.serverLink")
                        } header: {
                            Text("Connection")
                        }

                        Section {
                            Button("Sign Out", role: .destructive) {
                                confirmingSignOut = true
                            }
                            .accessibilityIdentifier("kit.signOut")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .background(Theme.Palette.background.ignoresSafeArea())
        }
        .alert("Sign Out?", isPresented: $confirmingSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {}
        } message: {
            Text("Spike alert only — nothing is actually signed out here.")
        }
    }
}

/// Pushed detail page for the "Server" row — just enough to prove a plain `NavigationLink` push
/// reads correctly inside a stock `List`.
private struct SettingsKitPreviewSubPage: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Text("sub page")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textPrimary)
            Button("Back") { dismiss() }
                .accessibilityIdentifier("kit.subPageBack")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.background.ignoresSafeArea())
    }
}

/// Presents `SettingsKitPreview` full-screen from the app root, gated on `debug.settingsKitPreview`
/// — same shape as `MPVSmokeModifier` (MPVSmokeTest.swift). Wired into `ContentView` under `#if
/// DEBUG` alongside the other debug modifiers.
struct SettingsKitPreviewModifier: ViewModifier {
    @State private var showPreview = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !showPreview else { return }
                showPreview = UserDefaults.standard.bool(forKey: "debug.settingsKitPreview")
            }
            .fullScreenCover(isPresented: $showPreview) {
                SettingsKitPreview()
            }
    }
}
#endif
