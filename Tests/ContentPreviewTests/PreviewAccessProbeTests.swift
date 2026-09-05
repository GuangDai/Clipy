/// PreviewAccessProbeTests — owner suites for the PLAY-TIER-1A decoder
/// access-mode characterization probe (docs/reviews/
/// 2026-08-22-clipy-maccy-deep-review/04-tdd-remediation-playbook.md §26
/// TIER row 1; that review's 09 §5/§12 DESIGN-TIER-16; docs/v2/
/// V2-08-decoder-access-modes.md).
///
/// Architecture (why no probed ImageIO call ever runs in THIS process):
/// the probe engine is DEBUG-only package code in Sources/ContentPreview/
/// PreviewAccessProbe.swift, executed by the DEBUG-only
/// `PreviewAccessProbeRunner` executable — one short-lived child per
/// fixture, the HistoryRestartProbe/TrueRestartChildTests precedent. The
/// incremental-range mode decodes DELIBERATELY TRUNCATED payloads, and
/// framework decoders log on partial data (libpng partial-decode error
/// lines failed the CI log self-scan in run 32259544566 — see
/// scripts/generate_fixtures.py's fixture-exclusion note); the child's
/// stderr is dropped so those diagnostics never reach the CI log, and the
/// process boundary additionally contains any partial-data decoder crash.
/// The parent asserts only the child's content-free JSONL records and its
/// `PROBE_OK` completion marker.
///
/// Two layers, mirroring the repo's fixture discipline:
///
/// - `PreviewAccessProbeTests` (always green, fresh-clone safe): sink
///   recording semantics with hand-built records (the
///   ThumbnailMeasurementTests posture — durations are
///   presence/non-negativity only, never a threshold), the envelope gate,
///   and the structural mode facts on one in-test synthesized PNG via the
///   child.
/// - `PreviewAccessProfileTests` (`.enabled(if: FixtureCatalog.available)`,
///   always on in CI because the fixture fetch step fails the job on any
///   error): the real-scale characterization over the fixtures-v1 image
///   set. Header-prefix floors are LITERAL facts of the pinned
///   fixture bytes (PNG IHDR ends at byte 33; the JPEG SOF0 segment ends at
///   byte 177; GIF LSD at 13; BMP dimensions at 26; the TIFF IFD sits at
///   the END of its file — the layout scan is recorded in V2-08 §3), not
///   UTI-name presumptions (09 §12's rule). Field placement gives no upper
///   bound on when ImageIO publishes dimensions from an unfinalized source.
///
/// Both suites only assert decoder facts the probe actually measures; no
/// timing threshold is ever adjudicated here (characterization, playbook
/// §26 — G8 adjudication stays with 06 §3 and V2-06's P3 record).
#if DEBUG
import ContentPreview
import CoreGraphics
import Foundation
import ImageIO
import Testing

// MARK: - Shared child boundary (file-private)

/// The child protocol's failure vocabulary. A thrown error beats a trap.
private enum ProbeChildError: Error {
    case childFailed
}

/// The runner executable, addressed by the same `.build/debug` convention
/// TrueRestartChildTests uses for HistoryRestartProbe; the Package.swift
/// test-target build edge guarantees it exists under a bare `swift test`.
private let previewAccessProbeRunnerURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".build/debug/PreviewAccessProbeRunner")

/// Decodes sink JSONL back through the real `PreviewAccessRecord` Codable
/// implementation — the same bytes an evidence run parses.
private func readProbeRecords(at fileURL: URL) throws -> [PreviewAccessRecord] {
    let data = try Data(contentsOf: fileURL)
    guard !data.isEmpty else { return [] }
    let decoder = JSONDecoder()
    return try data.split(separator: 0x0A).map { line in
        try decoder.decode(PreviewAccessRecord.self, from: line)
    }
}

