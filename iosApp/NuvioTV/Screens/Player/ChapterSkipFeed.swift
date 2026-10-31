import Foundation
import SharedCore

/// Container chapters → chapter-derived skip intervals (upstream 06f08dd8..1755d483, shared
/// `ChapterSkipIntervals`). Both engines already publish `[TransportChapter]` (mpv: `readChapters`
/// and the duration-change republish; native: the coordinator's remux chapters); the feed turns
/// them plus the duration into `SkipInterval`s. It computes only when Skip Intro is on, the
/// duration is known and the (chapters, duration) pair changed since the last computation, so the
/// engines may call it on every chapter or duration publish but never need to on the tick.
struct ChapterSkipFeed {
    /// The current chapter-derived intervals (empty with Skip Intro off).
    private(set) var intervals: [SkipInterval] = []
    /// The Skip Intro setting at the last `update` (nil before the first one): an engine compares
    /// it with the live setting to recompute when the setting is toggled during playback.
    private(set) var skipIntroEnabled: Bool?
    private var lastChapters: [TransportChapter]?
    private var lastDurationMs: Int64?

    /// The new interval list when it changed, nil when there is nothing new to merge.
    mutating func update(chapters: [TransportChapter], durationSec: Double, skipIntroEnabled: Bool) -> [SkipInterval]? {
        self.skipIntroEnabled = skipIntroEnabled
        guard skipIntroEnabled else {
            lastChapters = nil
            lastDurationMs = nil
            guard !intervals.isEmpty else { return nil }
            intervals = []
            return []
        }
        guard durationSec.isFinite, durationSec > 0 else { return nil }
        let durationMs = Self.ms(durationSec)
        if chapters == lastChapters, durationMs == lastDurationMs { return nil }
        lastChapters = chapters
        lastDurationMs = durationMs
        let next = Self.intervals(chapters: chapters, durationMs: durationMs)
        guard next != intervals else { return nil }
        intervals = next
        return next
    }

    /// Pure conversion: the shared title matcher over the chapters (sorted, as both engines
    /// publish them). An untitled chapter is passed as nil, which the matcher never classifies.
    static func intervals(chapters: [TransportChapter], durationMs: Int64) -> [SkipInterval] {
        guard chapters.count >= 2, durationMs > 0 else { return [] }
        let mapped = chapters.map { chapter in
            PlayerChapter(startMs: ms(chapter.sec), title: chapter.title.isEmpty ? nil : chapter.title)
        }
        return ChapterSkipIntervals.shared.fromChapters(chapters: mapped, durationMs: durationMs)
    }

    private static func ms(_ seconds: Double) -> Int64 {
        let value = (max(0, seconds) * 1000).rounded()   // NaN → 0
        guard value < 9.2e18 else { return Int64.max }
        return Int64(value)
    }
}

/// The two skip sources of one playback and their merge (upstream `recomputeMergedSkipIntervals`):
/// per category (opening / ending / recap) chapters win and the provider fetch fills the gaps,
/// uncategorised intervals (movie credits, post-credits) are kept from both, and a movie with any
/// IntroDB data keeps the IntroDB list. Each screen re-merges whenever either side changes.
struct SkipIntervalSources {
    /// The provider fetch's answer (IntroDB / AniSkip / Anime-Skip).
    var api: [SkipInterval] = []
    /// `ChapterSkipFeed`'s answer.
    var chapters: [SkipInterval] = []

    func merged(isMovie: Bool) -> [SkipInterval] {
        ChapterSkipIntervalsKt.mergeSkipIntervals(apiIntervals: api, chapterIntervals: chapters, isMovie: isMovie)
    }

    /// Upstream's rule: the content type, not the season, decides.
    static func isMovie(contentType: String) -> Bool {
        contentType.lowercased() == "movie"
    }
}
