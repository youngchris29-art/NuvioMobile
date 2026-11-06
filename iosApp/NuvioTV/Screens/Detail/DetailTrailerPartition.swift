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
    /// `localizedTrailer`: the word Kotlin fills a missing type with (see `sharedTrailerWord`).
    static func split<T>(
        _ items: [T],
        type: (T) -> String?,
        name: (T) -> String?,
        localizedTrailer: String? = nil
    ) -> (trailers: [T], bonus: [T]) {
        split(items, type: type, names: { [name($0)] }, localizedTrailer: localizedTrailer)
    }

    /// `names`: every name the item carries; an untyped item is a trailer when ANY of them says so.
    static func split<T>(
        _ items: [T],
        type: (T) -> String?,
        names: (T) -> [String?],
        localizedTrailer: String? = nil
    ) -> (trailers: [T], bonus: [T]) {
        var trailers: [T] = []
        var bonus: [T] = []
        for item in items {
            if isTrailer(type: type(item), names: names(item), localizedTrailer: localizedTrailer) {
                trailers.append(item)
            } else {
                bonus.append(item)
            }
        }
        // An empty trailers group is not promoted from bonus: both groups stay as classified.
        return (Array(trailers.prefix(perRowCap)), Array(bonus.prefix(perRowCap)))
    }

    /// A video whose source sent no type (`typeProvided` false: Kotlin filled `type` with the
    /// localized "Trailer" default) is classified by name, so an untyped add-on "Behind the Scenes"
    /// lands in Bonus instead of taking a trailer slot. On an English device that default cannot
    /// be told apart from a real "Trailer" type by its text alone, hence the flag.
    ///
    /// Both the source `name` and the `displayName` are checked: a display label ("Season 1",
    /// TMDB's generated season label) can sit over a name that says trailer, or over the parser's
    /// localized "Trailer" default, and must not hide it.
    static func split(_ items: [MetaTrailer],
                      localizedTrailer: String = sharedTrailerWord) -> (trailers: [MetaTrailer], bonus: [MetaTrailer]) {
        split(items, type: { $0.typeProvided ? $0.type : nil }, names: { [$0.name, $0.displayName] },
              localizedTrailer: localizedTrailer)
    }

    /// The shared module fills a video with no type with `resourceString("Trailer",
    /// StringKey.generic_trailer)` (`MetaDetailsParser`, `TmdbMetadataService`), which the tvOS app
    /// answers from the "Shared" catalog (`SharedStringProvider`): "Bande-annonce" on a French
    /// device. Read the same entry the same way, so such a video still counts as a trailer.
    ///
    /// An untyped video's NAME is that same word when the source gave none ("Bande-annonce",
    /// "Tráiler"), so the name fallback matches it too (`isTrailer`).
    static var sharedTrailerWord: String { sharedTrailerWord(bundle: .main) }

    static func sharedTrailerWord(bundle: Bundle) -> String {
        bundle.localizedString(forKey: "generic_trailer", value: "Trailer", table: "Shared")
    }

    static func isTrailer(type: String?, name: String?, localizedTrailer: String? = nil) -> Bool {
        isTrailer(type: type, names: [name], localizedTrailer: localizedTrailer)
    }

    /// A provided type decides alone. Untyped: a trailer when any name contains "trailer",
    /// "teaser" or the localized word (the parser's default name for an untyped video), case- and
    /// accent-insensitive.
    static func isTrailer(type: String?, names: [String?], localizedTrailer: String? = nil) -> Bool {
        let t = (type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let word = (localizedTrailer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            if t == "trailer" || t == "teaser" { return true }
            return !word.isEmpty && t == word.lowercased()
        }
        return names.contains { name in
            let n = (name ?? "").lowercased()
            if n.contains("trailer") || n.contains("teaser") { return true }
            return !word.isEmpty && n.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