/// Runs the probe-runner child over one fixture file and returns its three
/// records. stdout carries only the fixed `PROBE_OK` completion marker;
/// stderr is dropped (header rationale — decoder diagnostics on truncated
/// prefixes are neither evidence nor safe CI-log content).
private func runPreviewAccessProbeChild(
    fixtureID: String,
    typeIdentifier: String,
    maximumPixelExtent: Int,
    fixtureFileURL: URL,
    outFileURL: URL
) throws -> [PreviewAccessRecord] {
    let process = Process()
    let output = Pipe()
    process.executableURL = previewAccessProbeRunnerURL
    process.arguments = [
        fixtureID,
        typeIdentifier,
        String(maximumPixelExtent),
        fixtureFileURL.path,
        outFileURL.path,
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    try process.run()
    let result = try output.fileHandleForReading.readToEnd() ?? Data()
    process.waitUntilExit()
    guard process.terminationReason == .exit,
          process.terminationStatus == EXIT_SUCCESS,
          result == Data("PROBE_OK\n".utf8) else {
        throw ProbeChildError.childFailed
    }
    return try readProbeRecords(at: outFileURL)
}

/// One fresh pre-created directory per child run (the repo's CI-noise rule
/// for on-disk test artifacts). The caller owns removing it.
private func makeProbeChildDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

@Suite("PreviewAccessProbe mechanics")
struct PreviewAccessProbeTests {

    private enum FixtureError: Error {
        case synthesisFailed
    }

    /// Deterministic 64×48 BGRA8 pattern encoded as PNG through ImageIO —
    /// the always-available small fixture (the fixture tree covers real
    /// scale; this one keeps the mechanics suite green on a fresh clone,
    /// the `onePixelPNG` precedent in ContentPreviewTests). Valid and
    /// complete, so its synthesis in this process cannot emit decoder
    /// diagnostics. Encoded byte count is never asserted: only structure
    /// and relations are.
    private func synthesizedPNG() throws -> Data {
        let width = 64
        let height = 48
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                pixels[offset] = UInt8(x)
                pixels[offset + 1] = UInt8(y)
                pixels[offset + 2] = UInt8(x + y)
                pixels[offset + 3] = 255
            }
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw FixtureError.synthesisFailed
        }
        let image: CGImage = try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            ), let image = context.makeImage() else {
                throw FixtureError.synthesisFailed
            }
            return image
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw FixtureError.synthesisFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.synthesisFailed
        }
        return output as Data
    }

    // MARK: - Sink recording

    /// Hand-built records pass through the sink one sorted JSON line each,
    /// with sink-assigned `seq`/`monotonicMs` and an exact field round trip
    /// (durations excluded from equality: JSON `Double` text is not a
    /// contractual representation — they are asserted present and
    /// non-negative instead, the ThumbnailMeasurementTests posture). This
    /// test deliberately touches no decoder.
    @Test func sinkWritesOneSortedLinePerRecord() throws {
        let directory = try makeProbeChildDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("access-probe.jsonl")
        var records: [PreviewAccessRecord] = [
            PreviewAccessMode.headerOnly,
            .incrementalRange,
            .fullDecode,
        ].map { mode in
            var record = PreviewAccessRecord(
                fixtureID: "manual-\(mode.rawValue)",
                typeIdentifier: "public.png",
                mode: mode,
                inputBytes: 848_017,
                maximumPixelExtent: 640
            )
            record.satisfiedPrefixBytes = 33
            record.largestFailingPrefixBytes = 32
            record.wallMs = 0.5
            record.intrinsicWidth = 3_840
            record.intrinsicHeight = 2_160
            record.outputWidth = 640
            record.outputHeight = 360
            record.outputBytes = 640 * 360 * 4
            record.decoderStatus = 0
            record.decodesUnfinalizedAtFullLength = true
            record.dimensionsAvailableUnfinalizedAtFullLength = true
            return record
        }
        // Create-on-first-use: nothing on disk before the first record.
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        let sink = PreviewAccessMeasurement(fileURL: fileURL)
        for index in records.indices {
            sink.record(&records[index])
        }

        let decoded = try readProbeRecords(at: fileURL)
        #expect(decoded.count == 3)
        #expect(decoded.map(\.seq) == [1, 2, 3])
        #expect(decoded.map(\.monotonicMs) == records.map(\.monotonicMs))
        #expect(decoded[0].monotonicMs <= decoded[2].monotonicMs)
        for (actual, expectedRecord) in zip(decoded, records) {
            var normalizedActual = actual
            normalizedActual.wallMs = nil
            var expected = expectedRecord
            expected.wallMs = nil
            #expect(normalizedActual == expected)
            let wallMs = try #require(actual.wallMs)
            #expect(wallMs >= 0)
        }
    }

    /// The sink activates only for an absolute path in
    /// `CLIPY_PREVIEW_ACCESS_MEASUREMENT_PATH` (the
    /// `ThumbnailMeasurement.makeIfRequested` absolute-path gate, minus the
    /// running-app envelope: this probe is test-lane driven).
    @Test func sinkActivatesOnlyForAbsolutePath() {
        #expect(PreviewAccessMeasurement.makeIfRequested(environment: [:]) == nil)
        #expect(
            PreviewAccessMeasurement.makeIfRequested(environment: [
                "CLIPY_PREVIEW_ACCESS_MEASUREMENT_PATH": "relative.jsonl",
            ]) == nil
        )
        #expect(
            PreviewAccessMeasurement.makeIfRequested(environment: [
                "CLIPY_PREVIEW_ACCESS_MEASUREMENT_PATH": "/tmp/access-probe.jsonl",
            ]) != nil
        )
    }

    // MARK: - Mode structure via the child (synthesized PNG)

    /// One child run over the synthesized PNG yields the three modes in
    /// wire order, echoing fixture identity and input bytes; the header
    /// mode measures the prefix needed to publish the dimensions
    /// (floor 24: PNG width/height end at byte 24) while the full mode
    /// decodes the 64×48 image unscaled (below the 640-px box).
    @Test func synthesizedPNGHeaderPrefixAndFullDecode() throws {
        let directory = try makeProbeChildDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try synthesizedPNG()
        let fixtureURL = directory.appendingPathComponent("synthesized.png")
        try png.write(to: fixtureURL)
        let records = try runPreviewAccessProbeChild(
            fixtureID: "synthesized-64x48-png",
            typeIdentifier: "public.png",
            maximumPixelExtent: 640,
            fixtureFileURL: fixtureURL,
            outFileURL: directory.appendingPathComponent("records.jsonl")
        )

        #expect(records.map(\.mode) == [.headerOnly, .incrementalRange, .fullDecode])
        #expect(records.map(\.seq) == [1, 2, 3])
        #expect(records.allSatisfy { $0.fixtureID == "synthesized-64x48-png" })
        #expect(records.allSatisfy { $0.typeIdentifier == "public.png" })
        #expect(records.allSatisfy { $0.inputBytes == png.count })
        #expect(records.allSatisfy { $0.maximumPixelExtent == 640 })

        let header = records[0]
        #expect(header.intrinsicWidth == 64)
        #expect(header.intrinsicHeight == 48)
        #expect(header.decoderStatus != nil)
        #expect(header.dimensionsAvailableUnfinalizedAtFullLength == true)
        let headerPrefix = try #require(header.satisfiedPrefixBytes)
        #expect(headerPrefix >= 24)
        #expect(headerPrefix <= png.count)
        #expect(header.largestFailingPrefixBytes == headerPrefix - 1)
        let headerWallMs = try #require(header.wallMs)
        #expect(headerWallMs >= 0)

        let full = records[2]
        #expect(full.outputWidth == 64)
        #expect(full.outputHeight == 48)
        #expect(full.outputBytes == 64 * 48 * 4)
        #expect(full.satisfiedPrefixBytes == nil)
        let fullWallMs = try #require(full.wallMs)
        #expect(fullWallMs >= 0)

        // The range mode is discovery, not presumption: if a prefix
        // decoded, it cannot need fewer bytes than the header did; either
        // way the unfinalized full-length probe is recorded.
        let range = records[1]
        if let satisfied = range.satisfiedPrefixBytes {
            #expect(satisfied >= headerPrefix)
            #expect(satisfied < png.count)
            #expect(range.outputWidth != nil)
            #expect(range.wallMs != nil)
        } else {
            #expect(range.largestFailingPrefixBytes != nil)
            #expect(range.wallMs == nil)
        }
        #expect(range.decodesUnfinalizedAtFullLength != nil)
    }

    /// Non-image bytes fail closed into recorded nils (no dimensions, no
    /// prefix claim, no decode) rather than traps — under both ImageIO
    /// source-creation behaviors for unrecognized data.
    @Test func nonImageBytesRecordNoAccessMode() throws {
        let directory = try makeProbeChildDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let garbageURL = directory.appendingPathComponent("garbage.bin")
        try Data(repeating: 0x61, count: 1_024).write(to: garbageURL)
        let records = try runPreviewAccessProbeChild(
            fixtureID: "synthesized-garbage",
            typeIdentifier: "public.png",
            maximumPixelExtent: 640,
            fixtureFileURL: garbageURL,
            outFileURL: directory.appendingPathComponent("records.jsonl")
        )

        #expect(records.map(\.mode) == [.headerOnly, .incrementalRange, .fullDecode])
        let header = records[0]
        #expect(header.intrinsicWidth == nil)
        #expect(header.satisfiedPrefixBytes == nil)
        #expect(header.largestFailingPrefixBytes == nil)
        #expect(header.dimensionsAvailableUnfinalizedAtFullLength == nil)
        let full = records[2]
        #expect(full.outputWidth == nil)
        #expect(full.outputBytes == nil)
        let range = records[1]
        #expect(range.satisfiedPrefixBytes == nil)
        #expect(range.decodesUnfinalizedAtFullLength == false)
    }
}

