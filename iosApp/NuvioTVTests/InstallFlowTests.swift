import XCTest
@testable import NuvioTV

final class InstallFlowTests: XCTestCase {
    private let installed = AddonsViewModel.InstallOutcome.installed(name: "Torrentio", serial: 1)
    private let failed = AddonsViewModel.InstallOutcome.failed(message: "nope", serial: 2)

    func testSerialReadsBothOutcomes() {
        XCTAssertEqual(InstallFlow.serial(of: installed), 1)
        XCTAssertEqual(InstallFlow.serial(of: failed), 2)
    }

    func testBusyWinsOverAnyOutcome() {
        XCTAssertEqual(InstallFlow.installPhase(isInstalling: true, outcome: nil), .checking)
        XCTAssertEqual(InstallFlow.installPhase(isInstalling: true, outcome: failed), .checking)
        XCTAssertEqual(InstallFlow.installPhase(isInstalling: true, outcome: installed), .checking)
    }

    func testInstalledFailedAndIdle() {
        XCTAssertEqual(InstallFlow.installPhase(isInstalling: false, outcome: installed), .installed(name: "Torrentio"))
        XCTAssertEqual(InstallFlow.installPhase(isInstalling: false, outcome: failed), .failed(message: "nope"))
        XCTAssertEqual(InstallFlow.installPhase(isInstalling: false, outcome: nil), .idle)
    }

    func testSheetForwardersMatchInstallFlow() {
        XCTAssertEqual(AddonInstallSheet.serial(of: failed), InstallFlow.serial(of: failed))
        XCTAssertEqual(AddonInstallSheet.installPhase(isInstalling: false, outcome: installed), InstallFlow.installPhase(isInstalling: false, outcome: installed))
    }
}
