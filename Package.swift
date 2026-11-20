// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeTerminal",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Vendored (v1.13.0 + local scroll/mouse fixes) — see Vendor/SwiftTerm/VENDORED.md
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeTerminal",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
    ]
)
