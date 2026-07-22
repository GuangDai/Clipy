// swift-tools-version: 6.2
import PackageDescription

// Step-0 scaffold manifest (docs/roadmap/README.md §3, phase 0; target graph:
// docs/01-architecture.md §1, target list: docs/06-cross-cutting.md §5).
// The HistoryStorage→Fuse edge landed at roadmap step 3 (pinned below; first
// imported at step 7). xxh3 is package-internal (no product) and vendors
// pinned xxHash v0.8.3 since step 3 (see Sources/xxh3/VENDORED.md).
// ClipyIntegrationTests is XcodeGen-hosted and is NOT declared in this
// manifest.

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
    dependencies: [
        // Tag 1.4.0 (NOT 2.0.0-rc.x, per docs/roadmap/07-external-deps.md and
        // docs/AUDIT.md §4b).
        .package(url: "https://github.com/krisk/fuse-swift.git", revision: "26ba868691b2d8b7bf2b1322951eb591be70ccca"),
    ],
    targets: [
        .target(name: "HistoryCore"),
        .target(
            name: "HistoryDomain",
            dependencies: ["HistoryCore"]
        ),
        .target(
            name: "HistoryStorage",
            dependencies: [
                "HistoryCore",
                "HistoryDomain",
                "xxh3",
                .product(name: "Fuse", package: "fuse-swift"),
            ]
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
            dependencies: ["HistoryCore"],
            exclude: ["SymbolSurface"]
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
