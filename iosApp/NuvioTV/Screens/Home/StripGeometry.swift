import SwiftUI
import UIKit

// Home Stage & Strip (P1 §2, plan 2026-10-03 H1/H2): the one geometry the Stage layout agrees on.
//
// The screen is split into a fixed STAGE block on top (the focused title's logo, meta line and
// synopsis over its artwork) and a STRIP below it that shows exactly one row of posters, paged one
// row at a time, with the next row's heading peeking at the bottom edge. Everything here is a pure
// function of the Poster Style, the Appearance focus flags and the live font metrics, so the stage
// frame changes only when a setting changes, never with a swap or a page.
//
// Constants are the ones the rows ACTUALLY lay out with (each is named after its source); the
// unit table in `StripGeometryTests` is the spec's §2 table.

/// The strip and stage geometry for one (Poster Size × Hide Titles × No Zoom × font) regime.
nonisolated struct StripGeometry: Equatable, Sendable {

    /// What the geometry is computed from. Production builds it with `live(style:noZoom:leadingInset:)`,
    /// which reads the live font metrics; tests pass every metric explicitly.
    nonisolated struct Inputs: Equatable, Sendable {
        var posterHeight: CGFloat
        var posterWidth: CGFloat
        var titlesShown: Bool
        var landscapeCatalogRows: Bool
        var noZoom: Bool
        /// One `Theme.Font.sectionTitle` line: 38 system, ≈38.84 Open Sans.
        var titleHeight: CGFloat
        /// A folder tile's single-line `.caption2` caption: 23 at the default text size.
        var folderCaptionHeight: CGFloat
        /// One `Theme.Font.synopsis` line: ≈30 system, ≈31.32 Open Sans.
        var synopsisLineHeight: CGFloat
        var screenHeight: CGFloat
        /// `\.railLeadingInset` (R1): 36 with the rail Always Visible, else 0.
        var leadingInset: CGFloat

        /// The caption and synopsis defaults are the SYSTEM font's numbers, not the live metrics:
        /// those are main-actor state, and a nonisolated initializer's default arguments may not
        /// read it. Live callers use `live(style:noZoom:leadingInset:)`.
        init(posterHeight: CGFloat,
             posterWidth: CGFloat,
             titlesShown: Bool,
             landscapeCatalogRows: Bool = false,
             noZoom: Bool = false,
             titleHeight: CGFloat = Theme.Font.sectionTitleLineHeight,
             folderCaptionHeight: CGFloat = StripGeometry.systemCaptionLineHeight,
             synopsisLineHeight: CGFloat = StripGeometry.systemSynopsisLineHeight,
             screenHeight: CGFloat = StripGeometry.defaultScreenHeight,
             leadingInset: CGFloat = 0) {
            self.posterHeight = posterHeight
            self.posterWidth = posterWidth
            self.titlesShown = titlesShown
            self.landscapeCatalogRows = landscapeCatalogRows
            self.noZoom = noZoom
            self.titleHeight = titleHeight
            self.folderCaptionHeight = folderCaptionHeight
            self.synopsisLineHeight = synopsisLineHeight
            self.screenHeight = screenHeight
            self.leadingInset = leadingInset
        }
    }

    /// The tallest row's height (catalog or the tallest collection row, D2), on the half-point grid.
    let rowHeight: CGFloat
    /// What the focus treatment raises a focused card by: 20, or 0 with No Zoom.
    let focusLift: CGFloat
    /// One page of the strip: the row, top-aligned, plus the lift above and below it (P).
    let pageHeight: CGFloat
    /// The next row's heading plus a gap, peeking at the strip's bottom edge.
    let peek: CGFloat
    /// The strip's height (H): one page plus the peek.
    let stripHeight: CGFloat
    /// The stage block's height: the screen minus the strip, never below `stageFloor`.
    let stageHeight: CGFloat
    /// The logo slot: 150, or 110 when the stage is shorter than 480.
    let logoSlot: CGFloat
    /// What is left for the synopsis once the logo, meta line, gaps and bottom gutter are placed.
    let synopsisSlot: CGFloat
    /// How many synopsis lines fit the slot (1…5).
    let synopsisLines: Int
    /// The stage block's top inset (S1): 120, `Theme.Size.heroForegroundTopPadNuvio`.
    let stageBlockTop: CGFloat
    /// The rows' (and the stage block's) leading inset: 140 + `\.railLeadingInset`.
    let contentLeading: CGFloat
    /// Whether the REQUESTED poster size fits. When it does not, the strip lays out at
    /// `layoutPosterHeight`, the largest poster height that leaves the stage at `stageFloor` (#23).
    let fits: Bool
    /// The poster height the strip lays out with: the request, or the clamp (#23).
    let layoutPosterHeight: CGFloat
    /// The poster height that was asked for (probe only).
    let requestedPosterHeight: CGFloat
    /// The screen height the geometry was computed against (the art mask's denominator).
    let screenHeight: CGFloat

    /// S1: the stage block's leading edge (the same inset the rows use).
    var stageBlockLeading: CGFloat { contentLeading }
    /// The rows' trailing inset inside the strip.
    var trailingMargin: CGFloat { Self.edgeMargin }

    // MARK: Constants

    nonisolated static let defaultScreenHeight: CGFloat = 1080
    /// The stage never gets shorter than this (P1 §2).
    nonisolated static let stageFloor: CGFloat = 420
    /// `Theme.Size.heroForegroundTopPadNuvio`: the stage block starts under the tab bar zone.
    nonisolated static let stageBlockTopInset: CGFloat = Theme.Size.heroForegroundTopPadNuvio
    /// `Theme.Spacing.screen` (60) + the tvOS side safe area (80): the Stage root ignores the safe
    /// area, so its rows carry both, which is exactly where Classic's rows sit and what
    /// `RowEdgeMargins.standard` assumes.
    nonisolated static let edgeMargin: CGFloat = 140
    /// `Theme.Size.heroLogoSlotHeight`.
    nonisolated static let logoSlotFull: CGFloat = Theme.Size.heroLogoSlotHeight
    /// `Theme.Size.heroLogoSlotHeightPinned`.
    nonisolated static let logoSlotCompact: CGFloat = Theme.Size.heroLogoSlotHeightPinned
    /// Below this stage height the logo slot compresses to `logoSlotCompact`.
    nonisolated static let compactLogoBelowStage: CGFloat = 480
    /// `Theme.Size.heroPinnedSlotGap`.
    nonisolated static let slotGap: CGFloat = Theme.Size.heroPinnedSlotGap
    /// `Theme.Size.heroMetaSlotHeight`.
    nonisolated static let metaSlot: CGFloat = Theme.Size.heroMetaSlotHeight
    /// `Theme.Spacing.lg`: the stage block's bottom gutter. The strip's soft top edge (§3.4) lives
    /// in exactly this band.
    nonisolated static let stageBottomGap: CGFloat = Theme.Spacing.lg
    /// The hero-off panel's cap.
    nonisolated static let maxSynopsisLines = 5
    /// `HomeHeroForeground`'s `lineTolerance`: a slot short of a whole line by less than this still
    /// gets the line (the fixed frame clips an overhang that small).
    nonisolated static let synopsisLineTolerance: CGFloat = 1
    /// The gap under the peeking heading.
    nonisolated static let peekGap: CGFloat = 6
    /// System-font defaults for `Inputs` (see its init).
    nonisolated static let systemCaptionLineHeight: CGFloat = 23
    nonisolated static let systemSynopsisLineHeight: CGFloat = 30

    // MARK: Make

    static func make(_ i: Inputs) -> StripGeometry {
        let lift: CGFloat = i.noZoom ? 0 : Theme.Size.heroPinnedRowFocusLiftAllowance
        let peek = pixelCeil(i.titleHeight + peekGap)
        let requestedRow = rowHeight(i, posterHeight: i.posterHeight)
        let requestedStage = i.screenHeight - (requestedRow + 2 * lift + peek)
        let fits = requestedStage >= stageFloor

        var layoutPoster = i.posterHeight
        var row = requestedRow
        if !fits {
            // #23: every poster-dependent row is the poster height plus a constant, so the largest
            // poster that leaves the stage at the floor is one subtraction. `min` absorbs float
            // noise in the re-derived row so the stage can never land a half point under the floor.
            let budget = i.screenHeight - stageFloor - 2 * lift - peek
            layoutPoster = max(1, budget - dominantConstant(i))
            row = min(rowHeight(i, posterHeight: layoutPoster), budget)
        }

        let page = row + 2 * lift
        let strip = page + peek
        let stage = max(stageFloor, i.screenHeight - strip)
        let logo = stage < compactLogoBelowStage ? logoSlotCompact : logoSlotFull
        let synopsis = stage - stageBlockTopInset - logo - slotGap - metaSlot - slotGap - stageBottomGap

        return StripGeometry(rowHeight: row,
                             focusLift: lift,
                             pageHeight: page,
                             peek: peek,
                             stripHeight: strip,
                             stageHeight: stage,
                             logoSlot: logo,
                             synopsisSlot: synopsis,
                             synopsisLines: synopsisLines(slot: synopsis, lineHeight: i.synopsisLineHeight),
                             stageBlockTop: stageBlockTopInset,
                             contentLeading: edgeMargin + i.leadingInset,
                             fits: fits,
                             layoutPosterHeight: layoutPoster,
                             requestedPosterHeight: i.posterHeight,
                             screenHeight: i.screenHeight)
    }

    /// `CatalogRowView` without pinned reaches: heading, `md` 16, the shelf's `lg` 24 top padding,
    /// the art, the caption chrome when titles show (`PinnedRowTitle.cardLockupCaptionChrome`), and
    /// the shelf's `lg` 24 bottom padding.
    static func catalogRowHeight(art: CGFloat, titles: Bool, titleHeight: CGFloat) -> CGFloat {
        titleHeight + Theme.Spacing.md + Theme.Spacing.lg + art
            + (titles ? PinnedRowTitle.cardLockupCaptionChrome : 0) + Theme.Spacing.lg
    }

    /// `CollectionRowView` without pinned reaches, at its tallest tile (a poster-shaped folder with
    /// its per-folder caption): heading, `md` 16, `sm` 12 top padding, the poster, `sm` 12 caption
    /// spacing, the caption line, `sm` 12 bottom padding.
    static func collectionRowHeightMax(posterHeight: CGFloat, titleHeight: CGFloat, captionLine: CGFloat) -> CGFloat {
        titleHeight + Theme.Spacing.md + Theme.Spacing.sm + posterHeight + Theme.Spacing.sm
            + captionLine + Theme.Spacing.sm
    }

    /// §3.4: a page's opacity by its position in the strip's scroll space. The page at rest (minY 0)
    /// is exactly 1, the peeking page (minY = P) reads 0.6, and a page leaving upward (minY < 0) is
    /// left to the strip's top-edge mask.
    static func pageOpacity(minY: CGFloat, pageHeight: CGFloat) -> Double {
        guard minY > 0, pageHeight > 0 else { return 1 }
        return Double(1 - 0.4 * min(minY / pageHeight, 1))
    }

    /// Rounds up to the half-point grid. The 1e-6 slack (on the doubled value) keeps an exact half
    /// point computed with float noise above it (475.50000000000006) from rounding up a whole step.
    static func pixelCeil(_ x: CGFloat) -> CGFloat {
        (x * 2 - 1e-6).rounded(.up) / 2
    }

    /// How many whole synopsis lines fit `slot`, 1…`maxSynopsisLines`.
    static func synopsisLines(slot: CGFloat, lineHeight: CGFloat) -> Int {
        guard lineHeight > 0, slot > 0 else { return 1 }
        let whole = Int(((slot + synopsisLineTolerance) / lineHeight).rounded(.down))
        return min(maxSynopsisLines, max(1, whole))
    }

    // MARK: Private

    private static func rowHeight(_ i: Inputs, posterHeight: CGFloat) -> CGFloat {
        let art = i.landscapeCatalogRows ? Theme.Size.landscapeHeight : posterHeight
        let catalog = catalogRowHeight(art: art, titles: i.titlesShown, titleHeight: i.titleHeight)
        let collection = collectionRowHeightMax(posterHeight: posterHeight,
                                                titleHeight: i.titleHeight,
                                                captionLine: i.folderCaptionHeight)
        return pixelCeil(max(catalog, collection))
    }

    /// The constant part of the tallest POSTER-DEPENDENT row type. Landscape catalog rows do not
    /// grow with the poster, so only the collection row counts then.
    private static func dominantConstant(_ i: Inputs) -> CGFloat {
        let collection = collectionRowHeightMax(posterHeight: 0,
                                                titleHeight: i.titleHeight,
                                                captionLine: i.folderCaptionHeight)
        guard !i.landscapeCatalogRows else { return collection }
        return max(collection, catalogRowHeight(art: 0, titles: i.titlesShown, titleHeight: i.titleHeight))
    }
}

