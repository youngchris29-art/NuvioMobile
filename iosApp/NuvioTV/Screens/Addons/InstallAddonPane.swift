import SwiftUI

/// Add-ons hub v2: the inline Install section (replaces the install sheet). The URL field and
/// Install button stay; progress and the result show in `InstallStatusModal`, overlaid on the pane.
///
/// Phase rules are `InstallFlow`'s (busy wins, then the typed outcome). A pane rebuilt mid-install
/// seeds `.checking`; an outcome shows only when newer than the hub-owned `handledSerial`.
///
/// Menu: a handler is attached ONLY while the modal is up (Checking swallows it, Installed acts as
/// Done, Failed returns to the field). At idle there is none, so the hub's own Menu handler (back
/// to the sidebar) keeps working.
/// DEBUG knob `-debug.installPrefillUrl <url>`: prefills the URL field on appear (typing into the
/// tvOS field from XCUITest is unreliable).
struct InstallAddonPane: View {
    @ObservedObject var model: AddonsViewModel
    /// The hub's shared content focus; the field's key is `fieldKey`.
    let focus: FocusState<String?>.Binding
    /// The newest install outcome serial already handled (owned by the hub, so a stale outcome
    /// never shows when the pane is rebuilt).
    @Binding var handledSerial: Int?
    /// Installed -> Done: the hub switches to Installed and focuses the new row.
    let onInstalled: () -> Void

    nonisolated static let fieldKey = "install:field"
    nonisolated static let buttonKey = "install:button"

    @State private var newUrl = ""
    @State private var phase: InstallPhase = .idle

    var body: some View {
        form
            .disabled(phase != .idle)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay {
                if phase != .idle {
                    InstallStatusModal(
                        phase: phase,
                        onDone: finishInstalled,
                        onRetry: returnToField,
                        onCancel: returnToField
                    )
                }
            }
            .modifier(MenuWhileModal(phase: phase, onDone: finishInstalled, onBack: returnToField))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("addons_install_pane")
            .onAppear {
                seedPhase()
                #if DEBUG
                // `-debug.installPrefillUrl <url>` prefills the field (never persisted, never
                // written back); the UI tests use it.
                if newUrl.isEmpty, let prefill = UserDefaults.standard.string(forKey: "debug.installPrefillUrl"), !prefill.isEmpty {
                    newUrl = prefill
                }
                #endif
            }
            .onChange(of: model.isInstalling) { _, installing in
                if installing { phase = InstallFlow.installPhase(isInstalling: true, outcome: model.installOutcome) }
            }
            .onChange(of: model.installOutcome) { _, outcome in
                if let outcome { handledSerial = InstallFlow.serial(of: outcome) }
                phase = InstallFlow.installPhase(isInstalling: model.isInstalling, outcome: outcome)
                // The typed URL survives a failure; it clears only once the add-on is in.
                if case .installed? = outcome { newUrl = "" }
            }
    }

    /// A pane built (or rebuilt) mid-install shows Checking; an outcome shows only when it is
    /// newer than the last one handled.
    private func seedPhase() {
        if model.isInstalling {
            phase = .checking
        } else if let outcome = model.installOutcome, InstallFlow.serial(of: outcome) > (handledSerial ?? Int.min) {
            handledSerial = InstallFlow.serial(of: outcome)
            phase = InstallFlow.installPhase(isInstalling: false, outcome: outcome)
        }
    }

    private func finishInstalled() {
        phase = .idle
        onInstalled()
    }

    private func returnToField() {
        phase = .idle
        DispatchQueue.main.async { focus.wrappedValue = Self.fieldKey }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Install add-on").font(Theme.Font.sectionTitle)
            Text("Paste the manifest URL from your streaming addon's config page (e.g. your TorBox or Torrentio URL with your API key). It ends in /manifest.json.")
                .font(Theme.Font.body).foregroundStyle(.secondary)
                .frame(maxWidth: 1000, alignment: .leading)

            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("https://\u{2026}/manifest.json", text: $newUrl)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.screenTitle.weight(.regular))
                    .focused(focus, equals: Self.fieldKey)
                    .accessibilityIdentifier("addons_hub_install_field")
            }
            .padding(Theme.Spacing.lg)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card))

            HStack(spacing: Theme.Spacing.lg) {
                // Not `.disabled` while installing: that disabled the button the user had just
                // pressed and focus jumped away. Guarded in the action instead.
                Button {
                    guard !model.isInstalling else { return }
                    model.install(newUrl)
                } label: {
                    Label("Install", systemImage: "plus.circle.fill")
                        .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.xxs)
                }
                .buttonStyle(.borderedProminent)
                .focused(focus, equals: Self.buttonKey)
                .accessibilityIdentifier("addons_hub_install_button")

                #if DEBUG
                if DebugConfig.hasManifestURL {
                    Button {
                        guard !model.isInstalling else { return }
                        model.install(DebugConfig.manifestURL)
                    } label: {
                        Label("Quick install (from DebugConfig)", systemImage: "wrench.and.screwdriver")
                            .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.xxs)
                    }
                    .buttonStyle(.chip)
                }
                #endif
            }
        }
        .padding(.vertical, Theme.Spacing.lg)
    }
}

/// Attaches `.onExitCommand` only while the status modal is showing.
private struct MenuWhileModal: ViewModifier {
    let phase: InstallPhase
    let onDone: () -> Void
    let onBack: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if phase == .idle {
            content
        } else {
            content.onExitCommand {
                switch phase {
                case .idle, .checking: break
                case .installed: onDone()
                case .failed: onBack()
                }
            }
        }
    }
}
