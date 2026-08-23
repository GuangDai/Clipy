// swift-tools-version: 6.2
import PackageDescription

// Proof-only package for the dispatch-only General pasteboard cross-process
// leaf. Keeping these executables outside Clipy's root package preserves the
// production target graph while still compiling the writer against the
// shipped public History and PasteboardAdapter interfaces.
let package = Package(
    name: "ClipyPasteboardCrossProcessProbe",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ClipyPasteboardWriter", targets: ["ClipyPasteboardWriter"]),
        .executable(name: "ClipyPasteboardReader", targets: ["ClipyPasteboardReader"]),
    ],
    dependencies: [
        .package(name: "Clipy", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "ClipyPasteboardWriter",
            dependencies: [
                .product(name: "HistoryCore", package: "Clipy"),
                .product(name: "HistoryStorage", package: "Clipy"),
                .product(name: "PasteboardAdapter", package: "Clipy"),
            ],
            path: "Sources/Writer"
        ),
        .executableTarget(
            name: "ClipyPasteboardReader",
            path: "Sources/Reader"
        ),
    ],
    swiftLanguageModes: [.v6]
)
