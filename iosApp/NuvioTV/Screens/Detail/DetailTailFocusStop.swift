import SwiftUI

/// BUG-244: turns a content section that has nothing focusable after it into ONE focus stop, with
/// About's pattern (`DetailAboutSection`): the section's content is a single `.focusable()` target
/// with About's platter behind it, so Down from the row above has somewhere to land and the page
/// scrolls the section into view. Select on a stop does nothing; Menu still pops. The section's
/// heading stays outside the platter.
///
/// `active` false returns `content` untouched (an `if`, not `.focusable(false)`): an inactive page
/// is today's view tree, so configurations that work keep their focus path (invariant I1).
/// The stop is one combined VoiceOver element carrying `label` (a `LazyHStack` builds only the
/// visible cards, so `.combine` would drop names).
struct DetailTailFocusStop: ViewModifier {
    let active: Bool
    let isFocused: Bool
    let label: Text
    let identifier: String

    /// The platter snaps instead of fading under Reduce Motion (as About's).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content
                .background { platter }
                .focusable()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isFocused)
        } else {
            content
        }
    }

    /// Copy of `DetailAboutSection.platter` (itself a copy of `PersonDetailView.topFocusPlatter`):
    /// drawn outside the content's bounds through negative padding, so focusing never shifts the layout.
    private var platter: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.hero)
            .fill(Theme.Palette.surface.opacity(isFocused ? 0.9 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.hero)
                    .strokeBorder(Color.white.opacity(isFocused ? 0.55 : 0), lineWidth: 2) // neutral by design: the HIG contract bans accent focus rings
            )
            .padding(-Theme.Spacing.md)
    }
}

extension View {
    func detailTailFocusStop(active: Bool, isFocused: Bool, label: Text, identifier: String) -> some View {
        modifier(DetailTailFocusStop(active: active, isFocused: isFocused, label: label, identifier: identifier))
    }
}

extension View {
    /// A tail stop's focus REACH spans the page width: the section is a full-width focus section
    /// that routes a vertical press from any x to the stop, while the visible platter still hugs the
    /// content (round 1 P2: a stop on an intrinsic-width chip row was skipped by a Down press from a
    /// card far to the right). An inactive section returns `self` untouched (invariant I1).
    @ViewBuilder
    func detailTailFocusReach(active: Bool) -> some View {
        if active {
            focusRow(alignment: .leading)
        } else {
            self
        }
    }
}
