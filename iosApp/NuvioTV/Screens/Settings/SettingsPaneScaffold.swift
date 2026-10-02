import SwiftUI

// MARK: - Pane scaffold (FEAT-50, detail-settings-revamp W1-B)

/// One pushed Settings pane: the pane title, then the explainer column on the left (~1/3) and the
/// pane's native `List` on the right. The explainer describes the focused row (see
/// `SettingsExplainerModel`); a row with no description leaves the last one up, and before any
/// described row has focus it shows the category summary.
///
/// Focus graph:
/// - Push lands on the List's first focusable row (default focus of a newly pushed view).
/// - Up / Down walk the List; the explainer column is not focusable, so Left does nothing and
///   Right is the row control's own business — the same grammar every Settings row had before.
/// - Menu pops back to the Settings root. That is the system's default for a `NavigationStack`
///   destination: this scaffold installs NO `onExitCommand` and NO `.sidebarMenuReveal()`, so the
///   pop always wins inside a pane, in tabs and sidebar mode alike.
/// - BUG-47: every pane rendered here must keep at least one focusable row in every state.
///
/// Pushed sub-pages (Custom Posters, server connection) are stack destinations, not descendants of
/// this List, so they get no explainer environment and keep their own layout.
///
/// Glass: none (HIG hybrid contract — the scaffold is in-content, not floating chrome).
struct SettingsPaneScaffold<Content: View>: View {
    let category: SettingsCategory
    @ViewBuilder let content: () -> Content

    @StateObject private var explainer = SettingsExplainerModel()
    /// FEAT-7: "Minimal" drops the explainer column, so the List takes the full width.
    @AppStorage("settings_style") private var settingsStyle = "default"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(category.title)
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Spacing.screen)
                .padding(.top, Theme.Spacing.lg)
                .accessibilityIdentifier("settings_pane_title")

            GeometryReader { geo in
                HStack(spacing: Theme.Spacing.xl) {
                    if settingsStyle != "minimal" {
                        SettingsPaneExplainer(model: explainer, category: category)
                            .frame(width: max(400, geo.size.width / 3))
                            .padding(.leading, Theme.Spacing.screen)
                    }

                    List {
                        content()
                    }
                    .environment(\.settingsUsesNativeList, true)
                    .environment(\.settingsExplainer, explainer)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.Palette.background.ignoresSafeArea())
        // `.contain` first: an identifier on a bare stack would be pushed down onto its children
        // and overwrite `settings_pane_title` / the explainer ids. As a container element it
        // carries the pane id itself and leaves the children's ids alone.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings_pane_\(category.rawValue)")
        // Corrections F14: the ONLY place the explainer clears. Deferred so the reset never
        // publishes from inside the disappearance transaction.
        .onDisappear {
            let explainer = explainer
            Task { @MainActor in explainer.reset() }
        }
    }
}

/// The only view that observes the pane's explainer model, so a focus change re-renders this
/// column and never the List beside it.
private struct SettingsPaneExplainer: View {
    @ObservedObject var model: SettingsExplainerModel
    let category: SettingsCategory

    var body: some View {
        if let entry = model.focused {
            SettingsExplainerColumn(
                systemImage: entry.systemImage ?? category.icon,
                title: entry.title,
                text: Text(SettingsDescriptions.text(for: entry.id))
            )
        } else {
            SettingsExplainerColumn(
                systemImage: category.icon,
                title: category.title,
                text: Text(category.summary)
            )
        }
    }
}

/// Shared by the Settings root and every pane. Non-focusable. The accent symbol sits on an opaque
/// in-content tile (HIG contract: opaque `Palette.surface*` for in-content fills; the accent is
/// allowed here as an identity moment, it never marks focus).
struct SettingsExplainerColumn: View {
    let systemImage: String
    let title: String
    let text: Text

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.Palette.surfaceElevated)
                .frame(width: 240, height: 240)
                .overlay(
                    Image(systemName: systemImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .foregroundStyle(Theme.Palette.accent)
                )
                .accessibilityHidden(true)

            Text(title)
                .font(Theme.Font.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .accessibilityIdentifier("settings_explainer_title")

            text
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings_explainer_body")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // No custom animation. If one is added later, gate it on Reduce Motion.
    }
}
