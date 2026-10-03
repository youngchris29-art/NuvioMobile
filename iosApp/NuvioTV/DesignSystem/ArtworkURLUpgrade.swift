import Foundation

/// beta.19-rc1 verdict (I1, tracker BUG-134): "ask the CDN for a bigger file", decided in one pure
/// place. A larger rendition of the same picture on the same CDN; nil means no larger rendition is
/// known. It also tells the cache which URLs are one picture (`family`), so a poster a card decoded
/// from its `w780` variant is a hit for a caller that asks with the original `w500` URL.
///
/// Rules (the host match is exact; the path match is on the size segment only; the query string and
/// the file name are kept):
///
/// | Host | Role | From | To |
/// |---|---|---|---|
/// | `image.tmdb.org` | `.poster` | `/t/p/w92…w500/` | `/t/p/w780/` |
/// | `image.tmdb.org` | `.posterLarge` | `/t/p/w92…w780/` | `/t/p/original/` |
/// | `image.tmdb.org` | `.backdrop` | `/t/p/w300, w780, w1280/` | `/t/p/original/` |
/// | `image.tmdb.org` | `.logo` | `/t/p/w45…w500/` | `/t/p/original/`, except `.svg` (ImageIO cannot decode SVG) |
/// | `images.metahub.space` | `.poster`, `.posterLarge` | `/poster/small/`, `/poster/medium/` | `/poster/large/` |
/// | `images.metahub.space` | `.backdrop`, `.logo` | — | nil (large serves the same file as medium) |
/// | anything else | any | — | nil |
///
/// Measured 2026-10-03: metahub posters serve small 300×450, medium 500×750, large 780×1170 (2–3× the
/// bytes of medium) for tt0111161, tt0468569 and tt0903747; `/background/` and `/logo/` serve the same
/// bytes at medium and large, so those two are deliberately not rewritten.
nonisolated enum ArtworkURLUpgrade {
    nonisolated enum Role: Sendable, Hashable {
        case poster
        case posterLarge
        case backdrop
        case logo
    }

    private static let tmdbHost = "image.tmdb.org"
    private static let metahubHost = "images.metahub.space"

    private static let tmdbPosterSources: Set<String> = ["w92", "w154", "w185", "w342", "w500"]
    private static let tmdbPosterLargeSources: Set<String> = ["w92", "w154", "w185", "w342", "w500", "w780"]
    private static let tmdbBackdropSources: Set<String> = ["w300", "w780", "w1280"]
    private static let tmdbLogoSources: Set<String> = ["w45", "w92", "w154", "w185", "w300", "w500"]

    static func upgraded(_ url: String, role: Role) -> String? {
        guard !url.isEmpty, let host = URL(string: url)?.host?.lowercased() else { return nil }
        return rewrite(url, host: host, role: role)
    }

    static func upgraded(_ url: URL, role: Role) -> URL? {
        guard let host = url.host?.lowercased(),
              let rewritten = rewrite(url.absoluteString, host: host, role: role) else { return nil }
        return URL(string: rewritten)
    }

    /// Every larger rendition of `url` under any role, largest first, then `url` itself, deduped.
    /// The cache treats these as one family. For `…/t/p/w500/x.png`: `[…/original/x.png,
    /// …/w780/x.png, …/w500/x.png]`. A URL on any other host, or an `.svg`, is its own family.
    static func family(_ url: URL) -> [URL] {
        guard let host = url.host?.lowercased(), host == tmdbHost || host == metahubHost,
              !isSVG(url.absoluteString) else { return [url] }
        var out: [URL] = []
        let candidates: [URL?] = [
            upgraded(url, role: .posterLarge),   // TMDB: original; metahub: large
            upgraded(url, role: .backdrop),      // TMDB: original (a w1280 backdrop has no poster rule)
            upgraded(url, role: .logo),
            upgraded(url, role: .poster),        // TMDB: w780; metahub: large
            url,
        ]
        for candidate in candidates {
            if let candidate, !out.contains(candidate) { out.append(candidate) }
        }
        return out
    }

    /// `host=` and `size=` for the artwork probe: the CDN size segment (`w500` / `w780` / `original`
    /// for TMDB, `poster/medium` / `poster/large` for metahub), `-` otherwise.
    static func sizeSegment(_ url: URL) -> String {
        guard let host = url.host?.lowercased() else { return "-" }
        let s = url.absoluteString
        if host == tmdbHost {
            guard let marker = s.range(of: "/t/p/") else { return "-" }
            let rest = s[marker.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return "-" }
            return String(rest[..<slash])
        }
        if host == metahubHost {
            for kind in ["poster", "background", "logo"] {
                for size in ["small", "medium", "large"] where s.contains("/\(kind)/\(size)/") {
                    return "\(kind)/\(size)"
                }
            }
        }
        return "-"
    }

    // MARK: - Rewrites

    private static func rewrite(_ s: String, host: String, role: Role) -> String? {
        switch host {
        case tmdbHost: return rewriteTMDB(s, role: role)
        case metahubHost: return rewriteMetahub(s, role: role)
        default: return nil
        }
    }

    private static func rewriteTMDB(_ s: String, role: Role) -> String? {
        guard let marker = s.range(of: "/t/p/") else { return nil }
        let afterMarker = s[marker.upperBound...]
        guard let slash = afterMarker.firstIndex(of: "/") else { return nil }
        let size = String(afterMarker[..<slash])
        let sources: Set<String>
        let target: String
        switch role {
        case .poster:
            sources = tmdbPosterSources
            target = "w780"
        case .posterLarge:
            sources = tmdbPosterLargeSources
            target = "original"
        case .backdrop:
            sources = tmdbBackdropSources
            target = "original"
        case .logo:
            // ImageIO cannot decode SVG: keep the w500 path so an SVG logo is no worse than before.
            if isSVG(s) { return nil }
            sources = tmdbLogoSources
            target = "original"
        }
        guard sources.contains(size) else { return nil }
        var out = s
        out.replaceSubrange(marker.upperBound..<slash, with: target)
        return out
    }

    private static func rewriteMetahub(_ s: String, role: Role) -> String? {
        switch role {
        case .poster, .posterLarge: break
        case .backdrop, .logo: return nil
        }
        for from in ["/poster/small/", "/poster/medium/"] {
            if let range = s.range(of: from) {
                return s.replacingCharacters(in: range, with: "/poster/large/")
            }
        }
        return nil
    }

    /// True when the path (before any query or fragment) ends in `.svg`.
    private static func isSVG(_ s: String) -> Bool {
        let end = s.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? s.endIndex
        return s[..<end].lowercased().hasSuffix(".svg")
    }
}
