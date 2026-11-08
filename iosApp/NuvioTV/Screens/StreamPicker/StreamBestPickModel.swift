import Foundation
import SharedCore

/// Direction C D3: the best-pick card, as plain values built in `StreamsViewModel.apply(_:)`.
nonisolated struct StreamBestPickModel: Equatable {
    /// The card's fixed focus key and scroll id: focus never jumps when the stream under it changes.
    static let focusKey = "bestpick"
    /// The chosen stream's row key: Select plays it through `selectRow(rowKey)`.
    let rowKey: String
    /// False while the fan-out (in the current filter) is still answering: kicker "Best So Far".
    let isSettled: Bool
    /// `StreamPickerCopy.cardHeadline`, e.g. "4K Dolby Vision · Atmos DD+ 5.1".
    let headline: String
    /// `StreamPickerCopy.cardFacts`; nil when every part is missing (the line is not drawn).
    let facts: String?
    /// `StreamPickerCopy.rankLine(considered:)`.
    let rankLine: String
    /// Listable streams in the current filter (= the "Show all N" count).
    let considered: Int
}

/// Direction C D4: one pill of the alternatives row.
nonisolated struct StreamAlternativeModel: Equatable, Identifiable {
    enum Kind: Equatable { case bestFhd, bestDirect, showAll }
    let kind: Kind
    /// The stream's row key (`bestFhd` / `bestDirect`); nil for `showAll`.
    let rowKey: String?
    /// "Best 1080p · 1.9 GB", "Best direct link", "Show all 73".
    let title: String
    var id: String { focusKey }
    var focusKey: String {
        switch kind {
        case .bestFhd: return "alt:fhd"
        case .bestDirect: return "alt:direct"
        case .showAll: return "alt:all"
        }
    }
    var accessibilityID: String {
        switch kind {
        case .bestFhd: return "stream_picker_alt_fhd"
        case .bestDirect: return "stream_picker_alt_direct"
        case .showAll: return "stream_picker_show_all"
        }
    }
}

/// Direction C §5.6: the compact row's parts (what `StreamCompactRowView` draws, in order).
nonisolated struct StreamCompactParts: Equatable {
    /// `metaStrong`, primary: the headline with the short HDR mark, else the title.
    let lead: String
    /// `meta`, secondary: video facts then the audio label; nil when there are none.
    let facts: String?
    /// SF Symbol of the cached state; nil when the row has none.
    let glyph: String?
    /// The size text (trailing, primary); nil when the row has no size.
    let size: String?
    /// `caption`, secondary: "Failed recently", else the add-on name; nil when neither.
    let trailing: String?
}

/// Direction C: every user-facing string the card, pills, "more" row and compact row compose.
/// Pure; `@MainActor` only because `StreamFileSizeChip.label` and `String(localized:)` callers are
/// main-actor in this module. Tests call these directly. Separator is " · " everywhere.
@MainActor
enum StreamPickerCopy {
    nonisolated static let separator = " · "

    // MARK: - HDR

    /// §5.2: the row's short HDR mark spelled out for the card ("DV · HDR10" becomes
    /// "Dolby Vision + HDR10"). Nil for nil or blank.
    nonisolated static func hdrSpelledOut(_ mark: String?) -> String? {
        guard let mark else { return nil }
        let tokens = mark.components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { $0 == "DV" ? "Dolby Vision" : $0 }.joined(separator: " + ")
    }

    // MARK: - Card

    /// "BEST PICK · RESUME FROM 12:04" (drawn upper-case by the view; the string stays mixed case).
    static func kicker(settled: Bool, resumeLabel: String?) -> String {
        let lead = settled ? String(localized: "Best Pick") : String(localized: "Best So Far")
        return [lead, clean(resumeLabel)].compactMap { $0 }.joined(separator: separator)
    }

    /// "4K Dolby Vision · Atmos DD+ 5.1". No headline: the title alone.
    static func cardHeadline(_ row: StreamRowModel) -> String {
        guard let headline = row.headline else { return row.title }
        let video = [headline, hdrSpelledOut(row.hdrMark)].compactMap { $0 }.joined(separator: " ")
        return [video, clean(row.audio)].compactMap { $0 }.joined(separator: separator)
    }