@Suite(
    "PreviewAccessProbe real-scale profile (fixtures-v1)",
    .enabled(
        if: FixtureCatalog.available,
        "clipy-fixtures-v1 tree absent (CLIPY_FIXTURES_DIR unset)"
    ),
    .serialized
)
struct PreviewAccessProfileTests {

    /// One real-scale fixture and its LITERAL identity/layout facts (the
    /// pinned fixtures-v1 tree; byte counts from manifest.json, header
    /// floors from the byte-layout scan recorded in V2-08 §3).
    private struct RealFixture {
        let path: String
        let typeIdentifier: String
        let inputBytes: Int
        let intrinsicWidth: Int
        let intrinsicHeight: Int
        /// Structural minimum prefix for the dimensions (first byte after
        /// the field that carries them).
        let headerPrefixFloor: Int
        /// Expected full-decode thumbnail dimensions at the 640-px
        /// history-pane box (`maximumPixelExtent` is a maximum; smaller
        /// images pass through unscaled).
        let fullWidth: Int
        let fullHeight: Int
    }

    /// The six head-fixed-layout fixtures. The TIFF is deliberately NOT
    /// here: its IFD sits at the end of the file, which is exactly the
    /// access-mode fact `tiffHeaderIsNotAnEarlyPrefix` locks separately.
    private static let headFixedFixtures: [RealFixture] = [
        RealFixture(
            path: "images/photo4k-a.png",
            typeIdentifier: "public.png",
            inputBytes: 848_017,
            intrinsicWidth: 3_840,
            intrinsicHeight: 2_160,
            headerPrefixFloor: 24,
            fullWidth: 640,
            fullHeight: 360
        ),
        RealFixture(
            path: "images/icon-512.png",
            typeIdentifier: "public.png",
            inputBytes: 56_889,
            intrinsicWidth: 512,
            intrinsicHeight: 512,
            headerPrefixFloor: 24,
            fullWidth: 512,
            fullHeight: 512
        ),
        RealFixture(
            path: "images/huge-8k.png",
            typeIdentifier: "public.png",
            inputBytes: 3_136_852,
            intrinsicWidth: 7_680,
            intrinsicHeight: 4_320,
            headerPrefixFloor: 24,
            fullWidth: 640,
            fullHeight: 360
        ),
        RealFixture(
            path: "images/photo4k-b.jpg",
            typeIdentifier: "public.jpeg",
            inputBytes: 189_348,
            intrinsicWidth: 3_840,
            intrinsicHeight: 2_160,
            headerPrefixFloor: 158,
            fullWidth: 640,
            fullHeight: 360
        ),
        RealFixture(
            path: "images/anim-720.gif",
            typeIdentifier: "com.compuserve.gif",
            inputBytes: 342_612,
            intrinsicWidth: 1_280,
            intrinsicHeight: 720,
            headerPrefixFloor: 10,
            fullWidth: 640,
            fullHeight: 360
        ),
        RealFixture(
            path: "images/photo-1080.bmp",
            typeIdentifier: "com.microsoft.bmp",
            inputBytes: 6_220_854,
            intrinsicWidth: 1_920,
            intrinsicHeight: 1_080,
            headerPrefixFloor: 26,
            fullWidth: 640,
            fullHeight: 360
        ),
    ]

