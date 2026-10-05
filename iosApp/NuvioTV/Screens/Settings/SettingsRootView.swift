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
/// **Default focus.** The target row is `lastCategory` (the category the user last opened,
/// `Account & Profiles` when nothing has been opened this launch). Entering the tab, popping back
/// from a pane, and popping after a theme remount all land on it.
///
/// UI legs showed `.focusScope` + `.prefersDefaultFocus` is NOT honoured by a freshly built tvOS
/// `List` (test40: cold entry + Down landed on "Services"; test43: pop after the theme `.id()`
/// remount landed on "Account & Profiles"); only the plain push → pop (test81) worked, through
/// the system's own focus memory. So the root uses a `@FocusState` (`focusedCategory`) with two
/// layers:
/// 1. `.defaultFocus($focusedCategory, target)` on the `List` for automatic focus placement.
/// 2. A ONE-SHOT landing correction (`landingCorrectionArmed`). It is armed when the root becomes
///    visible with an empty path (`onAppear`: cold entry / tab switch back) and when the path
///    empties (a pop, including the pop after a remount, where the root was rebuilt hidden). The
///    FIRST focus report that lands on a row after arming disarms it, and if that landing is not
///    the target, focus is moved to the target once (deliberately no direct write on pop: during
///    the transition the rows are not focusable and a recorded write would disarm the correction
///    early). On a plain pop the system's memory and the
///    target are the same row (`lastCategory` is set by the Select that pushed), so nothing moves.
///    After the first landing nothing ever writes focus again: no repeated forcing, no stealing
///    focus after user input. Arming does not pull focus out of the tab bar or the rail: it only
///    acts once focus enters the list on its own. A rail exit arms it too (H9, P4 #21): the root
///    registers a rail return route whose restore arms the correction and takes the default
///    hand-off, so focus that lands in the freshly re-entered List moves to `lastCategory`.
///
/// **List.** Up / Down walk the ten categories across the four groups (headers are not
/// focusable). Up from the first row leaves upward to the tab bar; Down from the last does
/// nothing. Left and Right do nothing (the explainer is not focusable). Select pushes the pane.
///
/// **Menu.** In Rail navigation mode `.railMenuReveal()` (attached by `SettingsView` on this view,
/// inside the stack) opens the navigation rail; in tabs mode the system default applies (focus to
/// the tab bar, then exit). In Rail mode Left from a row also opens the rail (nothing focusable
/// sits left of the List). Inside a pane Menu pops back here — panes are stack destinations, not
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
    /// `@State`, not `@StateObject`: owned but not observed, so a focus move re-renders only
    /// `SettingsRootExplainer` (`@ObservedObject`), never this body and its `List` (review r1).
    @State private var focusModel = SettingsRootFocusModel()
    /// Which category row holds focus (nil = focus is outside the list). Read by this body, so a
    /// focus move re-renders the root (ten rows, cheap); the explainer model stays unobserved here.
    @FocusState private var focusedCategory: SettingsCategory?
    /// One-shot "correct the next landing" flag; see the focus graph above.
    @State private var landingCorrectionArmed = false
    /// Review r1 (B P3-5): the row that held focus when the rail armed (Left or Menu), so a rail
    /// exit comes back to it rather than to the last opened category. Cleared at the landing.
    @State private var railReturnCategory: SettingsCategory?

    /// The row focus should land on when it enters the list without system focus memory.
    private var focusTarget: SettingsCategory { railReturnCategory ?? lastCategory ?? .accountProfiles }

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
            focusModel.didFocus(focusTarget)
            // Cold entry, tab switch back, or a pop: correct the first landing in the list once.
            // Not armed while a pane is on top (the remount rebuilds this root hidden; the path
            // emptying below arms it then).
            if path.isEmpty, focusedCategory == nil {
                landingCorrectionArmed = true
            }
        }
        .onChange(of: path.isEmpty) { wasEmpty, isEmpty in
            guard isEmpty, !wasEmpty else { return }
            // A pop (plain, or after a theme remount). Arm the landing correction only. No direct
            // focus write here: while the pop transition runs the rows are not focusable yet, and a
            // write that SwiftUI records anyway would report itself as the "landing" and disarm the
            // correction before the focus engine's real landing arrives.
            landingCorrectionArmed = true
        }
        .onChange(of: focusedCategory) { _, landed in
            guard landingCorrectionArmed, let landed else { return }
            // First landing on a row since arming: disarm for good, then correct it at most once.
            landingCorrectionArmed = false
            let target = focusTarget
            railReturnCategory = nil
            if landed != target {
                focusedCategory = target
            }
        }
        // H9 (P4 §2.5, #21): a rail exit to Settings arms the one-shot landing correction above and
        // returns false, so the rail's default hand-off places focus in the List and the correction
        // moves it to the row the rail was opened from (else `lastCategory`). Rail mode only;
        // nothing is registered in tabs mode.
        .railReturnRoute {
            RailReturnRoute(name: "settings",
                            capture: {
                                railReturnCategory = focusedCategory
                            },
                            restore: {
                                landingCorrectionArmed = true
                                return false
                            },
                            vetoesLeftArm: { false })
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
                        .focused($focusedCategory, equals: category)
                        // Keeps `app.buttons["Appearance"]` etc. resolving at the root.
                        .accessibilityLabel(Text(category.title))
                        .accessibilityHint(Text(category.subtitle))
                        .accessibilityIdentifier("settings_category_\(category.rawValue)")
                    }
                }
            }
        }
        .defaultFocus($focusedCategory, focusTarget)
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
