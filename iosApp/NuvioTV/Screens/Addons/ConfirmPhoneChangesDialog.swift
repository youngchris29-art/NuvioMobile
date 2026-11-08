import SwiftUI

/// Add-ons hub v2, Stage C (C3): the confirm dialog for a change sent from the phone page. One
/// line per change (`RemoteSetupChangeList`), then Reject and Confirm. Focus starts on Confirm, and
/// Menu rejects. Lines take focus so a long list scrolls (review r1: every change can be read
/// before confirming).
struct ConfirmPhoneChangesDialog: View {
    let lines: [RemoteSetupChangeList.Line]
    /// The lines were recomputed at Confirm (the TV's lists changed); the dialog asks again.
    var refreshed = false
    let onConfirm: () -> Void
    let onReject: () -> Void

    /// The list's height; longer lists scroll as focus moves through them.
    static let listHeight: CGFloat = 520

    private enum Control: Hashable { case confirm, reject }
    @FocusState private var focus: Control?

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("Apply changes from your phone?")
                    .font(Theme.Font.screenTitle.weight(.bold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                if refreshed {
                    Label("The TV's lists changed while this was open. Check the changes again.", systemImage: "arrow.triangle.2.circlepath")
                        .font(Theme.Font.body)
                        .foregroundStyle(Color.orange)
                        .accessibilityIdentifier("phone_confirm_refreshed")
                }
                if lines.isEmpty {
                    Text("Nothing would change.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    // Review r1: every line can be reached. Lines take focus (tvOS scrolls only
                    // through focusable content), so Up from the buttons walks the whole list.
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            ForEach(lines) { line in
                                Button(action: {}) {
                                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                                        Image(systemName: Self.symbol(for: line.kind))
                                            .foregroundStyle(line.kind == .rejected ? Color.orange : Theme.Palette.textSecondary)
                                            .accessibilityHidden(true)
                                        Text(line.text)
                                            .font(Theme.Font.body)
                                            .foregroundStyle(Theme.Palette.textPrimary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, Theme.Spacing.md)
                                    .padding(.vertical, Theme.Spacing.xs)
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                    .scrollClipDisabled()
                    .frame(maxHeight: Self.listHeight)
                    .accessibilityIdentifier("phone_confirm_lines")
                    Text(lines.count == 1 ? String(localized: "1 change") : String(localized: "\(lines.count) changes"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
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
        .onChange(of: lines) { _, _ in focus = .confirm }
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
