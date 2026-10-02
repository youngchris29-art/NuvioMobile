import Combine
import SwiftUI

// MARK: - Explainer plumbing (FEAT-50, detail-settings-revamp W1-B)
//
// The left column of a Settings pane explains the focused row. The focused row reports itself
// to a `SettingsExplainerModel` the pane scaffold owns and injects through the environment.
//
// Why an environment object rather than the plan's `PreferenceKey` (P2 §J-1): preferences do
// not reliably propagate out of tvOS `List` cells (UIKit-hosted) or out of `Menu` labels, while
// environment values do cross those boundaries — `settingsUsesNativeList` and
// `settingsRowIsFocused` already depend on that. Writes happen in `onChange`, never during body
// evaluation.
//
// Corrections F14 (binding): the explainer is NEVER cleared on blur. It keeps the last focused
// row until the pane disappears (the scaffold resets it then), so moving focus to the tab bar or
// across a non-describing row does not flash the pane summary. Writes only happen when the entry
// actually changes, so walking the seven theme swatches (one shared id) publishes once.

/// Pane-level explainer state. Only `SettingsPaneExplainer` observes it, so a focus move
/// re-renders the explainer column, never the pane's `List`.
@MainActor
final class SettingsExplainerModel: ObservableObject {
    struct Entry: Equatable {
        let id: SettingsDescriptionID
        let title: String
        let systemImage: String?
    }

    @Published private(set) var focused: Entry?

    func didFocus(_ entry: Entry) {
        if focused != entry { focused = entry }
    }

    /// Called from the pane scaffold's `onDisappear` only (F14).
    func reset() {
        if focused != nil { focused = nil }
    }
}

private struct SettingsExplainerKey: EnvironmentKey {
    static let defaultValue: SettingsExplainerModel? = nil
}

extension EnvironmentValues {
    /// Set by `SettingsPaneScaffold` on its `List`. `nil` everywhere else (the Settings root,
    /// pushed sub-pages such as Custom Posters, any non-Settings screen), where the description
    /// modifier is a no-op.
    var settingsExplainer: SettingsExplainerModel? {
        get { self[SettingsExplainerKey.self] }
        set { self[SettingsExplainerKey.self] = newValue }
    }
}

/// Reports a row to the pane explainer while it has focus.
///
/// Must sit INSIDE the focusable control (its label): SwiftUI populates `\.isFocused` only for
/// the focusable control and its descendants, never upward. `SettingsRowLabel` is the label of
/// every kit row (Toggle, Menu, NavigationLink, Button), which is the same read site the kit's
/// `SettingsAccentTint` already proves on hardware. For a control with no label descendant (a
/// `TextField`) pass `focused:` from a `@FocusState`. Placed anywhere else the modifier is inert
/// and the explainer falls back to the pane summary, which is safe.
struct SettingsDescriptionModifier: ViewModifier {
    let id: SettingsDescriptionID?
    let title: String
    let systemImage: String?
    let explicitFocus: Bool?

    @Environment(\.isFocused) private var envFocused
    @Environment(\.settingsExplainer) private var explainer

    func body(content: Content) -> some View {
        let focused = explicitFocus ?? envFocused
        content
            .onChange(of: focused, initial: true) { _, now in
                guard now, let id, let explainer else { return }
                explainer.didFocus(.init(id: id, title: title, systemImage: systemImage))
            }
    }
}

extension View {
    /// Attach a description to a custom (non-kit) Settings row. Pass the id as a literal
    /// `.caseName` (the coverage test scans for it).
    func settingsDescription(
        _ id: SettingsDescriptionID?,
        title: String,
        systemImage: String? = nil,
        focused: Bool? = nil
    ) -> some View {
        modifier(SettingsDescriptionModifier(id: id, title: title, systemImage: systemImage, explicitFocus: focused))
    }
}

// MARK: - Root focus model (corrections F21b)

/// Which category the Settings root's explainer shows. Lives in its own tiny observable model,
/// read ONLY by the root's explainer column, so walking the category list re-renders that column
/// and not the whole root `List` (a root-level `@FocusState` would invalidate the root body on
/// every move). Rows report through `SettingsRootRowFocusReporter` from inside their labels.
@MainActor
final class SettingsRootFocusModel: ObservableObject {
    @Published private(set) var category: SettingsCategory = .accountProfiles

    func didFocus(_ category: SettingsCategory) {
        if self.category != category { self.category = category }
    }
}

/// Reads `\.isFocused` inside a root row's Button label and reports the category. Never clears:
/// when focus leaves for the tab bar the explainer keeps the last category, as the panes do.
struct SettingsRootRowFocusReporter: ViewModifier {
    let category: SettingsCategory
    let model: SettingsRootFocusModel

    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .onChange(of: isFocused, initial: true) { _, now in
                if now { model.didFocus(category) }
            }
    }
}
