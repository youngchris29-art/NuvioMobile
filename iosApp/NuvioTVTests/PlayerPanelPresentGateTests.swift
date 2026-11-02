import SwiftUI
import UIKit
import XCTest
@testable import NuvioTV

/// Review r10: the Sync Line panel is presented only once nothing is presented over the player,
/// and `panelHost` is latched only for a presentation UIKit accepted.
@MainActor
final class PlayerPanelPresentGateTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    func testGateDecisions() {
        XCTAssertEqual(PlayerPanelPresentGate.decide(blocked: false, elapsedMs: 0, capMs: 2000), .present)
        XCTAssertEqual(PlayerPanelPresentGate.decide(blocked: false, elapsedMs: 5000, capMs: 2000), .present)
        XCTAssertEqual(PlayerPanelPresentGate.decide(blocked: true, elapsedMs: 100, capMs: 2000), .wait)
        XCTAssertEqual(PlayerPanelPresentGate.decide(blocked: true, elapsedMs: 2000, capMs: 2000), .giveUp)
    }

    private func makeHost() -> NativePlayerHostController {
        let host = NativePlayerHostController()
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        _ = host.view
        return host
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// Stands in for AVKit's transport-bar popover, presented from the player VC.
    private func presentBlocker(on host: NativePlayerHostController) -> UIViewController {
        let blocker = UIViewController()
        blocker.modalPresentationStyle = .overFullScreen
        host.playerVC.present(blocker, animated: false)
        XCTAssertTrue(waitUntil(2) { host.playerVC.presentedViewController === blocker })
        return blocker
    }

    func testPresentsOnceTheBlockerIsGone() {
        let host = makeHost()
        let blocker = presentBlocker(on: host)
        XCTAssertTrue(host.isPresentationBlocked)

        let panel = PlayerPanelHostController(rootView: Color.clear)
        var result: Bool?
        host.presentWhenClear(panel: panel, capMs: 3000, pollMs: 20) { result = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(result, "no presentation while the popover is up")
        XCTAssertNil(host.panelHost, "nothing latched while waiting")

        blocker.dismiss(animated: false)
        XCTAssertTrue(waitUntil(3) { result != nil })
        XCTAssertEqual(result, true)
        XCTAssertTrue(host.panelHost === panel)
        XCTAssertNotNil(panel.presentingViewController)

        // The latch clears on close, so the next Sync Line press can present again.
        panel.close(animated: false)
        XCTAssertTrue(waitUntil(3) { host.panelHost == nil && host.presentedViewController == nil })
        let second = PlayerPanelHostController(rootView: Color.clear)
        var secondResult: Bool?
        host.presentWhenClear(panel: second, pollMs: 20) { secondResult = $0 }
        XCTAssertTrue(waitUntil(3) { secondResult != nil })
        XCTAssertEqual(secondResult, true)
        second.close(animated: false)
        XCTAssertTrue(waitUntil(3) { host.panelHost == nil })
    }

    func testGivesUpAndUnlatchesWhenTheBlockerStays() {
        let host = makeHost()
        let blocker = presentBlocker(on: host)
        let panel = PlayerPanelHostController(rootView: Color.clear)
        var result: Bool?
        host.presentWhenClear(panel: panel, capMs: 200, pollMs: 20) { result = $0 }
        XCTAssertTrue(waitUntil(3) { result != nil })
        XCTAssertEqual(result, false)
        XCTAssertNil(host.panelHost, "a panel that was never shown is not latched")
        XCTAssertNil(panel.presentingViewController)

        // Not stuck: once the popover goes, the next attempt presents.
        blocker.dismiss(animated: false)
        XCTAssertTrue(waitUntil(2) { !host.isPresentationBlocked })
        let next = PlayerPanelHostController(rootView: Color.clear)
        var nextResult: Bool?
        host.presentWhenClear(panel: next, pollMs: 20) { nextResult = $0 }
        XCTAssertTrue(waitUntil(3) { nextResult != nil })
        XCTAssertEqual(nextResult, true)
        XCTAssertTrue(host.panelHost === next)
        next.close(animated: false)
        XCTAssertTrue(waitUntil(3) { host.panelHost == nil })
    }

    func testClosePanelCancelsAWait() {
        let host = makeHost()
        let blocker = presentBlocker(on: host)
        let panel = PlayerPanelHostController(rootView: Color.clear)
        var result: Bool?
        host.presentWhenClear(panel: panel, capMs: 3000, pollMs: 20) { result = $0 }
        host.closePanel(animated: false)
        blocker.dismiss(animated: false)
        XCTAssertTrue(waitUntil(3) { result != nil })
        XCTAssertEqual(result, false, "a player going away never presents a late panel")
        XCTAssertNil(host.panelHost)
    }
}
