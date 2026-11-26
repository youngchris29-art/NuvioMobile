import SwiftUI
import UIKit

/// Scope identity W2 (spec 8.2, revision 2): the identity cover is its own `UIWindow` above the main
/// window, so it covers every SwiftUI `fullScreenCover` (they present inside the main window) and
/// nested player, detail and deep-link covers can dismiss underneath it unseen. Only
/// `IdentityModel` shows or hides it.
@MainActor
final class IdentityCoverWindow: IdentityCoverPresenting {
    static let shared = IdentityCoverWindow()

    private var window: UIWindow?
    private var host: UIHostingController<IdentityCoverView>?

    var isVisible: Bool { window?.isHidden == false }

    func show(_ kind: IdentityCoverKind) -> Bool {
        if window == nil {
            guard let scene = Self.activeScene() else {
                print("[Identity] cover: no window scene")
                return false
            }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            let host = UIHostingController(rootView: IdentityCoverView(kind: kind))
            host.view.backgroundColor = .clear
            window.rootViewController = host
            self.window = window
            self.host = host
        }
        host?.rootView = IdentityCoverView(kind: kind)
        window?.isHidden = false
        // Key, so remote presses go to the cover (Menu and Select do nothing there).
        window?.makeKeyAndVisible()
        return isVisible
    }

    func hide() {
        guard let window, !window.isHidden else { return }
        window.isHidden = true
        Self.mainWindow(excluding: window)?.makeKey()
    }

    /// The app's own window (never the cover).
    static func mainWindow(excluding cover: UIWindow? = nil) -> UIWindow? {
        let cover = cover ?? shared.window
        let windows = activeScene()?.windows.filter { $0 !== cover } ?? []
        return windows.first { $0.windowLevel == .normal } ?? windows.first
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}
