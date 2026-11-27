import Combine
import Foundation
import SharedCore
import UIKit

/// Which cover the identity window shows (spec 8.2, decision E).
enum IdentityCoverKind: Equatable {
    case switching
    case signingOut
}

/// What the app shows while the barrier is in Recovery after a failed publish or wipe (decision AA).
enum IdentityRecoveryScreen: Equatable {
    case none
    /// The loading splash while the retries run.
    case splash
    /// Welcome (Sign In, Continue as Guest) after the last retry, or at once for a failed wipe.
    case welcome
}

/// The surfaces whose unmount the barrier waits for before a profile apply (4.6, revision 8).
enum IdentityTeardownSurface: Hashable {
    case shell
    case deepLinkCover
}

/// The cover window, behind a protocol so `CoverOwnershipTests` can use a fake.
@MainActor
protocol IdentityCoverPresenting: AnyObject {
    /// Shows (or retargets) the cover; false when there is no scene to show it in.
    func show(_ kind: IdentityCoverKind) -> Bool
    func hide()
}

/// Dismisses everything presented over the main window's root, so the picker (or Welcome) is the
/// front, focusable screen (8.2 "Cover ownership").
@MainActor
protocol IdentityRootRecovering: AnyObject {
    func recoverToRoot()
}

/// Scope identity W2 (spec 8.2): the one owner of the identity cover, the shell revocation and the
/// teardown acknowledgement. Swift never infers identity from gate changes; it compares the
/// published `IdentityState` by value.
@MainActor
final class IdentityModel: ObservableObject {
    static let shared = IdentityModel(cover: IdentityCoverWindow.shared, root: MainWindowRootRecoverer())

    @Published private(set) var state: IdentityState?
    /// Held by `ProfilesViewModel.selectAndEnter` for the whole select (8.0.3).
    @Published var localSelectInFlight = false {
        didSet { if localSelectInFlight != oldValue { coverInputsChanged() } }
    }
    @Published private(set) var coverKind: IdentityCoverKind?
    @Published private(set) var recoveryScreen: IdentityRecoveryScreen = .none
    /// Bumped on every state change (Kotlin values are not Equatable to SwiftUI's onChange).
    @Published private(set) var revision = 0
    /// The published account as a comparable key ("account:<id>", "guest:<id>", "none").
    @Published private(set) var accountKey = "none"
    var coverVisible: Bool { coverKind != nil }

    /// True while the user is in an entered profile (`auth.gate == .main && entered`); ContentView
    /// and `selectAndEnter` keep it current. Read when the cover hides.
    var isEntered = false
    /// ContentView's revocation, run synchronously by `revoke` on the main thread (never via onChange).
    var onRevoke: ((IdentityState) -> Void)?
    /// The retry (`AuthRepository.retryIdentityRecovery`) and its spacing; replaced in tests.
    var retryRecovery: () async -> Void = { _ = try? await AuthRepository.shared.retryIdentityRecovery() }
    var retrySpacingNanoseconds: UInt64 = 5_000_000_000
    static let maxRecoveryRetries = 6

    private let cover: IdentityCoverPresenting
    private let root: IdentityRootRecovering
    private var watcher: FlowWatcher?
    /// Mounted instances per surface: a theme `.id()` rebuild mounts the incoming shell before the
    /// outgoing one disappears, so presence is a count, never a flag.
    private var mountCounts: [IdentityTeardownSurface: Int] = [:]
    private var mounted: Set<IdentityTeardownSurface> { Set(mountCounts.filter { $0.value > 0 }.keys) }
    private var awaitingTeardown: (id: Int64, waiting: Set<IdentityTeardownSurface>)?
    private var retryTask: Task<Void, Never>?
    /// Audit #7: the generation of the one live retry loop; a cancelled loop's tail never clears or restarts a newer one.
    private var retryGeneration = 0
    private(set) var recoveryRetries = 0
    /// Sends `teardownDone`; replaced in tests.
    var sendTeardown: (Int64) -> Void = { IdentityBarrier.shared.teardownDone(transitionId: $0) }

