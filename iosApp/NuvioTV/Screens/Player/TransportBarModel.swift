import Foundation
import Combine
import SwiftUI

struct TransportSpan: Equatable, Hashable { var start: Double; var end: Double; var kind: String? }
struct TransportChapter: Equatable { let title: String; let sec: Double }
enum PillKind: String, CaseIterable { case subtitles, audio, speed, sources, episodes, more }

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
    var pillsEngaged: Bool { focusedPill != nil }
}
