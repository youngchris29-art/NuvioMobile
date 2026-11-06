import Combine
import Foundation
import SharedCore

/// One reading of a request's probe state: its badges and the probe's reset generation
/// (`TitleFormatState.generation`). Badges only grow within a generation.
nonisolated struct DetailFormatBadgeSnapshot: Equatable, Sendable {
    var badges: [TitleFormatBadge]
    var generation: Int32

    static let empty = DetailFormatBadgeSnapshot(badges: [], generation: 0)
}

/// Where `DetailFormatBadgesModel` gets its badges: `TitleFormatProbe.shared` in the app, a fake in
/// NuvioTVTests so the dwell and gating run without the network.
nonisolated protocol DetailFormatBadgeSource {
    func start(_ request: TitleFormatRequest)
    func cancel(_ request: TitleFormatRequest)
    /// What is known for the request right now (empty when nothing is).
    func snapshot(for request: TitleFormatRequest) -> DetailFormatBadgeSnapshot
    /// The request's snapshot on every change of the probe's states; ends when the iterating task
    /// is cancelled.
    func updates(for request: TitleFormatRequest) -> AsyncStream<DetailFormatBadgeSnapshot>
}

/// Production source: the shared probe, watched with `FlowWatcher` like `StateFlowObserver`.
nonisolated struct TitleFormatProbeSource: DetailFormatBadgeSource {
    func start(_ request: TitleFormatRequest) { TitleFormatProbe.shared.start(request: request) }

    func cancel(_ request: TitleFormatRequest) { TitleFormatProbe.shared.cancel(request: request) }

    func snapshot(for request: TitleFormatRequest) -> DetailFormatBadgeSnapshot {
        Self.snapshot(TitleFormatProbe.shared.state(request: request))
    }

    private static func snapshot(_ state: TitleFormatState?) -> DetailFormatBadgeSnapshot {
        guard let state else { return .empty }
        return DetailFormatBadgeSnapshot(badges: state.badges, generation: state.generation)
    }

    func updates(for request: TitleFormatRequest) -> AsyncStream<DetailFormatBadgeSnapshot> {
        let key = request.key
        return AsyncStream { continuation in
            // A Kotlin `Map` arrives as an NSDictionary; read only our entry.
            let watcher = FlowWatcherKt.watch(TitleFormatProbe.shared.states) { emitted in
                let state = (emitted as? NSDictionary)?[key] as? TitleFormatState
                continuation.yield(Self.snapshot(state))
            }
            continuation.onTermination = { _ in watcher.cancel() }
        }
    }
}

/// Backs `DetailFormatBadgeRow`: starts the format probe once the page has dwelt on a request and
/// keeps `badges` in step with it. Within one request key and probe generation badges only grow
/// (the picker fold adds to them); a new key or a probe reset (new generation) replaces them.
@MainActor
final class DetailFormatBadgesModel: ObservableObject {
    @Published private(set) var badges: [TitleFormatBadge] = []

    private let source: DetailFormatBadgeSource
    private let dwell: Duration
    /// The key `badges` belongs to.
    private var shownKey: String?
    /// The probe generation `badges` belongs to.
    private var shownGeneration: Int32 = 0
    /// The request whose probe was started last, for `disappear()` and key changes.
    private var started: TitleFormatRequest?

    init(source: DetailFormatBadgeSource = TitleFormatProbeSource(), dwell: Duration = .seconds(1)) {
        self.source = source
        self.dwell = dwell
    }

    static func taskID(request: TitleFormatRequest?, enabled: Bool) -> String {
        "\(enabled ? "on" : "off")|\(request?.key ?? "-")"
    }

    /// Call from `.task(id: DetailFormatBadgesModel.taskID(request:enabled:))`. Shows any cached
    /// state at once, waits the dwell (returns without starting if cancelled during it), starts the
    /// probe and follows its state until the task is cancelled. Off or no request: clears, no start.
    func run(request: TitleFormatRequest?, enabled: Bool) async {
        guard enabled, let request else {
            stopStarted()
            shownKey = nil
            if !badges.isEmpty { badges = [] }
            return
        }
        if let started, started.key != request.key { stopStarted() }
        if shownKey != request.key {
            shownKey = request.key
            replace(with: source.snapshot(for: request))
        } else {
            apply(source.snapshot(for: request))
        }

        try? await Task.sleep(for: dwell)
        if Task.isCancelled { return }

        source.start(request)
        started = request
        for await next in source.updates(for: request) {
            guard shownKey == request.key else { break }
            apply(next)
        }
    }

    /// Call from `.onDisappear`: cancels the probe for the last started request.
    func disappear() {
        stopStarted()
    }

    /// Same generation: grows `badges` by `next` with the shared merge (canonical order, one
    /// dynamic-range badge). New generation (the probe reset this key): replaces them.
    private func apply(_ next: DetailFormatBadgeSnapshot) {
        guard next.generation == shownGeneration else {
            replace(with: next)
            return
        }
        let merged = TitleFormatBadges.shared.merge(a: badges, b: next.badges)
        if merged != badges { badges = merged }
    }

    private func replace(with snapshot: DetailFormatBadgeSnapshot) {
        shownGeneration = snapshot.generation
        if snapshot.badges != badges { badges = snapshot.badges }
    }

    private func stopStarted() {
        guard let started else { return }
        source.cancel(started)
        self.started = nil
    }
}
