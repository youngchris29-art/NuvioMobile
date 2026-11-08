import Foundation
import SharedCore

// MARK: - Row model (W3-16)

/// What shapes a prebuilt stream row beyond the stream itself: the shared badge settings and the
/// "- <Provider> Instant" suffix. Part of the row model's identity (`StreamRowModel.==` compares
/// the values it produced), and of `StreamsViewModel.Group`, so a settings flip rebuilds the rows.
nonisolated struct StreamRowDisplay: Equatable {
    /// The file-size chip is on (`showFileSizeBadges`; the row still needs a size to show it).
    var showFileSize = true
    /// Badges above the title instead of below it.
    var badgesOnTop = false
    /// The inline add-on label (logo + name) on the row's first line.
    var showAddonLogo = false
    /// The Instant suffix on debrid-cached rows (debrid resolution on, no custom name template).
    var instantSuffix = false
    /// GitHub #25 "Source Layout = Full Width": the list runs the screen's width, so a Nuvio row
    /// folds its lines into two and an add-on row puts its name and description side by side.
    var fullWidth = false
    /// GitHub #25 "Row Text = Add-on's Own": the row draws the add-on's `name` and `description`
    /// instead of Nuvio's headline and fact lines. Display only: ranking and grouping still parse.
    var addonText = false
}

/// An external player the row's long-press menu can offer. A plain-Swift copy of the Kotlin
/// `ExternalPlayerApp`, so the menu's list takes part in `StreamRowModel.==`.
nonisolated struct StreamRowPlayer: Equatable {
    let id: String
    let name: String
}

