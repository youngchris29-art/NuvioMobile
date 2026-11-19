import Foundation

/// Player P3: where the seek preview gets its pictures, one switch for both engines (Settings ›
/// Player › "Seek Preview Pictures"; device-wide, same `debug.seekPreviewMode` key as before).
/// Read once per playback, so a change applies to the next one.
///
/// - `off`: no pictures at all. The mpv harvest and decoder stay off, and the native engine's
///   loopback master carries no `EXT-X-I-FRAME-STREAM-INF` (byte for byte the pre-P3 master).
/// - `harvest` (default, also for an unset or unknown value): the P2 harvest saves frames the
///   viewer has played; the native engine publishes its I-frame rendition for FF/RW scan only when
///   "Native I-frame Scan (A/B)" is on (BUG-168, `allowsNativeIFrames(scanEnabled:)`).
/// - `decode`: harvest, plus the mpv keyframe thumbnailer for ground not watched yet.
nonisolated enum SeekPreviewMode: String, CaseIterable, Sendable {
    case off, harvest, decode

    static let defaultsKey = "debug.seekPreviewMode"
    static let defaultMode: SeekPreviewMode = .harvest

    /// nil, empty or unknown → `defaultMode`.
    static func parse(_ raw: String?) -> SeekPreviewMode {
        raw.flatMap(Self.init(rawValue:)) ?? defaultMode
    }

    static func current(_ defaults: UserDefaults = .standard) -> SeekPreviewMode {
        parse(defaults.string(forKey: defaultsKey))
    }

    /// The mode lets the native engine publish the `EXT-X-I-FRAMES-ONLY` rendition. Not enough on
    /// its own since BUG-168: the native engine reads `allowsNativeIFrames(scanEnabled:)`.
    var allowsIFrames: Bool { self != .off }

    // MARK: Native I-frame scan (BUG-168 native half)

    /// BUG-168 (Steven, beta.19-rc5 verdict 2026-10-17: "a transparent box" while scrubbing Spirited
    /// Away on the native player): with the I-frame rendition in the master, AVKit draws a preview
    /// slot over its scrubber, but on tvOS 27 its paused-scrub preview never requests an I-frame (P3
    /// spike, runs 1–4), so the slot stays empty. The rendition's only working use is FF/RW scan
    /// pictures. So the native engine now publishes it only when the Developer A/B row "Native
    /// I-frame Scan (A/B)" is on (device-local, off by default); the mpv harvest and decoder still
    /// follow the mode alone.
    static let nativeIFrameScanKey = "debug.nativeIFrameScan"
    static let nativeIFrameScanDefault = false

    static func nativeIFrameScanEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: nativeIFrameScanKey) == nil
            ? nativeIFrameScanDefault
            : defaults.bool(forKey: nativeIFrameScanKey)
    }

    /// The native engine publishes the I-frame rendition: the mode allows it AND the A/B row is on
    /// (Off still wins: it is the pre-P3 master whatever the row says).
    func allowsNativeIFrames(scanEnabled: Bool) -> Bool { allowsIFrames && scanEnabled }

    /// Both switches read from `defaults`, once per playback (`NativePlaybackCoordinator`).
    static func currentAllowsNativeIFrames(_ defaults: UserDefaults = .standard) -> Bool {
        current(defaults).allowsNativeIFrames(scanEnabled: nativeIFrameScanEnabled(defaults))
    }
    /// The mpv engine saves played frames (P2 harvest; its own crash guard still applies).
    var allowsHarvest: Bool { self != .off }
    /// The mpv engine runs the keyframe thumbnailer for unwatched ground.
    var allowsDecode: Bool { self == .decode }

    /// Picker label (Settings › Player › Seek Preview Pictures).
    var displayName: String {
        switch self {
        case .off: return String(localized: "Off")
        case .harvest: return String(localized: "Watched Parts")
        case .decode: return String(localized: "Whole Video")
        }
    }
}
