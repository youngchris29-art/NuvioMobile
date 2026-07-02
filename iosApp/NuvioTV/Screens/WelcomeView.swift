import SwiftUI

/// First-run / signed-out gate: choose between a Nuvio account (cloud sync with the phone app)
/// and local guest mode (the pre-cloud behavior). Shown whenever `AuthRepository` reports
/// `Unauthenticated` — existing guest installs never see this (their stored anonymous id
/// authenticates immediately).
struct WelcomeView: View {
    @ObservedObject var model: AuthViewModel

    private enum AuthSheet: String, Identifiable {
        case signIn, signUp
        var id: String { rawValue }
    }

    @State private var sheet: AuthSheet?

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.sectionGap) {
                VStack(spacing: Theme.Spacing.md) {
                    Text("Nuvio")
                        .font(Theme.Font.hero)
                        .foregroundStyle(Theme.Palette.accent)
                    Text("Sign in to sync your library, watch progress, and profiles across devices — or continue as a guest on this Apple TV only.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                }

                VStack(spacing: Theme.Spacing.lg) {
                    Button {
                        model.clearError()
                        sheet = .signIn
                    } label: {
                        Text("Sign In")
                            .frame(maxWidth: 600)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.accent)

                    Button {
                        model.clearError()
                        sheet = .signUp
                    } label: {
                        Text("Create Account")
                            .frame(maxWidth: 600)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.continueAsGuest()
                    } label: {
                        Text("Continue as Guest")
                            .frame(maxWidth: 600)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(Theme.Spacing.screen)
        }
        .fullScreenCover(item: $sheet) { mode in
            AuthView(model: model, isSignUp: mode == .signUp)
        }
    }
}
