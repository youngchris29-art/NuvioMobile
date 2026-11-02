import AVKit
import Combine
import SwiftUI
import UIKit

// Insights wave 1c: the native route's text pills under the seek bar (Info · Cast · Up Next, and
// Chapters only when tvOS does not draw its own). On tvOS 26 each `customInfoViewControllers`
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
        Group {
            if visibility.isVisible {
                NativePillContent(pill: pill, model: model)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct NativePillContent: View {
    let pill: PlayerInfoPill
    @ObservedObject var model: PlayerTopPanelModel

    var body: some View {
        switch pill {
        case .info: PlayerInfoTab(info: model.info)
        case .cast: PlayerCastContent(model: model)
        case .chapters: PlayerChaptersTab(model: model)
        case .upNext: PlayerUpNextContent(model: model)
        }
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

    /// Content height per pill on the tvOS 26 info panel; the width follows the screen. Starting
    /// values for the device pass to tune (the research report's AVKit rail is 340 pt).
    static func contentHeight(_ pill: PlayerInfoPill) -> CGFloat {
        switch pill {
        case .info: return 400
        case .cast: return 400
        case .chapters: return 420
        case .upNext: return 360
        }
    }

    init(pill: PlayerInfoPill, model: PlayerTopPanelModel) {
        let visibility = NativePillVisibility()
        self.pill = pill
        self.visibility = visibility
        self.model = model
        super.init(rootView: NativePillRoot(pill: pill, model: model, visibility: visibility))
        title = pill.title
        preferredContentSize = CGSize(width: 1760, height: Self.contentHeight(pill))
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

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if pill == .cast, presses.contains(where: { $0.type == .menu }), let model,
           menuRouter.menuBegan(menuBack: { model.menuBack() }) {
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }), menuRouter.menuEnded() { return }
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
