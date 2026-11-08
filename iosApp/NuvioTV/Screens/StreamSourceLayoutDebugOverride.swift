import Foundation
import SharedCore

/// DEBUG harness knobs (GitHub #25): `-debug.sourceLayout FULL|TWO` pins the stream picker's
/// "Source Layout" and `-debug.rowText ADDON|NUVIO` its "Row Text" for this launch, so the UI legs
/// can run every combination whatever the fixture profile stores. Read-through only, like
/// `StreamListOpensWithDebugOverride`: both settings are profile-local, so nothing is handed to a
/// repository and nothing is written. nil when absent, blank or unknown, and always nil in Release.
nonisolated enum StreamSourceLayoutDebugOverride {
    static let debugKey = "debug.sourceLayout"

    /// "FULL" / "FULL_WIDTH" -> .fullWidth; "TWO" / "TWO_PANE" -> .twoPane (trimmed, any case); else nil.
    static func parse(_ raw: String?) -> StreamSourceLayout? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else { return nil }
        switch text {
        case "FULL", "FULL_WIDTH": return .fullWidth
        case "TWO", "TWO_PANE": return .twoPane
        default: return nil
        }
    }

    /// The launch's override, or nil (and always nil in Release).
    static func layout(_ defaults: UserDefaults = .standard) -> StreamSourceLayout? {
        #if DEBUG
        return parse(defaults.string(forKey: debugKey))
        #else
        return nil
        #endif
    }
}

/// See `StreamSourceLayoutDebugOverride`: the "Row Text" twin.
nonisolated enum StreamRowTextDebugOverride {
    static let debugKey = "debug.rowText"

    /// "ADDON" / "ADD-ON" -> .addon; "NUVIO" -> .nuvio (trimmed, any case); else nil.
    static func parse(_ raw: String?) -> StreamRowText? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else { return nil }
        switch text {
        case "ADDON", "ADD-ON": return .addon
        case "NUVIO": return .nuvio
        default: return nil
        }
    }

    /// The launch's override, or nil (and always nil in Release).
    static func mode(_ defaults: UserDefaults = .standard) -> StreamRowText? {
        #if DEBUG
        return parse(defaults.string(forKey: debugKey))
        #else
        return nil
        #endif
    }
}

/// DEBUG harness knob (GitHub #25 poster fit, review p3): `-debug.exposePickerPoster YES` lets the UI
/// legs find the Two-Pane poster (`stream_picker_poster`) and read its drawn frame. The poster is
/// decorative and hidden from VoiceOver otherwise; always false in Release.
nonisolated enum StreamPickerPosterDebugProbe {
    static let debugKey = "debug.exposePickerPoster"

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
        return defaults.bool(forKey: debugKey)
        #else
        return false
        #endif
    }
}
