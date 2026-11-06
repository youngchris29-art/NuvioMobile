import Foundation
import SharedCore

/// A4.4 (C10): the crew group of a credit, in display order. Mirrors Kotlin's `MetaCrewCategory`
/// so the row's rules are testable with plain Swift values.
nonisolated enum DetailCreditCategory: Equatable, Sendable {
    case creator
    case director
    case writer
    case producer
}

/// One cast credit as the row reads it (`MetaPerson`'s fields).
nonisolated struct DetailCastCredit: Equatable, Sendable {
    let name: String
    let role: String?
    let photo: String?
    let tmdbId: Int?
}

/// One crew credit as the row reads it (`MetaCrewMember`'s fields). `creditKey` is Kotlin's
/// (`metaCreditKey`: person id or name, plus job).
nonisolated struct DetailCrewCredit: Equatable, Sendable {
    let name: String
    let job: String
    let category: DetailCreditCategory
    let photo: String?
    let tmdbId: Int?
    let creditKey: String
}

/// One card in the Cast & Crew row. `key` is stable across reloads and row reshuffles (the
/// return-focus memory stores it instead of the card's index) and carries no whitespace, so the
/// `debug_detail_focus … idx=<key>` probe stays one token.
nonisolated struct DetailCreditItem: Identifiable, Equatable, Sendable {
    nonisolated enum Kind: Equatable, Sendable {
        case cast
        case crew(DetailCreditCategory)
    }

    let key: String
    let kind: Kind
    let name: String
    /// The role line: the character for cast, the job for crew, in the device language for the
    /// common TMDB jobs (`DetailCreditRow.jobLabel`), else the provider's own job string.
    let subtitle: String?
    let photo: String?
    /// Only cards with a TMDB id open a person page.
    let tmdbId: Int?

    var id: String { key }
}

