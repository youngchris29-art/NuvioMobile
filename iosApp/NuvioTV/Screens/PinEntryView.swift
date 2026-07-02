import SwiftUI

/// Full-screen 4-digit PIN entry with a focus-friendly digit pad (mirrors mobile's dots + pad).
///
/// The parent owns what "submit" means: `onSubmit` receives the 4-digit PIN and a completion
/// callback — pass an error message to show it (and reset the pad), or `nil` on success (the
/// parent is expected to dismiss this view).
struct PinEntryView: View {
    let title: String
    var subtitle: String? = nil
    let onCancel: () -> Void
    let onSubmit: (String, @escaping (String?) -> Void) -> Void

    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var isBusy = false

    private let padRows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["delete", "0", "cancel"],
    ]

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.xl) {
                Text(title)
                    .font(Theme.Font.screenTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 800)
                }

                // PIN dots
                HStack(spacing: Theme.Spacing.lg) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(index < pin.count ? Theme.Palette.accent : Color.clear)
                            .overlay(
                                Circle().strokeBorder(
                                    errorMessage != nil ? Color.red : Theme.Palette.textSecondary,
                                    lineWidth: 3
                                )
                            )
                            .frame(width: 28, height: 28)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Font.meta)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 800)
                } else if isBusy {
                    ProgressView()
                        .tint(Theme.Palette.accent)
                }

                // Digit pad
                VStack(spacing: Theme.Spacing.md) {
                    ForEach(padRows, id: \.self) { row in
                        HStack(spacing: Theme.Spacing.md) {
                            ForEach(row, id: \.self) { key in
                                padButton(key)
                            }
                        }
                    }
                }
            }
            .padding(Theme.Spacing.screen)
        }
    }

    @ViewBuilder
    private func padButton(_ key: String) -> some View {
        switch key {
        case "delete":
            Button {
                errorMessage = nil
                if !pin.isEmpty { pin.removeLast() }
            } label: {
                Image(systemName: "delete.left")
                    .frame(width: 90, height: 60)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        case "cancel":
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 90, height: 60)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        default:
            Button {
                appendDigit(key)
            } label: {
                Text(key)
                    .font(Theme.Font.sectionTitle)
                    .frame(width: 90, height: 60)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        }
    }

    private func appendDigit(_ digit: String) {
        guard !isBusy, pin.count < 4 else { return }
        errorMessage = nil
        pin += digit
        guard pin.count == 4 else { return }

        // Auto-submit at 4 digits (mirrors mobile).
        isBusy = true
        let entered = pin
        onSubmit(entered) { error in
            isBusy = false
            if let error {
                errorMessage = error
                pin = ""
            }
            // nil = success; the parent dismisses this view.
        }
    }
}
