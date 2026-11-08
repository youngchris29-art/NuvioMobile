import SwiftUI
import SharedCore

/// W3-16 (BUG-207, F1): one stream row, `Equatable` over its `StreamRowModel` (the closures are not
/// compared, see `StreamPickerView.streamRowView`). Reads NOTHING from the picker: not the focus
/// state, not the resolve spinner, not the rejected set — the model carries them.
///
/// Polish D1: four lines. Line 1 is the headline (resolution) with the HDR mark, spinner, inline
/// add-on label and size; lines 2 and 3 are the fact lines; line 4 is the release file name, drawn
/// only after a focus dwell (BUG-16's "never truncated" still holds: the dwelled line is whole).
/// The dwell reads the row style's `\.settingsRowIsFocused` inside `StreamRowDwell`, a background
/// host, so a focus move re-evaluates that one leaf, never the row or its siblings.
struct StreamRowView: View, Equatable {
    let model: StreamRowModel
    let onSelect: () -> Void
    let onBuiltIn: () -> Void
    let onExternal: (String) -> Void
    /// Review r1 P2-3: called once the file line's dwell has grown the focused row and it has
    /// laid out (the picker scrolls it back on screen). Not compared, like the other closures.
    var onExpanded: () -> Void = {}

    /// Shown once the focused row has dwelled; flipped only by `StreamRowDwell`.
    @State private var fileLineShown = false

    nonisolated static func == (lhs: StreamRowView, rhs: StreamRowView) -> Bool {
        lhs.model == rhs.model
    }

