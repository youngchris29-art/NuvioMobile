import SwiftUI
import SharedCore

/// BUG-244: the Trakt comment cards of the Detail page's Comments section, built EAGERLY.
///
/// This was a `LazyVStack` inside the page's vertical `ScrollView`, so a card existed only once it
/// intersected the visible area. While focus sat on the row above, every card lay below the screen
/// and none was built: the focus engine searches only views that exist, the comments focus section
/// was empty and passed over, and Down either jumped to About (skipping all eight cards) or, with
/// About off, found nothing and never scrolled, so the cards were never built (a closed loop).
/// Eager cards (at most eight, text capped at five lines, no images) are always there, so Down
/// enters the first card from any x and the content height is exact. Never make this lazy again.
///
/// A separate view with equatable inputs, so a page body pass that does not change the comments
/// (every row focus change re-runs `DetailView.body`) skips this body: the cost of building all
/// eight cards stays off the page's per-focus work.
struct DetailCommentsList: View, Equatable {
    /// The caller passes `Array(model.comments.prefix(DetailCommentsList.maxCards))`.
    let comments: [TraktCommentReview]
    /// Cards expanded by Select (spoiler revealed, text uncapped).
    let expanded: Set<Int64>
    /// Toggles a card's expansion on the page. Not part of `==`: it always toggles the same page state.
    let onToggle: (Int64) -> Void

    static let maxCards = 8

    static func == (lhs: DetailCommentsList, rhs: DetailCommentsList) -> Bool {
        lhs.expanded == rhs.expanded && lhs.comments.map(\.id) == rhs.comments.map(\.id)
    }

    var body: some View {
        #if DEBUG
        let _ = DetailCommentsBodyCounter.bump()
        #endif
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                card(comment, index: index)
            }
        }
    }

    /// One comment as a focusable card. Pressing reveals spoilers / expands long text.
    private func card(_ comment: TraktCommentReview, index: Int) -> some View {
        let isExpanded = expanded.contains(comment.id)
        let hidesForSpoiler = (comment.spoiler || comment.hasSpoilerContent) && !isExpanded
        return Button {
            onToggle(comment.id)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.md) {
                    Text(comment.authorDisplayName)
                        .font(Theme.Font.meta)
                        .rowTextColor()
                    if let rating = comment.rating?.value {
                        HStack(spacing: 2) {
                            // BUG-50: the star's fixed gold (Theme.Palette.star) isn't a
                            // semantic color the row's colorScheme flip can fix, and reads as
                            // washed-out on the near-white focused platter. `rowAccentTint`
                            // preserves the gold at rest (active: false, inactiveColor: star)
                            // while forcing the platter-safe color on focus, same shape as
                            // BUG-22's row-icon fix.
                            Image(systemName: "star.fill")
                                .rowAccentTint(false, inactiveColor: Theme.Palette.star)
                            Text("\(rating)/10")
                        }
                        .font(Theme.Font.caption)
                        .rowTextColor(secondary: true)
                    }
                    if let date = commentDate(comment) {
                        Text(date)
                            .font(Theme.Font.caption)
                            .rowTextColor(secondary: true)
                    }
                    if comment.review {
                        Text("Review")
                            .font(Theme.Font.caption)
                            .rowAccentTint()
                    }
                    Spacer(minLength: 0)
                    if comment.likes > 0 {
                        Label("\(comment.likes)", systemImage: "heart.fill")
                            .font(Theme.Font.caption)
                            .rowTextColor(secondary: true)
                    }
                }
                if hidesForSpoiler {
                    Label("Contains spoilers \u{2014} press to reveal", systemImage: "eye.slash")
                        .font(Theme.Font.body)
                        .rowTextColor(secondary: true)
                } else {
                    Text(comment.comment)
                        .font(Theme.Font.body)
                        .rowTextColor()
                        .lineLimit(isExpanded ? nil : 5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if DEBUG
            // An overlay: the marker never takes part in the card's layout.
            .overlay(alignment: .topLeading) {
                if DetailScrollProbe.enabled { DetailCommentFocusMarker(index: index) }
            }
            #endif
        }
        .buttonStyle(.settingsRow)
        .accessibilityIdentifier("detail_comment_\(index)")
    }

    private func commentDate(_ comment: TraktCommentReview) -> String? {
        let raw: String? = comment.createdAt
        guard let raw, raw.count >= 10 else { return nil }
        return String(raw.prefix(10))
    }
}

#if DEBUG
/// BUG-244 probe: how many times `DetailCommentsList.body` ran. A plain static, never observed
/// (the `FolderBodyCounter` shape): the page's `debug_detail_sections` label prints it as `cbody=`
/// in the same body, so it shows the count as of the last page evaluation. Focus moving elsewhere
/// on the page must not move it (leg U3).
@MainActor enum DetailCommentsBodyCounter {
    static var count = 0
    static func bump() { count += 1 }
}

/// BUG-244 probe: the Comments section's laid-out bottom edge in global (screen) space, written by
/// `DetailCommentsSectionEndProbe` (a plain static, never observed).
@MainActor enum DetailCommentsProbe {
    static var sectionBottom: CGFloat = 0
}

/// A zero-size leaf at the bottom of the Comments section (under the "From Trakt" caption).
struct DetailCommentsSectionEndProbe: View {
    var body: some View {
        Color.clear
            .frame(height: 1)
            .allowsHitTesting(false)
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).maxY }) { DetailCommentsProbe.sectionBottom = $0 }
    }
}

/// BUG-244 probe: a leaf inside a comment card, drawn over it (no layout). While the card is focused
/// it shows `debug_comment_focus <index> y0=<card top> y1=<card bottom> sb=<section bottom>` in
/// global (screen) points, so a UI leg can read WHICH card holds focus (the tvOS runtime never
/// reports `hasFocus`) and where the page really is: the page's own scroll sample is published only
/// when the focused ROW changes, so it is stale for moves between cards. It reads its own
/// `isFocused` environment and keeps its own state, so neither the card nor the list re-runs.
struct DetailCommentFocusMarker: View {
    let index: Int
    @Environment(\.isFocused) private var isFocused
    @State private var frame: CGRect = .zero
    @State private var sectionBottom: CGFloat = 0

    var body: some View {
        ZStack {
            Color.clear
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $0 }
                .task(id: frame) {
                    // The section end moves in step with the card; read it once the card has settled.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    sectionBottom = DetailCommentsProbe.sectionBottom
                }
            if isFocused {
                Text(verbatim: "debug_comment_focus \(index) y0=\(Int(frame.minY)) y1=\(Int(frame.maxY)) sb=\(Int(sectionBottom))")
                    .font(.system(size: 8))
                    .opacity(0.011)
                    .accessibilityIdentifier("debug_comment_focus")
            }
        }
        .allowsHitTesting(false)
    }
}
#endif
