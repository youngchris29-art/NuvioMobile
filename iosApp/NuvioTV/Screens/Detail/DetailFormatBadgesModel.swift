import Combine
import Foundation
import SharedCore

/// Where `DetailFormatBadgesModel` gets its badges: `TitleFormatProbe.shared` in the app, a fake in
/// NuvioTVTests so the dwell and gating run without the network.
nonisolated protocol DetailFormatBadgeSource {
    func start(_ request: TitleFormatRequest)
    func cancel(_ request: TitleFormatRequest)
    /// What is known for the request right now (empty when nothing is).
    func badges(for request: TitleFormatRequest) -> [TitleFormatBadge]
    /// The request's badges on every change of the probe's states; ends when the iterating task is
    /// cancelled.
    func updates(for request: TitleFormatRequest) -> AsyncStream<[TitleFormatBadge]>
}

/// Production source: the shared probe, watched with `FlowWatcher` like `StateFlowObserver`.
nonisolated struct TitleFormatProbeSource: DetailFormatBadgeSource {
    func start(_ request: TitleFormatRequest) { TitleFormatProbe.shared.start(request: request) }

    func cancel(_ request: TitleFormatRequest) { TitleFormatProbe.shared.cancel(request: request) }

    func badges(for request: TitleFormatRequest) -> [TitleFormatBadge] {
        TitleFormatProbe.shared.state(request: request).badges
    }

    func updates(for request: TitleFormatRequest) -> AsyncStream<[TitleFormatBadge]> {
        let key = request.key
        return AsyncStream { continuation in
            // A Kotlin `Map` arrives as an NSDictionary; read only our entry.
            let watcher = FlowWatcherKt.watch(TitleFormatProbe.shared.states) { emitted in
                let state = (emitted as? NSDictionary)?[key] as? TitleFormatState
                continuation.yield(state?.badges ?? [])
            }
            continuation.onTermination = { _ in watcher.cancel() }
        }
    }
}

/// Backs `DetailFormatBadgeRow`: starts the format probe once the page has dwelt on a request and
/// keeps `badges` in step with it. Within one request key badges only grow (the picker fold adds
/// to them); a new key resets to that key's state.
@MainActor
final class DetailFormatBadgesModel: ObservableObject {
    @Published private(set) var badges: [TitleFormatBadge] = []

    private let source: DetailFormatBadgeSource
    private let dwell: Duration
    /// The key `badges` belongs to.
    private var shownKey: String?
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
            badges = source.badges(for: request)
        } else {
            apply(source.badges(for: request))
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

    /// Grows `badges` by `next` with the shared merge (canonical order, one dynamic-range badge).
    private func apply(_ next: [TitleFormatBadge]) {
        let merged = TitleFormatBadges.shared.merge(a: badges, b: next)
        if merged != badges { badges = merged }
    }

    private func stopStarted() {
        guard let started else { return }
        source.cancel(started)
        self.started = nil
    }
}
