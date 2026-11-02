import Foundation
import Combine
import SwiftUI
import CoreGraphics

/// The read side of the seek-preview thumbnail store (P2): a frame within about one GOP of `sec`,
/// or nil. The controller holds one as `seekPreviewSource`; nil means the scrub card shows time only.
protocol SeekPreviewSource: AnyObject, Sendable {
    func thumbnail(near sec: Double) async -> CGImage?
    /// P3: the frame plus its stamp and origin, so the scrub path can tell a near hit from a far one.
    func match(near sec: Double) async -> SeekPreviewMatch?
    /// BUG-181 (Steven rc7): the stored frame nearest `sec` at any distance (nil only when the
    /// store is empty). The scrub card shows it when `match(near:)` misses, so a Dolby Vision file
    /// (decode refuses DV P5, harvested frames only) never shows an empty card.
    func nearest(to sec: Double) async -> SeekPreviewMatch?
}

/// Where a stored preview frame came from (P3): played by the viewer, or decoded ahead of them.
nonisolated enum PreviewFrameOrigin: String, Sendable { case harvest, decode }

/// A seek-preview lookup hit: the frame, the time it shows, and its origin.
nonisolated struct SeekPreviewMatch: @unchecked Sendable {
    let image: CGImage
    let sec: Double
    let origin: PreviewFrameOrigin
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
    /// Insights (2026-11-01): the text pills under the times row (Info · Cast · Chapters · Up Next),
    /// fed from `PlayerInfoPill.visible(for:)`. Drawn non-focusable like the discs: the controller
    /// routes the remote and publishes `focusedInfoPill`.
    @Published var infoPills: [PlayerInfoPill] = []
    @Published var focusedInfoPill: PlayerInfoPill? = nil
    /// The pill whose content shelf is open over the lower screen; nil = none.
    @Published var openInfoPill: PlayerInfoPill? = nil
    /// The tool disc whose popover is open above it; nil = none. Aspect never opens one.
    @Published var openPopover: PillKind? = nil
    /// The scrub card's frame for the current preview target (nil = no frame yet).
    @Published var previewFrame: CGImage? = nil
    /// BUG-181 (Steven rc7): seek previews are on for this file (a harvest or the decoder can fill
    /// the store), so a scrub with no frame yet draws a placeholder card instead of an empty slot.
    /// False (Seek Preview Frames Off, harvest off after a crash) keeps the time-only card.
    @Published var previewCardEnabled = false
    /// The swipe scrub rate curve, for the probe: "o" Orivio, "b" bobsupra.
    @Published var scrubCurveCode = "o"
    /// Frames in the seek-preview store (P2-B), for the probe's `thumbs=` field.
    @Published var previewFrames: Int = 0
    /// Frames the keyframe thumbnailer stored (P3), for the probe's `decoded=` field.
    @Published var decodedFrames: Int = 0
    /// The stamp of the frame on the scrub card (P3), for the probe's `fsec=` field.
    @Published var previewFrameSec: Double? = nil
    /// The picture fit the Aspect pill cycles (P2).
    @Published var aspectMode: PlayerAspectMode = .fit
    /// The aspect label shown for 2 s after a cycle; nil = no flash.
    @Published var aspectFlash: String? = nil
    #if DEBUG
    /// The gesture arbiter's verdict on the last stroke ("u", "h", "v", "i").
    @Published var debugArbiter = "u"
    /// The resize mode the profile holds and the Aspect pill's synced writes this session, for
    /// the probe's `stored=` / `aw=` fields (review r1 P2 #1).
    @Published var debugAspectStored: PlayerAspectMode = .fit
    @Published var debugAspectWrites = 0
    #endif
    var pillsEngaged: Bool { focusedPill != nil }
    /// A popover or a content shelf is on screen.
    var overlayOpen: Bool { openPopover != nil || openInfoPill != nil }
    /// The chapter title at `sec` (the one rule, `PlayerChapters.title(at:in:)`); nil = none or untitled.
    func chapterTitle(at sec: Double) -> String? { PlayerChapters.title(at: sec, in: chapters) }
}
