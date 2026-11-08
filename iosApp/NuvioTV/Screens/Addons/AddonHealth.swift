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
        if health.failed { return " · " + String(localized: "Check failed") }
        guard let ms = health.latencyMs else { return "" }
        return " · \(ms) ms"
    }

    /// The accessibility phrase, nil with no data.
    static func spoken(_ health: AddonHealthSnapshot?) -> String? {
        guard let health else { return nil }
        if health.failed { return String(localized: "Check failed") }
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
        if health.failed { return when + " · " + String(localized: "Check failed") }
        guard let ms = health.latencyMs else { return when }
        return when + " · \(ms) ms"
    }
}

/// C4: the tvOS side of `AddonHealthTracker`. Review r1: in memory only, mirroring the tracker,
/// which is cleared with the add-on state on a profile switch or sign-out. Nothing goes to disk
/// (the map is keyed by manifest URLs, which can carry debrid keys), and nothing can be filed
/// under the wrong profile. Health shows from the first refresh after launch.
@MainActor
final class AddonHealthStore: ObservableObject {
    static let shared = AddonHealthStore()

    @Published private(set) var snapshots: [String: AddonHealthSnapshot] = [:]

    private var watcher: FlowWatcher?

    /// Idempotent: follows the Kotlin flow.
    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(AddonHealthTracker.shared.health) { [weak self] emitted in
            guard let map = emitted as? [String: AddonHealth] else { return }
            Task { @MainActor in self?.receive(map) }
        }
    }

    func snapshot(for manifestUrl: String) -> AddonHealthSnapshot? { snapshots[manifestUrl] }

    /// The tracker's whole map replaces the mirror (an empty map after a reset clears it).
    func receive(_ map: [String: AddonHealth]) {
        let next = map.mapValues { health in
            AddonHealthSnapshot(
                latencyMs: health.latencyMs.map { Int(truncating: $0) },
                failed: health.failed,
                checkedAt: Date(timeIntervalSince1970: Double(health.checkedAtEpochMs) / 1000)
            )
        }
        guard next != snapshots else { return }
        snapshots = next
    }
}
