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

/// BUG-244 probe: a leaf inside a comment card that exists only while the card is focused, so a UI
/// leg can read WHICH card holds focus (the tvOS runtime never reports `hasFocus`). It reads its own
/// `isFocused` environment, so the card's body does not depend on focus.
struct DetailCommentFocusMarker: View {
    let index: Int
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        if isFocused {
            Text(verbatim: "debug_comment_focus \(index)")
                .font(.system(size: 8))
                .opacity(0.011)
                .accessibilityIdentifier("debug_comment_focus")
        }
    }
}
#endif