    /// Runs one probe child over the fixture and re-records the child's
    /// records through the opt-in sink when
    /// `CLIPY_PREVIEW_ACCESS_MEASUREMENT_PATH` is set (the evidence-run
    /// extraction path; nil in every ordinary run).
    private func characterize(_ fixture: RealFixture) throws -> [PreviewAccessRecord] {
        let directory = try makeProbeChildDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var records = try runPreviewAccessProbeChild(
            fixtureID: fixture.path,
            typeIdentifier: fixture.typeIdentifier,
            maximumPixelExtent: 640,
            fixtureFileURL: try FixtureCatalog.url(fixture.path),
            outFileURL: directory.appendingPathComponent("records.jsonl")
        )
        if let sink = PreviewAccessMeasurement.makeIfRequested() {
            for index in records.indices {
                sink.record(&records[index])
            }
        }
        return records
    }

    /// Dimension fields are near the head, but ImageIO can defer publishing
    /// them until later bytes or until finalization (V2-08 §5.1). Require
    /// complete-source dimensions and validate the measured prefix relation;
    /// an unavailable incremental header must retain its failed full-input
    /// observation. Full decode still has exact product output expectations.
    private func expectHeadFixedProfile(_ fixture: RealFixture) throws {
        let records = try characterize(fixture)
        #expect(records.map(\.mode) == [.headerOnly, .incrementalRange, .fullDecode])
        #expect(records.map(\.seq) == [1, 2, 3])
        #expect(records.allSatisfy { $0.fixtureID == fixture.path })
        #expect(records.allSatisfy { $0.inputBytes == fixture.inputBytes })

        let header = records[0]
        #expect(header.intrinsicWidth == fixture.intrinsicWidth)
        #expect(header.intrinsicHeight == fixture.intrinsicHeight)
        let dimensionsAvailable = try #require(
            header.dimensionsAvailableUnfinalizedAtFullLength as Bool?
        )
        if dimensionsAvailable {
            let headerPrefix = try #require(header.satisfiedPrefixBytes)
            #expect(headerPrefix >= fixture.headerPrefixFloor)
            #expect(headerPrefix <= fixture.inputBytes)
            #expect(header.largestFailingPrefixBytes == headerPrefix - 1)
        } else {
            #expect(header.satisfiedPrefixBytes == nil)
            #expect(header.largestFailingPrefixBytes == fixture.inputBytes)
        }
        let headerWallMs = try #require(header.wallMs)
        #expect(headerWallMs >= 0)