/// W3-16 (F1/F4, BUG-207): everything a stream row shows, as one plain value. Built in two steps:
///
/// - `make(stream:key:display:)`, once per stream in `StreamsViewModel.apply(_:)`: the focus key,
///   the title (the plain label with a headline, else with the Instant suffix), the description, the
///   badges, the size, the inline add-on label, the headline and fact lines, the YouTube flag and
///   the playback key (one SHA-256 pair, so a row body never recomputes it);
/// - `applying(...)`, in the picker's body: the four things only the picker knows — the debrid
///   spinner, the "Failed recently" caption, and the external players with their default.
///
/// `StreamRowView` is `Equatable` over this value, so a row whose model is unchanged is never
/// re-evaluated when a sibling's focus, the scroll or the list's state moves. Every field below is
/// compared: dropping one would freeze that part of a row (the spinner, the rejected caption, the
/// badge settings, the Instant-suffix title, the player list with its default).
nonisolated struct StreamRowModel: Equatable, Identifiable {
    /// The focus key (`"<groupId>#<identity>"`), stable across republishes.
    let key: String
    /// The row title. With a `headline` it is the plain stream label (the cached glyph carries the
    /// Instant state); without one it keeps the "- <Provider> Instant" suffix on a cached torrent row.
    let title: String
    /// The add-on's description (release name), nil when empty or absent.
    let description: String?
    let badges: [StreamBadgeInfo]
    /// The size text's bytes (`StreamFacts.sizeBytes`); nil when File Size Badges is off or the
    /// stream has no size.
    let sizeBytes: Int64?
    let badgesOnTop: Bool
    /// The inline add-on label (logo + name) on line 1 is drawn ("Show Add-on Logo").
    let showsAddonColumn: Bool
    /// The add-on's name is drawn on line 1 (review r1 R1-2): always on a headline row, whose title
    /// no longer carries it, else exactly when "Show Add-on Logo" is on. The logo itself stays behind
    /// `showsAddonColumn`.
    let showsAddonName: Bool
    let addonName: String
    /// The add-on's logo URL, nil when it has none.
    let addonLogo: String?
    /// The add-on gave only a YouTube video id: the row says so and resolves it on the device.
    let isYouTube: Bool
    /// `StreamItem.playbackStreamKey`: what `RejectedStreamLinks` stores.
    let playbackKey: String
    /// polish D4: `StreamFacts.resolution`, drives the tier. Nil when the release names none.
    let resolution: Int?
    /// D1: "4K" / "1440p" / "1080p" / "720p" / "SD"; nil shows `title` on line 1 instead.
    let headline: String?
    /// D1: the HDR mark beside the headline ("DV · HDR10"); nil when `headline` is nil.
    let hdrMark: String?
    /// D1: fact line 1 terms (source type, codec).
    let videoFacts: [String]
    /// D1: fact line 2 terms before the cached part (audio, languages).
    let audioFacts: [String]
    /// D3: the cached part of fact line 2; already nil when the title carries the Instant suffix.
    let cachedState: StreamRowCachedState?
    /// Direction C: the audio label alone (`StreamFacts.audio`, trimmed; "Atmos DD+ 5.1"), for the
    /// best-pick headline and the compact row. Nil when the release names none. Defaulted so the
    /// tests' memberwise calls keep compiling; `make` always sets it.
    var audio: String? = nil
    /// GitHub #25: the row is laid out for the full-width list (`StreamRowDisplay.fullWidth`).
    var wide = false
    /// GitHub #25: the row draws the add-on's own text (`StreamRowDisplay.addonText`).
    var addonText = false
    /// GitHub #25: the stream's `name` split on newlines, trimmed, empties dropped (add-on text).
    var nameLines: [String] = []
    /// GitHub #25: in add-on text the cached part comes only from Nuvio's own debrid check
    /// (`StreamItem.debridCacheStatus`); an add-on that marks its cache in its text is not repeated.
    var addonCachedState: StreamRowCachedState? = nil

    /// This row's debrid / YouTube resolve is in flight (the spinner beside the title).
    var isResolving = false
    /// The link failed recently for this title ("Failed recently" caption).
    var failedRecently = false
    /// The external players the long-press menu offers (empty = no menu).
    var players: [StreamRowPlayer] = []
    /// The validated default external player's id, nil when the built-in player is the default.
    var defaultPlayerId: String?

    var id: String { key }

    /// The badge row is drawn (the size moved to line 1 and no longer makes one).
    var hasBadgeRow: Bool { !badges.isEmpty }
    /// Fact line 1 (source type, codec) is drawn.
    var hasVideoLine: Bool { !videoFacts.isEmpty }
    /// Fact line 2 (audio, languages, cached state) is drawn.
    var hasAudioLine: Bool { !audioFacts.isEmpty || cachedState != nil }
    /// The cached part the row actually draws: Nuvio's parsed state, or in add-on text only
    /// Nuvio's own debrid check.
    var drawnCachedState: StreamRowCachedState? { addonText ? addonCachedState : cachedState }
    /// The wide Nuvio row's second line (video facts, audio, languages, cached part) is drawn.
    var hasWideFactLine: Bool { hasVideoLine || hasAudioLine }

    /// What VoiceOver reads for the row, in the order it is drawn: the badge names (when on top),
    /// the headline (or title), the HDR mark, the add-on name, the size, the fact lines, the cached
    /// words, the badge names (when below), "YouTube" and "Failed recently".
    ///
    /// GitHub #25, add-on text: the badge names (when on top), the name lines, the source name (when
    /// drawn), the description with
    /// its newlines read as commas, the size (when drawn), the cached words (only Nuvio's own), the
    /// badge names (when below), "YouTube" and "Failed recently".
    @MainActor var spokenLabel: String {
        let badgeNames = badges.map(\.name)
        var parts: [String] = badgesOnTop ? badgeNames : []
        if addonText {
            parts += nameLines.isEmpty ? [title] : nameLines
            if showsAddonName { parts.append(addonName) }
            if let description {
                parts += Self.textLines(description)
            }
            if let sizeBytes { parts.append(StreamFileSizeChip.label(for: sizeBytes)) }
            if let state = drawnCachedState { parts.append(StreamRowFacts.cachedText(state)) }
            if !badgesOnTop { parts += badgeNames }
            if isYouTube { parts.append("YouTube") }
            if failedRecently { parts.append(String(localized: "Failed recently")) }
            return parts.joined(separator: ", ")
        }
        parts.append(headline ?? title)
        if let hdrMark { parts.append(hdrMark) }
        if showsAddonName { parts.append(addonName) }
        if let sizeBytes { parts.append(StreamFileSizeChip.label(for: sizeBytes)) }
        parts += videoFacts
        parts += audioFacts
        if let cachedState { parts.append(StreamRowFacts.cachedText(cachedState)) }
        if !badgesOnTop { parts += badgeNames }
        if isYouTube { parts.append("YouTube") }
        if failedRecently { parts.append(String(localized: "Failed recently")) }
        return parts.joined(separator: ", ")
    }

    /// GitHub #25: `text` split on newlines, each line trimmed, empty lines dropped.
    nonisolated static func textLines(_ text: String?) -> [String] {
        guard let text else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// GitHub #25 review r3/r4: the add-on's name already names its source when its FIRST line (the
    /// one always drawn first, whatever wraps after it) starts with the source label as a whole word
    /// ("AIOStreams" in "AIOStreams 4K", never "RD" in "HDR"), case-insensitive. Only then may the row
    /// leave its own source label out.
    nonisolated static func nameShowsSource(_ label: String, nameLines: [String]) -> Bool {
        let source = label.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty, let line = nameLines.first,
              let range = line.range(of: source, options: [.caseInsensitive, .anchored]) else { return false }
        guard range.upperBound < line.endIndex else { return true }
        let next = line[range.upperBound]
        return !(next.isLetter || next.isNumber)
    }

    /// GitHub #25: the add-on-text cached part, from Nuvio's own debrid check only.
    static func addonCachedState(_ status: StreamDebridCacheStatus?,
                                 providerLabel: (StreamDebridCacheStatus) -> String) -> StreamRowCachedState? {
        guard let status else { return nil }
        switch status.state {
        case .cached: return StreamRowFacts.cachedState(cached: true, provider: providerLabel(status))
        case .notCached: return .notCached
        default: return nil
        }
    }

    /// The part the picker's own state decides (spinner, rejected caption, players).
    func applying(isResolving: Bool, failedRecently: Bool, players: [StreamRowPlayer],
                  defaultPlayerId: String?) -> StreamRowModel {
        var copy = self
        copy.isResolving = isResolving
        copy.failedRecently = failedRecently
        copy.players = players
        copy.defaultPlayerId = defaultPlayerId
        return copy
    }

    /// Builds the static part of a row. `providerLabel` names the debrid provider for the Instant
    /// suffix (injected so a test needs no provider catalog). `facts` is the parsed `stream`.
    @MainActor
    static func make(
        stream: StreamItem,
        facts: StreamFacts,
        key: String,
        display: StreamRowDisplay,
        providerLabel: (StreamDebridCacheStatus) -> String = StreamRowModel.debridProviderLabel
    ) -> StreamRowModel {
        // Kotlin nullable Strings surface as non-optional Swift String, so widen explicitly.
        let desc: String? = stream.description_
        let logo: String? = stream.addonLogo
        let badges: [StreamBadge] = stream.badges
        // Repository-grouped plugin streams carry the repository in `addonName`; the shared helper
        // names the provider that found the stream instead (`rowSourceLabel` is non-optional).
        let sourceLabel: String = stream.rowSourceLabel
        // `facts` is parsed once per stream by the caller (`StreamFactsCache`), never here or in a
        // body (W3-16 F4); every derived field below comes from it.
        let resolution: Int? = facts.resolution.map { Int($0.intValue) }
        let headline = StreamRowFacts.headline(forResolution: resolution)
        // Exactly one of the title and the glyph says "Instant" (D3). With a headline the title is
        // the plain label and the glyph carries it; without one the title keeps the suffix, and the
        // glyph is dropped when the suffix was appended.
        let plainTitle: String = stream.streamLabel
        let fullTitle = title(for: stream, instantSuffix: display.instantSuffix, providerLabel: providerLabel)
        let titleCarriesInstant = headline == nil && fullTitle != plainTitle
        var provider: String?
        if let status = stream.debridCacheStatus, status.state == .cached {
            provider = providerLabel(status)
        }
        let cached: Bool? = facts.cached?.boolValue
        let sizeBytes: Int64? = display.showFileSize ? facts.sizeBytes?.int64Value : nil
        let languages: [String] = facts.languages
        let rawAudio: String? = facts.audio
        let trimmedAudio = rawAudio?.trimmingCharacters(in: .whitespaces) ?? ""
        let audioLabel: String? = trimmedAudio.isEmpty ? nil : trimmedAudio
        // GitHub #25: the add-on's own text. The description falls back to the legacy Stremio
        // `title` field, which older add-ons still fill instead of `description`.
        let rawName: String? = stream.name
        let nameLines = StreamRowModel.textLines(rawName)
        let legacyTitle: String? = stream.title
        let addonDescription: String? = {
            if let desc, !desc.isEmpty { return desc }
            if let legacyTitle, !legacyTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return legacyTitle }
            return nil
        }()
        return StreamRowModel(
            key: key,
            title: headline != nil ? plainTitle : fullTitle,
            description: display.addonText ? addonDescription : ((desc ?? "").isEmpty ? nil : desc),
            badges: badges.map { StreamBadgeInfo($0) },
            sizeBytes: sizeBytes,
            badgesOnTop: display.badgesOnTop,
            showsAddonColumn: display.showAddonLogo,
            // #16 (review r1): under a repository header the row is the only place the provider
            // can be read, so a repository-group row names it even with no headline and the logo
            // column off (other rows keep the setting: their group header already names the add-on).
            // GitHub #25 review r2: an add-on-text row names its source too (two add-ons can send the
            // same name under one quality heading; #16's provider name under a repository group),
            // unless the add-on's own name lines already carry it.
            // Show Add-on Logo keeps the label (and its logo) whatever the name says (review r4).
            showsAddonName: display.addonText
                ? !sourceLabel.isEmpty && (display.showAddonLogo
                    || !StreamRowModel.nameShowsSource(sourceLabel, nameLines: nameLines))
                : (headline != nil || display.showAddonLogo || stream.isPluginRepositoryGroup) && !sourceLabel.isEmpty,
            addonName: sourceLabel,
            addonLogo: (logo ?? "").isEmpty ? nil : logo,
            isYouTube: StreamPickerView.isYouTubeResolved(stream),
            playbackKey: stream.playbackStreamKey,
            resolution: resolution,
            headline: headline,
            hdrMark: headline == nil ? nil : StreamRowFacts.hdrMark(facts.hdr),
            videoFacts: StreamRowFacts.videoFacts(sourceType: facts.sourceType, codec: facts.codec),
            audioFacts: StreamRowFacts.audioFacts(audio: facts.audio, languages: languages,
                                                  locale: Locale.current),
            cachedState: titleCarriesInstant ? nil
                : StreamRowFacts.cachedState(cached: cached, provider: provider),
            audio: audioLabel,
            wide: display.fullWidth,
            addonText: display.addonText,
            // Add-on-text fields stay at their defaults on a Nuvio row, so it is the value it was.
            nameLines: display.addonText ? nameLines : [],
            addonCachedState: display.addonText
                ? StreamRowModel.addonCachedState(stream.debridCacheStatus, providerLabel: providerLabel) : nil
        )
    }

    /// Row title with the mobile "- <Provider> Instant" suffix on debrid-cached torrent rows
    /// (`StreamCard.kt:instantServiceLabel`), shown only while debrid resolution is enabled and
    /// no custom stream-name template is active (`instantSuffix`).
    @MainActor
    static func title(
        for stream: StreamItem,
        instantSuffix: Bool,
        providerLabel: (StreamDebridCacheStatus) -> String = StreamRowModel.debridProviderLabel
    ) -> String {
        let base = stream.streamLabel
        guard instantSuffix,
              let status = stream.debridCacheStatus,
              status.state == .cached else { return base }
        let provider = providerLabel(status)
        return provider.isEmpty ? base : String(localized: "\(base) - \(provider) Instant")
    }

    /// The provider's short name, else the cache status' own name, else the provider's display name.
    static func debridProviderLabel(_ status: StreamDebridCacheStatus) -> String {
        var provider = DebridProviders.shared.shortName(id: status.providerId)
        if provider.trimmingCharacters(in: .whitespaces).isEmpty {
            provider = status.providerName.trimmingCharacters(in: .whitespaces)
        }
        if provider.isEmpty {
            provider = DebridProviders.shared.displayName(id: status.providerId)
        }
        return provider
    }
}
