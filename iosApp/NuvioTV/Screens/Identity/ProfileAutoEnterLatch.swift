import Foundation

/// Scope identity W2 (spec 8.2): whether the FEAT-65 "Open Last Profile at Launch" decision may run
/// when the auth gate turns `.main`. Pure; replaces `ContentView.profileAutoEnterConsumed`.
///
/// A watchdog Welcome during a slow restore (loading → welcome) does not consume it, so the restore
/// that follows may still auto-enter. A visit to Welcome from `.main`, a sign-in the user started,
/// an account change while `.main`, and the decision itself all consume it (P6).
nonisolated struct ProfileAutoEnterLatch: Equatable {
    private(set) var consumed = false
    private(set) var provisionalWelcome = false

    enum Event {
        case gate(from: AuthViewModel.Gate, to: AuthViewModel.Gate)
        case userStartedSignIn
        case accountChangedWhileMain
        case autoEnterRan
    }

    mutating func apply(_ event: Event) {
        switch event {
        case .gate(from: .main, to: .welcome):
            consumed = true
        case .gate(from: .loading, to: .welcome):
            provisionalWelcome = true
        case .gate:
            break
        case .userStartedSignIn, .accountChangedWhileMain, .autoEnterRan:
            consumed = true
        }
    }

    /// Asked when the gate turns `.main`: true = run the FEAT-65 decision now.
    var mayAutoEnter: Bool { !consumed }
}
