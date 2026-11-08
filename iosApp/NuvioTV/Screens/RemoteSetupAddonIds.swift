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
        /// An id this session never minted, an id whose add-on left the list since, or an entry
        /// with neither id nor URL: the page's list is out of date.
        case stale
        /// A new add-on address is not a valid http(s) manifest URL.
        case invalidUrl
        /// A new add-on address is the same manifest as an add-on already installed (its row on
        /// the page would carry settings the TV cannot tell apart from the installed one's).
        case alreadyInstalled
    }

    /// The page's add-on list resolved to manifest URLs, in the proposed order, or why it must be
    /// refused as a whole. A new URL is normalised the way the repository normalises it
    /// (`stremio://` and bare hosts are accepted) and must come out as http(s) with a host. Later
    /// duplicates of an existing add-on are dropped; two new rows for one manifest are refused.
    func resolve(
        _ entries: [(id: String?, url: String?, enabled: Bool?)],
        currentUrls: [String],
        normalize: (String) -> String? = { AddonManifestURL.normalizeOrNil($0) },
        sameManifest: (String, String) -> Bool = { $0 == $1 }
    ) -> Result<[Resolved], Refusal> {
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
}
