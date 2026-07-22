// swift-tools-version: 6.2
import PackageDescription

// Step-0 scaffold manifest (docs/roadmap/README.md §3, phase 0; target graph:
// docs/01-architecture.md §1, target list: docs/06-cross-cutting.md §5).
// The HistoryStorage→Fuse edge is deferred to roadmap step 3 — do not add it
// here. xxh3 is package-internal (no product) and ships placeholder C source
// until step 3. ClipyIntegrationTests is XcodeGen-hosted and is NOT declared
// in this manifest.

let package = Package(
    name: "Clipy",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "HistoryCore", targets: ["HistoryCore"]),
        .library(name: "HistoryDomain", targets: ["HistoryDomain"]),
        .library(name: "HistoryStorage", targets: ["HistoryStorage"]),
        .library(name: "PasteboardAdapter", targets: ["PasteboardAdapter"]),
        .library(name: "PresentationUI", targets: ["PresentationUI"]),
    ],
    targets: [
        .target(name: "HistoryCore"),
        .target(
            name: "HistoryDomain",
            dependencies: ["HistoryCore"]
        ),
        .target(
            name: "HistoryStorage",
            dependencies: ["HistoryCore", "HistoryDomain", "xxh3"]
        ),
        .target(
            name: "PasteboardAdapter",
            dependencies: ["HistoryCore"]
        ),
        .target(
            name: "PresentationUI",
            dependencies: ["HistoryCore"]
        ),
        .target(
            name: "xxh3",
            path: "Sources/xxh3",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "HistoryPerfRunner",
            dependencies: ["HistoryCore"]
        ),
        .testTarget(
            name: "HistoryCoreTests",
            dependencies: ["HistoryCore"]
        ),
        .testTarget(
            name: "HistoryDomainTests",
            dependencies: ["HistoryDomain", "HistoryCore"]
        ),
        .testTarget(
            name: "HistoryStorageTests",
            dependencies: ["HistoryStorage", "HistoryDomain", "HistoryCore"]
        ),
        .testTarget(
            name: "PasteboardAdapterTests",
            dependencies: ["PasteboardAdapter", "HistoryCore"]
        ),
        .testTarget(
            name: "PresentationUITests",
            dependencies: ["PresentationUI", "HistoryCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
