import Foundation

/// BUG-198 (GitHub #8, Batch P Wave 2): whether the Detail page's background (hero) trailer may run.
/// Every cover the page can put over itself is an input here, so adding a cover means adding a
/// parameter — the series Play cover was missing from the inline rule for a month, and the hero
/// trailer kept playing (with sound) under the series source picker and the player.
nonisolated enum DetailTrailerGate {
    struct Inputs: Equatable {
        /// Settings › Detail Page › Background Trailer.
        var enabled: Bool
        /// A trailer URL has resolved for this title.
        var hasTrailer: Bool
        /// FEAT-8: the duration timer (or a stop) has faded the trailer back to the still backdrop.
        var stopped: Bool
        /// FEAT-87: Start Delay has not elapsed yet on this page's first appearance
        /// (`DetailTrailerStartDelay.holdsBackground`).
        var startDelayHeld: Bool
        /// The film stream picker cover (`showStreams`).
        var filmPickerShown: Bool
        /// The series Play cover: the series source picker and the player (`seriesPlay != nil`).
        var seriesPlayShown: Bool
        /// The full-screen trailer cover (`model.trailerPlayback != nil`).
        var fullScreenTrailerShown: Bool
        /// FEAT-35 (correction F8): the full-synopsis cover.
        var synopsisSheetShown: Bool
        /// The episode shuffle sheet (`showShuffleSheet`); its dismissal hands off to the series cover.
        var shuffleSheetShown: Bool
    }

    static func isActive(_ i: Inputs) -> Bool {
        i.enabled && i.hasTrailer && !i.stopped && !i.startDelayHeld
            && !i.filmPickerShown && !i.seriesPlayShown && !i.fullScreenTrailerShown
            && !i.synopsisSheetShown && !i.shuffleSheetShown
    }
}