/// A4.4 (C10): the Cast row continues into crew. Cast first, in order, then crew (creators,
/// directors, writers, producers: Kotlin's `buildMetaCrew` order). TMDB enrichment still prepends
/// the creators (series) or directors (films), else writers, to `cast` as pseudo-cast entries
/// whose role is the localized job word ("Director"); a crew credit for a person already shown
/// that way is skipped, so the director never appears twice. Crew is also deduped by `creditKey`.
nonisolated enum DetailCreditRow {
    static func items(
        cast: [DetailCastCredit],
        crew: [DetailCrewCredit],
        pseudoRoleLabels: (DetailCreditCategory) -> [String] = { DetailCreditRow.englishPseudoRoleLabels($0) }
    ) -> [DetailCreditItem] {
        var result: [DetailCreditItem] = []
        var usedKeys = Set<String>()
        func uniqueKey(_ base: String) -> String {
            var key = base
            var n = 2
            while !usedKeys.insert(key).inserted {
                key = "\(base)#\(n)"
                n += 1
            }
            return key
        }

        // Actors first, then the creator(s), then the other pseudo-cast entries (directors, writers);
        // the rest of the crew follows below. Order within each group is the order given.
        func pseudoLabels(_ category: DetailCreditCategory) -> Set<String> {
            Set(pseudoRoleLabels(category).map(normalized).filter { !$0.isEmpty })
        }
        let creatorLabels = pseudoLabels(.creator)
        let otherPseudoLabels = pseudoLabels(.director).union(pseudoLabels(.writer))
        var actors: [DetailCastCredit] = []
        var creators: [DetailCastCredit] = []
        var otherPseudo: [DetailCastCredit] = []
        for person in cast {
            let role = person.role.map(normalized) ?? ""
            if creatorLabels.contains(role) {
                creators.append(person)
            } else if otherPseudoLabels.contains(role) {
                otherPseudo.append(person)
            } else {
                actors.append(person)
            }
        }
        for person in actors + creators + otherPseudo {
            let name = trimmed(person.name)
            guard !name.isEmpty else { continue }
            let role = person.role.map(trimmed).flatMap { $0.isEmpty ? nil : $0 }
            result.append(DetailCreditItem(
                key: uniqueKey(castKey(name: name, role: role, tmdbId: person.tmdbId)),
                kind: .cast, name: name, subtitle: role, photo: person.photo, tmdbId: person.tmdbId
            ))
        }

        var seenCredits = Set<String>()
        for member in crew {
            let name = trimmed(member.name)
            guard !name.isEmpty, seenCredits.insert(member.creditKey).inserted else { continue }
            let labels = Set(([member.job] + pseudoRoleLabels(member.category)).map(normalized).filter { !$0.isEmpty })
            let shownAsPseudoCast = cast.contains { person in
                guard let role = person.role.map(normalized), labels.contains(role) else { return false }
                return samePerson(castId: person.tmdbId, castName: person.name, crewId: member.tmdbId, crewName: name)
            }
            if shownAsPseudoCast { continue }
            // Display only: the raw job stays the credit's identity (`creditKey`) and the pseudo-cast
            // match above.
            let job = jobLabel(member.job)
            result.append(DetailCreditItem(
                key: uniqueKey(focusKey(member.creditKey)),
                kind: .crew(member.category), name: name, subtitle: job.isEmpty ? nil : job,
                photo: member.photo, tmdbId: member.tmdbId
            ))
        }
        return result
    }

    /// A crew card's role line. TMDB sends its job names in English whatever the request
    /// language ("Director of Photography"), so the common ones are mapped to localized labels
    /// (matched case-insensitively, surrounding whitespace ignored); any other job is shown as sent,
    /// trimmed. Display only: identity and deduplication use the raw job.
    static func jobLabel(_ job: String) -> String {
        let raw = trimmed(job)
        switch raw.lowercased() {
        case "director": return String(localized: "Director")
        case "writer": return String(localized: "Writer")
        case "screenplay": return String(localized: "Screenplay")
        case "teleplay": return String(localized: "Teleplay")
        case "story": return String(localized: "Story")
        case "novel": return String(localized: "Novel")
        case "characters": return String(localized: "Characters")
        case "creator": return String(localized: "Creator")
        case "producer": return String(localized: "Producer")
        case "executive producer": return String(localized: "Executive Producer")
        case "original music composer": return String(localized: "Original Music Composer")
        case "director of photography": return String(localized: "Director of Photography")
        case "editor": return String(localized: "Editor")
        case "casting": return String(localized: "Casting")
        default: return raw
        }
    }

    /// The stable key of a cast card: `cast:tmdb:<id>|<role>` or `cast:name:<name>|<role>`,
    /// lowercased, the same shape as Kotlin's `metaCreditKey` with a `cast:` prefix.
    static func castKey(name: String, role: String?, tmdbId: Int?) -> String {
        let person = tmdbId.map { "tmdb:\($0)" } ?? "name:\(normalized(name))"
        return focusKey("cast:\(person)|\(normalized(role ?? ""))")
    }

    /// A key with its whitespace runs folded to `_` (Kotlin's `creditKey` keeps the job's spaces,
    /// "tmdb:1|executive producer").
    static func focusKey(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: "_")
    }

    /// The job words the shared module gives pseudo-cast entries in English (its inline fallbacks).
    static func englishPseudoRoleLabels(_ category: DetailCreditCategory) -> [String] {
        switch category {
        case .creator: ["Creator"]
        case .director: ["Director"]
        case .writer: ["Writer"]
        case .producer: []
        }
    }

    /// The same words in the device language: the shared module fills them with
    /// `resourceString(…, StringKey.person_role_*)`, which `SharedStringProvider` answers from the
    /// "Shared" catalog. English is kept too, for a key missing from the catalog.
    static func sharedPseudoRoleLabels(_ category: DetailCreditCategory) -> [String] {
        let key: String
        switch category {
        case .creator: key = "person_role_creator"
        case .director: key = "person_role_director"
        case .writer: key = "person_role_writer"
        case .producer: return []
        }
        let english = englishPseudoRoleLabels(category)
        let localized = Bundle.main.localizedString(forKey: key, value: english.first ?? "", table: "Shared")
        return english + [localized]
    }

    /// The Kotlin model's credits as the row's inputs.
    static func items(cast: [MetaPerson], crew: [MetaCrewMember]) -> [DetailCreditItem] {
        items(
            cast: cast.map { DetailCastCredit(name: $0.name, role: $0.role, photo: $0.photo,
                                              tmdbId: $0.tmdbId?.value) },
            crew: crew.map { member in
                DetailCrewCredit(name: member.name, job: member.job, category: category(of: member.category),
                                 photo: member.photo, tmdbId: member.tmdbId?.value,
                                 creditKey: member.creditKey)
            },
            pseudoRoleLabels: { sharedPseudoRoleLabels($0) }
        )
    }

    /// Compared with `==` rather than switched over (the `SettingsViewModel` caution: bridged
    /// Kotlin enum entries do not import as an exhaustive Swift enum).
    static func category(of category: MetaCrewCategory) -> DetailCreditCategory {
        if category == MetaCrewCategory.creator { return .creator }
        if category == MetaCrewCategory.director { return .director }
        if category == MetaCrewCategory.writer { return .writer }
        return .producer
    }

    private static func samePerson(castId: Int?, castName: String, crewId: Int?, crewName: String) -> Bool {
        if let castId, let crewId { return castId == crewId }
        return normalized(castName) == normalized(crewName)
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func normalized(_ s: String) -> String { trimmed(s).lowercased() }
}
