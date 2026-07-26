import SwiftUI

/// Email/password form for signing in to (or creating) a Nuvio account. tvOS text entry uses the
/// system full-screen keyboard. Success is observed via `AuthRepository.state` (the cover is torn
/// down when the root gate flips to `.main`), so this view only handles input, busy, and errors.
struct AuthView: View {
    @ObservedObject var model: AuthViewModel
    let isSignUp: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""

    private var canSubmit: Bool {
        !model.isBusy &&
            email.contains("@") &&
            password.count >= 6
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.xl) {
                Text(isSignUp ? String(localized: "Create your Nuvio account") : String(localized: "Sign in to Nuvio"))
                    .font(Theme.Font.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)

                VStack(spacing: Theme.Spacing.lg) {
                    TextField("Email", text: $email)
                        .textFieldStyle(.plain)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(Theme.Spacing.lg)
                        .frame(maxWidth: 800)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

                    SecureField("Password", text: $password)
                        .textFieldStyle(.plain)
                        .textContentType(isSignUp ? .newPassword : .password)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(Theme.Spacing.lg)
                        .frame(maxWidth: 800)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(Theme.Font.meta)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 800)
                }

                if isSignUp && password.count > 0 && password.count < 6 {
                    Text("Password must be at least 6 characters.")
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }

                HStack(spacing: Theme.Spacing.lg) {
                    Button {
                        submit()
                    } label: {
                        if model.isBusy {
                            ProgressView()
                        } else {
                            Text(isSignUp ? String(localized: "Create Account") : String(localized: "Sign In"))
                                .font(Theme.Font.meta)
                                .padding(.horizontal, Theme.Spacing.xl)
                                .padding(.vertical, Theme.Spacing.xs)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.Palette.accent)
                    .disabled(!canSubmit)

                    Button {
                        model.clearError()
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .font(Theme.Font.meta)
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.vertical, Theme.Spacing.xs)
                    }
                    .buttonStyle(.glass)
                    .disabled(model.isBusy)
                }
            }
            .padding(Theme.Spacing.screen)
        }
    }

    private func submit() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        if isSignUp {
            model.signUp(email: trimmedEmail, password: password)
        } else {
            model.signIn(email: trimmedEmail, password: password)
        }
    }
}