    var body: some View {
        #if DEBUG
        let _ = HomeBodyCounter.tick("StreamRow")
        #endif
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if model.addonText {
                    // GitHub #25 "Row Text = Add-on's Own": the add-on's name and description, no
                    // Nuvio headline or fact lines. The badge row sits inside the content.
                    if model.wide { addonWideContent } else { addonStackedContent }
                } else {
                    if model.hasBadgeRow && model.badgesOnTop {
                        StreamRowBadges(badges: model.badges)
                    }
                    headlineLine
                    if model.wide {
                        // GitHub #25 Full Width: the two fact lines fold into one, with the cached
                        // part pinned to the trailing edge so it lines up down the screen.
                        if model.hasWideFactLine {
                            StreamRowFactLine.wide(video: model.videoFacts, audio: model.audioFacts,
                                                   cached: model.cachedState)
                        }
                    } else {
                        if model.hasVideoLine {
                            StreamRowFactLine.video(model.videoFacts)
                        }
                        if model.hasAudioLine {
                            StreamRowFactLine.audio(model.audioFacts, cached: model.cachedState)
                        }
                    }
                    if fileLineShown, let description = model.description {
                        StreamRowFileLine(text: description)
                    }
                    if model.hasBadgeRow && !model.badgesOnTop {
                        StreamRowBadges(badges: model.badges)
                    }
                }
                // Batch D U2: the add-on gave only a YouTube video id — the row plays after an
                // on-device resolve (the spinner above), so say where the video comes from.
                if model.isYouTube {
                    Text(verbatim: "YouTube")
                        .font(Theme.Font.caption)
                        .rowTextColor(secondary: true)
                }
                // Orivio batch item 2: this link failed recently for this title, so the
                // automatic pickers skip it. Still selectable by hand.
                if model.failedRecently {
                    Text("Failed recently")
                        .font(Theme.Font.caption)
                        .rowTextColor(secondary: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The dwell host: always present, no layout space, the only view that reads focus.
            .background(StreamRowDwell(isShown: $fileLineShown, hasText: model.description != nil || model.addonText,
                                       onExpanded: onExpanded))
            .padding(Theme.Spacing.md)
        }
        // `.settingsRow` (platter-free, soft white highlight + accent ring) replaces the system
        // `.glass` style: Liquid Glass's focus platter goes near-white, which made this row's
        // title text (statically `textPrimary`, near-white) unreadable on focus.
        .buttonStyle(.settingsRow)
        // P3.2: a 12 pt card on `surface` at rest so the row reads inside the panel (upstream mobile
        // white 5 %, Android TV #1A1A1A). Drawn BEHIND the style: focus keeps `.settingsRow`'s white
        // platter and lift on top (the native-List pass is a separate debt, not this batch).
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .accessibilityLabel(Text(verbatim: model.spokenLabel))
        .accessibilityIdentifier("stream_picker_row")
        // FEAT-5: long-press → the OTHER player(s). With the built-in default, the menu offers
        // the installed external players; with an external default (plain Select already hands
        // off) it inverts to offer "Play in NuvioTV Player" plus any non-default externals. The
        // modifier is skipped entirely when no external player is installed, so the long-press
        // stays inert rather than opening an empty menu.
        .modifier(ExternalPlayMenu(
            players: model.players,
            defaultPlayerId: model.defaultPlayerId,
            onExternal: onExternal,
            onBuiltIn: onBuiltIn
        ))
    }

    // MARK: - Add-on text (GitHub #25)

    /// The name lines, or the title when the add-on sent no name.
    private var addonNameText: String {
        model.nameLines.isEmpty ? model.title : model.nameLines.joined(separator: "\n")
    }

    /// The description: `descriptionRestLines` lines at rest, the whole text once the row has
    /// dwelled (the same `StreamRowDwell` that reveals the Nuvio row's file line).
    @ViewBuilder
    private var addonDescription: some View {
        if let description = model.description {
            Text(verbatim: description)
                .font(Theme.Font.meta)
                .rowTextColor(secondary: true)
                .multilineTextAlignment(.leading)
                .lineLimit(fileLineShown ? nil : StreamPickerWideMetrics.descriptionRestLines)
                .fixedSize(horizontal: false, vertical: fileLineShown)
        }
    }

    /// The badge row in its Badge Placement slot of the add-on text column.
    @ViewBuilder
    private func addonBadges(top: Bool) -> some View {
        if model.hasBadgeRow && model.badgesOnTop == top {
            StreamRowBadges(badges: model.badges)
        }
    }

    /// The trailing column: spinner, size (always: the add-on's text may hold it past the resting
    /// line limit, review r3), Nuvio's cached part.
    private var addonTrailing: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                if model.isResolving {
                    ProgressView().scaleEffect(0.7)
                }
                if let bytes = model.sizeBytes {
                    Text(verbatim: StreamFileSizeChip.label(for: bytes))
                        .font(Theme.Font.metaStrong)
                        .rowTextColor()
                        .lineLimit(1)
                }
            }
            if let cached = model.drawnCachedState {
                StreamRowFactLine.cached(cached)
            }
        }
        .fixedSize()
    }

    /// Full Width: two columns like the classic Stremio list. The name in a fixed column (up to
    /// three lines), the description filling the rest, the trailing column at the edge.
    private var addonWideContent: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(verbatim: addonNameText)
                    .font(Theme.Font.metaStrong)
                    .rowTextColor()
                    .multilineTextAlignment(.leading)
                    .lineLimit(fileLineShown ? nil : StreamPickerWideMetrics.nameRestLines)
                    .fixedSize(horizontal: false, vertical: fileLineShown)
                if model.showsAddonName {
                    StreamRowAddonLabel(name: model.addonName, logo: model.showsAddonColumn ? model.addonLogo : nil)
                }
            }
            .frame(width: StreamPickerWideMetrics.nameColumnWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                addonBadges(top: true)
                addonDescription
                addonBadges(top: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            addonTrailing
        }
    }

    /// Two-Pane: the same content stacked, the name lines first, the description under them.
    private var addonStackedContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            addonBadges(top: true)
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Text(verbatim: addonNameText)
                    .font(Theme.Font.metaStrong)
                    .rowTextColor()
                    .multilineTextAlignment(.leading)
                    .lineLimit(fileLineShown ? nil : StreamPickerWideMetrics.nameRestLines)
                    .fixedSize(horizontal: false, vertical: fileLineShown)
                    .layoutPriority(1)
                if model.showsAddonName {
                    StreamRowAddonLabel(name: model.addonName, logo: model.showsAddonColumn ? model.addonLogo : nil)
                }
                Spacer(minLength: Theme.Spacing.sm)
                addonTrailing
            }
            addonDescription
            addonBadges(top: false)
        }
    }

    /// Line 1: headline (or the title when the release names no resolution), HDR mark, spinner,
    /// inline add-on label, then the size at the trailing edge. The headline/title carry layout
    /// priority and the size is `fixedSize`, so the line can never widen the row.
    private var headlineLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            if let headline = model.headline {
                Text(verbatim: headline)
                    .font(Theme.Font.body.weight(.bold))
                    .rowTextColor()
                    .lineLimit(1)
                    .layoutPriority(1)
                if let mark = model.hdrMark {
                    Text(verbatim: mark)
                        .font(Theme.Font.caption)
                        .rowTextColor(secondary: true)
                        .lineLimit(1)
                }
            } else {
                Text(model.title)
                    .font(Theme.Font.body)
                    .rowTextColor()
                    .lineLimit(2)
                    .layoutPriority(1)
            }
            if model.isResolving {
                ProgressView().scaleEffect(0.7)
            }
            if model.showsAddonName {
                StreamRowAddonLabel(name: model.addonName, logo: model.showsAddonColumn ? model.addonLogo : nil)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if let bytes = model.sizeBytes {
                Text(verbatim: StreamFileSizeChip.label(for: bytes))
                    .font(Theme.Font.metaStrong)
                    .rowTextColor()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// Direction C D6: the compact row of the `.tiers` list. One 64 pt line, `Equatable` over its
/// `StreamRowModel` (closures not compared, BUG-207). No badges, no file line, no dwell and no
/// `@State`: focus never changes its height. The full `StreamRowView` is untouched.
struct StreamCompactRowView: View, Equatable {
    enum Metrics {
        static let height: CGFloat = 64
    }

    let model: StreamRowModel
    let onSelect: () -> Void
    let onBuiltIn: () -> Void
    let onExternal: (String) -> Void

    nonisolated static func == (lhs: StreamCompactRowView, rhs: StreamCompactRowView) -> Bool {
        lhs.model == rhs.model
    }

    var body: some View {
        #if DEBUG
        let _ = HomeBodyCounter.tick("StreamCompactRow")
        #endif
        let parts = StreamPickerCopy.compactParts(model)
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Text(verbatim: parts.lead)
                    .font(Theme.Font.metaStrong)
                    .rowTextColor()
                    .lineLimit(1)
                    .layoutPriority(1)
                if let facts = parts.facts {
                    Text(verbatim: "\u{00B7}")
                        .font(Theme.Font.meta)
                        .rowTextColor(secondary: true)
                    Text(verbatim: facts)
                        .font(Theme.Font.meta)
                        .rowTextColor(secondary: true)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Theme.Spacing.sm)
                if model.isResolving {
                    ProgressView().scaleEffect(0.7)
                }
                if let glyph = parts.glyph {
                    Image(systemName: glyph)
                        .font(Theme.Font.meta)
                        .rowTextColor(secondary: true)
                }
                if let size = parts.size {
                    Text(verbatim: size)
                        .font(Theme.Font.metaStrong)
                        .rowTextColor()
                        .lineLimit(1)
                        .fixedSize()
                }
                if let trailing = parts.trailing {
                    Text(verbatim: trailing)
                        .font(Theme.Font.caption)
                        .rowTextColor(secondary: true)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: Metrics.height, alignment: .leading)
            .transaction { $0.animation = nil }
        }
        .buttonStyle(.settingsRow)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Palette.surface)
        )
        .accessibilityLabel(Text(verbatim: StreamPickerCopy.compactSpokenLabel(model, parts: parts)))
        .accessibilityIdentifier("stream_picker_compact_row")
        .modifier(ExternalPlayMenu(
            players: model.players,
            defaultPlayerId: model.defaultPlayerId,
            onExternal: onExternal,
            onBuiltIn: onBuiltIn
        ))
    }
}

