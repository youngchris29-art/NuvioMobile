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
///   destination: this scaffold installs NO `onExitCommand` and NO `.railMenuReveal()`, so the
///   pop always wins inside a pane, in tabs and Rail mode alike. In Rail mode a Left from a row
///   (the explainer column is not focusable) opens the navigation rail.
/// - BUG-47: every pane rendered here must keep at least one focusable row in every state.
///
/// Pushed sub-pages (Custom Posters, server connection) are stack destinations, not descendants of
/// this List, so they get no explainer environment and keep their own layout.
///
/// Glass: none (HIG hybrid contract — the scaffold is in-content, not floating chrome).
struct SettingsPaneScaffold<Content: View>: View {
    let category: SettingsCategory
    @ViewBuilder let content: () -> Content

    /// `@State`, not `@StateObject`: the scaffold OWNS the model but must not observe it, or every
    /// focus move would re-render the whole pane including the `List` (review r1). Only
    /// `SettingsPaneExplainer` (`@ObservedObject`) subscribes; rows reach the same instance
    /// through the environment without observing it.
    @State private var explainer = SettingsExplainerModel()
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
            // V5: a row without its own icon shows the pane's icon.
            SettingsExplainerColumn(
                systemImage: entry.systemImage ?? category.icon,
                title: entry.title,
                text: Text(SettingsDescriptions.text(for: entry.id)),
                footnote: SettingsDescriptions.footnote(for: entry.id).map { Text($0) }
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

/// Shared by the Settings root and every pane. Non-focusable, never on a platter.
///
/// V5 (D11, the option 1 mockup): an accent-gradient tile (theme accent → a darker shade of it,
/// corner radius 20 % of the side) carrying the symbol in `accentText` — white on every theme
/// except White, whose near-white accent gets the dark ink so the symbol never vanishes; a bold
/// display-size title (`screenTitle`, title3 bold, the mockup's title/body ratio); the description
/// in `body` + `textSecondary`; and an optional footnote in `detail` + `.tertiary`.
///
/// HIG contract: the tile is an opaque in-content fill and an identity moment, not focus chrome
/// (the accent never marks focus here). No glass. No custom animation; if one is added later,
/// gate it on Reduce Motion.
struct SettingsExplainerColumn: View {
    let systemImage: String
    let title: String
    let text: Text
    var footnote: Text? = nil

    static let tileSide: CGFloat = 240
    static let symbolSide: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            tile
                .accessibilityHidden(true)

            Text(title)
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings_explainer_title")

            text
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings_explainer_body")

            if let footnote {
                footnote
                    .font(Theme.Font.detail)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings_explainer_footnote")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: Self.tileSide * 0.2, style: .continuous)
        return shape
            .fill(Theme.Palette.accent)
            // The darker end of the gradient: the accent itself, shaded toward black, so every
            // theme gets its own gradient without a second colour per theme.
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [Color.black.opacity(0), Color.black.opacity(0.38)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .frame(width: Self.tileSide, height: Self.tileSide)
            .overlay(
                Image(systemName: systemImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.symbolSide, height: Self.symbolSide)
                    .foregroundStyle(Theme.Palette.accentText)
            )
    }
}
