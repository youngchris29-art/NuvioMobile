import SwiftUI

/// FEAT-35 (D3): the full synopsis, opened from the Cinematic hero's teaser when the text does not
/// fit its four lines. Presented as a full-screen cover; Menu closes it through the system's own
/// cover dismissal (no `onExitCommand`: Menu = back, per the remote-grammar rule).
///
/// The material is a background LAYER over the cover's default opaque background — never a
/// `.presentationBackground`. A clear cover background keeps the presenting page alive under it,
/// and one Menu press then dismissed the cover AND popped Detail (FEAT-32, 2026-09-05; correction
/// F8). The material also never wraps anything focusable.
struct DetailSynopsisSheet: View {
    let title: String
    let logoURL: String?
    let overview: String

    @State private var position = ScrollPosition()
    @State private var offset: CGFloat = 0
    @State private var maxOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One D-pad press scrolls this far.
    private static let pageStep: CGFloat = 240

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Theme.Surface.panel)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                logo
                ScrollView(.vertical) {
                    Text(overview)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 1400, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("detail_synopsis_sheet_text")
                }
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }, action: { _, newOffset in
                    offset = newOffset
                })
                .onScrollGeometryChange(for: CGFloat.self, of: { geo in
                    max(0, geo.contentSize.height - geo.containerSize.height)
                }, action: { _, newMax in
                    maxOffset = newMax
                })
                // tvOS cannot focus or scroll a ScrollView with no focusable content, so the scroll
                // view itself is the (inert) focus target and the D-pad pages it.
                .focusable()
                .onMoveCommand { direction in
                    switch direction {
                    case .down: scroll(to: min(offset + Self.pageStep, maxOffset))
                    case .up: scroll(to: max(offset - Self.pageStep, 0))
                    default: break
                    }
                }
            }
            .padding(Theme.Spacing.screen)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail_synopsis_sheet")
    }

    @ViewBuilder
    private var logo: some View {
        let fallback = Text(title)
            .font(Theme.Font.screenTitle)
            .foregroundStyle(Theme.Palette.textPrimary)
        if let logoURL, !logoURL.isEmpty {
            CachedAsyncImage(string: logoURL, contentMode: .fit, failure: { fallback })
                .frame(maxWidth: 520, maxHeight: 120, alignment: .leading)
        } else {
            fallback
        }
    }

    private func scroll(to y: CGFloat) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { position.scrollTo(y: y) }
        } else {
            withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(y: y) }
        }
    }
}
