import SwiftUI

/// Add-ons hub v2, Stage C (C3): the confirm dialog for a change sent from the phone page. One
/// line per change (`RemoteSetupChangeList`), then Reject and Confirm. Focus starts on Confirm, and
/// Menu rejects. At most `visibleLines` lines show; the rest are counted, so the dialog never
/// needs to scroll (tvOS scrolls only through focusable content).
struct ConfirmPhoneChangesDialog: View {
    let lines: [RemoteSetupChangeList.Line]
    let onConfirm: () -> Void
    let onReject: () -> Void

    nonisolated static let visibleLines = 8

    private enum Control: Hashable { case confirm, reject }
    @FocusState private var focus: Control?

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("Apply changes from your phone?")
                    .font(Theme.Font.screenTitle.weight(.bold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                if lines.isEmpty {
                    Text("Nothing would change.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        ForEach(Array(lines.prefix(Self.visibleLines))) { line in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                                Image(systemName: Self.symbol(for: line.kind))
                                    .foregroundStyle(line.kind == .rejected ? Color.orange : Theme.Palette.textSecondary)
                                    .accessibilityHidden(true)
                                Text(line.text)
                                    .font(Theme.Font.body)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        let hidden = lines.count - Self.visibleLines
                        if hidden > 0 {
                            Text(hidden == 1
                                 ? String(localized: "and 1 more change")
                                 : String(localized: "and \(hidden) more changes"))
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    .accessibilityIdentifier("phone_confirm_lines")
                }
                HStack(spacing: Theme.Spacing.lg) {
                    Button(role: .cancel, action: onReject) {
                        Text("Reject").padding(.horizontal, Theme.Spacing.lg)
                    }
                    .focused($focus, equals: .reject)
                    .accessibilityIdentifier("phone_confirm_reject")
                    Button(action: onConfirm) {
                        Text("Confirm").padding(.horizontal, Theme.Spacing.lg)
                    }
                    .buttonStyle(.borderedProminent)
                    .focused($focus, equals: .confirm)
                    .accessibilityIdentifier("phone_confirm_confirm")
                }
                .padding(.top, Theme.Spacing.sm)
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color(white: 0.12)))
            .focusSection()
        }
        .defaultFocus($focus, .confirm)
        .onAppear { focus = .confirm }
        .onExitCommand(perform: onReject)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("phone_confirm_dialog")
    }

    nonisolated static func symbol(for kind: RemoteSetupChangeList.Line.Kind) -> String {
        switch kind {
        case .install: return "plus.circle"
        case .remove: return "minus.circle"
        case .move: return "arrow.up.arrow.down"
        case .turnOn: return "checkmark.circle"
        case .turnOff: return "circle.slash"
        case .key: return "key"
        case .pattern: return "photo"
        case .badges: return "seal"
        case .rejected: return "exclamationmark.triangle"
        }
    }
}
