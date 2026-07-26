import Combine
import CoreImage
import SwiftUI
import UIKit
import SharedCore

/// QR sign-in: the shared `TvLoginRepository` runs the whole flow (anonymous scaffolding session →
/// `start_tv_login_session` → poll → `tv-logins-exchange` token import); this screen just renders
/// its `uiState` — a QR of the approval URL plus the short code as a manual fallback. When the
/// exchange completes, `AuthRepository`'s session collector publishes the real account and the
/// observing `AuthViewModel` swaps the app past the Welcome gate; we also dismiss on `completed`.
@MainActor
final class QrSignInViewModel: ObservableObject {
    @Published private(set) var state: TvLoginUiState?
    /// Rendered QR for the current webUrl (regenerated only when the URL changes).
    @Published private(set) var qrImage: UIImage?

    private var watcher: FlowWatcher?
    private var renderedUrl: String?

    func start() {
        guard watcher == nil else { return }
        watcher = FlowWatcherKt.watch(TvLoginRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? TvLoginUiState else { return }
            self.state = value
            self.renderQrIfNeeded(value)
        }
        TvLoginRepository.shared.startFlow(deviceName: "Apple TV")
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        TvLoginRepository.shared.cancel()
    }

    func retry() {
        TvLoginRepository.shared.cancel()
        TvLoginRepository.shared.startFlow(deviceName: "Apple TV")
    }

    private func renderQrIfNeeded(_ state: TvLoginUiState) {
        let url: String? = state.webUrl
        guard let url, !url.isEmpty else {
            qrImage = nil
            renderedUrl = nil
            return
        }
        guard url != renderedUrl else { return }
        renderedUrl = url
        qrImage = Self.makeQrImage(from: url)
    }

    private static func makeQrImage(from string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        // The raw QR is ~30pt; scale it up sharply (nearest-neighbor via affine transform).
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 14, y: 14))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    deinit { watcher?.cancel() }
}

struct QrSignInView: View {
    @StateObject private var model = QrSignInViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            HStack(spacing: Theme.Spacing.sectionGap) {
                qrPanel
                instructions
            }
            .padding(Theme.Spacing.screen)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.state?.completed ?? false) { _, completed in
            // Session imported — the auth collector flips the app past Welcome; close this cover.
            if completed { dismiss() }
        }
    }

    @ViewBuilder
    private var qrPanel: some View {
        VStack(spacing: Theme.Spacing.lg) {
            if let image = model.qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 420, height: 420)
                    .padding(Theme.Spacing.lg)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(Theme.Palette.surface)
                        .frame(width: 460, height: 460)
                    ProgressView()
                }
            }
        }
    }

    @ViewBuilder
    private var instructions: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Sign In with Your Phone")
                .font(Theme.Font.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)

            if let error = errorMessage {
                Text(error)
                    .font(Theme.Font.body)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 700, alignment: .leading)
                Button {
                    model.retry()
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(Theme.Font.meta)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.Palette.accent)
            } else {
                Text("Scan the QR code with your phone's camera and approve the sign-in — no typing on the TV.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 700, alignment: .leading)

                if let code = shortCode {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Or go to nuvio.tv/tv-login and enter:")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        // The backend's pairing code is a long hex string (not a short human
                        // code); chunk it into groups of 4 so it's readable/typeable on a phone
                        // instead of one unbroken 32-character run.
                        Text(Self.groupedForDisplay(code))
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .kerning(4)
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(maxWidth: 700, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text(statusLine)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }

            Button {
                dismiss()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
                    .font(Theme.Font.meta)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xs)
            }
            .buttonStyle(.glass)
        }
        .frame(maxWidth: 800, alignment: .leading)
    }

    private var errorMessage: String? {
        let message: String? = model.state?.errorMessage
        return message
    }

    private var shortCode: String? {
        let code: String? = model.state?.code
        return code
    }

    /// Groups a long pairing code into 4-character chunks (e.g. `AB12 CD34 EF56 ...`) so it's
    /// readable and easier to type on a phone. A no-op for codes already short enough to display
    /// as-is (kept simple rather than guessing at a length threshold).
    private static func groupedForDisplay(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { offset -> String in
            let start = code.index(code.startIndex, offsetBy: offset)
            let end = code.index(start, offsetBy: 4, limitedBy: code.endIndex) ?? code.endIndex
            return String(code[start..<end])
        }.joined(separator: " ")
    }

    private var statusLine: String {
        let status: String? = model.state?.status
        switch status {
        case "approved": return String(localized: "Approved \u{2014} finishing sign-in\u{2026}")
        case "pending": return String(localized: "Waiting for approval\u{2026} this screen updates automatically.")
        default: return String(localized: "Preparing sign-in\u{2026}")
        }
    }
}
