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
                VStack(spacing: Theme.Spacing.lg) {
                    // Brand mark (the app icon's gradient triangle) instead of a text wordmark —
                    // same asset family as the icon/top-shelf art, so Welcome reads as the brand
                    // regardless of which accent theme the user later picks.
                    Image("LogoMark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 130)
                        .accessibilityLabel("Nuvio")
                    Text("Sign in with your phone — scan a QR code, no typing on the remote.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                }

                VStack(spacing: Theme.Spacing.xl) {
                    // Liquid Glass, same as the Detail action row: prominent accent glass for the
                    // primary action, plain glass for the secondary ones. Plain `.glass` pills
                    // below are left to the system (see StreamPicker's `.glass` note) — but this
                    // one is `.glassProminent` + an accent tint, and the "verified on a sim" claim
                    // this comment used to make only held for the *focused* state (glass's focus
                    // lift auto-picks dark text regardless of tint). Unfocused, the fill is the
                    // raw accent tint with no auto contrast, so on the White theme — reachable by
                    // arrowing down to "Sign In with Email" and back — this label went invisible
                    // white-on-near-white, same failure as BUG-14's Detail Play button.
                    // `prominentAccentLabel()` handles both states.
                    Button {
                        model.clearError()
                        sheet = .qr
                    } label: {
                        VStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "qrcode")
                                .font(Theme.Font.hero)
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
                    .buttonStyle(.glassProminent)
                    .tint(Theme.Palette.accent)
                    .prefersDefaultFocus(true, in: focusNamespace)

                    VStack(spacing: Theme.Spacing.md) {
                        Text("Or continue another way")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)

                        GlassEffectContainer(spacing: Theme.Spacing.md) {
                            HStack(spacing: Theme.Spacing.md) {
                                Button {
                                    model.clearError()
                                    sheet = .signIn
                                } label: {
                                    Text("Sign In with Email")
                                        .font(Theme.Font.meta)
                                        .padding(.horizontal, Theme.Spacing.lg)
                                        .padding(.vertical, Theme.Spacing.xs)
                                }
                                .buttonStyle(.glass)

                                Button {
                                    model.clearError()
                                    sheet = .signUp
                                } label: {
                                    Text("Create Account")
                                        .font(Theme.Font.meta)
                                        .padding(.horizontal, Theme.Spacing.lg)
                                        .padding(.vertical, Theme.Spacing.xs)
                                }
                                .buttonStyle(.glass)

                                Button {
                                    model.continueAsGuest()
                                } label: {
                                    Text("Continue as Guest")
                                        .font(Theme.Font.meta)
                                        .padding(.horizontal, Theme.Spacing.lg)
                                        .padding(.vertical, Theme.Spacing.xs)
                                }
                                .buttonStyle(.glass)
                            }
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
