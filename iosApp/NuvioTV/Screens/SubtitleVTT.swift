import Foundation

// D5 of the hybrid player: external subtitles on the native path. Addon subtitles arrive as SRT
// (occasionally VTT) URLs in `PlaybackContext.externalSubtitles`; the native player exposes them as
// WebVTT SUBTITLES renditions in the synthesized HLS master, so AVPlayer's built-in subtitle menu,
// styling and accessibility settings all apply. `LocalHLSServer` serves `sub-N.m3u8` (single-segment
// VOD playlist) + `sub-N.vtt` (downloaded and converted just-in-time, cached per session).
//
// Cue timing needs no offset bookkeeping: SRT times are relative to the file start, which is exactly
// the playlist origin, and a lone VTT segment at playlist t=0 with no X-TIMESTAMP-MAP is interpreted
// on the playlist timeline directly.

/// One subtitle rendition offered in the master playlist.
nonisolated struct SubtitleRendition: Sendable {
    let index: Int          // sub-<index>.m3u8 / .vtt
    let name: String        // menu display name (unique within the group)
    let language: String?   // RFC 5646-ish tag when the addon provided one
    let sourceURL: URL

    var playlistName: String { "sub-\(index).m3u8" }
    var fileName: String { "sub-\(index).vtt" }
}

nonisolated enum SubtitleVTT {
    /// Build the rendition list from the addon-provided files: parse language tags, synthesize
    /// unique menu names, drop duplicates, cap the count (a debrid title can carry dozens).
    static func renditions(from subs: [SubtitleFile]) -> [SubtitleRendition] {
        var seenURLs = Set<String>()
        var seenNames = Set<String>()
        var out: [SubtitleRendition] = []
        for sub in subs {
            guard out.count < 16 else { break }
            guard let url = URL(string: sub.url), !sub.url.isEmpty, seenURLs.insert(sub.url).inserted else { continue }
            let tag = languageTag(sub.language)
            var name = displayName(name: sub.name, language: sub.language, tag: tag)
            if !seenNames.insert(name).inserted {
                var n = 2
                while !seenNames.insert("\(name) \(n)").inserted { n += 1 }
                name = "\(name) \(n)"
            }
            out.append(SubtitleRendition(index: out.count, name: name, language: tag, sourceURL: url))
        }
        return out
    }

    /// A usable RFC 5646-ish tag ("en", "eng", "pt-BR") or nil when the value is a display word.
    private static func languageTag(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 11 else { return nil }
        let parts = trimmed.split(separator: "-")
        guard (1...2).contains(parts.count),
              let first = parts.first, (2...3).contains(first.count),
              parts.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber } }) else { return nil }
        return parts.count == 2
            ? "\(first.lowercased())-\(parts[1].uppercased())"
            : first.lowercased()
    }

    private static func displayName(name: String?, language: String, tag: String?) -> String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(name.trimmingCharacters(in: .whitespaces).prefix(48))
        }
        if let tag, let localized = Locale.current.localizedString(forIdentifier: tag) {
            return localized.prefix(1).uppercased() + localized.dropFirst()
        }
        let lang = language.trimmingCharacters(in: .whitespaces)
        return lang.isEmpty ? String(localized: "Subtitles") : String(lang.prefix(48))
    }

    // MARK: - Conversion

    /// Decode a downloaded subtitle file and return WebVTT text, or nil when it is unusable.
    /// Accepts SRT (converted) and WebVTT (passed through after cleanup).
    static func webVTT(from data: Data) -> String? {
        guard var text = decode(data) else { return nil }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.hasPrefix("WEBVTT") { return text }

        var lines = [String]()
        var previousBlank = true                     // file start behaves like after-a-blank
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let cueTiming = vttTiming(from: line) {
                // A bare SRT cue counter directly above the timing line must not become a VTT cue
                // identifier that LOOKS like content — drop it for cleanliness.
                if let last = lines.last, !previousBlank, Int(last.trimmingCharacters(in: .whitespaces)) != nil {
                    lines.removeLast()
                }
                lines.append(cueTiming)
                previousBlank = false
            } else {
                lines.append(cleanCueText(line))
                previousBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
        let body = lines.joined(separator: "\n")
        // A subtitle file with no timing lines at all converted to nothing useful — treat as bad.
        guard body.contains("-->") else { return nil }
        return "WEBVTT\n\n" + body
    }

    /// `HH:MM:SS,mmm --> HH:MM:SS,mmm[ position hints]` → `HH:MM:SS.mmm --> HH:MM:SS.mmm`.
    /// Tolerates dot-separated millis and missing hour fields; drops SRT coordinate suffixes.
    private static func vttTiming(from line: String) -> String? {
        guard line.contains("-->") else { return nil }
        let sides = line.components(separatedBy: "-->")
        guard sides.count == 2,
              let start = vttTimestamp(sides[0]), let end = vttTimestamp(sides[1]) else { return nil }
        return "\(start) --> \(end)"
    }

    private static func vttTimestamp(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        let secondsPart = parts.last ?? ""
        let secComps = secondsPart.split(separator: ".").map(String.init)
        guard let sec = Int(secComps.first ?? ""), sec < 60 else { return nil }
        let millis = secComps.count > 1 ? String((secComps[1] + "000").prefix(3)) : "000"
        guard Int(millis) != nil else { return nil }
        var hour = 0, minute = 0
        if parts.count == 3 {
            guard let h = Int(parts[0]), let m = Int(parts[1]), m < 60 else { return nil }
            hour = h; minute = m
        } else {
            guard let m = Int(parts[0]), m < 60 else { return nil }
            minute = m
        }
        return String(format: "%02d:%02d:%02d.%@", hour, minute, sec, millis)
    }

    /// Strip markup AVPlayer's WebVTT renderer doesn't understand: `{\ass tags}` and `<font …>`.
    /// `<i>/<b>/<u>` are valid VTT and pass through.
    private static func cleanCueText(_ line: String) -> String {
        var out = ""
        out.reserveCapacity(line.count)
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "{", let close = line[i...].firstIndex(of: "}") {
                i = line.index(after: close)
                continue
            }
            if ch == "<", let close = line[i...].firstIndex(of: ">") {
                let tag = line[line.index(after: i)..<close].lowercased()
                if tag.hasPrefix("font") || tag.hasPrefix("/font") {
                    i = line.index(after: close)
                    continue
                }
            }
            out.append(ch)
            i = line.index(after: i)
        }
        return out
    }

    /// Subtitle files are notoriously non-UTF-8: BOM-sniff UTF-16, then UTF-8, then Windows-1252,
    /// then Latin-1 — in that order, best effort.
    private static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if data.count >= 2 {
            let b0 = data[data.startIndex], b1 = data[data.index(after: data.startIndex)]
            if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF) {
                return String(data: data, encoding: b0 == 0xFF ? .utf16LittleEndian : .utf16BigEndian)
                    .map { $0.hasPrefix("\u{FEFF}") ? String($0.dropFirst()) : $0 }
            }
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }
}
