import Foundation

/// What one click on Left/Right does in the mpv player (`player.edgeClickMode`, device-local).
enum EdgeClickMode: String { case skip10, chapter }

/// The resolved click: a relative seek (P1's ±10 s) or an absolute chapter start.
enum EdgeClickAction: Equatable { case relative(Double), absolute(Double) }

/// Chapters of the playing file (mpv `chapter-list`), pure: parsing, the title at a time, and the
/// edge-click rule. The controller reads the list on `eventQueue` at FILE_LOADED and publishes it
/// as `TransportBarModel.chapters`; the bar's ticks, the scrub card's title, the Chapters tab and
/// the edge click all read it from there.
enum PlayerChapters {
    /// mpv's `chapter-list` printed as JSON (`mpv_get_property_string` on a node property): a
    /// top-level array of `{"title": String?, "time": Number}`. `time` is required and finite (a
    /// slightly negative one is clamped to 0, see `clampedTime`);
    /// a missing title is "". Malformed JSON or a non-array → []. Sorted by time, exact-duplicate
    /// times dropped (the first kept).
    static func parse(json: String) -> [TransportChapter] {
        guard let data = json.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        var out: [TransportChapter] = []
        for item in array {
            guard let object = item as? [String: Any], let number = object["time"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            guard let sec = clampedTime(number.doubleValue) else { continue }
            let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            out.append(TransportChapter(title: title, sec: sec))
        }
        return normalized(out)
    }

    /// The indexed sub-property fallback (`chapter-list/N/title`, `chapter-list/N/time`), for a
    /// build whose string form of the node is not JSON.
    static func parseIndexed(count: Int, title: (Int) -> String?, time: (Int) -> Double) -> [TransportChapter] {
        guard count > 0 else { return [] }
        var out: [TransportChapter] = []
        for i in 0..<count {
            guard let sec = clampedTime(time(i)) else { continue }
            out.append(TransportChapter(title: title(i)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", sec: sec))
        }
        return normalized(out)
    }

    /// mpv reports chapter times relative to the container's start time, so the first chapter of
    /// a file whose streams start a few ms late reads slightly negative (the fixture: −0.023).
    /// A small negative time is the start; anything further back, or not finite, is dropped.
    static let negativeTimeSlack: Double = 1

    private static func clampedTime(_ sec: Double) -> Double? {
        guard sec.isFinite, sec >= -negativeTimeSlack else { return nil }
        return max(sec, 0)
    }

    private static func normalized(_ chapters: [TransportChapter]) -> [TransportChapter] {
        // Stable sort keeps the first of equal times first; then drop exact duplicates.
        let sorted = chapters.enumerated().sorted { ($0.element.sec, $0.offset) < ($1.element.sec, $1.offset) }.map(\.element)
        var out: [TransportChapter] = []
        for c in sorted where out.last?.sec != c.sec { out.append(c) }
        return out
    }

    /// The index of the chapter `sec` is in: the last one starting at or before `sec + 0.01`.
    static func index(at sec: Double, in chapters: [TransportChapter]) -> Int? {
        chapters.lastIndex { $0.sec <= sec + 0.01 }
    }

    /// The title of the chapter `sec` is in; nil before the first chapter or when that chapter has
    /// no title (the scrub card then shows the time only).
    static func title(at sec: Double, in chapters: [TransportChapter]) -> String? {
        guard let i = index(at: sec, in: chapters) else { return nil }
        let title = chapters[i].title
        return title.isEmpty ? nil : title
    }

    /// The Chapters tab's row title: the chapter's own title, or "Chapter N" (1-based) when empty.
    static func displayTitle(_ chapter: TransportChapter, index: Int) -> String {
        chapter.title.isEmpty ? String(localized: "Chapter \(index + 1)") : chapter.title
    }

    /// One click on Left (`direction` < 0) or Right from `baseSec`.
    /// - Skip 10 s, or fewer than 2 chapters: ±`skipSec`, relative.
    /// - Chapter, Right: the first chapter starting after `baseSec + 0.5`; inside the last chapter, +`skipSec`.
    /// - Chapter, Left: the last chapter starting before `baseSec − 3` (a click within 3 s of a
    ///   chapter start goes to the one before, as Infuse does); none → the start (0).
    static func edgeClick(mode: EdgeClickMode, direction: Int, baseSec: Double,
                          chapters: [TransportChapter], skipSec: Double = 10) -> EdgeClickAction {
        let dir: Double = direction < 0 ? -1 : 1
        guard mode == .chapter, chapters.count >= 2 else { return .relative(dir * skipSec) }
        if dir > 0 {
            if let next = chapters.first(where: { $0.sec > baseSec + 0.5 }) { return .absolute(next.sec) }
            return .relative(skipSec)
        }
        if let previous = chapters.last(where: { $0.sec < baseSec - 3 }) { return .absolute(previous.sec) }
        return .absolute(0)
    }
}
