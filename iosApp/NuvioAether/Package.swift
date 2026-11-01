// swift-tools-version: 6.1
// Aether feasibility spike (2026-11-01). A façade over AetherEngine so NuvioTV never imports Aether's
// Clang modules: MPVKit's `Libavutil` (FFmpeg 8.1.2) and Aether's `AetherLibavutil` (8.1.3 + patches)
// define the same inline functions with different bodies, and Clang refuses to load both in one
// compilation ("has different definitions in different modules"). `internal import AetherEngine`
// keeps the engine out of this package's public interface, so the app only loads this module.
import PackageDescription

let package = Package(
    name: "NuvioAether",
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [.library(name: "NuvioAether", targets: ["NuvioAether"])],
    dependencies: [
        .package(
            url: "https://github.com/superuser404notfound/AetherEngine",
            .upToNextMinor(from: "7.54.0"),
            traits: ["TrueHDObjectAudio", "DTSXObjectAudio", "DualLayerDolbyVision"]
        ),
    ],
    targets: [
        .target(
            name: "NuvioAether",
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Library evolution is what makes `internal import AetherEngine` hide the engine's
                // Clang modules from the app (SE-0409): without it the binary swiftmodule still makes
                // clients load AetherLibavutil, which clashes with MPVKit's Libavutil (2026-11-01).
                .unsafeFlags(["-enable-library-evolution"]),
            ]
        ),
    ]
)
