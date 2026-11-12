import Foundation

/// Every full-screen presentation `DetailView` can put over its own page (covers, the shuffle
/// sheet, the library alert). `.onDisappear` never fires under any of them, so the format-badge
/// probe stops on `isPresented` instead (`\.detailCoverPresented`). A presentation added to the
/// page belongs here: `DetailCoverStatesTests` fails until its flag is listed there, so a new cover
/// cannot be forgotten silently. Pure: no SwiftUI, one Bool per presentation.
struct DetailCoverStates: Equatable {
    /// `.fullScreenCover(isPresented: $showStreams)`.
    var streams = false
    /// `.fullScreenCover(item: $seriesPlay)`.
    var seriesPlay = false
    /// The trailer request (`model.trailerPlayback`), set before the cover is shown.
    var trailerPlayback = false
    /// What the trailer cover itself shows (`presentedTrailer`).
    var presentedTrailer = false
    /// `showSynopsisSheet`: the hero's `.fullScreenCover` (DetailCinematicHero).
    var synopsisSheet = false
    /// `showAboutOverviewSheet`: the About section's `.fullScreenCover`.
    var aboutOverviewSheet = false
    /// `.sheet(isPresented: $showShuffleSheet)`.
    var shuffleSheet = false
    /// The failed-library `.alert`.
    var libraryAlert = false

    var isPresented: Bool {
        streams || seriesPlay || trailerPlayback || presentedTrailer
            || synopsisSheet || aboutOverviewSheet || shuffleSheet || libraryAlert
    }
}
