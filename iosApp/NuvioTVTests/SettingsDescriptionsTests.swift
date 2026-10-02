import XCTest
@testable import NuvioTV

/// FEAT-50 (detail-settings-revamp W1-B): the Settings explainer copy catalog.
///
/// The "unknown id" direction is compile-checked (ids are an enum). These tests cover the other
/// directions: every id has copy, no copy is still the placeholder, and every id in the catalog is
/// actually used by a Settings row (found by scanning the Settings sources for literal
/// `descriptionID: .caseName` / `.settingsDescription(.caseName` call sites).
@MainActor
final class SettingsDescriptionsTests: XCTestCase {
    func testEveryIDHasNonEmptyCopy() {
        for id in SettingsDescriptionID.allCases {
            XCTAssertFalse(String(localized: SettingsDescriptions.text(for: id)).isEmpty, "\(id)")
        }
    }

    func testRawValuesAreUnique() {
        let raws = SettingsDescriptionID.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
    }

    func testNoPlaceholderCopy() throws {
        try XCTSkipIf(true, "enabled by W3-A once every description has real copy")
        for id in SettingsDescriptionID.allCases {
            XCTAssertNotEqual(String(localized: SettingsDescriptions.text(for: id)), "TODO", "\(id)")
        }
    }

    /// Always on: the scan finds the ids wired so far (Home Screen, W1-B) and every one it finds
    /// is a real case. Guards the scanner itself, so the full-coverage test below cannot pass
    /// vacuously once its skip is removed.
    func testScannedIDsAreKnownCases() throws {
        let used = try usedCaseNames()
        XCTAssertTrue(used.contains("homeShowHero"), "scanner found: \(used.sorted())")
        let known = Set(SettingsDescriptionID.allCases.map { String(describing: $0) })
        XCTAssertTrue(used.isSubset(of: known), "unknown: \(used.subtracting(known).sorted())")
    }

    func testEveryIDIsUsedAndOnlyKnownIDsAreUsed() throws {
        try XCTSkipIf(true, "enabled once W2 + W3-A have wired every row (whoever finishes the wiring removes this)")
        let used = try usedCaseNames()
        let known = Set(SettingsDescriptionID.allCases.map { String(describing: $0) })
        XCTAssertEqual(known.subtracting(used).sorted(), [], "ids with copy but no row")
        XCTAssertEqual(used.subtracting(known).sorted(), [], "rows naming unknown ids")
    }

    // MARK: - Source scan

    /// `NuvioTV/Screens/Settings/`, resolved from this file's path. Simulator tests run on the
    /// host, so the repo checkout is readable.
    private var settingsSourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("NuvioTV/Screens/Settings")
    }

    private func usedCaseNames() throws -> Set<String> {
        let files = try FileManager.default.contentsOfDirectory(
            at: settingsSourcesURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no sources at \(settingsSourcesURL.path)")

        let patterns = [
            #"descriptionID:\s*\.(\w+)"#,
            #"settingsDescription\(\s*\.(\w+)"#,
        ].map { try! NSRegularExpression(pattern: $0) }

        var used = Set<String>()
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for regex in patterns {
                for match in regex.matches(in: source, range: range) {
                    if let r = Range(match.range(at: 1), in: source) {
                        used.insert(String(source[r]))
                    }
                }
            }
        }
        return used
    }
}