extension StripGeometry.Inputs {
    /// Production inputs: the Poster Style from the environment and the LIVE font metrics (which
    /// follow the Open Sans choice and Larger Text). The folder Rows page (W2-B) builds its geometry
    /// the same way, passing its own `\.railLeadingInset`.
    @MainActor
    static func live(style: PosterStyle, noZoom: Bool, leadingInset: CGFloat) -> StripGeometry.Inputs {
        StripGeometry.Inputs(posterHeight: style.height,
                             posterWidth: style.width,
                             titlesShown: style.showTitle,
                             landscapeCatalogRows: style.landscapeCatalogRows,
                             noZoom: noZoom,
                             titleHeight: Theme.Font.sectionTitleLineHeight,
                             folderCaptionHeight: Theme.Font.uiFont(for: .caption2).lineHeight.rounded(.up),
                             synopsisLineHeight: Theme.Font.synopsisLineHeight,
                             leadingInset: leadingInset)
    }
}

// MARK: - Rail inset (R1)

private struct RailLeadingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// R1 (P4): how far an Always Visible navigation rail pushes a tab root's content right. The Stage
    /// root ignores the safe area (and with it the shell's reserved width, UIKit safe area on the tab
    /// controller), so it reads this instead and adds it to `StripGeometry.contentLeading`. Default 0;
    /// P4's `.railTabRoot` sets it.
    var railLeadingInset: CGFloat {
        get { self[RailLeadingInsetKey.self] }
        set { self[RailLeadingInsetKey.self] = newValue }
    }
}

