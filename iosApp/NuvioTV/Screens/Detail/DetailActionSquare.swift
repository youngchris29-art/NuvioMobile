import SwiftUI

/// FEAT-82 (Steven rc10, D4): with Poster › Corners = Square, every icon-only Detail action button
/// (Start Over, Watch Trailer, Mark Watched, Add to Library, Shuffle) is one equal square whose side
/// is Play's measured height. An icon-only label is its SF Symbol's own aspect plus 32 pt of padding,
/// so the buttons differ from each other (`play.rectangle.fill` is wider than `plus`) and no shape
/// change can equalise them; a fixed frame can.
///
/// The frame goes on the padded LABEL, not the Button: a fixed outer frame on the Button did not
/// size the style's platter on hardware (`.glass` then, device pass 2026-10-20; `.bordered` since
/// D9), while the style always wraps the label in the same insets. So the chrome is measured once, off Play (its button size minus its
/// padded label size), and the label is cut to `labelSize(side:playLabel:playButton:)`.
///
/// Rounded and Round, and Classic with text labels, never see a side (nil) and keep today's layout.
nonisolated enum DetailActionSquare {
    /// The square's side: Play's measured button height (whole points), or nil until Play has
    /// been measured (0 or a sliver).
    static func side(playHeight: CGFloat) -> CGFloat? {
        playHeight > 1 ? playHeight.rounded() : nil
    }

    /// Whether a button takes the fixed square: Corners = Square, an icon-only label, a measured side.
    static func applies(isSquare: Bool, iconOnly: Bool, side: CGFloat?) -> Bool {
        isSquare && iconOnly && side != nil
    }

    /// The padded icon label's frame that makes a secondary BUTTON `side × side` (side = Play's
    /// button height), or nil until both of Play's sizes are measured.
    ///
    /// The button style wraps the label in its own insets, and they are not equal: on the FA87 sim
    /// Play's padded label is 314.5 × 42 inside a 374.5 × 72 button, 60 pt across and 30 pt down. A
    /// `side × side` label therefore came out 30 pt wider than tall (42 × 42 → 102 × 72). The style's
    /// insets are read off Play (its button minus its padded label, the same insets every action
    /// button gets) and taken off the side: `(side − across) × (side − down)`, at least 1 pt each.
    /// The glyph is centred and may be wider than the label frame; the platter is still `side` wide.
    static func labelSize(side: CGFloat, playLabel: CGSize, playButton: CGSize) -> CGSize? {
        let across = playButton.width - playLabel.width
        let down = playButton.height - playLabel.height
        guard playLabel.width > 1, playLabel.height > 1, across >= 0, down >= 0 else { return nil }
        return CGSize(width: max((side - across).rounded(), 1), height: max((side - down).rounded(), 1))
    }

    /// Rounded and Round: Play (a text label, shorter) and the icon-only secondaries share one label
    /// height, the tallest secondary's, so Play is as tall as the round buttons beside it. nil in
    /// Square (the squares are cut to Play instead) and before any secondary is measured.
    static func matchedLabelHeight(isSquare: Bool, tallestSecondaryLabel: CGFloat) -> CGFloat? {
        guard !isSquare, tallestSecondaryLabel > 1 else { return nil }
        return tallestSecondaryLabel
    }

    /// A measured size in whole points (both sides rounded), so a geometry read writes only on a
    /// real change (BUG-41).
    static func whole(_ size: CGSize) -> CGSize {
        CGSize(width: size.width.rounded(), height: size.height.rounded())
    }
}

/// The padded icon label sized to `DetailActionSquare.labelSize`, so the button style's insets
/// around it make the button a square as tall as Play.
struct DetailActionSquareLabel: ViewModifier {
    let size: CGSize?

    func body(content: Content) -> some View {
        if let size {
            content.frame(width: size.width, height: size.height)
        } else {
            content
        }
    }
}
