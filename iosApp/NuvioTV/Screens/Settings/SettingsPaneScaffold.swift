import CoreImage
import SwiftUI
import UIKit

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
                            .frame(width: SettingsExplainerLayout.columnWidth(forPaneWidth: geo.size.width))
                            .environment(\.settingsExplainerColumnHeight, geo.size.height)
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
                footnote: SettingsDescriptions.footnote(for: entry.id).map { Text($0) },
                qrPayload: entry.id == .aboutSupport ? AboutSettingsPane.supportURLString : nil
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
    /// When set, the tile is a QR code for this string instead of the symbol (About › Support:
    /// tvOS cannot open a link, so the phone scans it).
    var qrPayload: String? = nil

    static let tileSide: CGFloat = 240
    static let symbolSide: CGFloat = 112

    #if DEBUG
    /// Truncation probe inputs, all read from laid-out views (never accessibility frames): the
    /// stack's own height (its texts are `fixedSize` vertically, so this is the full ideal height
    /// even when it runs past the column), the column's laid-out width, and the height of the
    /// GeometryReader the column sits in (`settingsExplainerColumnHeight`). The column's own frame
    /// is no bound: a `maxHeight: .infinity` frame grows to an oversized child (seen on the
    /// simulator 2026-11-20: avail 815 = content 815 in a 766 pt pane), so the overflow runs off
    /// the bottom of the screen instead of being clipped.
    @State private var probeContentHeight: CGFloat = 0
    @State private var probeGivenSize: CGSize = .zero
    @Environment(\.settingsExplainerColumnHeight) private var columnHeight
    #endif

    var body: some View {
        content
            #if DEBUG
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { probeContentHeight = $0 }
            #endif
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #if DEBUG
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { probeGivenSize = $0 }
            .overlay(alignment: .topLeading) {
                // Harness-readable, invisible (same hidden single-Text pattern as
                // `debug_detail_hero`). `desc_truncated=1` means the explainer runs past the
                // bottom of its column, i.e. the last lines are cut off on screen.
                Text(verbatim: SettingsExplainerLayout.probeLabel(
                    width: probeGivenSize.width,
                    available: columnHeight ?? probeGivenSize.height,
                    content: probeContentHeight
                ))
                .font(.system(size: 4))
                .opacity(0.011)
                .accessibilityIdentifier("debug_settings_explainer")
            }
            #endif
    }

    /// Tile, title, description and footnote: the part of the column that has to fit. Measured
    /// on its own by `SettingsExplainerFitTests` (the same view, so the test cannot drift from
    /// what the pane draws).
    var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if let qrPayload, let code = SettingsQRCode.image(for: qrPayload) {
                qrTile(code, label: qrPayload)
            } else {
                tile
                    .accessibilityHidden(true)
            }

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
        }
    }

    /// Dark modules on a white card on every theme: phone cameras read that most reliably. The
    /// card's padding is the code's quiet zone. `.interpolation(.none)` keeps module edges sharp.
    /// Not hidden from accessibility like the symbol tile: VoiceOver reads the address the code
    /// stands for, and the UI leg finds the code by its identifier.
    private func qrTile(_ code: UIImage, label: String) -> some View {
        Image(uiImage: code)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .padding(Self.qrQuietZone)
            .frame(width: Self.tileSide, height: Self.tileSide)
            .background(
                Color.white,
                in: RoundedRectangle(cornerRadius: Self.qrCornerRadius, style: .continuous)
            )
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityIdentifier("settings_explainer_qr")
    }

    static let qrQuietZone: CGFloat = 18
    static let qrCornerRadius: CGFloat = 20

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

/// Layout facts of the explainer column, shared by the root, every pane, the DEBUG truncation
/// probe and `SettingsExplainerFitTests`.
nonisolated enum SettingsExplainerLayout {
    /// The column never gets narrower than this, whatever the pane width.
    static let minimumColumnWidth: CGFloat = 400

    /// The column takes a third of the width beside it (the GeometryReader's width), never less
    /// than `minimumColumnWidth`.
    static func columnWidth(forPaneWidth paneWidth: CGFloat) -> CGFloat {
        max(minimumColumnWidth, paneWidth / 3)
    }

    /// Whether a stack of `content` height runs past a column `available` high. Half a point of
    /// slack absorbs layout rounding.
    static func isTruncated(content: CGFloat, available: CGFloat) -> Bool {
        content > available + 0.5
    }

    /// The DEBUG probe's text; the UI harness parses it by key (`desc_truncated=0|1`).
    static func probeLabel(width: CGFloat, available: CGFloat, content: CGFloat) -> String {
        let truncated = available > 0 && isTruncated(content: content, available: available)
        return "debug_settings_explainer w=\(Int(width.rounded())) avail=\(Int(available.rounded())) "
            + "content=\(Int(content.rounded())) desc_truncated=\(truncated ? 1 : 0)"
    }
}

private struct SettingsExplainerColumnHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The height of the GeometryReader the explainer column sits in (Settings root and every
    /// pane): the space the explainer has before the bottom of the screen. Read only by the
    /// column's DEBUG truncation probe.
    var settingsExplainerColumnHeight: CGFloat? {
        get { self[SettingsExplainerColumnHeightKey.self] }
        set { self[SettingsExplainerColumnHeightKey.self] = newValue }
    }
}

/// QR codes for the Settings explainer, generated on-device with Core Image (no network, no
/// bundled asset to drift from the address in the row).
enum SettingsQRCode {
    /// One point per module; the view scales it up without interpolation. `nil` if Core Image
    /// cannot produce a code, in which case the explainer keeps its symbol tile.
    static func image(for payload: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        // Medium error correction: the code is shown large on a TV and scanned from the sofa.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static let context = CIContext()
}
