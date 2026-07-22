import SwiftUI

/// First-run / signed-out gate. QR sign-in (scan with the phone, approve, done) is the primary,
/// default-focused path — typing an email/password with the Siri Remote is painful, so we lead
/// with the option that needs no on-screen keyboard. Email sign-in, account creation, and guest
/// mode remain one Select-press away as clearly secondary options. Shown whenever
/// `AuthRepository` reports `Unauthenticated` — existing guest installs never see this (their
/// stored anonymous id authenticates immediately).
struct WelcomeView: View {
    @ObservedObject var model: AuthViewModel

    private enum AuthSheet: String, Identifiable {
        case signIn, signUp, qr
        var id: String { rawValue }
    }

    @State private var sheet: AuthSheet?
    /// Anchors `.prefersDefaultFocus` so initial D-pad focus lands on the QR action below,
    /// regardless of layout order.
    @Namespace private var focusNamespace

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.sectionGap) {
                VStack(spacing: Theme.Spacing.md) {
                    Text("Nuvio")
                        .font(Theme.Font.hero)
                        .foregroundStyle(Theme.Palette.accent)
                    Text("Sign in with your phone — scan a QR code, no typing on the remote.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                }

                VStack(spacing: Theme.Spacing.xl) {
                    Button {
                        model.clearError()
                        sheet = .qr
                    } label: {
                        VStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "qrcode")
                                .font(.system(size: 64, weight: .semibold))
                            Text("Sign In with Your Phone")
                                .font(Theme.Font.sectionTitle)
                            Text("Scan a QR code to sign in — no typing required")
                                .font(Theme.Font.caption)
                                .opacity(0.85)
                        }
                        .prominentAccentLabel()
                        .frame(maxWidth: 640)
                        .padding(.vertical, Theme.Spacing.xl)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.accent)
                    .prefersDefaultFocus(true, in: focusNamespace)

                    VStack(spacing: Theme.Spacing.sm) {
                        Text("Or continue another way")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)

                        HStack(spacing: Theme.Spacing.md) {
                            Button {
                                model.clearError()
                                sheet = .signIn
                            } label: {
                                Text("Sign In with Email")
                            }
                            .buttonStyle(.chip)

                            Button {
                                model.clearError()
                                sheet = .signUp
                            } label: {
                                Text("Create Account")
                            }
                            .buttonStyle(.chip)

                            Button {
                                model.continueAsGuest()
                            } label: {
                                Text("Continue as Guest")
                            }
                            .buttonStyle(.chip)
                        }
                    }
                }
                .focusScope(focusNamespace)
            }
            .padding(Theme.Spacing.screen)
        }
        .fullScreenCover(item: $sheet) { mode in
            if mode == .qr {
                QrSignInView()
            } else {
                AuthView(model: model, isSignUp: mode == .signUp)
            }
        }
    }
}
