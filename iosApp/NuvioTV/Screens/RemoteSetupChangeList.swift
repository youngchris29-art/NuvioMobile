import Foundation

/// Add-ons hub v2, Stage C (C3): what a Remote Setup proposal changes, one line per change, for
/// the confirm dialog on the TV. Pure: the view model passes in the lists as they are now and as
/// the proposal would leave them.
///
/// Add-ons are named by their title (a new one by its host): never by manifest URL, which can
/// carry a debrid key. A reorder lists only the items that actually moved (everything outside the
/// longest run that kept its relative order), so dragging one item gives one line.
nonisolated enum RemoteSetupChangeList {

    struct Line: Equatable, Identifiable {
        enum Kind: Equatable {
            case install, remove, move, turnOn, turnOff, key, pattern, badges, rejected
        }
        let kind: Kind
        let text: String
        /// Review r2: the add-on or row the line is about (empty for settings lines), so two lines
        /// for same-titled items never compare equal or share an id.
        var subject: String = ""
        var id: String { "\(kind)|\(subject)|\(text)" }
    }

    /// An installed add-on or a Home row as it is now.
    struct Item: Equatable {
        let id: String
        let title: String
        let enabled: Bool
    }

    /// One add-on of the proposed list: an installed one by `id`, or a new one (`isNew`, titled by host).
    struct ProposedAddon: Equatable {
        let id: String
        let title: String
        let enabled: Bool?
        let isNew: Bool
    }

    /// The lines for a proposal. `proposedAddons` is nil when the proposal leaves add-ons alone,
    /// `rowOrder` nil when it leaves the row order alone, `disabledRows` nil when it leaves the
    /// rows' on/off alone (each is applied on its own, as `applyRows` does).
    static func lines(
        addons: [Item],
        proposedAddons: [ProposedAddon]?,
        rows: [Item],
        rowOrder: [String]?,
        disabledRows: Set<String>?,
        setsMdbListKey: Bool,
        mdbListEnabled: Bool = true,
        posterPattern: String?,
        posterPatternValid: (String) -> Bool,
        badgePackUrls: [String]
    ) -> [Line] {
        var out: [Line] = []
        // Review r2: same-titled items get their current position, so the user can tell them apart.
        func named(_ items: [Item]) -> [String: String] {
            let counts = Dictionary(items.map { ($0.title, 1) }, uniquingKeysWith: +)
            var names: [String: String] = [:]
            for (index, item) in items.enumerated() {
                names[item.id] = counts[item.title, default: 0] > 1 ? "\(item.title) (#\(index + 1))" : item.title
            }
            return names
        }
        let addonName = named(addons)
        let rowName = named(rows)

        if let proposed = proposedAddons {
            let keptIds = Set(proposed.filter { !$0.isNew }.map(\.id))
            for addon in addons where !keptIds.contains(addon.id) {
                out.append(Line(kind: .remove, text: String(localized: "Remove add-on \(addonName[addon.id] ?? addon.title)"), subject: addon.id))
            }
            // Review r3: new add-ons sharing a host are told apart by their place in the
            // proposed list (the URL itself never shows).
            let newHosts = Dictionary(proposed.filter(\.isNew).map { ($0.title, 1) }, uniquingKeysWith: +)
            for (position, entry) in proposed.enumerated() where entry.isNew {
                let off = entry.enabled == false
                let title = newHosts[entry.title, default: 0] > 1 ? "\(entry.title) (#\(position + 1))" : entry.title
                out.append(Line(kind: .install, text: off
                    ? String(localized: "Install add-on \(title) (turned off)")
                    : String(localized: "Install add-on \(title)"), subject: entry.id))
            }
            let kept = proposed.filter { !$0.isNew }
            for id in movedIds(before: addons.map(\.id).filter(keptIds.contains), after: kept.map(\.id)) {
                guard let title = addonName[id],
                      let position = kept.firstIndex(where: { $0.id == id }) else { continue }
                out.append(Line(kind: .move, text: String(localized: "Move add-on \(title) to position \(position + 1)"), subject: id))
            }
            for entry in kept {
                guard let enabled = entry.enabled,
                      let current = addons.first(where: { $0.id == entry.id }),
                      current.enabled != enabled else { continue }
                let title = addonName[current.id] ?? current.title
                out.append(enabled
                    ? Line(kind: .turnOn, text: String(localized: "Turn on add-on \(title)"), subject: current.id)
                    : Line(kind: .turnOff, text: String(localized: "Turn off add-on \(title)"), subject: current.id))
            }
        }

        // Review r1: the same simulation `applyRows` runs. The proposed order goes to the front
        // in that order; rows the phone did not list (a sync added them) keep their order after it.
        if let order = rowOrder {
            let current = rows.map(\.id)
            let known = Set(current)
            var seen = Set<String>()
            let listed = order.filter { known.contains($0) && seen.insert($0).inserted }
            let result = listed + current.filter { !seen.contains($0) }
            for id in movedIds(before: current, after: result) {
                guard let title = rowName[id],
                      let position = result.firstIndex(of: id) else { continue }
                out.append(Line(kind: .move, text: String(localized: "Move Home row \(title) to position \(position + 1)"), subject: id))
            }
        }
        // Review r1: on/off is applied whenever the proposal carries the disabled set, with or
        // without an order, and only then.
        if let disabled = disabledRows {
            for row in rows {
                let shouldBeOn = !disabled.contains(row.id)
                guard row.enabled != shouldBeOn else { continue }
                let title = rowName[row.id] ?? row.title
                out.append(shouldBeOn
                    ? Line(kind: .turnOn, text: String(localized: "Turn on Home row \(title)"), subject: row.id)
                    : Line(kind: .turnOff, text: String(localized: "Turn off Home row \(title)"), subject: row.id))
            }
        }

        if setsMdbListKey {
            // Review r3: applying a key also turns MDBList on.
            out.append(Line(kind: .key, text: mdbListEnabled
                ? String(localized: "Set the MDBList API key")
                : String(localized: "Set the MDBList API key and turn MDBList on")))
        }
        if let raw = posterPattern {
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if pattern.isEmpty {
                out.append(Line(kind: .pattern, text: String(localized: "Clear the custom poster pattern")))
            } else if posterPatternValid(pattern) {
                out.append(Line(kind: .pattern, text: String(localized: "Set the custom poster pattern")))
            } else {
                out.append(Line(kind: .rejected, text: String(localized: "Ignore the poster pattern (it must be an http(s) URL)")))
            }
        }
        // Review r6/r7: one line per pack (a pack URL is a public file). Packs import in order
        // and the last one imported is the active pack, so the dialog says which one that is.
        let labels = badgePackLabels(badgePackUrls)
        for (index, url) in badgePackUrls.enumerated() {
            let label = labels[index]
            out.append(Line(kind: .badges,
                            text: index == badgePackUrls.count - 1
                                ? String(localized: "Import badge pack \(label) and make it the active pack")
                                : String(localized: "Import badge pack \(label)"),
                            subject: url))
        }
        return out
    }

    /// Labels for `urls` in order: `host/file.json`, or the whole path where two would read the
    /// same (review r7).
    static func badgePackLabels(_ urls: [String]) -> [String] {
        let short = urls.map(badgePackLabel)
        let counts = Dictionary(short.map { ($0, 1) }, uniquingKeysWith: +)
        return urls.enumerated().map { index, url in
            guard counts[short[index], default: 0] > 1,
                  let parts = URLComponents(string: url), let host = parts.host else { return short[index] }
            return host + parts.path
        }
    }

    /// `host/file.json` for a badge pack URL (the query is dropped), or the trimmed text when it
    /// does not parse.
    static func badgePackLabel(_ url: String) -> String {
        guard let parts = URLComponents(string: url), let host = parts.host, !host.isEmpty else {
            return String(url.prefix(60))
        }
        let file = parts.path.split(separator: "/").last.map(String.init) ?? ""
        return file.isEmpty ? host : "\(host)/\(file)"
    }

    /// The ids that moved from `before` to `after` (same set of ids): everything outside a longest
    /// subsequence that kept its relative order, in `after` order.
    static func movedIds(before: [String], after: [String]) -> [String] {
        let rank = Dictionary(uniqueKeysWithValues: before.enumerated().map { ($1, $0) })
        let ranks = after.compactMap { rank[$0] }
        guard ranks.count == after.count, !ranks.isEmpty else { return [] }
        // Longest increasing subsequence of `ranks`, keeping the indices that form it.
        var tailRanks: [Int] = []
        var tailIndex: [Int] = []
        var previous = Array(repeating: -1, count: ranks.count)
        for (i, r) in ranks.enumerated() {
            var low = 0, high = tailRanks.count
            while low < high {
                let mid = (low + high) / 2
                if tailRanks[mid] < r { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[i] = tailIndex[low - 1] }
            if low == tailRanks.count {
                tailRanks.append(r)
                tailIndex.append(i)
            } else {
                tailRanks[low] = r
                tailIndex[low] = i
            }
        }
        var stays = Set<Int>()
        var cursor = tailIndex.last ?? -1
        while cursor >= 0 {
            stays.insert(cursor)
            cursor = previous[cursor]
        }
        return after.enumerated().filter { !stays.contains($0.offset) }.map(\.element)
    }
}
