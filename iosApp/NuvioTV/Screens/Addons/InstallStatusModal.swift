import SwiftUI

/// What the install sheet's status modal shows. Derived from the hub's typed outcome, never from
/// the localized `statusMessage`.
nonisolated enum InstallPhase: Equatable {
    case idle
    case checking
    case installed(name: String)
    case failed(message: String)
}

/// The pure install rules shared by the sheet and the hub's inline Install pane.
enum InstallFlow {
    nonisolated static func serial(of outcome: AddonsViewModel.InstallOutcome) -> Int {
        switch outcome {
        case .installed(_, let serial), .failed(_, let serial): return serial
        }
    }

    /// The pure phase rule behind `.onChange`: busy wins, then the typed outcome, else idle.
    nonisolated static func installPhase(isInstalling: Bool, outcome: AddonsViewModel.InstallOutcome?) -> InstallPhase {
        if isInstalling { return .checking }
        switch outcome {
        case .installed(let name, _)?: return .installed(name: name)
        case .failed(let message, _)?: return .failed(message: message)
        case nil: return .idle
        }
    }
}

/// Dimmed scrim plus a card: a busy indicator while checking, then a glyph, title, message and
/// the confirm (and, on failure, dismiss) buttons.
struct InstallStatusModal: View {
    let phase: InstallPhase
    /// The modal's own scope, apart from the form's, for Done / Try again's default focus.
    @Namespace private var focusNamespace
    /// Where focus sits inside the modal. The form keeps the engine's focus when it is disabled
    /// underneath an overlay (observed on the FA87 sim: Install stayed focused after Installed),
    /// so the modal moves focus itself on appear and on every phase change.
    private enum Target: Hashable { case card, done, retry, cancel }
    @FocusState private var focus: Target?
    let onDone: () -> Void
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            card
        }
        // Default focus for the engine's own update (the card stops being focusable when
        // Checking ends, which empties focus on the FA87 sim), plus explicit requests at 50 ms,
        // 350 ms and 1.25 s after the phase change: a request made in the same pass as the
        // button's insertion is dropped. The requests stop as soon as anything in the modal holds
        // focus, so a user who has already moved to Cancel is not pulled back.
        .defaultFocus($focus, Self.target(for: phase))
        .task(id: phase) {
            let target = Self.target(for: phase)
            for delay in [0.05, 0.3, 0.9] {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled || focus != nil { return }
                focus = target
            }
        }
    }

    private nonisolated static func target(for phase: InstallPhase) -> Target? {
        switch phase {
        case .idle: return nil
        case .checking: return .card
        case .installed: return .done
        case .failed: return .retry
        }
    }

    private var title: String {
        switch phase {
        case .idle: return ""
        case .checking: return String(localized: "Checking the add-on\u{2026}")
        case .installed(let name): return String(localized: "Installed \(name).")
        case .failed: return String(localized: "Couldn't install that add-on.")
        }
    }

    /// `.focusable(false)` on the card would make its buttons unreachable too (the FA87 sim kept
    /// focus on the disabled Install button, then on nothing), so the modifier is only applied
    /// while Checking, when the card itself must hold focus.
    @ViewBuilder private var card: some View {
        if phase == .checking {
            cardBody.focusable().focused($focus, equals: .card)
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            switch phase {
            case .idle:
                EmptyView()
            case .checking:
                ProgressView()
                Text(title).font(Theme.Font.sectionTitle)
                Text("Fetching its manifest.").font(Theme.Font.body).foregroundStyle(.secondary)
            case .installed:
                Image(systemName: "checkmark.circle.fill")
                    .font(Theme.Font.screenTitle).foregroundStyle(Theme.Palette.accent)
                Text(title).font(Theme.Font.sectionTitle)
                Text("It is on and will answer the next search for streams.")
                    .font(Theme.Font.body).foregroundStyle(.secondary)
                HStack(spacing: Theme.Spacing.lg) {
                    Button(action: onDone) {
                        Text("Done").padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.xxs)
                    }
                    .buttonStyle(.borderedProminent)
                    .focused($focus, equals: .done)
                    .prefersDefaultFocus(true, in: focusNamespace)
                    .accessibilityIdentifier("addons_hub_install_done")
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Theme.Font.screenTitle).foregroundStyle(Theme.Palette.error)
                Text(title).font(Theme.Font.sectionTitle)
                Text(message).font(Theme.Font.body).foregroundStyle(.secondary).lineLimit(4)
                HStack(spacing: Theme.Spacing.lg) {
                    Button(action: onRetry) {
                        Text("Try again").padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.xxs)
                    }
                    .buttonStyle(.borderedProminent)
                    .focused($focus, equals: .retry)
                    .prefersDefaultFocus(true, in: focusNamespace)
                    .accessibilityIdentifier("addons_hub_install_retry")
                    Button(action: onCancel) {
                        Text("Cancel").padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.xxs)
                    }
                    .buttonStyle(.bordered)
                    .focused($focus, equals: .cancel)
                    .accessibilityIdentifier("addons_hub_install_cancel")
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 720, alignment: .leading)
        .background(Theme.Palette.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.hero))
        // While checking there is no button: the card itself holds focus (see `card`) so Menu
        // reaches the sheet's `.onExitCommand` (which swallows it) instead of closing the sheet.
        .focusScope(focusNamespace)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("addons_hub_install_modal")
    }
}