    /// "Torrentio · WEB-DL · HEVC · 3.1 GB · cached on TB"; nil when every part is missing.
    static func cardFacts(_ row: StreamRowModel) -> String? {
        var parts: [String] = []
        if let addon = clean(row.addonName) { parts.append(addon) }
        parts += row.videoFacts
        if let size = row.sizeBytes { parts.append(StreamFileSizeChip.label(for: size)) }
        if let state = row.cachedState {
            switch state {
            case .instant(let provider):
                if let provider = clean(provider) {
                    parts.append(String(localized: "cached on \(provider)"))
                } else {
                    parts.append(String(localized: "cached"))
                }
            case .notCached:
                parts.append(String(localized: "stream.picker.notCached"))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    /// "Best of 73 · resolution, then HDR, then cached, then size"; n is the listable count.
    static func rankLine(considered n: Int) -> String {
        String(localized: "Best of \(n) · resolution, then HDR, then cached, then size")
    }

    /// What VoiceOver reads for the card: kicker, headline, facts, rank line.
    static func cardSpokenLabel(_ model: StreamBestPickModel, resumeLabel: String?) -> String {
        [kicker(settled: model.isSettled, resumeLabel: resumeLabel), model.headline, model.facts,
         model.rankLine].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: - Pills and "more"

    /// "Best 1080p · 1.9 GB" / "Best direct link" (+ size when the row has one). `.showAll` has no
    /// row: use `showAllTitle(_:)` (this returns an empty string for it).
    static func pillTitle(_ kind: StreamAlternativeModel.Kind, _ row: StreamRowModel) -> String {
        let base: String
        switch kind {
        case .bestFhd: base = String(localized: "Best 1080p")
        case .bestDirect: base = String(localized: "Best direct link")
        case .showAll: return ""
        }
        guard let size = row.sizeBytes else { return base }
        return base + separator + StreamFileSizeChip.label(for: size)
    }

    static func showAllTitle(_ n: Int) -> String { String(localized: "Show all \(n)") }

    /// "10 more" (the view adds the trailing chevron image).
    static func moreText(_ hidden: Int) -> String { String(localized: "\(hidden) more") }

    /// "1080p, 10 more": the section title then the visible text, joined for VoiceOver.
    static func moreSpokenLabel(sectionTitle: String, hidden: Int) -> String {
        [sectionTitle, moreText(hidden)].joined(separator: ", ")
    }

    // MARK: - Compact row

    static func compactParts(_ row: StreamRowModel) -> StreamCompactParts {
        if row.addonText { return addonCompactParts(row) }
        let lead: String
        if let headline = row.headline {
            lead = [headline, row.hdrMark].compactMap { $0 }.joined(separator: " ")
        } else {
            lead = row.title
        }
        let factTerms = row.videoFacts + [clean(row.audio)].compactMap { $0 }
        let trailing: String? = row.failedRecently
            ? String(localized: "Failed recently")
            : clean(row.addonName)
        return StreamCompactParts(
            lead: lead,
            facts: factTerms.isEmpty ? nil : factTerms.joined(separator: separator),
            glyph: row.cachedState.map(StreamRowFacts.cachedSymbol),
            size: row.sizeBytes.map { StreamFileSizeChip.label(for: $0) },
            trailing: trailing
        )
    }

    /// GitHub #25, add-on text: the lead is the name lines joined with spaces, the facts are the
    /// description's first line, then Nuvio's own cached glyph and the size. Same 64 pt row.
    private static func addonCompactParts(_ row: StreamRowModel) -> StreamCompactParts {
        let lead = row.nameLines.isEmpty ? row.title : row.nameLines.joined(separator: " ")
        let facts = StreamRowModel.textLines(row.description).first
        // Review r5: an add-on's generic name ("4K ⚡ RD") does not tell sources apart, so a failed
        // row keeps its source beside the caption.
        let trailing: String? = row.failedRecently
            ? [String(localized: "Failed recently"), clean(row.addonName)].compactMap { $0 }.joined(separator: separator)
            : clean(row.addonName)
        // Review r1/r2: the one line truncates, so text that "carries" the size may not show it; the
        // compact row always keeps its own size.
        let size: String? = row.sizeBytes.map { StreamFileSizeChip.label(for: $0) }
        return StreamCompactParts(
            lead: lead,
            facts: facts,
            glyph: row.drawnCachedState.map(StreamRowFacts.cachedSymbol),
            size: size,
            trailing: trailing
        )
    }

    /// Lead, fact terms, cached words, size, add-on, "YouTube", "Failed recently". In add-on text:
    /// lead, every description line (review r1: VoiceOver is not bound by the visual one line), then
    /// the same tail.
    static func compactSpokenLabel(_ row: StreamRowModel, parts: StreamCompactParts? = nil) -> String {
        let parts = parts ?? compactParts(row)
        if row.addonText {
            var spoken: [String] = [parts.lead]
            spoken += StreamRowModel.textLines(row.description)
            if let state = row.drawnCachedState { spoken.append(StreamRowFacts.cachedText(state)) }
            if let size = parts.size { spoken.append(size) }
            if let addon = clean(row.addonName) { spoken.append(addon) }
            if row.isYouTube { spoken.append("YouTube") }
            if row.failedRecently { spoken.append(String(localized: "Failed recently")) }
            return spoken.joined(separator: ", ")
        }
        var spoken: [String] = [parts.lead]
        spoken += row.videoFacts
        if let audio = clean(row.audio) { spoken.append(audio) }
        if let state = row.cachedState { spoken.append(StreamRowFacts.cachedText(state)) }
        if let size = parts.size { spoken.append(size) }
        if let addon = clean(row.addonName) { spoken.append(addon) }
        if row.isYouTube { spoken.append("YouTube") }
        if row.failedRecently { spoken.append(String(localized: "Failed recently")) }
        return spoken.joined(separator: ", ")
    }

    private nonisolated static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
