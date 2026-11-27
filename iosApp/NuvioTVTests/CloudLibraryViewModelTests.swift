import XCTest
import SharedCore
@testable import NuvioTV

/// Scope identity W3b (spec 9.1.4, 9.1.5): the Debrid Cloud chip row shows at Library open, from the
/// profile's configured providers, before any listing is published (BUG-257).
@MainActor
final class CloudLibraryViewModelTests: XCTestCase {
    func testChipsShowFromConfiguredProvidersBeforeAnyListing() {
        let model = CloudLibraryViewModel(isFixture: false, configuredProviders: { [DebridProviders.shared.Torbox] })
        model.start()
        defer { model.stop() }
        XCTAssertTrue(model.hasConnectedProvider, "the chip row shows at open")
        // Until the listing carries Torbox, its section is the existing loading style.
        let torbox = model.providers.first { $0.providerId == "torbox" }
        XCTAssertEqual(torbox?.isLoading, true)
    }

    func testNoConfiguredProviderNoChips() {
        let model = CloudLibraryViewModel(isFixture: false, configuredProviders: { [] })
        model.start()
        defer { model.stop() }
        XCTAssertFalse(model.hasConnectedProvider)
    }

    /// Review r3 #2: no loading placeholder once the repository reports loaded.
    func testPlaceholdersOnlyWhileNothingIsLoaded() {
        let torbox = DebridProviders.shared.Torbox
        XCTAssertEqual(CloudLibraryViewModel.displayedProviders(listed: [], configured: [torbox], isLoaded: false).map(\.isLoading), [true])
        XCTAssertTrue(CloudLibraryViewModel.displayedProviders(listed: [], configured: [torbox], isLoaded: true).isEmpty)
    }
}
