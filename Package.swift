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
        .target(name: "ClipboardFormats"),
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
                "ClipboardFormats",
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
            dependencies: ["HistoryCore", "ClipboardFormats"]
        ),
        .target(
            name: "xxh3",
            path: "Sources/xxh3",
            publicHeadersPath: "include",
            // Compile the vendored implementation as translation-unit-local
            // inline code. Only Clipy's wrapper remains a global symbol;
            // scripts/xxh3_symbol_gate.sh proves that boundary.
            cSettings: [.define("XXH_INLINE_ALL")]
        ),
        .executableTarget(
            name: "HistoryPerfRunner",
            // HistoryStorage added at step 8: the §9 runner drives the public
            // SwiftDataHistory concrete facade. WL8 also calls the package
            // ThumbnailService seam after one prefetched immutable source so
            // it measures the shared decode rather than Authority serialization
            // (docs/06-cross-cutting.md §9; V1-Verified/04).
            dependencies: ["HistoryCore", "HistoryStorage"]
        ),
        .executableTarget(
            name: "HistoryRestartProbe",
            dependencies: ["HistoryCore", "HistoryStorage"]
        ),
        .testTarget(
            name: "ClipboardFormatsTests",
            dependencies: ["ClipboardFormats"]
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
            dependencies: [
                "HistoryStorage",
                "HistoryDomain",
                "HistoryCore",
                // RET-PLATFORM-1b(e) engine-level interruption fixture
                // (HistoryMigrationInterruptionTests) spawns the DEBUG
                // HistoryPerfRunner child mode; this edge guarantees
                // `swift test` builds that executable even without a prior
                // `swift build`.
                .target(name: "HistoryPerfRunner"),
                // Evidence Card 1C-1 runs three short-lived probe processes.
                // This build edge guarantees `.build/debug/HistoryRestartProbe`
                // exists before the test launches it directly; never nest a
                // second SwiftPM process inside `swift test`.
                .target(name: "HistoryRestartProbe"),
            ]
        ),
        .testTarget(
            // Perf/AB measurement-helper proofs live OUTSIDE the default
            // correctness lane: PR/push CI skips this target and the
            // dispatch-only `perf-tests` job runs its explicit filter only
            // after correctness is green.
            name: "HistoryPerfTests",
            dependencies: [.target(name: "HistoryPerfRunner")]
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
