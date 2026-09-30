import Combine
import Foundation
import SharedCore

/// Loads a single cast/crew member's detail via the shared `TmdbMetadataService.fetchPersonDetail`
/// (bio, photo, known-for, movie/TV credits). This is TMDB-backed: it returns `nil` unless TMDB
/// enrichment is turned on (`TmdbSettings.enabled` — the API key is bundled, upstream 60ee0160),
/// so `failed` drives a friendly empty state.
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
        // Uses the `@Throws`-checked twin: an unchecked suspend function crossing to Swift
        // SIGABRTs the whole app on any non-cancellation failure instead of surfacing it here
        // (see `TmdbMetadataService.fetchPreviewEnrichmentChecked`'s KDoc, 2026-09-12).
        TmdbMetadataService.shared.fetchPersonDetailChecked(
            personId: Int32(personId),
            preferCrewCredits: nil
        ) { [weak self] detail, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                if let error {
                    NSLog("[PersonDetailViewModel] fetchPersonDetailChecked failed: %@", String(describing: error))
                }
                // Custom poster URL pattern (Details screen) over the filmography rails; the
                // original art stays in each item's `rawPosterUrl` as the load-failure fallback.
                CustomPosterUrlRepository.shared.ensureLoaded()
                let pattern = CustomPosterUrlRepository.shared.patternForScreen(screen: .details)
                self.person = detail?.withCustomPosterUrls(pattern: pattern)
                self.failed = (detail == nil)
            }
        }
    }
}