/// The two fact lines under the headline. Terms are joined into one `AttributedString` with a font
/// per run, so the line truncates as a unit and takes the row's secondary colour (`RowTextColor` is
/// a view modifier, so one colour per line; emphasis is by weight). `Text(AttributedString)` makes no
/// `LocalizedStringKey` (an interpolated `Text` made a `%@%@%@` catalog key), and `Text + Text` is
/// deprecated. Line 1 terms are `metaStrong`; line 2 is `meta`.
private enum StreamRowFactLine {
    private static let separator = " \u{00B7} "

    /// The terms joined by the separator, each term in `termFont` and the separator in `separatorFont`.
    private static func joined(_ terms: [String], termFont: Font, separatorFont: Font) -> AttributedString {
        var line = AttributedString()
        for (index, term) in terms.enumerated() {
            if index > 0 {
                var sep = AttributedString(separator)
                sep.font = separatorFont
                line.append(sep)
            }
            var span = AttributedString(term)
            span.font = termFont
            line.append(span)
        }
        return line
    }

    /// Fact line 1: source type and codec, every term bold.
    static func video(_ terms: [String]) -> some View {
        Text(joined(terms, termFont: Theme.Font.metaStrong, separatorFont: Theme.Font.meta))
            .rowTextColor(secondary: true)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// GitHub #25, the wide Nuvio row's second line: video facts (bold) then audio and languages as
    /// one truncating run, and the cached part pinned to the trailing edge.
    static func wide(video: [String], audio: [String], cached: StreamRowCachedState?) -> some View {
        var line = joined(video, termFont: Theme.Font.metaStrong, separatorFont: Theme.Font.meta)
        if !video.isEmpty && !audio.isEmpty {
            var sep = AttributedString(separator)
            sep.font = Theme.Font.meta
            line.append(sep)
        }
        line.append(joined(audio, termFont: Theme.Font.meta, separatorFont: Theme.Font.meta))
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Text(line)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Spacing.sm)
            if let cached {
                Self.cached(cached)
            }
        }
        .font(Theme.Font.meta)
        .rowTextColor(secondary: true)
    }

    /// The cached glyph and words alone ("RD Instant"), never truncated.
    static func cached(_ state: StreamRowCachedState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Text(Image(systemName: StreamRowFacts.cachedSymbol(state)))
            Text(verbatim: StreamRowFacts.cachedText(state))
                .lineLimit(1)
        }
        .font(Theme.Font.meta)
        .rowTextColor(secondary: true)
        .fixedSize()
    }

    /// Fact line 2: audio and languages, then the cached glyph and words (D3). An attributed string
    /// cannot hold an image, so the glyph and words sit after the terms in an `HStack`: the terms
    /// truncate first and the cached state stays visible. The glyph is a `Text(Image)`, which
    /// inherits the line's colour, platter-safe.
    static func audio(_ terms: [String], cached: StreamRowCachedState?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if !terms.isEmpty {
                let head = joined(terms, termFont: Theme.Font.meta, separatorFont: Theme.Font.meta)
                Text(cached == nil ? head : head + AttributedString(separator))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let cached {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text(Image(systemName: StreamRowFacts.cachedSymbol(cached)))
                    Text(verbatim: StreamRowFacts.cachedText(cached))
                        .lineLimit(1)
                }
                .fixedSize()
            }
        }
        .font(Theme.Font.meta)
        .rowTextColor(secondary: true)
    }
}

