import Foundation
import SharedCore

/// What a playback is, for the credits lookup: the four identity fields and nothing stream-related
/// (no URL, no headers). A source switch for the same title keeps the same identity, so the cast
/// stays put; the next episode changes it.
struct PlayerInsightsIdentity: Equatable {
    let contentType: String
    let parentMetaId: String
    let season: Int?
    let episode: Int?

    init(contentType: String, parentMetaId: String, season: Int?, episode: Int?) {
        self.contentType = contentType
        self.parentMetaId = parentMetaId
        self.season = season
        self.episode = episode
    }

    init(context: PlaybackContext) {
        self.init(contentType: context.contentType, parentMetaId: context.parentMetaId,
                  season: context.season, episode: context.episode)
    }
}

/// The people for one identity, tagged with the key the shared resolver settled on.
struct PlayerInsightsCredits: Equatable {
    let identityKey: String
    let people: [PlayerPanelPerson]
}

/// Fills the Cast pill (`PlayerTopPanelModel.people`) and the compact actor view's detail. Fetches
/// run off the main actor; every result is applied only if its generation is still current, so a
/// slow answer for the previous episode (or the previous card) can never overwrite a newer one.
@MainActor
final class PlayerInsightsLoader {
    typealias CreditsFetch = @Sendable (PlayerInsightsIdentity) async -> PlayerInsightsCredits?
    typealias PersonFetch = @Sendable (Int) async -> PlayerPanelPersonDetail?

    private let model: PlayerTopPanelModel
    private let fetchCredits: CreditsFetch
    private let fetchPerson: PersonFetch

    /// Bumped by every accepted `load`; a credits result applies only while it still matches.
    private(set) var generation = 0
    /// Bumped by every person-detail request (and by anything that closes the actor view).
    private(set) var personGeneration = 0
    private(set) var lastIdentity: PlayerInsightsIdentity?
    private var creditsTask: Task<Void, Never>?
    private var personTask: Task<Void, Never>?

    init(model: PlayerTopPanelModel,
         fetchCredits: @escaping CreditsFetch = PlayerInsightsLoader.liveCredits,
         fetchPerson: @escaping PersonFetch = PlayerInsightsLoader.livePerson) {
        self.model = model
        self.fetchCredits = fetchCredits
        self.fetchPerson = fetchPerson
        model.onOpenPerson = { [weak self] person in self?.openPerson(person) }
    }

    deinit {
        creditsTask?.cancel()
        personTask?.cancel()
    }

    /// One-liner for the engine adapters: build the loader, start the first load. The model keeps
    /// the loader alive through `onOpenPerson`'s capture only weakly, so the caller must retain it.
    @discardableResult
    static func attach(model: PlayerTopPanelModel, context: PlaybackContext) -> PlayerInsightsLoader {
        let loader = PlayerInsightsLoader(model: model)
        loader.load(identity: PlayerInsightsIdentity(context: context))
        return loader
    }

    func load(identity: PlayerInsightsIdentity) {
        guard model.castEnabled else {
            // Off: no fetch, nothing shown. The identity is not remembered, so turning the setting
            // on later (next playback) loads normally.
            creditsTask?.cancel()
            generation += 1
            lastIdentity = nil
            model.people = []
            closeActorView()
            return
        }
        guard identity != lastIdentity else { return }
        lastIdentity = identity
        generation += 1
        let token = generation
        creditsTask?.cancel()
        model.people = []
        closeActorView()
        let fetch = fetchCredits
        creditsTask = Task { [weak self] in
            let result = await fetch(identity)
            guard !Task.isCancelled else { return }
            self?.applyCredits(result, token: token)
        }
    }

    private func applyCredits(_ result: PlayerInsightsCredits?, token: Int) {
        guard token == generation else { return }
        model.people = result?.people ?? []
    }

    private func closeActorView() {
        personGeneration += 1
        personTask?.cancel()
        model.actorView = nil
        model.actorDetail = nil
    }

