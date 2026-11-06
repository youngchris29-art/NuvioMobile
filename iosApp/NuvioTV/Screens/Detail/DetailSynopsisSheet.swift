import SwiftUI

/// A4.2 (C12, Apple TV detail): the pure parts of the compact synopsis overlay — the info line and
/// the text box's height. No SharedCore, no Theme, so it stays `nonisolated` and unit-testable.
nonisolated enum DetailSynopsisOverlay {
    /// Year · Runtime · up to three genres · age rating, only the non-blank parts, in that order.
    /// The IMDb score is not here: the overlay draws it with the meta line's star.
    static func infoParts(_ info: DetailMetaLineModel?) -> [String] {
        guard let info else { return [] }
        var parts: [String] = []
        func add(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        add(info.year)
        add(info.runtime)
        let genres = info.genres
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxGenres)
            .joined(separator: ", ")
        add(genres)
        add(info.ageRating)
        return parts
    }

    /// The IMDb score for the info line (one decimal), nil when blank.
    static func imdbScore(_ info: DetailMetaLineModel?) -> String? {
        guard let raw = info?.imdbRating else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : RatingFormat.oneDecimal(trimmed)
    }

    static let maxGenres = 3

    /// The text box hugs short text and stops at `maxHeight` (the rest scrolls). Before the first
    /// measurement (`contentHeight` 0) it takes `maxHeight`, so the focusable scroll view is never
    /// zero-sized on the cover's first frame.
    static func textBoxHeight(contentHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard contentHeight > 0 else { return maxHeight }
        return min(contentHeight.rounded(.up), maxHeight)
    }
}

/// FEAT-35 (D3): the full synopsis, opened from the Cinematic hero's teaser when the text does not
/// fit its four lines (and the Person page's full biography, BUG-179). Presented as a full-screen
/// cover; Menu closes it through the system's own cover dismissal (no `onExitCommand`: Menu = back,
/// per the remote-grammar rule), and the system returns focus to the control that opened it (the
/// teaser), the only focusable the cover covered there.
///
/// A4.2 (C12): an Apple TV-style compact overlay. The page's backdrop under a flat dim fills the
/// screen; a centered rounded panel (at most `panelMaxWidth` wide) holds the title logo (or the
/// title), an info line (year, runtime, genres, age rating, IMDb score) and the full text, which
/// scrolls inside the panel when it is long. The panel is a flat surface fill, not a material
/// (BUG-193: blur read as a smear on Steven's OLED).
///
/// BUG-193 (Steven rc10): the backdrop is the page's own backdrop under a flat dark scrim, a plain
/// fade with no blur (the `.thick` material it replaces read as a blurred smear on his OLED). It is
/// a background LAYER over the cover's default opaque background — never a `.presentationBackground`.
/// A clear cover background keeps the presenting page alive under it, and one Menu press then
/// dismissed the cover AND popped Detail (FEAT-32, 2026-09-05; correction F8). The layers also
/// never wrap anything focusable.
struct DetailSynopsisSheet: View {
    let title: String
    let logoURL: String?
    let overview: String
    /// BUG-193: the same backdrop URL the Detail page draws (already upgraded). The page releases
    /// its own bitmap while covered, so this is normally a memory-cache hit. Nil (the biography)
    /// draws the app background under the same scrim.
    var backdropURL: String? = nil
    /// The page's fallback chain entry (the original URL when `backdropURL` is an upgraded one).
    var backdropFallbackURL: String? = nil
    /// A4.2: the hero's meta line facts (year, runtime, genres, age rating, IMDb). Nil (the
    /// biography, or a presenter that has not passed it) draws no info line.
    var info: DetailMetaLineModel? = nil

    @State private var position = ScrollPosition()
    @State private var offset: CGFloat = 0
    @State private var maxOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var textVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Flat scrim over the backdrop. The text needs at least the Cinematic text-block floor
    /// (`DetailScrimCinematicTests.testTextBlockFloor`, 0.31); the panel carries the text now, so
    /// this only dims the page. Tune on the rig.
    static let scrimOpacity: Double = 0.72

