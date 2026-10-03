import SwiftUI

// MARK: - Settings root (FEAT-50, detail-settings-revamp W1-B)

/// The Settings tab's root: one "Settings" title, the explainer on the left (~1/3: large accent
/// symbol, the focused category's title and summary) and a native grouped `List` of category
/// `Button`s on the right. Selecting a category pushes its pane (`SettingsPaneScaffold`) by
/// writing the `NavigationStack` path, which `ContentView` owns so it survives the theme `.id()`
/// remount.
///
/// ## Focus graph (written before the code, per the tvOS skill's workflow)
///
/// **Default focus.** The `List` is a `.focusScope(rootFocus)`; the row for `lastCategory` (the
/// category the user last opened, `Account & Profiles` on a cold mount) carries
/// `.prefersDefaultFocus(true, in: rootFocus)`. Entering the tab, popping back from a pane, and
/// popping after a theme remount all land on that row. There is no `@FocusState` write on appear:
/// the scope's default is the only mechanism, so tvOS's own focus memory still wins where the
/// system wants it to.
///
/// **List.** Up / Down walk the ten categories across the four groups (headers are not
/// focusable). Up from the first row leaves upward to the tab bar; Down from the last does
/// nothing. Left and Right do nothing (the explainer is not focusable). Select pushes the pane.
///
/// **Menu.** In sidebar navigation mode `.sidebarMenuReveal()` (attached by `SettingsView` on this
/// view, inside the stack) reveals the sidebar; in tabs mode the system default applies (focus to
/// the tab bar, then exit). Inside a pane Menu pops back here — panes are stack destinations, not
/// descendants of this view, so this view's exit handler never sees their Menu press.
///
/// **Explainer.** Driven by `SettingsRootFocusModel`, written from inside each row's label (the
/// one place `\.isFocused` is populated) and observed only by the explainer column, so a focus
/// move re-renders the column and not this List (corrections F21b). It never clears: focus
/// leaving for the tab bar keeps the last category up.
///
/// **Minimal style** (`settings_style == "minimal"`): no explainer column and no row icons; rows
/// keep their title + subtitle, the rest platter and the chevron.
///
/// **D11 visual pass:** each category row sits on the kit's rest platter (`SettingsRowChrome`)
/// with a trailing `›`, and the group headers come from `SettingsSection` (small uppercase).
struct SettingsRootView: View {
    @Binding var path: [SettingsCategory]
    @Binding var lastCategory: SettingsCategory?

    @AppStorage("settings_style") private var settingsStyle = "default"
    @StateObject private var focusModel = SettingsRootFocusModel()
    @Namespace private var rootFocus

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // One title for the whole screen (HIG Split views: never one per column).
            Text("Settings")
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Spacing.screen)
                .padding(.top, Theme.Spacing.lg)

            GeometryReader { geo in
                HStack(spacing: Theme.Spacing.xl) {
                    if settingsStyle != "minimal" {
                        SettingsRootExplainer(model: focusModel)
                            .frame(width: max(400, geo.size.width / 3))
                            .padding(.leading, Theme.Spacing.screen)
                    }

                    categoryList
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            // Seed the explainer so a remount or a pop shows the category focus will land on,
            // before the first focus report arrives.
            focusModel.didFocus(lastCategory ?? .accountProfiles)
        }
    }

    private var categoryList: some View {
        List {
            ForEach(SettingsCategoryGroup.allCases, id: \.self) { group in
                SettingsSection(group.title) {
                    ForEach(group.categories) { category in
                        Button {
                            lastCategory = category
                            path = [category]
                        } label: {
                            // D11: the same rest platter and trailing `›` as the pane rows (mockup
                            // option 1's list), inside the Button's label so the platter fades
                            // out under the system focus platter.
                            SettingsRowChrome {
                                rowLabel(category)
                            } trailing: {
                                SettingsTrailingValue(value: nil)
                            }
                            .modifier(SettingsRootRowFocusReporter(category: category, model: focusModel))
                        }
                        .prefersDefaultFocus(category == (lastCategory ?? .accountProfiles), in: rootFocus)
                        // Keeps `app.buttons["Appearance"]` etc. resolving at the root.
                        .accessibilityLabel(Text(category.title))
                        .accessibilityHint(Text(category.subtitle))
                        .accessibilityIdentifier("settings_category_\(category.rawValue)")
                    }
                }
            }
        }
        .focusScope(rootFocus)
        .environment(\.settingsUsesNativeList, true)
        .accessibilityIdentifier("settings_root_list")
    }

    @ViewBuilder
    private func rowLabel(_ category: SettingsCategory) -> some View {
        if settingsStyle == "minimal" {
            SettingsRowLabel(title: category.title, subtitle: String(localized: category.subtitle))
        } else {
            // The kit label: accent glyph at rest, platter-flipped on focus, `Theme.Font` tokens,
            // and no explicit title colour (BUG-45). No `descriptionID`: the root explainer is
            // driven by the root focus model, not the pane explainer.
            SettingsRowLabel(
                title: category.title,
                subtitle: String(localized: category.subtitle),
                systemImage: category.icon
            )
        }
    }
}

/// The only view observing the root focus model (corrections F21b).
private struct SettingsRootExplainer: View {
    @ObservedObject var model: SettingsRootFocusModel

    var body: some View {
        SettingsExplainerColumn(
            systemImage: model.category.icon,
            title: model.category.title,
            text: Text(model.category.summary)
        )
    }
}