    private func openPerson(_ person: PlayerPanelPerson) {
        personGeneration += 1
        let token = personGeneration
        personTask?.cancel()
        let fetch = fetchPerson
        personTask = Task { [weak self] in
            let detail = await fetch(person.id)
            guard !Task.isCancelled else { return }
            self?.applyPerson(detail, for: person, token: token)
        }
    }

    private func applyPerson(_ detail: PlayerPanelPersonDetail?, for person: PlayerPanelPerson, token: Int) {
        // Stale (a newer open), closed, or switched to another card: drop it.
        guard token == personGeneration, model.actorView?.id == person.id else { return }
        model.actorDetail = detail
    }

    // MARK: - Live fetches (SharedCore)

    nonisolated static let liveCredits: CreditsFetch = { identity in
        await withCheckedContinuation { (cont: CheckedContinuation<PlayerInsightsCredits?, Never>) in
            // Uses the `@Throws`-checked twin (an unchecked suspend crossing to Swift aborts the app
            // on any non-cancellation failure). The callback may arrive off the main thread.
            PlayerCreditsService.shared.fetchCreditsForPlaybackChecked(
                contentType: identity.contentType,
                parentMetaId: identity.parentMetaId,
                season: identity.season.map { KotlinInt(int: Int32($0)) },
                episode: identity.episode.map { KotlinInt(int: Int32($0)) }
            ) { credits, error in
                if let error {
                    NSLog("[PlayerInsightsLoader] credits failed: %@", String(describing: error))
                }
                cont.resume(returning: credits.map(mapCredits))
            }
        }
    }

    nonisolated static let livePerson: PersonFetch = { personId in
        await withCheckedContinuation { (cont: CheckedContinuation<PlayerPanelPersonDetail?, Never>) in
            PlayerCreditsService.shared.fetchPersonSummaryChecked(personId: Int32(personId)) { summary, error in
                if let error {
                    NSLog("[PlayerInsightsLoader] person failed: %@", String(describing: error))
                }
                cont.resume(returning: summary.map(mapPerson))
            }
        }
    }

    nonisolated static func mapCredits(_ credits: PlayerCredits) -> PlayerInsightsCredits {
        PlayerInsightsCredits(
            identityKey: credits.identityKey,
            people: credits.people.map {
                PlayerPanelPerson(id: Int($0.personId), name: $0.name, role: $0.role,
                                  photo: $0.photoUrl.flatMap { URL(string: $0) },
                                  isCrew: $0.isCrew, isGuest: $0.isGuest)
            }
        )
    }

    nonisolated static func mapPerson(_ s: PlayerPersonSummary) -> PlayerPanelPersonDetail {
        PlayerPanelPersonDetail(
            id: Int(s.personId), name: s.name, photo: s.profilePhotoUrl.flatMap { URL(string: $0) },
            knownForDepartment: s.knownForDepartment,
            lifeDates: lifeDates(birthday: s.birthday, deathday: s.deathday),
            biography: trimmedBiography(s.biography),
            knownFor: s.knownFor.map {
                PlayerPanelKnownFor(id: $0.id, title: $0.title, poster: $0.posterUrl.flatMap { URL(string: $0) })
            }
        )
    }

    /// "1956 – 2024" with both years, "Born 1974" with only a birthday, nil otherwise. A year is
    /// the first four characters of the ISO date.
    nonisolated static func lifeDates(birthday: String?, deathday: String?) -> String? {
        func year(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespaces), s.count >= 4 else { return nil }
            let y = String(s.prefix(4))
            return y.allSatisfy(\.isNumber) ? y : nil
        }
        guard let born = year(birthday) else { return nil }
        if let died = year(deathday) { return "\(born) \u{2013} \(died)" }
        return String(localized: "Born \(born)")
    }

    nonisolated static func trimmedBiography(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
