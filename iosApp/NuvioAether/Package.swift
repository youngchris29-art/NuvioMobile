// swift-tools-version: 6.1
// NuvioAether: the only module in NuvioTV that imports AetherEngine (Aether Phase 1, 2026-11-01).
//
// MPVKit's `Libavutil` (FFmpeg 8.1.2) and Aether's `AetherLibavutil` (8.1.3 + patches) define the same
// inline functions with different bodies, and Clang refuses to load both in one compilation ("has
// different definitions in different modules"). Every file here that needs the engine writes
// `internal import AetherEngine`, and library evolution keeps it out of this module's interface, so the
// app only ever loads NuvioAether and sees fork-owned types. Never import MPVKit here.
import PackageDescription

let package = Package(
    name: "NuvioAether",
    platforms: [.tvOS(.v18), .iOS(.v18), .macOS(.v15)],
    products: [.library(name: "NuvioAether", targets: ["NuvioAether"])],
    dependencies: [
        // Pinned: Aether ships minors almost daily, and a bump is its own task with the fixture matrix
        // rerun (plan section 11).
        .package(
            url: "https://github.com/superuser404notfound/AetherEngine",
            exact: "7.54.0",
            traits: ["TrueHDObjectAudio", "DTSXObjectAudio", "DualLayerDolbyVision"]
        ),
    ],
    targets: [
        .target(
            name: "NuvioAether",
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Library evolution is what makes `internal import AetherEngine` hide the engine's Clang
                // modules from the app (SE-0409): without it the binary swiftmodule still makes clients
                // load AetherLibavutil, which clashes with MPVKit's Libavutil (spike, 2026-11-01).
                .unsafeFlags(["-enable-library-evolution"]),
            ]
        ),
        .testTarget(
            name: "NuvioAetherTests",
            dependencies: ["NuvioAether"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
