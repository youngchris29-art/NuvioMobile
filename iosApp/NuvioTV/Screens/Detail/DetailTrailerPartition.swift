import Foundation
import SharedCore

/// Apple TV splits a title's videos into a "Trailers" row and a "Bonus" row. Pure partition of the
/// Detail page's `MetaTrailer` list (TMDB video `type`; add-on metas fall back to the name).
/// `MetaTrailer` carries no duration field, so there is deliberately no `durationLabel`.
nonisolated enum DetailTrailerPartition {
    /// Per-row cap (the single row used to `prefix(10)`), applied after the split, per group.
    static let perRowCap = 10

    /// The generic core, so the rule is testable without constructing Kotlin objects.
    /// `type` is the TMDB video type (nil/blank = unknown), `name` the display name fallback.
    static func split<T>(
        _ items: [T],
        type: (T) -> String?,
        name: (T) -> String?
    ) -> (trailers: [T], bonus: [T]) {
        var trailers: [T] = []
        var bonus: [T] = []
        for item in items {
            if isTrailer(type: type(item), name: name(item)) {
                trailers.append(item)
            } else {
                bonus.append(item)
            }
        }
        // An empty trailers group is not promoted from bonus: both groups stay as classified.
        return (Array(trailers.prefix(perRowCap)), Array(bonus.prefix(perRowCap)))
    }

    static func split(_ items: [MetaTrailer]) -> (trailers: [MetaTrailer], bonus: [MetaTrailer]) {
        split(items, type: { $0.type }, name: { $0.displayName ?? $0.name })
    }

    static func isTrailer(type: String?, name: String?) -> Bool {
        let t = (type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !t.isEmpty {
            return t == "trailer" || t == "teaser"
        }
        let n = (name ?? "").lowercased()
        return n.contains("trailer") || n.contains("teaser")
    }
}
