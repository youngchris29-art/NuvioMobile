import Foundation

/// Home Watchlist row (FEAT-92), W3 review r1: when the provider pull may start, "after Home's
/// first rows draw" (decision I). The model feeds the inputs and calls `evaluate()` whenever one
/// of them may have turned true; the release fires once per subscription, `drawDelaySeconds`
/// after the inputs first allow it and only if they still allow it then. `reset()` (the model's
/// `stopWatchlist()`: toggle off, teardown, profile switch, sign-out) drops a pending release and
/// re-arms for the next subscription. Out of `HomeViewModel` so the rule is unit-tested
/// (`HomeWatchlistReleaseGateTests`).
@MainActor
final class HomeWatchlistReleaseGate {
    struct Inputs: Equatable {
        /// A live `observeWatchlist()` watcher (never on the DEBUG seed path).
        var subscribed: Bool
        /// `HomeViewModel.catalogRowsSettledAfterGateOpen`.
        var settled: Bool
        /// Another tab, a push, the stream picker or the root cover is over Home.
        var covered: Bool
        /// A Home row view has appeared in this pipeline run.
        var rowDrawn: Bool
        /// Home has no row of any kind to draw.
        var nothingToDraw: Bool
    }

    /// Time between the inputs allowing a release and the release, re-checked when it fires.
    nonisolated static let drawDelaySeconds: Double = 0.3

    nonisolated static func allows(_ inputs: Inputs) -> Bool {
        inputs.subscribed && inputs.settled && !inputs.covered && (inputs.rowDrawn || inputs.nothingToDraw)
    }

    typealias Schedule = (_ seconds: Double, _ block: @escaping @MainActor () -> Void) -> Void

    private let inputs: @MainActor () -> Inputs
    private let schedule: Schedule
    private let release: @MainActor () -> Void
    private var released = false
    private var token = 0

    /// `schedule` is injectable for tests only.
    init(inputs: @escaping @MainActor () -> Inputs,
         schedule: @escaping Schedule = { seconds, block in
             Task { @MainActor in
                 try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                 block()
             }
         },
         release: @escaping @MainActor () -> Void) {
        self.inputs = inputs
        self.schedule = schedule
        self.release = release
    }

    func evaluate() {
        guard !released, Self.allows(inputs()) else { return }
        token &+= 1
        let armed = token
        schedule(Self.drawDelaySeconds) { [weak self] in
            guard let self, armed == self.token, !self.released, Self.allows(self.inputs()) else { return }
            self.released = true
            self.release()
        }
    }

    func reset() {
        released = false
        token &+= 1
    }
}