/// Polish D1: the add-on's logo (when it has one) and name, inline on the headline line. Drawn only
/// for "Show Add-on Logo". Replaces the old trailing `StreamRowAddonColumn`.
private struct StreamRowAddonLabel: View {
    let name: String
    let logo: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let logo, let url = URL(string: logo) {
                // Cached + downsampled: the same logo repeats on every row of a group, and the
                // uncached `AsyncImage` refetched and re-decoded it as each row was realized.
                // Clear while loading and on failure: add-on logos often 404, and a shimmer or
                // grey film tile on every row of the group is noise.
                CachedAsyncImage(url: url, contentMode: .fit, decodeSize: .points(width: 28, height: 28),
                                 loading: { Color.clear }, failure: { Color.clear })
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip))
            }
            Text(name)
                .font(Theme.Font.caption)
                .rowTextColor(secondary: true)
                .lineLimit(1)
        }
    }
}

/// The release file name, the row's fourth line: the whole description, monospaced, never clamped
/// (BUG-16: release names are dot/underscore-separated with no break points, so no fixed cap fits).
private struct StreamRowFileLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.caption.monospaced())
            .rowTextColor(secondary: true)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The dwell host of the file line (BUG-16, W3-16 F2, review r1 P2-3). At rest the row draws NO
/// file line; after ~0.5 s of the row holding focus it is shown in full, and it collapses at once
/// on losing focus. Neither direction animates. A browsing move therefore changes no row height
/// (F2). Lives in a `.background` so it adds no layout space and is the only view reading focus.
///
/// Once the row has grown it calls `onExpanded` (the picker's `scrollTo(key, anchor: nil)`), which
/// scrolls only when the grown row overflows, so a row near the bottom edge does not leave its file
/// name below the fold.
struct StreamRowDwell: View {
    @Binding var isShown: Bool
    let hasText: Bool
    let onExpanded: () -> Void
    /// ~0.5 s of the row holding focus before the file line appears.
    static let dwell: Duration = .milliseconds(500)
    /// After the grow, one frame or so for the taller row to lay out before the reveal is asked for:
    /// a `scrollTo` issued in the same update would measure the row at its old height.
    static let revealDelay: Duration = .milliseconds(20)

    @Environment(\.settingsRowIsFocused) private var focused

    /// The line is drawn only for a focused, dwelled row that has a description.
    static func showsLine(focused: Bool, dwelled: Bool, hasText: Bool) -> Bool {
        focused && dwelled && hasText
    }

