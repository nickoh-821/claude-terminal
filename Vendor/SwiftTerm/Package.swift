// swift-tools-version:5.9
// Vendored SwiftTerm — see VENDORED.md for provenance and local patches.
// Library target only: the upstream fuzzer, termcast, tests, and benchmarks
// (and their swift-argument-parser / docc dependencies) are dropped.
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v13),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md"],
            resources: [
                .process("Apple/Metal/Shaders.metal")
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
