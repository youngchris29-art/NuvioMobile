import SwiftUI

/// Add-ons hub C, H3: the install sheet. The field and Install button stay; progress and the
/// result moved into a status modal that mirrors upstream's `NuvioStatusModal` (a dialog surface
/// with an optional busy indicator, a title, a message and one or two buttons; while busy it
/// cannot be dismissed). The sheet closes on Done, so the viewer reads the confirmation first.
///
/// Menu during Checking: `.onExitCommand` swallows it as best effort, but the sheet's own Menu
/// recogniser may still close the sheet (the repo saw this on a full-screen cover,
/// `MPVPlayerView.swift:820-845`). A mid-install close is therefore made harmless: the install
/// keeps running in the view model, a reopened sheet seeds `.checking` while it is still busy,
/// and the hub toasts and focuses the new card if the add-on lands while the sheet is closed.
/// DEBUG knob `-debug.installPrefillUrl <url>`: prefills the URL field on appear (typing into the
/// tvOS field from XCUITest is unreliable); used by `AddonsHubUITests.testInstallReorderPickerAndRemove`.
/// DEVICE CHECK OWED IN H5: press Menu during Checking on the box, with a slow stub install, and
/// confirm which of the two happens (swallowed, or closed and recovered).
struct AddonInstallSheet: View {
    @ObservedObject var model: AddonsViewModel
    @State private var newUrl = ""
    @State private var phase: InstallPhase = .idle
    /// Serial of the newest install outcome this sheet has handled (or that the hub handled
    /// before the sheet opened), so a stale outcome never shows on reopen.
    @State private var handledSerial: Int?
    @FocusState private var fieldFocused: Bool
    @Namespace private var focusNamespace
    @Environment(\.dismiss) private var dismiss

    init(model: AddonsViewModel, handledSerial: Int? = nil) {
        self.model = model
        _handledSerial = State(initialValue: handledSerial)
    }

    nonisolated static func serial(of outcome: AddonsViewModel.InstallOutcome) -> Int {
        InstallFlow.serial(of: outcome)
    }

    /// The pure phase rule behind `.onChange`: forwards to `InstallFlow`.
    nonisolated static func installPhase(isInstalling: Bool, outcome: AddonsViewModel.InstallOutcome?) -> InstallPhase {
        InstallFlow.installPhase(isInstalling: isInstalling, outcome: outcome)
    }

    var body: some View {
        form
            .disabled(phase != .idle)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .focusScope(focusNamespace)
            .overlay {
                if phase != .idle {
                    InstallStatusModal(
                        phase: phase,
                        onDone: { dismiss() },
                        onRetry: returnToField,
                        onCancel: returnToField
                    )
                }
            }
            .onAppear {
                fieldFocused = true
                seedPhase()
                #if DEBUG
                // `-debug.installPrefillUrl <url>` prefills the field (never persisted, never
                // written back); used by `AddonsHubUITests.testInstallReorderPickerAndRemove`.
                if newUrl.isEmpty, let prefill = UserDefaults.standard.string(forKey: "debug.installPrefillUrl"), !prefill.isEmpty {
                    newUrl = prefill
                }
                #endif
            }
            .onChange(of: model.isInstalling) { _, installing in
                if installing { phase = Self.installPhase(isInstalling: true, outcome: model.installOutcome) }
            }
            .onChange(of: model.installOutcome) { _, outcome in
                if let outcome { handledSerial = Self.serial(of: outcome) }
                phase = Self.installPhase(isInstalling: model.isInstalling, outcome: outcome)
                // The typed URL survives a failure; it clears only once the add-on is in.
                if case .installed? = outcome { newUrl = "" }
            }
            .onExitCommand {
                switch phase {
                case .idle, .installed: dismiss()
                case .checking: break
                case .failed: returnToField()
                }
            }
    }

    /// A sheet opened (or reopened) mid-install shows Checking; an outcome shows only when it is
    /// newer than the last one handled.
    private func seedPhase() {
        if model.isInstalling {
            phase = .checking
        } else if let outcome = model.installOutcome, Self.serial(of: outcome) > (handledSerial ?? Int.min) {
            handledSerial = Self.serial(of: outcome)
            phase = Self.installPhase(isInstalling: false, outcome: outcome)
        }
    }

    private func returnToField() {
        phase = .idle
        DispatchQueue.main.async { fieldFocused = true }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Install add-on").font(Theme.Font.screenTitle)
            Text("Paste the manifest URL from your streaming addon's config page (e.g. your TorBox or Torrentio URL with your API key). It ends in /manifest.json.")
                .font(Theme.Font.body).foregroundStyle(.secondary)
                .frame(maxWidth: 1200, alignment: .leading)

            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("https://\u{2026}/manifest.json", text: $newUrl)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.screenTitle.weight(.regular))
                    .focused($fieldFocused)
                    .prefersDefaultFocus(true, in: focusNamespace)
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
        .padding(Theme.Spacing.screen)
        .focusSection()
    }
}
