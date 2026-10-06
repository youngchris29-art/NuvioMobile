import XCTest
@testable import NuvioTV

/// Search & Discover B4: the system-keyboard focus match over a focused item's view-class chain.
/// The class names are the ones the S1 spike recorded on tvOS 27.2; anything unknown fails closed.
final class SystemKeyboardFocusTests: XCTestCase {
    func testGridKeyboardChainMatches() {
        XCTAssertTrue(SystemKeyboardFocus.isKeyboard(classChain: [
            "UIKBKeyView", "UIKeyboardLayoutStar", "UIKeyboard", "UIInputSetHostView", "UIWindow",
        ]))
        XCTAssertTrue(SystemKeyboardFocus.isKeyboard(classChain: ["UIView", "UIKeyboard", "UIWindow"]))
    }

    func testSearchControllerBandChainMatches() {
        XCTAssertTrue(SystemKeyboardFocus.isKeyboard(classChain: [
            "UIView", "_UISearchControllerTVKeyboardContainerView", "UIView", "UITransitionView", "UIWindow",
        ]))
    }

    func testUIKBPrefixMatches() {
        XCTAssertTrue(SystemKeyboardFocus.isKeyboard(classChain: ["UIKBKeyView"]))
        XCTAssertTrue(SystemKeyboardFocus.isKeyboardClass("UIKBRenderingView"))
    }

    func testTabBarAndHostingChainsDoNotMatch() {
        XCTAssertFalse(SystemKeyboardFocus.isKeyboard(classChain: [
            "UITabBarButton", "UITabBar", "UILayoutContainerView", "UIWindow",
        ]))
        XCTAssertFalse(SystemKeyboardFocus.isKeyboard(classChain: [
            "SwiftUI.FocusableViewResponderItem", "_UIHostingView<ModifiedContent<AnyView, RootModifier>>",
            "UIView", "UIWindow",
        ]))
    }

    func testGenericParametersAreIgnored() {
        XCTAssertFalse(SystemKeyboardFocus.isKeyboardClass("_UIHostingView<SearchKeyboardSpacer>"))
    }

    func testEmptyChainFailsClosed() {
        XCTAssertFalse(SystemKeyboardFocus.isKeyboard(classChain: []))
        XCTAssertFalse(SystemKeyboardFocus.isKeyboardClass(""))
    }
}