    /// A4.2: the panel's geometry. Tune on the rig.
    static let panelMaxWidth: CGFloat = 1100
    static let panelCornerRadius: CGFloat = 28
    static let panelOpacity: Double = 0.94
    /// The text box's tallest size; longer text scrolls inside it.
    static let textMaxHeight: CGFloat = 560

    /// One D-pad press scrolls this far.
    private static let pageStep: CGFloat = 240

    var body: some View {
        ZStack {
            backdropLayers
            panel
                .padding(Theme.Spacing.screen)
        }
        .onAppear {
            guard !textVisible else { return }
            if reduceMotion { textVisible = true } else {
                withAnimation(.easeOut(duration: 0.25)) { textVisible = true }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail_synopsis_sheet")
    }

    /// Logo/title, info line, then the scrolling text, on a rounded flat surface.
    private var panel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // The fade sits on the logo, the info line and the text only: the focusable scroll view
            // itself is never at opacity 0 (an opacity-0 control is unfocusable on hardware).
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                logo
                infoLine
            }
            .opacity(textVisible || reduceMotion ? 1 : 0)
            ScrollView(.vertical) {
                Text(overview)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(textVisible || reduceMotion ? 1 : 0)
                    .accessibilityIdentifier("detail_synopsis_sheet_text")
            }
            .frame(height: DetailSynopsisOverlay.textBoxHeight(contentHeight: contentHeight,
                                                              maxHeight: Self.textMaxHeight))
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }, action: { _, newOffset in
                offset = newOffset
            })
            .onScrollGeometryChange(for: CGFloat.self, of: { geo in
                max(0, geo.contentSize.height - geo.containerSize.height)
            }, action: { _, newMax in
                maxOffset = newMax
            })
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height.rounded(.up) }, action: { _, newHeight in
                if contentHeight != newHeight { contentHeight = newHeight }
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
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: Self.panelMaxWidth, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous)
                .fill(Theme.Palette.surface.opacity(Self.panelOpacity))
        }
    }

    /// Year · Runtime · Genres · Rating, then the IMDb star (same star colour as the meta line).
    @ViewBuilder
    private var infoLine: some View {
        let parts = DetailSynopsisOverlay.infoParts(info)
        let score = DetailSynopsisOverlay.imdbScore(info)
        if !parts.isEmpty || score != nil {
            HStack(spacing: Theme.Spacing.md) {
                if !parts.isEmpty {
                    Text(parts.joined(separator: " \u{00B7} "))
                }
                if let score {
                    HStack(spacing: Theme.Spacing.xxs) {
                        Image(systemName: "star.fill").foregroundStyle(Theme.Palette.star)
                        Text(score)
                    }
                }
            }
            .font(Theme.Font.metaStrong)
            .foregroundStyle(Theme.Palette.textSecondary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("detail_synopsis_sheet_info")
        }
    }

    /// App background, then (when there is one) the page's backdrop full-bleed, then the flat scrim.
    /// No blur, no material.
    private var backdropLayers: some View {
        ZStack {
            Theme.Palette.background
            if let backdropURL, !backdropURL.isEmpty {
                GeometryReader { geo in
                    CachedAsyncImage(string: backdropURL, fallback: backdropFallbackURL, decodeSize: .fullBleed)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                #if DEBUG
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: "synopsis backdrop"))
                .accessibilityIdentifier("detail_synopsis_backdrop")
                #endif
            }
            Color.black.opacity(Self.scrimOpacity)
        }
        .ignoresSafeArea()
        #if !DEBUG
        .accessibilityHidden(true)
        #endif
    }

    @ViewBuilder
    private var logo: some View {
        let fallback = Text(title)
            .font(Theme.Font.screenTitle)
            .foregroundStyle(Theme.Palette.textPrimary)
        if let logoURL, !logoURL.isEmpty {
            // beta.19-rc1 verdict (I1, BUG-134): the TMDB `original` logo (the data keeps w500; the
            // w500 file is the automatic fallback), decoded for the 520×120 box it is drawn in. The
            // spec lists 600×180 here; the box below is the real drawn size.
            CachedAsyncImage(string: logoURL, contentMode: .fit,
                             decodeSize: .points(width: 520, height: 120), upgrade: .logo,
                             failure: { fallback })
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
