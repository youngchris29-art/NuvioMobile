import Combine
import Foundation
import SharedCore

/// Loads a single cast/crew member's detail via the shared `TmdbMetadataService.fetchPersonDetail`
/// (bio, photo, known-for, movie/TV credits). This is TMDB-backed: it returns `nil` unless a TMDB API
/// key is configured (`TmdbSettings.enabled && hasApiKey`), so `failed` drives a friendly empty state.
@MainActor
final class PersonDetailViewModel: ObservableObject {
    @Published private(set) var person: PersonDetail?
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false

    private let personId: Int
    private var didLoad = false

    init(personId: Int) {
        self.personId = personId
    }

    func start() {
        guard !didLoad else { return }
        didLoad = true
        isLoading = true
        // suspend fun → Swift completion; result may arrive off the main thread, so hop back.
        TmdbMetadataService.shared.fetchPersonDetail(
            personId: Int32(personId),
            preferCrewCredits: nil
        ) { [weak self] detail, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                self.person = detail
                self.failed = (detail == nil)
            }
        }
    }
}
