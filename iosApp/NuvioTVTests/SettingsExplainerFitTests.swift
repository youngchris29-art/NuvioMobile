import SwiftUI
import UIKit
import XCTest
@testable import NuvioTV

/// GitHub #33 device pass (2026-11-20): Settings › Player › Seek Preview Pictures' explainer ran
/// past the bottom of the screen ("The Apple TV player used for Dolby Vision…" was the last line
/// on the box). The whole explainer (tile, title, description, footnote) has to fit its column in
/// every shipped language.
///
/// Measures the SAME view the pane draws (`SettingsExplainerColumn.content`, hosted in a
/// `UIHostingController` at the column width), with the pane's own fonts, spacing and tile, so a
/// change to any of those moves this test with it. The column width comes from
/// `SettingsExplainerLayout.columnWidth(forPaneWidth:)`, the rule the scaffold uses.
///
/// The per-language copy is read from `Localizable.xcstrings` in the source tree (resolved from
/// `#filePath`, like `SettingsDescriptionsTests`): the test host runs in one locale, so the catalog
/// file is the honest way to get all six. English is also checked against the bundle's own lookup.
///
/// The live counterpart is the DEBUG probe `debug_settings_explainer` (`desc_truncated=0|1`) read
/// by `NuvioTVUITests.test82SettingsExplainerFollowsFocus` from the laid-out view on the simulator.
@MainActor
final class SettingsExplainerFitTests: XCTestCase {
    /// The 1080p layouts the explainer column is laid out in, as read from the DEBUG probe on the
    /// tvOS simulator's 1920×1080 screen (2026-11-20, `test82SettingsExplainerFollowsFocus`):
    /// `w=` is the column's laid-out width, `avail=` the height of the GeometryReader the column
    /// sits in (pane title and safe areas already taken off). `paneWidth` is that GeometryReader's
    /// width, the column's `w` × 3 (both layouts are above the 400 pt floor).
    /// - tabs: the system tab bar (the default navigation). Probe: w=587 avail=766.
    /// - rail: the navigation rail, Always Visible (the box's layout, the narrowest column).
    ///   Probe: w=575 avail=766.
    private struct Layout1080p {
        let name: String
        let paneWidth: CGFloat
        let availableHeight: CGFloat
    }

    private static let layouts: [Layout1080p] = [
        Layout1080p(name: "tabs", paneWidth: 587 * 3, availableHeight: 766),
        Layout1080p(name: "rail", paneWidth: 575 * 3, availableHeight: 766),
    ]

    private static let locales = ["en", "de", "es", "fr", "it", "vi"]

    // MARK: - Tests

    func testSeekPreviewExplainerFitsEveryLanguageAndLayout() throws {
        let catalog = try loadCatalog()
        let id = SettingsDescriptionID.playerSeekPreview
        let bodyKey = SettingsDescriptions.text(for: id).key
        let footnoteKey = try XCTUnwrap(SettingsDescriptions.footnote(for: id)).key
        let titleKey = "Seek Preview Pictures"

        var report: [String] = []
        for locale in Self.locales {
            let title = try translation(of: titleKey, in: locale, catalog: catalog)
            let body = try translation(of: bodyKey, in: locale, catalog: catalog)
            let footnote = try translation(of: footnoteKey, in: locale, catalog: catalog)
            for layout in Self.layouts {
                let width = SettingsExplainerLayout.columnWidth(forPaneWidth: layout.paneWidth)
                let height = measuredHeight(title: title, body: body, footnote: footnote, width: width)
                report.append("\(locale) \(layout.name): content=\(Int(height.rounded())) avail=\(Int(layout.availableHeight)) width=\(Int(width))")
                XCTAssertFalse(
                    SettingsExplainerLayout.isTruncated(content: height, available: layout.availableHeight),
                    "\(locale) (\(layout.name)): the Seek Preview Pictures explainer is \(Int(height.rounded())) pt tall, its column \(Int(layout.availableHeight)) pt"
                )
            }
        }
        let attachment = XCTAttachment(string: report.joined(separator: "\n"))
        attachment.name = "seek_preview_explainer_heights"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[ExplainerFit]\n" + report.joined(separator: "\n"))
    }

