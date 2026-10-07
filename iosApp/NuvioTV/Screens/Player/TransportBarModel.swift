import Foundation
import Combine
import SwiftUI
import CoreGraphics

/// The read side of the seek-preview thumbnail store (P2): a frame within about one GOP of `sec`,
/// or nil. The controller holds one as `seekPreviewSource`; nil means the scrub card shows time only.
protocol SeekPreviewSource: AnyObject, Sendable {
    func thumbnail(near sec: Double) async -> CGImage?
}

struct TransportSpan: Equatable, Hashable { var start: Double; var end: Double; var kind: String? }
struct TransportChapter: Equatable { let title: String; let sec: Double }
enum PillKind: String, CaseIterable { case subtitles, audio, speed, aspect, sources, episodes, more }

/// The one published transport state of the mpv player (`MPVPlaybackState.transport`): what the
/// bar draws, and what the controller's preview model writes.
@MainActor final class TransportBarModel: ObservableObject {
    @Published var positionSec: Double = 0
    @Published var durationSec: Double = 0
    @Published var previewSec: Double? = nil
    @Published var mode: TransportPreview.Mode = .idle
    @Published var bufferedRanges: [BufferedRange] = []
    @Published var skipSpans: [TransportSpan] = []
    @Published var chapters: [TransportChapter] = []
    @Published var title = ""
    @Published var metaLine = ""
    @Published var isPaused = false
    @Published var playbackSpeed: Double = 1
    @Published var showsEndTime = false
    @Published var showsClock = false
    @Published var pills: [PillKind] = []
    @Published var focusedPill: PillKind? = nil
    /// The scrub card's frame for the current preview target (nil = time only).
    @Published var previewFrame: CGImage? = nil
    /// The swipe scrub rate curve, for the probe: "o" Orivio, "b" bobsupra.
    @Published var scrubCurveCode = "o"
    /// Frames in the seek-preview store (P2-B), for the probe's `thumbs=` field.
    @Published var previewFrames: Int = 0
    /// The picture fit the Aspect pill cycles (P2).
    @Published var aspectMode: PlayerAspectMode = .fit
    /// The aspect label shown for 2 s after a cycle; nil = no flash.
    @Published var aspectFlash: String? = nil
    #if DEBUG
    /// The gesture arbiter's verdict on the last stroke ("u", "h", "v", "i").
    @Published var debugArbiter = "u"
    #endif
    var pillsEngaged: Bool { focusedPill != nil }
    /// The chapter title at `sec` (the one rule, `PlayerChapters.title(at:in:)`); nil = none or untitled.
    func chapterTitle(at sec: Double) -> String? { PlayerChapters.title(at: sec, in: chapters) }
}
