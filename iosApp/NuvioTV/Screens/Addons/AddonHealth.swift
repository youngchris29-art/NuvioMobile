import Combine
import Foundation
import SharedCore

/// Add-ons hub v2 (C4): the traffic-light level of an add-on's last manifest fetch.
nonisolated enum AddonHealthLevel: Equatable {
    case good, slow, bad

    static let goodBelowMs = 1000
    static let slowBelowMs = 3000

    /// failed -> bad; < 1000 ms good; < 3000 ms slow; else bad; no data -> nil (no dot).
    static func of(latencyMs: Int?, failed: Bool) -> AddonHealthLevel? {
        if failed { return .bad }
        guard let latencyMs else { return nil }
        if latencyMs < goodBelowMs { return .good }
        if latencyMs < slowBelowMs { return .slow }
        return .bad
    }

    static func of(_ health: AddonHealthSnapshot?) -> AddonHealthLevel? {
        guard let health else { return nil }
        return of(latencyMs: health.latencyMs, failed: health.failed)
    }
}

/// One add-on's last check, as persisted and shown.
nonisolated struct AddonHealthSnapshot: Codable, Equatable {
    var latencyMs: Int?
    var failed: Bool
    var checkedAt: Date
}

/// Wording for a snapshot: the row suffix, the VoiceOver phrase and the detail value.
nonisolated enum AddonHealthText {
    /// "210 ms" below a second, "1.8 s" from there.
    static func latency(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }

    /// The subtitle suffix (leading " · " included), "" with no data.
    static func rowSuffix(_ health: AddonHealthSnapshot?) -> String {
        guard let health else { return "" }
        if health.failed { return " · " + String(localized: "Not responding") }
        guard let ms = health.latencyMs else { return "" }
        return " · \(ms) ms"
    }

    /// The accessibility phrase, nil with no data.
    static func spoken(_ health: AddonHealthSnapshot?) -> String? {
        guard let health else { return nil }
        if health.failed { return String(localized: "Not responding") }
        guard let ms = health.latencyMs, let level = AddonHealthLevel.of(health) else { return nil }
        switch level {
        case .good: return String(localized: "Responds in \(latency(ms))")
        case .slow, .bad: return String(localized: "Slow, \(latency(ms))")
        }
    }

    /// The detail pane's "Last checked" value.
    static func lastChecked(_ health: AddonHealthSnapshot?, now: Date = Date()) -> String {
        guard let health else { return String(localized: "Not checked yet") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let when = formatter.localizedString(for: health.checkedAt, relativeTo: now)
        if health.failed { return when + " · " + String(localized: "Not responding") }
        guard let ms = health.latencyMs else { return when }
        return when + " · \(ms) ms"
    }
}

/// Watches the shared tracker and keeps the last check per profile in UserDefaults.
@MainActor
final class AddonHealthStore: ObservableObject {
    static let shared = AddonHealthStore()

    @Published private(set) var snapshots: [String: AddonHealthSnapshot] = [:]

    private var watcher: FlowWatcher?
    private let defaults: UserDefaults
    private let profileId: () -> Int32
    private var loadedProfile: Int32?

    init(defaults: UserDefaults = .standard,
         profileId: @escaping () -> Int32 = { Int32(truncatingIfNeeded: ProfileRepository.shared.activeProfileId) }) {
        self.defaults = defaults
        self.profileId = profileId
    }

    nonisolated static func storageKey(profileId: Int32) -> String { "addonHealth.v1.\(profileId)" }

    /// Idempotent: loads the active profile's persisted map, then follows the Kotlin flow.
    func start() {
        reloadPersistedIfProfileChanged()
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(AddonHealthTracker.shared.health) { [weak self] emitted in
            guard let map = emitted as? [String: AddonHealth] else { return }
            Task { @MainActor in self?.receive(map) }
        }
    }

    func snapshot(for manifestUrl: String) -> AddonHealthSnapshot? { snapshots[manifestUrl] }

    private func reloadPersistedIfProfileChanged() {
        let id = profileId()
        guard loadedProfile != id else { return }
        loadedProfile = id
        snapshots = Self.decode(defaults.data(forKey: Self.storageKey(profileId: id)))
    }

    /// Kotlin values win over persisted ones.
    func receive(_ map: [String: AddonHealth]) {
        reloadPersistedIfProfileChanged()
        guard !map.isEmpty else { return }
        var next = snapshots
        for (url, health) in map {
            next[url] = AddonHealthSnapshot(
                latencyMs: health.latencyMs.map { Int(truncating: $0) },
                failed: health.failed,
                checkedAt: Date(timeIntervalSince1970: Double(health.checkedAtEpochMs) / 1000)
            )
        }
        guard next != snapshots else { return }
        snapshots = next
        defaults.set(Self.encode(next), forKey: Self.storageKey(profileId: loadedProfile ?? profileId()))
    }

    nonisolated static func encode(_ map: [String: AddonHealthSnapshot]) -> Data? {
        try? JSONEncoder().encode(map)
    }

    nonisolated static func decode(_ data: Data?) -> [String: AddonHealthSnapshot] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: AddonHealthSnapshot].self, from: data)) ?? [:]
    }
}
