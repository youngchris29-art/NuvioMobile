import SwiftUI

/// Add-ons hub v2, Stage C (C2): the "Manage from phone" section. It hosts Remote Setup: the local
/// config page starts shortly after the section opens and stops when it closes (the pane is
/// rebuilt per section, so leaving the section or the hub tears it down). It shows the QR, the URL
/// and a status line, and a proposal from the phone surfaces as a confirm alert here (C3 replaces
/// the alert with the per-change dialog).
///
/// The start waits `startDelay` so focus passing over the sidebar row (the hub selects a section
/// after a short dwell) does not open a server for a fraction of a second.
struct ManageFromPhonePane: View {
    /// The hub's shared content focus; the pane's one control is `primaryKey`.
    let focus: FocusState<String?>.Binding

    @StateObject private var remote = RemoteSetupViewModel()
    /// Review r1: the server runs only while the Add-ons tab is selected (a mounted tab subtree
    /// survives a tab switch, so `onDisappear` alone is not enough).
    @ObservedObject private var tab = AddonsTabActivity.shared

    nonisolated static let primaryKey = "phone:primary"
    static let startDelay: Duration = .milliseconds(600)
    static let qrSize: CGFloat = 300

    var body: some View {
        let status = ManageFromPhoneStatus(
            isRunning: remote.isRunning,
            isStarting: remote.isStarting,
            startFailed: remote.startFailed,
            phoneConnected: remote.phoneConnected
        )
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Manage add-ons, catalogs and Home rows from a phone or laptop browser on the same network. Nothing changes until you confirm it here.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1000, alignment: .leading)

            HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                qrBlock
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: status.systemImage).accessibilityHidden(true)
                        Text(status.title).accessibilityIdentifier("addons_phone_status")
                    }
                    .font(Theme.Font.screenTitle.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    if let detail = status.detail {
                        Text(detail)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .frame(maxWidth: 700, alignment: .leading)
                    }
                    if let url = remote.serverURL {
                        Text(url)
                            .font(Theme.Font.body.monospaced())
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .accessibilityIdentifier("addons_phone_url")
                    }
                    primaryButton(status)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("addons_phone_pane")
        .task(id: tab.isActive) {
            // Leaving the tab stops the server at once; coming back (or opening the section)
            // starts it after the delay, unless the tab or the section is left meanwhile.
            guard tab.isActive else {
                remote.stop()
                return
            }
            try? await Task.sleep(for: Self.startDelay)
            guard !Task.isCancelled, tab.isActive else { return }
            remote.start()
        }
        .onDisappear { remote.stop() }
        .alert(
            "Apply changes from your phone?",
            isPresented: Binding(
                get: { remote.pendingChange != nil },
                set: { if !$0 { remote.rejectPending() } }
            )
        ) {
            Button("Apply") { remote.confirmPending() }
            Button("Decline", role: .cancel) { remote.rejectPending() }
        } message: {
            Text(remote.pendingSummary)
        }
    }

    @ViewBuilder
    private var qrBlock: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Color.white.opacity(0.06))
            if let qr = remote.qrImage {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(Theme.Spacing.sm)
                    .accessibilityLabel(Text("QR code for the setup page"))
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 96))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: Self.qrSize, height: Self.qrSize)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    /// The pane's one focusable control, present in every state so focus can always enter the
    /// pane: Try again after a failed start, New code while running (a fresh token unpairs any
    /// phone holding the old one), and an inert Starting… while the server comes up.
    private func primaryButton(_ status: ManageFromPhoneStatus) -> some View {
        Button {
            switch status {
            case .failed:
                remote.start()
            case .ready, .connected:
                remote.stop()
                remote.start()
            case .starting:
                break
            }
        } label: {
            Label(status.buttonTitle, systemImage: status.buttonImage)
                .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.xxs)
        }
        .buttonStyle(.chip)
        .focused(focus, equals: Self.primaryKey)
        .accessibilityIdentifier("addons_phone_primary")
    }
}

/// C2: the pane's state, from the Remote Setup model's flags (pure, tested).
enum ManageFromPhoneStatus: Equatable {
    case starting, ready, connected, failed

    init(isRunning: Bool, isStarting: Bool, startFailed: Bool, phoneConnected: Bool) {
        if isRunning {
            self = phoneConnected ? .connected : .ready
        } else if startFailed {
            self = .failed
        } else {
            // Not running, not failed: about to start or starting.
            self = .starting
        }
    }

    var title: String {
        switch self {
        case .starting: return String(localized: "Starting…")
        case .ready: return String(localized: "Ready")
        // Review r5: past tense. The page sends nothing while the user edits, so the TV cannot
        // tell a phone that is still there from one that closed the page.
        case .connected: return String(localized: "Page opened")
        case .failed: return String(localized: "Couldn't start")
        }
    }

    var detail: String? {
        switch self {
        case .starting: return nil
        case .ready: return String(localized: "Scan the code with your phone's camera, or open the address in any browser on this network.")
        case .connected: return String(localized: "The setup page was opened on a phone or laptop. Make your changes there, then confirm them here. Leaving this section closes the page.")
        case .failed: return String(localized: "Couldn't start the local server. Check the network connection and try again.")
        }
    }

    var systemImage: String {
        switch self {
        case .starting: return "hourglass"
        case .ready: return "qrcode.viewfinder"
        case .connected: return "iphone.radiowaves.left.and.right"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var buttonTitle: String {
        switch self {
        case .starting: return String(localized: "Starting…")
        case .ready, .connected: return String(localized: "New code")
        case .failed: return String(localized: "Try again")
        }
    }

    var buttonImage: String {
        switch self {
        case .starting: return "hourglass"
        case .ready, .connected: return "arrow.triangle.2.circlepath"
        case .failed: return "arrow.clockwise"
        }
    }
}