    /// The test reads the copy from the catalog file; this ties that file to what the app shows
    /// in English (the bundle's own lookup of the same resources).
    func testEnglishCatalogKeysAreWhatTheAppShows() {
        let id = SettingsDescriptionID.playerSeekPreview
        XCTAssertEqual(String(localized: SettingsDescriptions.text(for: id)), SettingsDescriptions.text(for: id).key)
        XCTAssertEqual(
            SettingsDescriptions.text(for: id).key,
            "Shows a picture of where you will land when you skip or scrub. Watched Parts uses pictures saved from what you have played. Whole Video also reads unwatched parts: about 2% of the file, between 16 and 150 MB for most titles, plus up to 50 MB more while you skip around. On Aether both choices work the same. The Apple TV player (Dolby Vision, HDR10) shows no picture card. This Apple TV only. Default: Watched Parts."
        )
        XCTAssertEqual(SettingsDescriptions.footnote(for: id)?.key, "Applies to the next playback.")
    }

    /// Guards the measurement itself: a stack that obviously cannot fit must read as truncated,
    /// so the fit test above cannot pass by measuring nothing.
    func testMeasurementSeesOverflow() {
        let width = SettingsExplainerLayout.columnWidth(forPaneWidth: 1800)
        let long = Array(repeating: "Shows a picture of where you will land when you skip or scrub.", count: 20)
            .joined(separator: " ")
        let height = measuredHeight(title: "Seek Preview Pictures", body: long, footnote: "Applies to the next playback.", width: width)
        XCTAssertTrue(SettingsExplainerLayout.isTruncated(content: height, available: 766), "measured \(height)")
        let short = measuredHeight(title: "T", body: "One line.", footnote: nil, width: width)
        XCTAssertGreaterThan(short, SettingsExplainerColumn.tileSide, "the tile alone is \(SettingsExplainerColumn.tileSide) pt")
        XCTAssertFalse(SettingsExplainerLayout.isTruncated(content: short, available: 766), "measured \(short)")
    }

    func testColumnWidthRuleAndProbeLabel() {
        XCTAssertEqual(SettingsExplainerLayout.columnWidth(forPaneWidth: 1800), 600)
        XCTAssertEqual(SettingsExplainerLayout.columnWidth(forPaneWidth: 900), 400)
        XCTAssertEqual(SettingsExplainerLayout.probeLabel(width: 600, available: 767, content: 700),
                       "debug_settings_explainer w=600 avail=767 content=700 desc_truncated=0")
        XCTAssertEqual(SettingsExplainerLayout.probeLabel(width: 600, available: 767, content: 768),
                       "debug_settings_explainer w=600 avail=767 content=768 desc_truncated=1")
        // Before the first layout pass the probe has no column height: never a false alarm.
        XCTAssertTrue(SettingsExplainerLayout.probeLabel(width: 0, available: 0, content: 500).hasSuffix("desc_truncated=0"))
    }

    // MARK: - Measurement

    private func measuredHeight(title: String, body: String, footnote: String?, width: CGFloat) -> CGFloat {
        let column = SettingsExplainerColumn(
            systemImage: "play.rectangle",
            title: title,
            text: Text(verbatim: body),
            footnote: footnote.map { Text(verbatim: $0) }
        )
        let host = UIHostingController(rootView: column.content.frame(width: width))
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    // MARK: - Catalog

    private var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("NuvioTV/Localizable.xcstrings")
    }

    private func loadCatalog() throws -> [String: Any] {
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: Any], "no strings in \(catalogURL.path)")
    }

    private func translation(of key: String, in locale: String, catalog: [String: Any]) throws -> String {
        let entry = try XCTUnwrap(catalog[key] as? [String: Any], "'\(key.prefix(60))…' is not in the catalog")
        if locale == "en" { return key }
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "'\(key.prefix(60))…' has no translations")
        let unit = try XCTUnwrap((localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any],
                                 "'\(key.prefix(60))…' has no \(locale) translation")
        return try XCTUnwrap(unit["value"] as? String)
    }
}
