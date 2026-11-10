import XCTest

/// Pure-logic coverage for BUG-49 (`CollectionsUI.swift`'s `TabChipLabel` painting near-white
/// `textPrimary` text on its own near-white focus platter when a chip was focused-but-unselected)
/// — see `TabChipLabel.body`'s `foregroundStyle` decision in
/// `NuvioTV/Screens/CollectionsUI.swift`.
///
/// A hand-copied mirror, not an import: this is a UI test bundle, which runs in its own process
/// and cannot link the app's code. (The badge colour tests that used to sit above this class moved
/// to the hosted target, `NuvioTVTests/StreamBadgeColorTests.swift`.) `TabChipLabel`'s decision is
/// a plain 3-way branch with no `Color` math involved, so it mirrors exactly.
///
/// Keep this in sync by hand with `TabChipLabel.body`'s `foregroundStyle` branch whenever that
/// logic changes.
final class TabChipContrastTests: XCTestCase {

    /// Mirror of `ChipButtonStyle.ChipBody.labelColor` — the single decision `TabChip` now
    /// delegates to via `.chip(selected:)` (BUG-49 review round 1 removed the label-owned copy,
    /// whose capsule also covered the focus platter).
    private enum ChipLabelColor: Equatable {
        /// `FocusLook.onPlatter` — always wins while focused.
        case onFocusPlatter
        /// `Theme.Palette.accentText` — selected, at rest (label on the accent fill).
        case accentText
        /// `Theme.Palette.textPrimary` — unselected, at rest.
        case textPrimary
    }

    /// Mirror of `ChipButtonStyle.ChipBody.labelColor`'s decision.
    private func chipLabelColor(isFocused: Bool, isSelected: Bool) -> ChipLabelColor {
        if isFocused { return .onFocusPlatter }
        return isSelected ? .accentText : .textPrimary
    }

    /// BUG-49 reproduction: a focused-but-unselected chip. Before the fix the label-owned color
    /// fell through to `textPrimary` (near-white) on the style's near-white focus platter.
    func testFocusedUnselected_usesFocusPlatterColor_notTextPrimary() {
        XCTAssertEqual(chipLabelColor(isFocused: true, isSelected: false), .onFocusPlatter)
    }

    /// Focus must win outright over selection too, not just over the unselected default —
    /// mirrors the "focus wins unconditionally" rule `RowAccentTint`/BUG-45 established.
    func testFocusedSelected_usesFocusPlatterColor_notAccentText() {
        XCTAssertEqual(chipLabelColor(isFocused: true, isSelected: true), .onFocusPlatter)
    }

    /// Unfocused + selected keeps the style's look (accent fill with its own contrast color) —
    /// the fix must not change any unfocused case.
    func testUnfocusedSelected_keepsAccentTextColor() {
        XCTAssertEqual(chipLabelColor(isFocused: false, isSelected: true), .accentText)
    }

    /// Unfocused + unselected keeps today's look too.
    func testUnfocusedUnselected_keepsTextPrimaryColor() {
        XCTAssertEqual(chipLabelColor(isFocused: false, isSelected: false), .textPrimary)
    }
}
