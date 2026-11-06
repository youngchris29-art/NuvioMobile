import CoreGraphics

/// One place for the Cinematic detail page geometry, so a visual pass can tune it without
/// hunting through the hero and the page. `nonisolated` and free of `Theme` references like
/// `DetailCinematicLayout`, so unit tests can read it synchronously. Classic geometry is not
/// part of this type.
nonisolated enum DetailGeometry {
    // MARK: Page

    /// Cinematic page side inset (leading and trailing). Was 60 (`Theme.Spacing.screen`).
    /// `DetailView` still pads the page with `Theme.Spacing.screen` on every side; it must read
    /// this token for the Cinematic horizontal padding.
    static let pageSideInset: CGFloat = 80
    /// Cinematic page top and bottom inset. Unchanged at 60 (== `Theme.Spacing.screen`).
    static let pageVerticalInset: CGFloat = 60
    /// Gap between the page's rows. == `Theme.Spacing.lg + Theme.Spacing.sm`.
    static let pageRowSpacing: CGFloat = 36

    // MARK: Hero

    /// Hero text column (logo, meta line, ratings, synopsis, actions). Was 900.
    static let heroTextColumnMaxWidth: CGFloat = 680
    /// Right-aligned credits block beside the action row. Unchanged.
    static let creditsMaxWidth: CGFloat = 640
    static let logoSlotHeight: CGFloat = 180
    static let logoMaxWidth: CGFloat = 600
    static let metaLineHeight: CGFloat = 40
    static let ratingsSlotHeight: CGFloat = 44
    static let peekBand: CGFloat = 140
    static let heroMinimumHeight: CGFloat = 520

    // MARK: Shelves (defined for a later pass; not yet applied)

    static let wideCardWidth: CGFloat = 410
    static let wideCardGap: CGFloat = 40
    static let personCardWidth: CGFloat = 260
}
