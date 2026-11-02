import AVKit
import Combine
import SwiftUI
import UIKit

// Insights wave 1c: the native route's text pills under the seek bar (Info · Cast · Up Next, and
// Chapters only when tvOS does not draw its own; the app's Info content is titled "Stream Info"
// because tvOS draws its own Info pill from `externalMetadata`). On tvOS 26 each `customInfoViewControllers`
// entry renders as a pill titled by the controller's `title`; selecting it opens the controller's
// view above the transport with system focus, and Menu closes it. The content views are the shared
// ones the mpv shelf draws too.

/// Whether a pill's content is on screen. The content observes the panel model (Info rows change
/// on every tick), so it is mounted only while the pill is open.
@MainActor
final class NativePillVisibility: ObservableObject {
    @Published var isVisible = false
}

struct NativePillRoot: View {
    let pill: PlayerInfoPill
    let model: PlayerTopPanelModel
    @ObservedObject var visibility: NativePillVisibility

    var body: some View {
        // A fixed band, content pinned to its top edge: whatever the content measures (Color.clear
        // while closed, a taller Info grid, the Cast row swapping for the actor view) the root
        // reports the same size, so AVKit never re-centres the panel while it opens and nothing
        // grows upward under the pill row. Overflow, if any, runs off the bottom.
        Group {
            if visibility.isVisible {
                NativePillContent(pill: pill, model: model)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: NativePillPlan.contentHeight, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

private struct NativePillContent: View {
    let pill: PlayerInfoPill
    @ObservedObject var model: PlayerTopPanelModel

    var body: some View {
        switch pill {
        case .info:
            if NativePillPlan.systemDrawsInfoPill {
                NativeStreamInfoContent(info: model.info)
            } else {
                PlayerInfoTab(info: model.info)
            }
        case .cast: PlayerCastContent(model: model)
        case .chapters: PlayerChaptersTab(model: model)
        case .upNext: PlayerUpNextContent(model: model)
        }
    }
}

/// The native "Stream Info" pill: what the system's own Info pill cannot show — the badge-pack
/// chips, the metadata chips and the live stream rows (codec, resolution, bitrate, HDR, routing
/// note). No what's-playing header: the system Info pill already shows title, episode line,
/// synopsis and artwork from `externalMetadata`. Read-only, nothing focusable.
struct NativeStreamInfoContent: View {
    let info: PlayerPanelInfo

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if !info.badges.isEmpty {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(Array(info.badges.enumerated()), id: \.offset) { _, badge in
                        StreamBadgeChipView(badge: badge)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(info.badges.map(\.name).joined(separator: ", "))
                .accessibilityIdentifier("player.panel.badges")
            }
            if !info.chips.isEmpty {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(info.chips) { chip in
                        HStack(spacing: Theme.Spacing.xxs) {
                            if let symbol = chip.symbol { Image(systemName: symbol) }
                            Text(chip.text)
                        }
                        .font(Theme.Font.meta)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xxs + 2)
                        .background(Theme.Palette.textPrimary.opacity(0.12), in: Capsule())
                        .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .accessibilityElement(children: .combine)
                .accessibilityLabel(info.chips.map(\.text).joined(separator: ", "))
            }
            rows
        }
        // Read-only and never focused, so clipping costs no focus halo: a long row list ends at
        // the band's bottom edge instead of running over the transport bar.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    /// Two columns of label/value pairs, the same split as the mpv Info shelf.
    private var rows: some View {
        let rows = info.rows
        let half = (rows.count + 1) / 2
        return Grid(alignment: .topLeading, horizontalSpacing: Theme.Spacing.xl, verticalSpacing: Theme.Spacing.xs) {
            if rows.isEmpty {
                GridRow {
                    Text("No stream details yet.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .gridCellColumns(2)
                }
            } else {
                ForEach(0..<half, id: \.self) { i in
                    GridRow {
                        rowView(rows[i])
                        if i + half < rows.count { rowView(rows[i + half]) } else { Color.clear.frame(height: 1) }
                    }
                }
            }
        }
    }

    private func rowView(_ row: NativeInfoRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text(row.label)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 260, alignment: .leading)
            Text(row.value)
                .font(Theme.Font.body.monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One pill. The Cast pill takes Menu while its actor view is open (`NativePillMenuRouter`).
final class NativeInfoPillController: UIHostingController<NativePillRoot> {
    let pill: PlayerInfoPill
    private let visibility: NativePillVisibility
    private weak var model: PlayerTopPanelModel?
    private var menuRouter = NativePillMenuRouter()
    /// The pill opened (`true`) or closed (`false`).
    var onVisibleChange: ((PlayerInfoPill, Bool) -> Void)?

    init(pill: PlayerInfoPill, model: PlayerTopPanelModel) {
        let visibility = NativePillVisibility()
        self.pill = pill
        self.visibility = visibility
        self.model = model
        super.init(rootView: NativePillRoot(pill: pill, model: model, visibility: visibility))
        title = NativePillPlan.title(for: pill)
        // One fixed size for every pill, never derived from the SwiftUI content (no
        // `.preferredContentSize` sizing option, no safe-area insets feeding back into layout).
        sizingOptions = []
        safeAreaRegions = []
        preferredContentSize = CGSize(width: NativePillPlan.contentWidth, height: NativePillPlan.contentHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "player.pill.\(pill.rawValue)"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        visibility.isVisible = true
        onVisibleChange?(pill, true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        visibility.isVisible = false
        // Reopening Cast starts on the card row, not on the actor view it was closed from.
        if pill == .cast { model?.menuBack() }
        menuRouter.menuCancelled()
        onVisibleChange?(pill, false)
    }

    // Menu with the actor view open: both phases are consumed here and the actor view closes on
    // the release, so the press never reaches AVKit (which would close the whole pill). Any other
    // Menu goes to `super` untouched.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            let actorOpen = model?.actorView != nil
            // Device-pass oracle: this line missing on a Cast-pill Menu means the press never
            // reached the pill's controller (an AVKit recogniser took it first).
            if pill == .cast { print("[NativePlayer] cast pill: Menu down actor=\(actorOpen ? 1 : 0)") }
            if menuRouter.menuBegan(pill: pill, actorViewOpen: actorOpen) { return }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }), menuRouter.menuEnded() == .consumeAndBack {
            print("[NativePlayer] cast pill: Menu → card row")
            // After the release has been delivered, so the focused view is not swapped mid-press.
            DispatchQueue.main.async { [weak model] in _ = model?.menuBack() }
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { menuRouter.menuCancelled() }
        super.pressesCancelled(presses, with: event)
    }
}

/// Keeps `playerVC.customInfoViewControllers` in step with the visible pill set. The array is
/// reassigned only when the set changes (people known, the Cast setting, chapters, a next
/// episode), never per SwiftUI tick; controllers are reused across reassignments.
@MainActor
final class NativeInfoPillsInstaller {
    private weak var playerVC: AVPlayerViewController?
    private let model: PlayerTopPanelModel
    private var controllers: [PlayerInfoPill: NativeInfoPillController] = [:]
    private var installed: [PlayerInfoPill]?
    private var open: Set<PlayerInfoPill> = []
    private var cancellable: AnyCancellable?
    /// Some pill opened (`true`) or the last open one closed (`false`).
    var onOpenChanged: ((Bool) -> Void)?

    init(playerVC: AVPlayerViewController, model: PlayerTopPanelModel) {
        self.playerVC = playerVC
        self.model = model
        apply()
        // `@Published` emits before the new value is stored: hop to the next main-queue turn so
        // `PlayerInfoPill.visible(for:)` reads the values that triggered the emission.
        cancellable = Publishers.MergeMany([
            model.$people.map { !$0.isEmpty }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            model.$castEnabled.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            model.$chapters.map { !$0.isEmpty }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            model.$upNext.map { $0 != nil }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.apply() }
    }

    private func apply() {
        let pills = NativePillPlan.pills(visible: PlayerInfoPill.visible(for: model))
        guard pills != installed, let playerVC else { return }
        installed = pills
        playerVC.customInfoViewControllers = pills.map(controller(for:))
        print("[NativePlayer] pills=\(pills.map(\.rawValue).joined(separator: ","))")
    }

    private func controller(for pill: PlayerInfoPill) -> NativeInfoPillController {
        if let existing = controllers[pill] { return existing }
        let made = NativeInfoPillController(pill: pill, model: model)
        made.onVisibleChange = { [weak self] pill, visible in self?.pillVisibilityChanged(pill, visible) }
        controllers[pill] = made
        return made
    }

    private func pillVisibilityChanged(_ pill: PlayerInfoPill, _ visible: Bool) {
        let wasOpen = !open.isEmpty
        if visible { open.insert(pill) } else { open.remove(pill) }
        if wasOpen != !open.isEmpty { onOpenChanged?(!open.isEmpty) }
    }
}
