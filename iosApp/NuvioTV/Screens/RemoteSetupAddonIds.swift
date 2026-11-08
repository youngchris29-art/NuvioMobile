import Foundation

/// Add-ons hub v2, Stage C (C1): the phone page never sees add-on manifest URLs.
///
/// A manifest URL can carry a debrid key in its path or query (`/torbox=KEY/manifest.json`), and
/// the Remote Setup page used to receive every one of them, protected only by the session token.
/// Now each add-on is sent as an opaque, per-session id plus its host; the page proposes changes
/// to existing add-ons by id and only a NEW add-on carries a URL (the one the user just typed).
///
/// The ids are minted per server session (a fresh random prefix on every start) and mean nothing
/// outside it. A proposal naming an id this session never minted, or one whose add-on has since
/// left the list, is rejected as a whole: dropping the entry would silently REMOVE that add-on.
nonisolated struct RemoteSetupAddonIds {
    private(set) var prefix: String
    private var idsByUrl: [String: String] = [:]
    private var urlsById: [String: String] = [:]

    init(prefix: String = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()) {
        self.prefix = prefix
    }

    /// The session id for `url`, minted on first use and stable for the session.
    mutating func id(for url: String) -> String {
        if let existing = idsByUrl[url] { return existing }
        let id = "\(prefix)-\(idsByUrl.count + 1)"
        idsByUrl[url] = id
        urlsById[id] = url
        return id
    }

    func url(for id: String) -> String? { urlsById[id] }

    /// One add-on of a resolved proposal, in the proposed order.
    struct Resolved: Equatable {
        let url: String
        let enabled: Bool?
        let isNew: Bool
    }

    /// Why a proposal's add-on list cannot be applied as sent.
    enum Refusal: Error, Equatable {
        /// The TV's list is no longer the one the page loaded (an add-on arrived, left or moved),
        /// an id this session never minted, or an entry with neither id nor URL.
        case stale
        /// A new add-on address is not a valid http(s) manifest URL.
        case invalidUrl
        /// A new add-on address is the same manifest as an add-on already installed (its row on
        /// the page would carry settings the TV cannot tell apart from the installed one's).
        case alreadyInstalled
    }

    /// The page's add-on list resolved to manifest URLs, in the proposed order, or why it must be
    /// refused as a whole. `baseline` is the id list the page loaded; it must equal the TV's list
    /// now, in order. A new URL is normalised the way the repository normalises it
    /// (`stremio://` and bare hosts are accepted) and must come out as http(s) with a host. Later
    /// duplicates of an existing add-on are dropped; two new rows for one manifest are refused.
    func resolve(
        _ entries: [(id: String?, url: String?, enabled: Bool?)],
        baseline: [String]?,
        currentUrls: [String],
        normalize: (String) -> String? = { AddonManifestURL.normalizeOrNil($0) },
        sameManifest: (String, String) -> Bool = { $0 == $1 }
    ) -> Result<[Resolved], Refusal> {
        // The list the page edited must still be the TV's list: an add-on that arrived since
        // (sync, another screen) is absent from the proposal and would be removed by omission.
        guard let baseline, baseline == currentUrls.map({ idsByUrl[$0] ?? "" }) else { return .failure(.stale) }
        var resolved: [Resolved] = []
        var seen = Set<String>()
        for entry in entries {
            if let id = entry.id {
                guard let url = urlsById[id], currentUrls.contains(url) else { return .failure(.stale) }
                guard seen.insert(url).inserted else { continue }
                resolved.append(Resolved(url: url, enabled: entry.enabled, isNew: false))
            } else if let raw = entry.url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                guard let url = normalize(raw),
                      let components = URLComponents(string: url),
                      let scheme = components.scheme?.lowercased(),
                      scheme == "http" || scheme == "https",
                      components.host?.isEmpty == false
                else { return .failure(.invalidUrl) }
                if currentUrls.contains(where: { sameManifest($0, url) }) { return .failure(.alreadyInstalled) }
                if resolved.contains(where: { $0.isNew && sameManifest($0.url, url) }) { return .failure(.invalidUrl) }
                resolved.append(Resolved(url: url, enabled: entry.enabled, isNew: true))
            } else {
                return .failure(.stale)
            }
        }
        return .success(resolved)
    }

    /// C1 review r10: an add-on's name and description reach the page too, and either can quote a
    /// keyed URL (a synced name, a manifest description). Every URL becomes `<link>`, secret-style
    /// `name=value` pairs lose their value, and any long path or query piece of the add-on's own
    /// manifest URL (where debrid keys live) is cut wherever it appears.
    static func pageSafe(_ text: String, manifestUrl: String) -> String {
        pageSafe(text, manifestUrls: [manifestUrl])
    }

    /// `pageSafe` against every installed add-on's URL (review r12: Home-row titles come from
    /// catalog names, which any add-on can set).
    static func pageSafe(_ text: String, manifestUrls: [String]) -> String {
        var out = text
        let pieces = Set(manifestUrls.flatMap(secretPieces(of:))).sorted { $0.count > $1.count }
        for piece in pieces {
            if piece.count >= longPiece {
                out = out.replacingOccurrences(of: piece, with: "<redacted>")
            } else {
                // Review r14: a short value is matched as a whole word only, so ordinary text that
                // merely contains its letters stays readable.
                let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: piece) + "(?![A-Za-z0-9])"
                out = out.replacingOccurrences(of: pattern, with: "<redacted>", options: .regularExpression)
            }
        }
        out = out.replacingOccurrences(
            of: #"(?i)\b(?:https?|stremio)://[^\s"'<>]+"#, with: "<link>", options: .regularExpression)
        out = out.replacingOccurrences(
            of: #"(?i)\b(token|access_token|apikey|api_key|key|auth|password)=[^&\s"'<>)]+"#,
            with: "$1=<redacted>", options: .regularExpression)
        return out
    }

    /// Pieces at least this long are cut wherever they appear; shorter ones only as whole words.
    private static let longPiece = 8

    /// The pieces of `manifestUrl` long enough to hold a key, longest first: each path segment and
    /// the query, and (review r11) each value inside them (`torbox=KEY`, `a=1|b=KEY`, query items),
    /// plain and percent-decoded, so a key quoted on its own is cut too.
    static func secretPieces(of manifestUrl: String) -> [String] {
        // Parsed by hand: a literal `|` (common in debrid add-on paths) makes URLComponents fail.
        guard let sep = manifestUrl.range(of: "://") else { return [] }
        let afterScheme = manifestUrl[sep.upperBound...]
        let afterHost = afterScheme.drop(while: { $0 != "/" && $0 != "?" })
        // Review r13: `user:password@` credentials in the authority are pieces too.
        let authority = afterScheme[..<afterHost.startIndex]
        var userinfo: [String] = []
        if let at = authority.lastIndex(of: "@") {
            let info = authority[..<at]
            userinfo.append(String(info))
            userinfo.append(contentsOf: info.split(separator: ":").map(String.init))
        }
        let noFragment = afterHost.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let halves = noFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var raw = (halves.first ?? "").split(separator: "/").map(String.init).filter { $0 != "manifest.json" }
        if halves.count > 1 { raw.append(String(halves[1])) }
        raw.append(contentsOf: userinfo)
        var pieces = Set<String>()
        // Review r12: each chunk is split both as written and percent-decoded, so an encoded
        // separator (`%3D`, `%7C`) cannot hide a value inside it.
        let chunks = raw.flatMap { chunk in [chunk, chunk.removingPercentEncoding].compactMap { $0 } }
        for chunk in chunks {
            pieces.insert(chunk)
            for part in chunk.split(whereSeparator: { "&|,;".contains($0) }) {
                pieces.insert(String(part))
                if let eq = part.firstIndex(of: "=") { pieces.insert(String(part[part.index(after: eq)...])) }
            }
        }
        for piece in pieces {
            if let decoded = piece.removingPercentEncoding { pieces.insert(decoded) }
        }
        // Whole chunks need 8+ characters; a parsed value or userinfo credential counts from 4
        // (review r14: short passwords and keys), shorter ones are flags like `rd` or `en`.
        return pieces.filter { $0.count >= 4 }.sorted { $0.count > $1.count }
    }
}