        let range = records[1]
        if let satisfied = range.satisfiedPrefixBytes {
            if let headerPrefix = header.satisfiedPrefixBytes {
                #expect(satisfied >= headerPrefix)
            }
            #expect(satisfied < fixture.inputBytes)
            let outputWidth = try #require(range.outputWidth)
            let outputHeight = try #require(range.outputHeight)
            #expect(outputWidth > 0)
            #expect(outputHeight > 0)
            #expect(range.outputBytes == outputWidth * outputHeight * 4)
            #expect(range.wallMs != nil)
        } else {
            #expect(range.largestFailingPrefixBytes != nil)
            #expect(range.wallMs == nil)
        }
        #expect(range.decodesUnfinalizedAtFullLength != nil)

        let full = records[2]
        #expect(full.outputWidth == fixture.fullWidth)
        #expect(full.outputHeight == fixture.fullHeight)
        #expect(full.outputBytes == fixture.fullWidth * fixture.fullHeight * 4)
        let fullWallMs = try #require(full.wallMs)
        #expect(fullWallMs >= 0)
    }

    @Test func photo4kPNGProfile() throws {
        try expectHeadFixedProfile(Self.headFixedFixtures[0])
    }

    @Test func icon512PNGProfile() throws {
        try expectHeadFixedProfile(Self.headFixedFixtures[1])
    }

    @Test func huge8kPNGProfile() throws {
        try expectHeadFixedProfile(Self.headFixedFixtures[2])
    }

    @Test func photo4kJPEGProfile() throws {
        try expectHeadFixedProfile(Self.headFixedFixtures[3])
    }

    @Test func anim720GIFProfile() throws {
        try expectHeadFixedProfile(Self.headFixedFixtures[4])
    }

    @Test func photo1080BMPProfile() throws {
        try expectHeadFixedProfile(Self.headFixedFixtures[5])
    }

    /// The TIFF counterexample that justifies PLAY-TIER-1A's "never presume
    /// header-only from the UTI" rule (09 §12): this fixture's IFD — the
    /// structure carrying pixel dimensions — sits at offset 1,185,738 of
    /// 1,189,326 bytes (99.7%), so a prefix-only header read is impossible;
    /// the decoder either reports dimensions only from a near-complete
    /// prefix or never reports them unfinalized. Both are recorded as
    /// evidence that THIS layout's header mode costs effectively the full
    /// read (or a two-range read, which only a post-G8 physical range seam
    /// could serve — PLAY-TIER-2B is BLOCKED-SPEC/BLOCKED-G8).
    @Test func tiffHeaderIsNotAnEarlyPrefix() throws {
        let fixture = RealFixture(
            path: "images/photo4k-c.tiff",
            typeIdentifier: "public.tiff",
            inputBytes: 1_189_326,
            intrinsicWidth: 3_840,
            intrinsicHeight: 2_160,
            headerPrefixFloor: 0,
            fullWidth: 640,
            fullHeight: 360
        )
        let records = try characterize(fixture)
        #expect(records.map(\.mode) == [.headerOnly, .incrementalRange, .fullDecode])
        #expect(records.allSatisfy { $0.inputBytes == fixture.inputBytes })

        let header = records[0]
        #expect(header.intrinsicWidth == 3_840)
        #expect(header.intrinsicHeight == 2_160)
        if let headerPrefix = header.satisfiedPrefixBytes {
            #expect(header.dimensionsAvailableUnfinalizedAtFullLength == true)
            #expect(headerPrefix > fixture.inputBytes - 8_192)
            #expect(headerPrefix <= fixture.inputBytes)
            #expect(header.largestFailingPrefixBytes == headerPrefix - 1)
        } else {
            // Unfinalized incremental TIFF never surfaced dimensions: the
            // header purpose is unservable by any prefix on this layout.
            #expect(header.dimensionsAvailableUnfinalizedAtFullLength == false)
            #expect(header.largestFailingPrefixBytes == fixture.inputBytes)
        }
        let headerWallMs = try #require(header.wallMs)
        #expect(headerWallMs >= 0)

        let full = records[2]
        #expect(full.outputWidth == 640)
        #expect(full.outputHeight == 360)
        #expect(full.outputBytes == 640 * 360 * 4)
        let fullWallMs = try #require(full.wallMs)
        #expect(fullWallMs >= 0)
    }
}
#endif
