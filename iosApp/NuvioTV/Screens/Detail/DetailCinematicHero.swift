import SwiftUI

/// FEAT-35: the one focus target `DetailView` asks the engine to land on first (`.defaultFocus`).
/// The synopsis teaser can be focusable and sits above Play, so without this the engine's
/// top-leading default would land on the teaser.
nonisolated enum DetailHeroFocus: Hashable {
    case play
}

/// FEAT-35 (Detail revamp "Cinematic Clean", Christian's pick 2026-10-02): the first screen of the
/// Cinematic Detail layout. A bottom-anchored text column (fixed logo slot, meta line, MDBList
/// ratings strip, a four-line synopsis teaser, the action row) with a non-focusable credits block
/// right-aligned beside the action row (D9). The hero fills the viewport minus a peek band, so the
/// first row's title shows under it on landing.
///
/// Every slot above the action row has a constant height once laid out (correction F3): the logo
/// slot, the meta line, the reserved ratings slot and the synopsis slot. Late data (the logo image,
/// the MDBList emission, the enriched overview) fills a slot in place, so the bottom-anchored stack
/// never moves after first paint.
///
/// The action row is `DetailView.actionRow`, passed in verbatim, so its closures, labels and
/// accessibility identifiers are the same ones Classic uses.
struct DetailCinematicHero<Actions: View>: View {
    let title: String
    let logoURL: String?
    let meta: DetailMetaLineModel
    let ratings: [DetailRatingEntry]
    /// The ratings strip's slot is laid out (reserved, possibly still empty) only while this is on:
    /// the Ratings section toggle, the MDBList gate, and a usable IMDb id.
    let ratingsGateOn: Bool
    /// The Ratings section toggle alone (D10: OFF also hides the meta line's IMDb ★).
    let ratingsSectionOn: Bool
    let overview: String?
    /// False once the meta has resolved with no overview at all: the slot then goes away.
    let synopsisSlotVisible: Bool
    let credits: DetailCreditsText
    /// Correction F8: owned by `DetailView` (it also pauses the background trailer).
    @Binding var showSynopsisSheet: Bool
    /// Runs before the sheet opens (counts as interacting; withdraws a leaving trailer bridge).
    let onOpenSynopsis: () -> Void
    @ViewBuilder let actions: () -> Actions

