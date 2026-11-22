import Foundation

/// Return from background on mpv (spec-mpv-return §3.3): the explicit, owner-bound payload a fresh
/// mpv controller starts from. Built by `MPVReturnPlan` at an mpv return, or by the native and
/// Aether return runners when their rule hands off to mpv during a return. Pure value.
nonisolated struct PlayerReturnHandoff: Sendable, Equatable {
    enum Start: Sendable, Equatable {
        /// Resume exactly here (0 and positions of 10 s or less included; no saved-progress read).
        case position(Double)
        /// Not started yet: today's start (handoff, retry, saved progress, Start Over).
        case normalStart
        /// A live stream: no resume.
        case live

        var logToken: String {
            switch self {
            case .position(let p): "position(\(String(format: "%.1f", p)))"
            case .normalStart: "normalStart"
            case .live: "live"
            }
        }
    }

    enum Intent: Sendable, Equatable {
        case pause, play
        var toggled: Intent { self == .pause ? .play : .pause }
    }

    enum Origin: Sendable, Equatable { case mpvReturn, nativeReturn, aetherReturn }

    enum AudioPick: Sendable, Equatable {
        case auto
        /// The viewer's own pick: language, title and the ordinal among tracks sharing both.
        case picked(lang: String, title: String, ordinal: Int)

        var logToken: String {
            switch self {
            case .auto: "auto"
            case .picked(let lang, _, _): "picked(\(lang.isEmpty ? "-" : lang))"
            }
        }
    }

    enum SubtitlePick: Sendable, Equatable {
        case auto
        case off
        case embedded(lang: String, title: String, ordinal: Int)
        /// An add-on file, matched by the add-on's own URL (never logged).
        case addon(originalURL: String, lang: String, title: String)

        var logToken: String {
            switch self {
            case .auto: "auto"
            case .off: "off"
            case .embedded(let lang, _, _): "embedded(\(lang.isEmpty ? "-" : lang))"
            case .addon: "addon(pending)"
            }
        }
    }

    enum DiscardReason: String, Sendable, Equatable { case owner, context, generation }

    enum Validation: Sendable, Equatable {
        case accept
        case discard(DiscardReason)
    }

    /// The creation owner of the playback, carried unchanged.
    let owner: PlaybackIdentity
    let contextID: String
    let streamKey: String
    let start: Start
    /// Starts `.pause`; flipped only by presses after park.
    let intent: Intent
    let playedSec: Double
    let healthyReported: Bool
    let returnGeneration: Int
    /// 1 at an mpv return; 0 for a native or Aether transfer (no second fresh start either way:
    /// a failure goes to the return alert, §3.7).
    let freshStartsLeft: Int
    let audio: AudioPick
    let subtitle: SubtitlePick
    /// The audio delay total in seconds (a session tweak over a stream hint is not saved); nil =
    /// leave what the fresh controller restores.
    let audioDelaySec: Double?
    let speed: Double
    let origin: Origin

    /// Discard when the owner is not the current identity (account-only and profile-only changes
    /// both count), the context differs, or the generation is not newer than the last accepted.
    func validate(current: PlaybackIdentity, contextID: String, lastGeneration: Int) -> Validation {
        if owner != current { return .discard(.owner) }
        if self.contextID != contextID { return .discard(.context) }
        if returnGeneration <= lastGeneration { return .discard(.generation) }
        return .accept
    }

    /// The fresh controller's `pause` option before `loadfile`.
    var startsPaused: Bool { intent == .pause }
}

// MARK: - Resume from a return start

/// What `computeResumePosition` does with a return start (the payload's, or a retry's
/// `PlaybackContext.returnStart`). Pure.
nonisolated enum PlayerReturnResume: Sendable, Equatable {
    /// Seek to exactly this position after load; no saved progress is read.
    case at(Double)
    /// No resume at all (live).
    case none
    /// Today's resume rule.
    case normal

    static func decide(_ start: PlayerReturnHandoff.Start?) -> PlayerReturnResume {
        switch start {
        case .position(let p)?:
            guard p.isFinite, p >= 0 else { return .normal }
            return .at(p)
        case .live?: return .none
        case .normalStart?, nil: return .normal
        }
    }
}

// MARK: - Selection by semantics

/// One track as the controller's walk saw it (mpv id, language, title).
nonisolated struct MPVTrackSemantics: Sendable, Equatable {
    let id: Int
    let lang: String
    let title: String
}

/// spec-mpv-return §3.3: audio and embedded subtitle picks restored by meaning, not by mpv id
/// (ids are per file load). Pure.
nonisolated enum MPVSelectionRestore {
    enum Choice: Sendable, Equatable {
        case select(Int)
        case notFound
    }

    /// The ordinal of `track` among the tracks sharing its language and title (0 = first).
    static func ordinal(of trackID: Int, in tracks: [MPVTrackSemantics]) -> Int? {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return nil }
        let same = tracks.filter { $0.lang == track.lang && $0.title == track.title }
        return same.firstIndex(where: { $0.id == trackID })
    }

    /// Language and title must match; the ordinal picks among duplicates. A track list with fewer
    /// duplicates than the ordinal is `.notFound` (auto, logged), never "the nearest".
    static func choose(lang: String, title: String, ordinal: Int, tracks: [MPVTrackSemantics]) -> Choice {
        let same = tracks.filter { $0.lang == lang && $0.title == title }
        guard ordinal >= 0, ordinal < same.count else { return .notFound }
        return .select(same[ordinal].id)
    }

    static func choose(_ pick: PlayerReturnHandoff.AudioPick, tracks: [MPVTrackSemantics]) -> Choice? {
        guard case let .picked(lang, title, ordinal) = pick else { return nil }
        return choose(lang: lang, title: title, ordinal: ordinal, tracks: tracks)
    }

    /// Embedded picks only: `.addon` goes through `MPVPendingSubtitlePick`, `.off` and `.auto`
    /// need no track (nil).
    static func choose(_ pick: PlayerReturnHandoff.SubtitlePick, tracks: [MPVTrackSemantics]) -> Choice? {
        guard case let .embedded(lang, title, ordinal) = pick else { return nil }
        return choose(lang: lang, title: title, ordinal: ordinal, tracks: tracks)
    }
}

// MARK: - Native / Aether transfer during a return

/// spec-mpv-return §3.3: what the native or Aether return runner knows when its rule hands off to mpv
/// during a return (it runs only in a non-idle mode). The screen completes it into a payload.
nonisolated struct PlayerReturnTransfer: Sendable, Equatable {
    let owner: PlaybackIdentity
    let intent: PlayerReturnHandoff.Intent
    let atSec: Double
    let generation: Int

    /// Picks by meaning are not carried across engines (their track names do not map onto mpv's
    /// tracks): the fresh mpv start uses its own automatic choice. `freshStartsLeft` is 0.
    func payload(contextID: String, streamKey: String, origin: PlayerReturnHandoff.Origin,
                 playedSec: Double) -> PlayerReturnHandoff {
        PlayerReturnHandoff(owner: owner, contextID: contextID, streamKey: streamKey,
                            start: .position(atSec.isFinite ? max(0, atSec) : 0), intent: intent,
                            playedSec: playedSec, healthyReported: false, returnGeneration: generation,
                            freshStartsLeft: 0, audio: .auto, subtitle: .auto, audioDelaySec: nil, speed: 1,
                            origin: origin)
    }
}
