import Foundation

/// Stream links that failed recently, per title (orivio batch item 2): a source that never
/// started, or died within five minutes (`PlaybackFailoverPolicy.shouldReject`), is remembered for
/// eight hours and skipped by every automatic picker — the stream picker's first-play auto-start
/// and its failover walk, and the Up Next engine's selection. The picker's rows caption them
/// "Failed recently". A link that later plays past five minutes clears itself (`keep`).
///
/// Storage: one JSON blob in `UserDefaults.standard` under `storageKey`,
/// `[title: [streamKey: Date]]` (dates as seconds since 1970). Every call reads it through — there
/// is deliberately NO in-memory cache, because the sign-out wipe deletes the key out from under
/// this type (registered as `RejectedStreamLinks` in the shared `AccountDataStores`), and a cache
/// would resurrect the previous account's history. `title` is the playing video's id
/// (`PlaybackContext.videoId`: the movie id, or the episode's `meta:season:episode`); keys are
/// `StreamItem.playbackStreamKey` — an info hash or a digest, never link text, so neither this
/// store nor its log lines hold a token or a debrid API key (`PlaybackStreamKey`).
///
/// Caps: 6 keys per title and 60 titles, the oldest dropped first; entries past the 8-hour TTL
/// are pruned on every read and write. The `defaults` / `now` parameters exist for tests.
enum RejectedStreamLinks {
    static let storageKey = "tvos_rejected_stream_links_v1"
    static let ttl: TimeInterval = 8 * 60 * 60
    static let maxKeysPerTitle = 6
    static let maxTitles = 60

    private typealias Store = [String: [String: Date]]

    /// Remember `streamKey` as failed for `title`. Empty keys or titles are ignored.
    static func reject(_ streamKey: String, title: String,
                       defaults: UserDefaults = .standard, now: Date = Date()) {
        guard !streamKey.isEmpty, !title.isEmpty else { return }
        var store = load(defaults: defaults, now: now)
        var keys = store[title] ?? [:]
        keys[streamKey] = now
        if keys.count > maxKeysPerTitle {
            let overflow = keys.count - maxKeysPerTitle
            for (key, _) in keys.sorted(by: { $0.value < $1.value }).prefix(overflow) {
                keys.removeValue(forKey: key)
            }
        }
        store[title] = keys
        if store.count > maxTitles {
            // A title's age is its NEWEST rejection: the one nobody has hit for longest goes first.
            let overflow = store.count - maxTitles
            let byAge = store.sorted { ($0.value.values.max() ?? .distantPast) < ($1.value.values.max() ?? .distantPast) }
            for (oldTitle, _) in byAge.prefix(overflow) {
                store.removeValue(forKey: oldTitle)
            }
        }
        save(store, defaults: defaults)
        print("[Failover] reject title=\(title) key=\(streamKey) (\(keys.count) for this title)")
    }

    /// Keys rejected for `title` within the last eight hours.
    static func rejected(for title: String,
                         defaults: UserDefaults = .standard, now: Date = Date()) -> Set<String> {
        guard !title.isEmpty, let keys = load(defaults: defaults, now: now)[title] else { return [] }
        return Set(keys.keys)
    }

    /// Forget a rejection: the link has now played past five minutes. Only that key is cleared.
    static func keep(_ streamKey: String, title: String,
                     defaults: UserDefaults = .standard, now: Date = Date()) {
        guard !streamKey.isEmpty, !title.isEmpty else { return }
        var store = load(defaults: defaults, now: now)
        guard var keys = store[title], keys[streamKey] != nil else { return }
        keys.removeValue(forKey: streamKey)
        store[title] = keys.isEmpty ? nil : keys
        save(store, defaults: defaults)
        print("[Failover] keep title=\(title) key=\(streamKey)")
    }

    // MARK: - Storage

    private static func load(defaults: UserDefaults, now: Date) -> Store {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let decoded = try? decoder.decode(Store.self, from: data) else { return [:] }
        // Prune on read, so an expired entry never reaches a caller. The window is measured both
        // ways: an entry dated in the future (the clock was set back) also lapses after the TTL.
        var pruned: Store = [:]
        for (title, keys) in decoded {
            let live = keys.filter { abs(now.timeIntervalSince($0.value)) < ttl }
            if !live.isEmpty { pruned[title] = live }
        }
        return pruned
    }

    private static func save(_ store: Store, defaults: UserDefaults) {
        guard !store.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(store) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
