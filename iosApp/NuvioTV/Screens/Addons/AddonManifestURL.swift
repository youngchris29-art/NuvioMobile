import Foundation

/// Add-ons hub C, H1: the manifest-URL rules the install field applies before it ever calls the
/// repository, so the UI's checks and messages agree with what `AddonRepository` will do.
///
/// Mirrors the shared `normalizeManifestUrl` (`AddonRepository.kt`): trim, `stremio://` becomes
/// `https://`, a bare host gets `https://`, a `#fragment` is dropped, the query is split off at the
/// first `?`, trailing slashes leave the path, `/manifest.json` is appended unless the path already
/// ends with it, and the query is re-attached. On top of that it adds the Android TV rule the plan
/// asks for: any other `scheme://` is rejected instead of being prefixed into a broken URL.
nonisolated enum AddonManifestURL {

    nonisolated enum Failure: Error, Equatable {
        case empty
        case unsupportedScheme(String)
    }

    private nonisolated static let manifestSuffix = "/manifest.json"

    /// The normalised manifest URL, or why the input cannot be one.
    nonisolated static func normalize(_ raw: String) throws(Failure) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }

        var withScheme: String
        if let scheme = explicitScheme(of: trimmed) {
            switch scheme.lowercased() {
            case "http", "https":
                // Lowercased so the shared `startsWith("http://")` (case-sensitive) never
                // double-prefixes a mixed-case scheme.
                withScheme = scheme.lowercased() + "://" + trimmed.dropFirst(scheme.count + 3)
            case "stremio":
                withScheme = "https://" + trimmed.dropFirst(scheme.count + 3)
            default:
                throw .unsupportedScheme(scheme)
            }
        } else {
            withScheme = "https://" + trimmed
        }

        if let hash = withScheme.firstIndex(of: "#") {
            withScheme = String(withScheme[..<hash])
        }
        var path = withScheme
        var query = ""
        if let question = withScheme.firstIndex(of: "?") {
            path = String(withScheme[..<question])
            query = String(withScheme[withScheme.index(after: question)...])
        }
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix(manifestSuffix) { path += manifestSuffix }
        return query.isEmpty ? path : "\(path)?\(query)"
    }

    /// `normalize`, or nil when the input cannot be a manifest URL.
    nonisolated static func normalizeOrNil(_ raw: String) -> String? {
        try? normalize(raw)
    }

    /// True when both inputs normalise to the same manifest. Scheme and host compare lowercased;
    /// the path and query compare exactly. Anything that fails to normalise is never "the same".
    nonisolated static func isSameManifest(_ a: String, _ b: String) -> Bool {
        guard let left = try? normalize(a), let right = try? normalize(b) else { return false }
        return comparisonKey(left) == comparisonKey(right)
    }

    /// `scheme` of a leading `scheme://` (letter, then letters/digits/`+`/`.`/`-`), else nil.
    private nonisolated static func explicitScheme(of text: String) -> String? {
        guard let range = text.range(of: "://") else { return nil }
        let scheme = text[..<range.lowerBound]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return nil }
        let allowed = scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
        return allowed ? String(scheme) : nil
    }

    /// Lowercases the scheme and the host (the authority after its last `@`); userinfo, path and
    /// query keep their case.
    private nonisolated static func comparisonKey(_ url: String) -> String {
        guard let sep = url.range(of: "://") else { return url }
        let scheme = url[..<sep.lowerBound].lowercased()
        let afterSep = url[sep.upperBound...]
        let authorityEnd = afterSep.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? afterSep.endIndex
        let authority = afterSep[..<authorityEnd]
        let rest = afterSep[authorityEnd...]
        if let at = authority.lastIndex(of: "@") {
            let userinfo = authority[...at]
            let host = authority[authority.index(after: at)...].lowercased()
            return scheme + "://" + userinfo + host + rest
        }
        return scheme + "://" + authority.lowercased() + rest
    }
}
