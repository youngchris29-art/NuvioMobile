import SwiftUI

/// "About" category content: build/version truth (FEAT-13). Reads the version straight out of the
/// running bundle instead of any hand-maintained constant, so this pane can never drift from what
/// was actually built — the "Stamp Build Metadata" run-script build phase writes NuvioCommitSHA /
/// NuvioBetaTag into Info.plist at build time (see project.pbxproj, NuvioTV target).
///
/// detail-settings-revamp W2-C: every diagnostic, probe and A/B row moved to
/// `DeveloperSettingsPane`. Value rows are `focusable: true` so this pushed pane has a focusable
/// row (BUG-47) and each row can describe itself in the explainer. Returns ROWS ONLY.
struct AboutSettingsPane: View {
    var body: some View {
        SettingsSection(String(localized: "About")) {
            SettingsValueRow(
                title: String(localized: "Version"),
                value: "\(Self.marketingVersion) (\(Self.buildNumber))",
                descriptionID: .aboutVersion,
                focusable: true
            )
            SettingsValueRow(
                title: String(localized: "Build"),
                value: Self.betaTag,
                descriptionID: .aboutBuild,
                focusable: true
            )
            SettingsValueRow(
                title: String(localized: "Commit"),
                value: Self.commitSHA,
                descriptionID: .aboutCommit,
                focusable: true
            )
            SettingsValueRow(
                title: String(localized: "tvOS"),
                value: ProcessInfo.processInfo.operatingSystemVersionString,
                descriptionID: .aboutTvos,
                focusable: true
            )
            SettingsValueRow(
                title: String(localized: "Device"),
                value: Self.deviceModelIdentifier,
                descriptionID: .aboutDevice,
                focusable: true
            )
            SettingsValueRow(
                title: String(localized: "Source"),
                value: "github.com/youngchris29-art/NuvioTV",
                descriptionID: .aboutSource,
                focusable: true
            )
            // FEAT-31 attribution: the font ships in this same branch (Theme.Font.uiFont).
            SettingsValueRow(
                title: String(localized: "Fonts"),
                value: "Open Sans — SIL Open Font License 1.1",
                descriptionID: .aboutFonts,
                focusable: true
            )
        }
    }

    private static var marketingVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0"
    }

    private static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }

    /// Stamped by the "Stamp Build Metadata" run-script build phase from `NUVIO_BETA_TAG` (set by
    /// scripts/release-beta.sh). Empty on plain Xcode Debug builds, which never set that env var.
    private static var betaTag: String {
        let tag = (Bundle.main.object(forInfoDictionaryKey: "NuvioBetaTag") as? String) ?? ""
        return tag.isEmpty ? String(localized: "Dev build") : tag
    }

    /// Stamped by the same build phase from `git rev-parse --short=8 HEAD`.
    private static var commitSHA: String {
        let sha = (Bundle.main.object(forInfoDictionaryKey: "NuvioCommitSHA") as? String) ?? ""
        return sha.isEmpty ? "\u{2014}" : sha
    }

    /// The hardware model identifier (e.g. "AppleTV6,2"), read via `uname(2)` — `UIDevice.current`
    /// only exposes the marketing/user-assigned name, not the model.
    private static var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            identifier += String(UnicodeScalar(UInt8(value)))
        }
    }
}
