import CoreGraphics

/// One place for the Cinematic detail page geometry, so a visual pass can tune it without
/// hunting through the hero and the page. `nonisolated` and free of `Theme` references like
/// `DetailCinematicLayout`, so unit tests can read it synchronously. Classic geometry is not
/// part of this type.
nonisolated enum DetailGeometry {
    // MARK: Page

    /// Cinematic page side inset (leading and trailing), inside the tvOS horizontal safe area:
    /// 80 + 60 = 140 pt from the bezel, as before the Apple-style pass (== `Theme.Spacing.screen`).
    static let pageSideInset: CGFloat = 60
    /// Apple-style page side inset, measured from the BEZEL: the scroll content ignores the
    /// horizontal safe area (so focus halos and shelves bleed to the screen edge unclipped) and
    /// pads itself this far instead, which puts every row 80 pt in, as in the Apple TV app.
    static let appleStylePageSideInset: CGFloat = 80
    /// Cinematic page top and bottom inset. Unchanged at 60 (== `Theme.Spacing.screen`).
    static let pageVerticalInset: CGFloat = 60
    /// Gap between the page's rows. == `Theme.Spacing.lg + Theme.Spacing.sm`.
    static let pageRowSpacing: CGFloat = 36

    /// The page's horizontal placement per layout (`DetailView`'s scroll content).
    struct PageInsets: Equatable {
        let leading: CGFloat
        let trailing: CGFloat
        /// The scroll content ignores the horizontal safe area (Apple-style only).
        let ignoresSideSafeArea: Bool
    }

    /// - Parameters:
    ///   - appleStyle: the user's choice is Apple-style (`DetailLayout.appleStyle`).
    ///   - cinematicBase: the visual base is Cinematic (Cinematic and Apple-style); false = Classic.
    ///   - screenPadding: Classic's padding (`Theme.Spacing.screen`, 60).
    ///   - railLeadingExtra: the rail's extra leading safe area (`\.railLeadingInset`; 0 unless the
    ///     rail is Always Visible in Centre). Apple-style ignores the safe area, so it adds this
    ///     back itself and never slides under the rail.
    static func pageInsets(appleStyle: Bool, cinematicBase: Bool, screenPadding: CGFloat,
                           railLeadingExtra: CGFloat) -> PageInsets {
        if appleStyle {
            return PageInsets(leading: appleStylePageSideInset + railLeadingExtra,
                              trailing: appleStylePageSideInset, ignoresSideSafeArea: true)
        }
        let side = cinematicBase ? pageSideInset : screenPadding
        return PageInsets(leading: side, trailing: side, ignoresSideSafeArea: false)
    }

    /// The rows' distance to the visible screen edges for their edge fade, from the host's value
    /// (`\.rowEdgeMargins`, measured for content padded `screenPadding` inside the safe area).
    /// Inside the safe area the page's own inset replaces `screenPadding`; Apple-style's content
    /// ignores the side safe area and pads from the bezel, so its margin is its padding:
    /// host − `screenPadding` (the host's leading already carries the rail extra).
    static func rowEdgeMargins(host: (leading: CGFloat, trailing: CGFloat), insets: PageInsets,
                               screenPadding: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        if insets.ignoresSideSafeArea {
            return (host.leading - screenPadding, host.trailing - screenPadding)
        }
        return (host.leading + insets.leading - screenPadding, host.trailing + insets.trailing - screenPadding)
    }

    // MARK: Hero

    /// Hero text column (logo, meta line, ratings, synopsis, actions). Was 900.
    static let heroTextColumnMaxWidth: CGFloat = 680
    /// Right-aligned credits block beside the action row. Unchanged.
    static let creditsMaxWidth: CGFloat = 640
    static let logoSlotHeight: CGFloat = 180
    static let logoMaxWidth: CGFloat = 600
    static let metaLineHeight: CGFloat = 40
    static let ratingsSlotHeight: CGFloat = 44
    /// The format-badge row's reserved slot (present only while the setting is on and the title has a request): one `Theme.Font.meta` line plus the 1 pt chip stroke and padding.
    static let formatBadgeRowHeight: CGFloat = 40
    static let peekBand: CGFloat = 140
    /// Apple-style's peek: the first row's title and the top of its cards show about 60 pt under
    /// the hero at rest (Cinematic and Classic keep `peekBand`).
    static let appleStylePeekBand: CGFloat = 60
    static func peekBand(appleStyle: Bool) -> CGFloat { appleStyle ? appleStylePeekBand : peekBand }
    static let heroMinimumHeight: CGFloat = 520

    // MARK: Shelves (Apple-style; `DetailWideCard`, `DetailPosterShelfCard`, the Cast & Crew avatar)

    static let wideCardWidth: CGFloat = 410
    static let wideCardGap: CGFloat = 40
    static let personCardWidth: CGFloat = 260
    /// More Like This / collection poster cards: 260 wide, 2:3.
    static let posterCardWidth: CGFloat = 260
    static let posterCardHeight: CGFloat = 390
}