    @State private var measuredSynopsisHeight: CGFloat = 0
    /// The rendered height of four `Theme.Font.synopsis` lines (a hidden probe, font-only). The slot
    /// is sized from this, not from `UIFont.lineHeight` — see `DetailSynopsisTeaser.resolvedSlotHeight`.
    @State private var measuredFourLineHeight: CGFloat = 0
    #if DEBUG
    @State private var measuredHeroHeight: CGFloat = 0
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var synopsisLineHeight: CGFloat { Theme.Font.synopsisLineHeight }
    private var synopsisSlotHeight: CGFloat {
        DetailSynopsisTeaser.resolvedSlotHeight(measuredFourLineHeight: measuredFourLineHeight,
                                                lineHeight: synopsisLineHeight)
    }
    private var synopsisTruncated: Bool {
        DetailSynopsisTeaser.isTruncated(fullTextHeight: measuredSynopsisHeight, slotHeight: synopsisSlotHeight)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Correction F5: the hero's height comes from the scroll view's container through
            // `containerRelativeFrame`, with no stored viewport state and no extra scroll-geometry
            // observer. It sits on an invisible spacer so it acts as a MINIMUM: Larger Text grows
            // the hero (and shrinks the peek) instead of clipping the text column.
            Color.clear
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical) { height, _ in
                    DetailCinematicLayout.heroHeight(containerHeight: height)
                }
                .accessibilityHidden(true)
            content
        }
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        #if DEBUG
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded() }, action: { height in
            measuredHeroHeight = height
        })
        .overlay(alignment: .topLeading) {
            // Gate 1 diagnostic (invisible, harness-readable), same shape as `debug_bridge`.
            Text("debug_detail_hero h=\(Int(measuredHeroHeight)) logo=\(Int(DetailCinematicLayout.logoSlotHeight)) syn=\(Int(synopsisSlotHeight)) trunc=\(synopsisTruncated ? 1 : 0) ratings=\(ratings.count) reserved=\(ratingsGateOn ? 1 : 0)")
                .font(.system(size: 8))
                .opacity(0.011)
                .accessibilityIdentifier("debug_detail_hero")
        }
        #endif
        // BUG-117 (kept): the hero spans the full content width, so Up from a far-right season
        // poster still finds a target in here.
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail_hero")
        .fullScreenCover(isPresented: $showSynopsisSheet) {
            DetailSynopsisSheet(title: title, logoURL: logoURL, overview: overview ?? "")
        }
    }

    // MARK: - Layout

    /// D9: the action row sits inside the text column; the credits are right-aligned and bottom-
    /// aligned to it. The column takes priority so it always gets its full 900 pt before the
    /// credits block claims what is left.
    private var content: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    logoSlot
                    metaLine
                    if ratingsGateOn { ratingsSlot }
                    if synopsisSlotVisible { synopsisSlot }
                }
                actions()
            }
            .frame(maxWidth: DetailCinematicLayout.textColumnMaxWidth, alignment: .leading)
            .layoutPriority(1)
            if !credits.isEmpty {
                creditsBlock
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pieces

    private var titleFallback: some View {
        Text(title)
            .font(Theme.Font.hero)
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(2)
    }

    /// Fixed 180 pt slot, logo (or the title) bottom-leading inside it.
    private var logoSlot: some View {
        Group {
            if let logoURL, !logoURL.isEmpty {
                CachedAsyncImage(string: logoURL, contentMode: .fit, failure: { titleFallback })
                    .frame(maxWidth: DetailCinematicLayout.logoMaxWidth,
                           maxHeight: DetailCinematicLayout.logoSlotHeight,
                           alignment: .bottomLeading)
            } else {
                titleFallback
            }
        }
        .frame(maxWidth: DetailCinematicLayout.logoMaxWidth, alignment: .bottomLeading)
        .frame(height: DetailCinematicLayout.logoSlotHeight, alignment: .bottomLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail_logo_slot")
    }

    private var metaParts: [String] {
        DetailMetaLine.textParts(year: meta.year, runtime: meta.runtime, genres: meta.genres)
    }

    private var showImdbStar: Bool {
        DetailRatings.showsImdbStar(sectionRatings: ratingsSectionOn, ratingsGateOn: ratingsGateOn,
                                    ratingCount: ratings.count, imdbRating: meta.imdbRating)
    }

    /// Year · Runtime · Genres, the stroked age chip, then the IMDb ★ (D10). One line in a fixed
    /// slot; no spinner (correction F3).
    private var metaLine: some View {
        HStack(spacing: Theme.Spacing.md) {
            if !metaParts.isEmpty {
                Text(metaParts.joined(separator: " \u{00B7} "))
            }
            if let age = meta.ageRating, !age.isEmpty {
                // Stroke only: the Cinematic hero carries no glass chips (nothing for BUG-41's
                // flattening to do here).
                Text(age)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip)
                            .stroke(Theme.Palette.textSecondary, lineWidth: 1)
                    }
            }
            if showImdbStar, let rating = meta.imdbRating {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.Palette.star)
                    Text(rating)
                }
            }
        }
        .font(Theme.Font.metaStrong)
        .foregroundStyle(Theme.Palette.textSecondary)
        .lineLimit(1)
        .frame(height: DetailCinematicLayout.metaLineHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail_meta_line")
    }

    /// Reserved 44 pt whenever the gate is on, even while empty: MDBList lands in a second meta
    /// emission and must fade in without moving anything. Widest candidate that fits wins.
    private var ratingsSlot: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: ratings.count, through: 1, by: -1)), id: \.self) { visible in
                HStack(spacing: Theme.Spacing.lg) {
                    ForEach(ratings.prefix(visible)) { entry in
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(entry.label)
                                .font(Theme.Font.meta)
                                .foregroundStyle(Theme.Palette.textSecondary)
                            Text(entry.value)
                                .font(Theme.Font.metaStrong)
                                .foregroundStyle(Theme.Palette.textPrimary)
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .frame(maxWidth: DetailCinematicLayout.textColumnMaxWidth, alignment: .leading)
        .frame(height: DetailCinematicLayout.ratingsSlotHeight, alignment: .leading)
        .opacity(ratings.isEmpty ? 0 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: ratings.isEmpty)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail_ratings_strip")
    }

    /// Four lines in a fixed slot. D3: when the full text needs more, the teaser is a focusable
    /// button that opens the full text; otherwise plain text that focus skips.
    private var synopsisSlot: some View {
        Group {
            if synopsisTruncated {
                Button {
                    onOpenSynopsis()
                    showSynopsisSheet = true
                } label: {
                    teaserText
                }
                .buttonStyle(.borderless)
                .accessibilityHint(String(localized: "Shows the full synopsis"))
                .accessibilityIdentifier("detail_synopsis_teaser")
            } else {
                teaserText
                    .accessibilityIdentifier("detail_synopsis_teaser")
            }
        }
        .frame(maxWidth: DetailCinematicLayout.textColumnMaxWidth, alignment: .topLeading)
        .frame(height: synopsisSlotHeight, alignment: .topLeading)
        .background(alignment: .topLeading) {
            // Measures the full (unclamped) text at the slot's width; the truncation decision
            // compares it against four lines (`DetailSynopsisTeaser.isTruncated`).
            Text(overview ?? "")
                .font(Theme.Font.synopsis)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height in
                    if measuredSynopsisHeight != height { measuredSynopsisHeight = height }
                })
                .accessibilityHidden(true)
        }
        .background(alignment: .topLeading) {
            // Gate 1 fix: four rendered lines of the same font, whatever the title. Font-only, so
            // it lands on the first layout pass and never changes for the visit (correction F3).
            Text(verbatim: "Hg\nHg\nHg\nHg")
                .font(Theme.Font.synopsis)
                .lineLimit(DetailSynopsisTeaser.maxLines)
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height in
                    if measuredFourLineHeight != height { measuredFourLineHeight = height }
                })
                .accessibilityHidden(true)
        }
    }

    private var teaserText: some View {
        Text(overview ?? "")
            .font(Theme.Font.synopsis)
            .foregroundStyle(Theme.Palette.textPrimary)
            .lineLimit(DetailSynopsisTeaser.maxLines)
            .multilineTextAlignment(.leading)
            // Gate 1 fix: the line limit decides how many lines draw, never the proposed height
            // (a proposal a fraction short of four lines made SwiftUI drop to three). The slot
            // above is the measured four-line height, so this never overflows it.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: DetailCinematicLayout.textColumnMaxWidth, alignment: .topLeading)
    }

    /// "With …" / "Directed by …" ("Created by …" for series), names in the primary colour.
    /// Interpolated `Text`, not `Text + Text` (deprecated in the 26 SDK).
    private var creditsBlock: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
            if let cast = credits.castNames {
                Text("With \(Text(cast).foregroundStyle(Theme.Palette.textPrimary))")
                    .lineLimit(2)
            }
            if let crew = credits.crewNames, let label = credits.crewLabel {
                switch label {
                case .directedBy:
                    Text("Directed by \(Text(crew).foregroundStyle(Theme.Palette.textPrimary))")
                        .lineLimit(2)
                case .createdBy:
                    Text("Created by \(Text(crew).foregroundStyle(Theme.Palette.textPrimary))")
                        .lineLimit(2)
                }
            }
        }
        .font(Theme.Font.detail)
        .foregroundStyle(Theme.Palette.textSecondary)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: DetailCinematicLayout.creditsMaxWidth, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail_credits")
    }
}
