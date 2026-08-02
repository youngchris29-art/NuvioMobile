import SwiftUI
import SharedCore

/// "About" category content: build/version truth (FEAT-13). Reads the version straight out of the
/// running bundle instead of any hand-maintained constant, so this pane can never drift from what
/// was actually built — the "Stamp Build Metadata" run-script build phase writes NuvioCommitSHA /
/// NuvioBetaTag into Info.plist at build time (see project.pbxproj, NuvioTV target).
struct AboutSettingsPane: View {
    var body: some View {
        settingsSection(String(localized: "About")) {
            SettingsInfoRow(
                title: String(localized: "Version"),
                value: "\(Self.marketingVersion) (\(Self.buildNumber))"
            )
            SettingsInfoRow(
                title: String(localized: "Build"),
                value: Self.betaTag
            )
            SettingsInfoRow(
                title: String(localized: "Commit"),
                value: Self.commitSHA
            )
            SettingsInfoRow(
                title: String(localized: "tvOS"),
                value: ProcessInfo.processInfo.operatingSystemVersionString
            )
            SettingsInfoRow(
                title: String(localized: "Device"),
                value: Self.deviceModelIdentifier
            )
            SettingsInfoRow(
                title: String(localized: "Source"),
                value: "github.com/youngchris29-art/NuvioTV"
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