    var body: some View {
        Color.clear
            .task(id: focused) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                guard focused else {
                    withTransaction(transaction) { isShown = false }
                    return
                }
                try? await Task.sleep(for: Self.dwell)
                guard !Task.isCancelled else { return }
                withTransaction(transaction) {
                    isShown = Self.showsLine(focused: true, dwelled: true, hasText: hasText)
                }
                guard hasText else { return }
                // Review r1 P2-3: reveal the grown row once it has laid out. Focus leaving in the
                // meantime cancels this task (its id is `focused`), so a departed row never scrolls.
                try? await Task.sleep(for: Self.revealDelay)
                guard !Task.isCancelled else { return }
                onExpanded()
            }
    }
}

/// BUG-16: the badge row of a stream row — `ViewThatFits` over a ladder of candidates.
private struct StreamRowBadges: View {
    let badges: [StreamBadgeInfo]

    var body: some View {
        // BUG-16: this used to be one plain HStack with up to 8 badge chips (each up to
        // `StreamBadgeMetrics.maxImageWidth` = 150pt (180 before polish D2) for image-based
        // community badge packs) — none of them width-flexible. An HStack whose children are all
        // non-shrinking ignores the width it's offered and reports the full sum of its children
        // back to its parent instead. That inflated "ideal" width bubbled up through the
        // row's content VStack, widening the *whole row* — and
        // since every row shares one LazyVStack, effectively the whole list — past the screen.
        // The add-on logo and the tail end of the badges then rendered off the
        // trailing edge, which is what testers saw as "no space left" for title/size/seeders.
        //
        // Fix: hand `ViewThatFits` a ladder of candidates from "every badge" down to "just an
        // overflow count", widest first. It measures each against the width actually left over
        // once the other lines and the add-on logo have claimed theirs, and renders the
        // first one that fits — so this row can never again demand more width than it's given.
        // Every candidate shares the same fixed container height, so switching between them never
        // changes the row's height class. (Polish D1: the size moved to the headline line; this
        // row holds badges only.)
        let displayBadges = Array(badges.prefix(8))
        let hiddenBeyondCap = max(0, badges.count - 8)
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: displayBadges.count, through: 0, by: -1)), id: \.self) { visible in
                variant(
                    displayBadges: displayBadges,
                    visibleCount: visible,
                    hiddenCount: (displayBadges.count - visible) + hiddenBeyondCap
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One `ViewThatFits` candidate: the first `visibleCount` badges + a
    /// non-focusable "+N" overflow chip for everything else. `hiddenCount` folds in both badges
    /// dropped by this candidate and any beyond the 8-badge display cap, so the count the user sees
    /// is always accurate.
    private func variant(displayBadges: [StreamBadgeInfo], visibleCount: Int, hiddenCount: Int) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(Array(displayBadges.prefix(visibleCount).enumerated()), id: \.offset) { _, badge in
                StreamBadgeChipView(badge: badge)
            }
            if hiddenCount > 0 {
                BadgeOverflowChip(count: hiddenCount)
            }
        }
    }
}

/// Attaches the "play somewhere else" context menu only when at least one supported external
/// player is installed (FEAT-5). A conditional modifier rather than an inline `.contextMenu` so
/// the no-players case adds NOTHING to the row — an empty context menu would still swallow the
/// long-press and show a blank platter, which reads as broken.
///
/// The menu always offers the destinations plain Select does NOT: with the built-in player as
/// default it lists the external players; with an external default it lists "Play in NuvioTV
/// Player" first (the escape hatch back) plus any other installed externals. The default player
/// itself is omitted — Select already goes there, and a menu entry duplicating Select reads as
/// two different actions.
private struct ExternalPlayMenu: ViewModifier {
    let players: [StreamRowPlayer]
    /// The validated default external player id, or nil when the built-in player is default.
    let defaultPlayerId: String?
    /// Called with the chosen player's `id`.
    let onExternal: (String) -> Void
    let onBuiltIn: () -> Void

    func body(content: Content) -> some View {
        if players.isEmpty {
            content
        } else {
            content.contextMenu {
                if defaultPlayerId != nil {
                    Button {
                        onBuiltIn()
                    } label: {
                        Label("Play in NuvioTV Player", systemImage: "play.tv")
                    }
                }
                ForEach(players.filter { $0.id != defaultPlayerId }, id: \.id) { player in
                    Button {
                        onExternal(player.id)
                    } label: {
                        Label("Open in \(player.name)", systemImage: "arrow.up.forward.app")
                    }
                }
            }
        }
    }
}