// MARK: - Tuning knobs (§8, #6)

/// Launch-latched knobs for the strip's page glide, the stage's swap timing and the focus-memory
/// fallback. Not `#if DEBUG`: Christian's device pass sets them on whatever binary is installed
/// (the `TabBarRestFix` house rule). Each lands in the argument domain of `UserDefaults.standard`:
///
///     -debug.stripPageSeconds 0.3…1.0    (default 0.5)
///     -debug.stageSwapPause 0.2…0.8      (default 0.45)
///     -debug.stageFadeOut 0.05…0.4       (default 0.15)
///     -debug.stageFadeIn 0.05…0.4        (default 0.20)
///     -debug.stripFocusMemory off        (Down/Up land geometrically; memory serves Menu and rail
///                                         restores only — the §3.3 / Q5 fallback)
nonisolated enum StageStripTuning {
    static let defaultPageSeconds: TimeInterval = 0.5

    /// The strip's page animation length.
    static let pageSeconds: TimeInterval =
        knob("debug.stripPageSeconds", in: 0.3...1.0) ?? defaultPageSeconds

    /// The stage's swap timing: `TextSwapTiming.stage` (0.45 / 0.15 / 0.20) unless a knob is set.
    static let swapTiming: TextSwapTiming = TextSwapTiming(
        pause: knob("debug.stageSwapPause", in: 0.2...0.8) ?? TextSwapTiming.stage.pause,
        fadeOut: knob("debug.stageFadeOut", in: 0.05...0.4) ?? TextSwapTiming.stage.fadeOut,
        fadeIn: knob("debug.stageFadeIn", in: 0.05...0.4) ?? TextSwapTiming.stage.fadeIn
    )

    /// Whether remembered cards drive `.defaultFocus` on Down/Up (§3.3). Gate G-F (end-of-Wave-2 FA87
    /// walk, 2026-10-05): with the strip's rows in a `LazyVStack` it seemed to fail, because the row
    /// above was rebuilt while focus landed on its remembered card; with the mounted window
    /// (`StripMountWindow`) Up lands on that card on Home and on the folder page, so memory stays on.
    /// `-debug.stripFocusMemory off` gives the Q5 fallback (Down/Up land geometrically; memory then
    /// serves Menu and rail restores only).
    static let focusMemoryDefaultFocus: Bool = {
        guard let raw = UserDefaults.standard.string(forKey: "debug.stripFocusMemory")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return true }
        return !["off", "no", "0", "false"].contains(raw)
    }()

    /// A positive number under `key`, clamped into `range`; nil when unset or not positive.
    static func knob(_ key: String, in range: ClosedRange<Double>,
                     defaults: UserDefaults = .standard) -> TimeInterval? {
        guard defaults.object(forKey: key) != nil else { return nil }
        let value = defaults.double(forKey: key)
        guard value > 0 else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