    init(cover: IdentityCoverPresenting, root: IdentityRootRecovering) {
        self.cover = cover
        self.root = root
    }

    /// Watches `IdentityGate.state`. Idempotent. Each delivery re-reads the current value, so a
    /// late delivery can never put an older state over the one a revoke installed.
    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(IdentityGate.shared.state) { [weak self] _ in
            guard let self else { return }
            self.setState(IdentityGate.shared.state.value_ as? IdentityState)
        }
    }

    /// The state the gate holds now (Kotlin's StateFlow value, read synchronously).
    func currentState() -> IdentityState? {
        IdentityGate.shared.state.value_ as? IdentityState
    }

    func setState(_ newState: IdentityState?) {
        if !IdentityValues.same(state, newState) {
            state = newState
            revision &+= 1
            let key = newState?.scope.account.storageKey() ?? "none"
            if key != accountKey { accountKey = key }
        }
        coverInputsChanged()
        evaluateRecovery()
    }

    // MARK: - Revocation (4.6)

    /// Runs on the main thread before the barrier drains, applies, wipes or publishes: shows the
    /// cover for kinds that have one, leaves the shell (ContentView's closure) and starts waiting
    /// for the shell and the deep-link cover to unmount. True only if every step succeeded.
    func revoke(_ newState: IdentityState) -> Bool {
        setState(newState)
        onRevoke?(newState)
        beginTeardown(newState)
        // For a cover kind, `coverKind` is non-nil only if the window could be shown.
        return Self.coverKind(state: newState, localSelectInFlight: localSelectInFlight) == nil || coverKind != nil
    }

    // MARK: - Cover ownership (8.2, revision 7)

    /// Pure: which cover the inputs ask for.
    nonisolated static func coverKind(state: IdentityState?, localSelectInFlight: Bool) -> IdentityCoverKind? {
        if localSelectInFlight { return .switching }
        guard let state, state.transitioning, let kind = state.kind else { return nil }
        switch kind {
        case .profileselect, .activeprofiledelete, .slotremoved: return .switching
        case .signout, .deleteaccount, .serverswitch, .accountwipe: return .signingOut
        default: return nil // accountpublished: no cover (4.6)
        }
    }

    /// The transition kind the visible cover is covering (the last one seen while it was up).
    private var coveredKind: TransitionKind?
    /// Whether the last server switch failed (its screen shows the error); replaced in tests.
    var serverSwitchFailed: () -> Bool = {
        (ServerConnectionController.shared.state.value_ as? ServerConnectionUiState)?.switchFailure != nil
    }

    private func coverInputsChanged() {
        let wanted = Self.coverKind(state: state, localSelectInFlight: localSelectInFlight)
        if wanted != nil, let state, state.transitioning, let kind = state.kind { coveredKind = kind }
        guard wanted != coverKind else { return }
        let wasVisible = coverKind != nil
        if let wanted {
            coverKind = cover.show(wanted) ? wanted : nil
        } else {
            coverKind = nil
            cover.hide()
            let ended = coveredKind
            coveredKind = nil
            // P13(c): every cover exit leaves the user on a focusable screen (review r2 #3: the
            // decision is CoverExitRule's, from what ended and how).
            if wasVisible && CoverExitRule.dismissPresented(endedKind: ended,
                                                             serverSwitchFailed: ended == .serverswitch && serverSwitchFailed(),
                                                             entered: isEntered) {
                root.recoverToRoot()
            }
        }
    }

    // MARK: - Teardown acknowledgement (4.6, revision 8)

    func surfaceAppeared(_ surface: IdentityTeardownSurface) {
        mountCounts[surface, default: 0] += 1
    }

    func surfaceDisappeared(_ surface: IdentityTeardownSurface) {
        mountCounts[surface] = max(0, (mountCounts[surface] ?? 0) - 1)
        guard (mountCounts[surface] ?? 0) == 0, var awaiting = awaitingTeardown else { return }
        awaiting.waiting.remove(surface)
        awaitingTeardown = awaiting
        if awaiting.waiting.isEmpty { finishTeardown() }
    }

    private func beginTeardown(_ state: IdentityState) {
        guard state.transitionId != 0 else { return } // windows are not acknowledged
        awaitingTeardown = (state.transitionId, mounted)
        if mounted.isEmpty {
            // After the revoke returned: the barrier records the id it is waiting for at Begin.
            DispatchQueue.main.async { [weak self] in self?.finishTeardown() }
        }
    }

    private func finishTeardown() {
        guard let awaiting = awaitingTeardown, awaiting.waiting.isEmpty else { return }
        awaitingTeardown = nil
        #if DEBUG
        if UserDefaults.standard.integer(forKey: "debug.identitySuppressTeardown") == 1 {
            print("[Identity] debug: teardownDone suppressed for transition \(awaiting.id)")
            return
        }
        #endif
        sendTeardown(awaiting.id)
    }

    // MARK: - Recovery (rule B, decision AA)

    /// Retries on return to the foreground too (rule B).
    func returnedToForeground() {
        guard state?.recovery == .failedpublish else { return }
        Task { await retryRecovery() }
    }

    private func evaluateRecovery() {
        let screen: IdentityRecoveryScreen
        switch state?.recovery {
        case .some(.failedpublish):
            screen = recoveryRetries < Self.maxRecoveryRetries ? .splash : .welcome
            if screen == .splash { scheduleRetry() }
        case .some(.failedwipe):
            screen = .welcome
        default:
            // FailedApply has no screen of its own: the cover hides and the picker is the front (B′).
            screen = .none
            recoveryRetries = 0
            retryTask?.cancel()
            retryTask = nil
            retryGeneration += 1
        }
        if screen != recoveryScreen { recoveryScreen = screen }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryGeneration += 1
        let generation = retryGeneration
        retryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.retrySpacingNanoseconds)
            guard !Task.isCancelled, generation == self.retryGeneration else { return }
            self.recoveryRetries += 1
            await self.retryRecovery()
            // Cancelled or superseded while the retry ran: the newer loop owns retryTask.
            guard !Task.isCancelled, generation == self.retryGeneration else { return }
            self.retryTask = nil
            self.setState(self.currentStateForRetry())
        }
    }

    /// The state after a retry: the gate's in the app, the last known in tests.
    var currentStateForRetry: () -> IdentityState? = { IdentityGate.shared.state.value_ as? IdentityState }
}

/// Review r2 #3: whether the cover's exit dismisses what is presented over the root. Pure.
///
/// Entered: never (the shell stays). A failed server switch: never (ServerConnectionView, presented
/// from Welcome or pushed from Settings, keeps its error so the user can correct it in place).
/// Every other exit while not entered dismisses, so the picker or Welcome is the front, focusable
/// screen: a profile select or delete or slot removal (players or covers left from the shell), a
/// sign-out or delete account (the gate is Welcome), a lost session's wipe, a successful server
/// switch (its own screen would dismiss itself too).
nonisolated enum CoverExitRule {
    static func dismissPresented(endedKind: TransitionKind?, serverSwitchFailed: Bool, entered: Bool) -> Bool {
        if entered { return false }
        if endedKind == .serverswitch && serverSwitchFailed { return false }
        return true
    }
}

/// The real root recovery: dismiss whatever is presented over the main window's root.
@MainActor
final class MainWindowRootRecoverer: IdentityRootRecovering {
    func recoverToRoot() {
        guard let root = IdentityCoverWindow.mainWindow()?.rootViewController, root.presentedViewController != nil else { return }
        print("[Identity] cover hidden while not entered: dismissing presented screens")
        root.dismiss(animated: false)
    }
}
