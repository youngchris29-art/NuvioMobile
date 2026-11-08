import SwiftUI

/// What the source panel's body holds. `.list` is the A batch's list (full rows under tier or
/// add-on headers); `.tiers` (Direction C) is the best-pick card, the alternatives and the
/// collapsed sections. The panel's layout does not depend on it.
nonisolated enum StreamPickerSourceContent: Equatable {
    case list
    case tiers
}

/// Stream picker A, P1: the right pane (60 % of the screen). One rounded panel on
/// `Theme.Surface.panel` (the token's own comment names this screen), inner padding `md`, holding
/// in order a header (the resume pill and the chip row, P2/P3; today the credential banner), the
/// scrolling body, and a footer. Padding `screen` from the top, trailing and bottom screen edges;
/// the info panel supplies the leading gap (Full Width, GitHub #25: the panel pads the leading edge
/// and the header strip above it supplies the top). The panel is one focus section so Up/Down stay inside
/// the list and never wander into the static info pane.
///
/// Review r1 (P2): the header and footer get the panel's inset; the body runs edge to edge and
/// insets its own scroll content (`contentMargins`), so a focused row's 1.02 lift and shadow have
/// room inside the ScrollView's clip instead of being cut flat at the panel edge.
struct StreamPickerSourcePanel<Header: View, PanelBody: View, Footer: View>: View {
    let content: StreamPickerSourceContent
    /// GitHub #25: there is no info pane on the leading side (Full Width), so the panel pads that
    /// edge itself; the header strip above it supplies the top gap.
    var fullWidth = false
    @ViewBuilder let header: () -> Header
    @ViewBuilder let panelBody: () -> PanelBody
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            header()
                .padding(.horizontal, Theme.Spacing.md)
            panelBody()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer()
                .padding(.horizontal, Theme.Spacing.md)
        }
        .padding(.vertical, Theme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
        .padding(fullWidth ? [.leading, .trailing, .bottom] : [.top, .trailing, .bottom], Theme.Spacing.screen)
        .focusSection()
        .accessibilityIdentifier("stream_picker_source_panel")
    }

    @ViewBuilder
    private var panelBackground: some View {
        if StreamPickerSourcePanelStyle.usesMaterial {
            Rectangle().fill(Theme.Surface.panel)
        } else {
            Theme.Palette.surface.opacity(0.72)
        }
    }
}

/// Knobs that do not depend on the panel's generic content.
nonisolated enum StreamPickerSourcePanelStyle {
    /// P4.2 fallback: when the material costs frames on the device over a 150-stream list, flip
    /// this to draw a flat `surface` at 0.72 behind the panel instead (Android TV below API 31).
    static let usesMaterial = true
}

/// GitHub #25: sizes the Full Width layout uses.
nonisolated enum StreamPickerWideMetrics {
    /// The Best Pick card and its pills stop here on Full Width (leading-aligned); unbounded on Two-Pane.
    static let cardMaxWidth: CGFloat = 1100

    static func cardMaxWidth(fullWidth: Bool) -> CGFloat {
        fullWidth ? cardMaxWidth : .infinity
    }

    /// The add-on name column of a wide add-on-text row.
    static let nameColumnWidth: CGFloat = 300
    /// Name lines an add-on-text row shows at rest; the whole name after the focus dwell (review r1).
    static let nameRestLines = 3
    /// Description lines an add-on-text row shows at rest, in both layouts; the whole text after
    /// the focus dwell (Christian after the device pass, 2026-11-08: 3, down from 4).
    static let descriptionRestLines = 3
}
