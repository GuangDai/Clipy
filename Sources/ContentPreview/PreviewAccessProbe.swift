/// PreviewAccessProbe.swift — PLAY-TIER-1A decoder access-mode
/// characterization for ContentPreview's ImageIO raster path
/// (docs/reviews/2026-08-22-clipy-maccy-deep-review/
/// 04-tdd-remediation-playbook.md §26 TIER row 1; that review's
/// 09-tiered-storage-and-unbounded-history.md §5 and §12 DESIGN-TIER-16;
/// docs/v2/V2-08-decoder-access-modes.md).
///
/// This is a PLATFORM CHARACTERIZATION, not a gate (playbook §26:
/// "`PLAY-TIER-1A` [PLATFORM CHARACTERIZATION，非 Red]"). Nothing here
/// evaluates a threshold, fails a build, or changes product behavior. The
/// probe records which of header / incremental-range / full-decode the
/// concrete decoder actually needs for a purpose, because 09 §12 forbids
/// inferring the mode from the UTI name ("access mode 是具体
/// decoder+fixture+OS 实测分类，不由 UTI 名称静态推断"). Its two claims are
/// deliberately narrow:
///
/// - "Bytes read" is measured as the smallest PREFIX of the encoded payload
///   that satisfies the mode's condition on a fresh
///   `CGImageSourceCreateIncremental` source. The product decoder consumes
///   an in-memory `Data` (`ContentPreview.renderRaster`), so no file or
///   syscall trace exists inside ImageIO to sample; the prefix the parser
///   can work with is the honest, OS-independent proxy for what a future
///   range read (PLAY-TIER-2B is BLOCKED-SPEC/BLOCKED-G8) would have to
///   deliver. Satisfaction is assumed monotone in prefix length — a parser
///   that has seen a header never un-sees it when more bytes arrive — and
///   both binary-search endpoints are verified, never assumed.
/// - "Time" is one `ContinuousClock` window around the mode's single
///   representative operation on the full in-memory input (the
///   current-layout cost; the whole-aggregate hydration upstream of this
///   decoder is current-layout fact, separately accounted by
///   PLAY-TIER-2A-THUMB's `returnedRepresentationBytes`/
///   `aggregateHydratedBytes` receipt pair).
///
/// Everything in this file compiles out of Release and is `package`-scoped
/// (the `ContentPreviewDebugInstrumentation` posture): the probe is pure
/// measurement returning in-memory records, and the sink is opt-in
/// persistence for evidence runs. Records are content-free: fixture
/// identity, mode, byte counts, dimensions, status and durations — never
/// pixel or clipboard bytes.
#if DEBUG
import CoreGraphics
import Foundation
import ImageIO

/// The three access modes PLAY-TIER-1A compares. Wire values are stable:
/// `PreviewAccessMeasurement` JSONL is an evidence artifact.
package enum PreviewAccessMode: String, Codable, Sendable {
    /// Intrinsic primary-image properties (pixel dimensions) without any
    /// pixel decode — the cheapest purpose a header can serve.
    case headerOnly
    /// A thumbnail decode attempted on an UNFINALIZED incremental source
    /// fed only a prefix — what a range read could serve.
    case incrementalRange
    /// The product's decode core: complete source + thumbnail creation with
    /// the exact option dictionary of `ContentPreview.renderRaster`.
    case fullDecode
}

/// One probe observation. `seq`/`monotonicMs` are sink-assigned (zero while
/// a record only exists in memory). Optional fields are present exactly
/// where the mode measured them:
///
/// - `satisfiedPrefixBytes`/`largestFailingPrefixBytes`: header mode
///   binary-searches the EXACT minimum satisfying prefix (failing = minimum
///   − 1), or records the full input as failing when the unfinalized
///   source never publishes dimensions; range mode reports the factor-4
///   ladder rung that first decoded and the previous failing rung;
///   full mode leaves both nil (it reads the
///   whole input by construction).
/// - `wallMs`: header = full-data `CGImageSourceCopyPropertiesAtIndex`;
///   range = the satisfying ladder decode (nil when no prefix decoded);
///   full = the complete-source thumbnail decode.
/// - `intrinsicWidth/Height`: header mode only. `outputWidth/Height`/
///   `outputBytes` (w×h×4 — the product's BGRA8 artifact cost): the two
///   decode modes only, when an image was produced.
/// - `decoderStatus`: `CGImageSourceStatus.rawValue` at the mode's final
///   check — kept as a literal because partial-data statuses are the
///   decoder's own vocabulary.
/// - `decodesUnfinalizedAtFullLength`: range mode only — separates "needs
///   the tail bytes" from "needs the completion flag" when no proper prefix
///   decoded.
/// - `dimensionsAvailableUnfinalizedAtFullLength`: header mode only, after
///   complete-source dimensions are available. A false value distinguishes
///   an incremental decoder limitation from missing dimensions in the file.
package struct PreviewAccessRecord: Codable, Sendable, Equatable {
    package var seq = 0
    /// Milliseconds on the continuous clock since sink creation — monotone
    /// ordering evidence, not a wall-clock timestamp.
    package var monotonicMs: Int64 = 0
    /// Content-free fixture identity (fixture-tree relative path or a
    /// synthesized-fixture label).
    package var fixtureID: String
    package var typeIdentifier: String
    package var mode: PreviewAccessMode
    /// Full encoded byte count of the fixture input.
    package var inputBytes: Int
    /// The thumbnail pixel box the decode modes ran with (the product's
    /// history-pane profile is 640; `ContentPreview.ResourceProfile`).
    package var maximumPixelExtent: Int
    package var satisfiedPrefixBytes: Int?
    package var largestFailingPrefixBytes: Int?
    package var wallMs: Double?
    package var intrinsicWidth: Int?
    package var intrinsicHeight: Int?
    package var outputWidth: Int?
    package var outputHeight: Int?
    package var outputBytes: Int?
    package var decoderStatus: Int?
    package var decodesUnfinalizedAtFullLength: Bool?
    package var dimensionsAvailableUnfinalizedAtFullLength: Bool?

    package init(
        fixtureID: String,
        typeIdentifier: String,
        mode: PreviewAccessMode,
        inputBytes: Int,
        maximumPixelExtent: Int
    ) {
        self.fixtureID = fixtureID
        self.typeIdentifier = typeIdentifier
        self.mode = mode
        self.inputBytes = inputBytes
        self.maximumPixelExtent = maximumPixelExtent
    }
}

/// The probe engine. Stateless namespace (no actor, no I/O, no cache): each
/// mode runs fresh ImageIO sources over the caller's immutable bytes and
/// returns its record. Synchronous because ImageIO's in-memory source API is
/// synchronous; owner tests and evidence runs drive it directly.
package enum PreviewAccessProbe {

    /// Runs all three modes over one fixture, in the fixed wire order
    /// `[headerOnly, incrementalRange, fullDecode]`. `maximumPixelExtent`
    /// must be named by the caller so a record can never silently drift
    /// from the product profile it claims to characterize.
    package static func characterize(
        fixtureID: String,
        typeIdentifier: String,
        bytes: Data,
        maximumPixelExtent: Int
    ) -> [PreviewAccessRecord] {
        [
            headerOnly(
                fixtureID: fixtureID,
                typeIdentifier: typeIdentifier,
                bytes: bytes,
                maximumPixelExtent: maximumPixelExtent
            ),
            incrementalRange(
                fixtureID: fixtureID,
                typeIdentifier: typeIdentifier,
                bytes: bytes,
                maximumPixelExtent: maximumPixelExtent
            ),
            fullDecode(
                fixtureID: fixtureID,
                typeIdentifier: typeIdentifier,
                bytes: bytes,
                maximumPixelExtent: maximumPixelExtent
            ),
        ]
    }

    // MARK: - headerOnly

    /// Cost of the dimensions-only purpose: a timed property read over the
    /// FULL input (the current layout, where the bytes are already
    /// materialized), then a binary search for the exact minimum prefix
    /// whose fresh incremental source surfaces both pixel dimensions. The
    /// search only runs when full data actually satisfies the condition —
    /// without a verified satisfying upper endpoint there is no prefix
    /// claim to record.
    private static func headerOnly(
        fixtureID: String,
        typeIdentifier: String,
        bytes: Data,
        maximumPixelExtent: Int
    ) -> PreviewAccessRecord {
        var record = PreviewAccessRecord(
            fixtureID: fixtureID,
            typeIdentifier: typeIdentifier,
            mode: .headerOnly,
            inputBytes: bytes.count,
            maximumPixelExtent: maximumPixelExtent
        )
        let start = ContinuousClock.Instant.now
        if let source = CGImageSourceCreateWithData(bytes as CFData, nil) {
            let index = CGImageSourceGetPrimaryImageIndex(source)
            let size = primaryPixelSize(of: source, index: index)
            // Read AFTER the property copy so the parser's settled state is
            // what gets recorded.
            record.decoderStatus = Int(
                CGImageSourceGetStatusAtIndex(source, index).rawValue
            )
            record.intrinsicWidth = size?.width
            record.intrinsicHeight = size?.height
        }
        record.wallMs = elapsedMilliseconds(since: start)
        guard record.intrinsicWidth != nil else { return record }
        let unfinalizedSize = primaryPixelSizeFromIncrementalPrefix(
            bytes, count: bytes.count
        )
        record.dimensionsAvailableUnfinalizedAtFullLength = unfinalizedSize != nil
        guard unfinalizedSize != nil else {
            record.largestFailingPrefixBytes = bytes.count
            return record
        }
        let search = minimumSatisfyingPrefix(totalBytes: bytes.count) { prefix in
            primaryPixelSizeFromIncrementalPrefix(bytes, count: prefix) != nil
        }
        record.satisfiedPrefixBytes = search?.satisfied
        record.largestFailingPrefixBytes = search?.failing
        return record
    }

    // MARK: - incrementalRange

    /// What a range read could serve: fresh UNFINALIZED incremental sources
    /// fed a factor-4 prefix ladder (coarse by design — the result feeds an
    /// order-of-magnitude access plan, and every rung costs a real partial
    /// decode proportional to the prefix). The final unfinalized
    /// full-length attempt distinguishes "the tail bytes were required"
    /// from "the completion flag was required" when no proper prefix
    /// decoded; both outcomes are evidence, not failures.
    private static func incrementalRange(
        fixtureID: String,
        typeIdentifier: String,
        bytes: Data,
        maximumPixelExtent: Int
    ) -> PreviewAccessRecord {
        var record = PreviewAccessRecord(
            fixtureID: fixtureID,
            typeIdentifier: typeIdentifier,
            mode: .incrementalRange,
            inputBytes: bytes.count,
            maximumPixelExtent: maximumPixelExtent
        )
        var prefix = 64
        while prefix < bytes.count {
            let attemptStart = ContinuousClock.Instant.now
            let attempt = thumbnailFromIncrementalPrefix(
                bytes,
                count: prefix,
                maximumPixelExtent: maximumPixelExtent
            )
            if let image = attempt.image {
                record.satisfiedPrefixBytes = prefix
                record.wallMs = elapsedMilliseconds(since: attemptStart)
                record.decoderStatus = attempt.status
                record.outputWidth = image.width
                record.outputHeight = image.height
                record.outputBytes = image.width * image.height * 4
                break
            }
            record.largestFailingPrefixBytes = prefix
            prefix *= 4
        }
        let unfinalized = thumbnailFromIncrementalPrefix(
            bytes,
            count: bytes.count,
            maximumPixelExtent: maximumPixelExtent
        )
        record.decodesUnfinalizedAtFullLength = unfinalized.image != nil
        return record
    }

    // MARK: - fullDecode

    /// The product's decode core, timed once on the complete input: the
    /// same source construction and the same four thumbnail options as
    /// `ContentPreview.renderRaster` (Sources/ContentPreview/
    /// ContentPreview.swift). The eager BGRA8 redraw that follows in the
    /// product is deterministic from the reported dimensions
    /// (`outputBytes`), so it is not re-measured here; the end-to-end
    /// product-path timing is already the running-app lane's
    /// `ThumbnailMeasurement.rasterMs` evidence.
    private static func fullDecode(
        fixtureID: String,
        typeIdentifier: String,
        bytes: Data,
        maximumPixelExtent: Int
    ) -> PreviewAccessRecord {
        var record = PreviewAccessRecord(
            fixtureID: fixtureID,
            typeIdentifier: typeIdentifier,
            mode: .fullDecode,
            inputBytes: bytes.count,
            maximumPixelExtent: maximumPixelExtent
        )
        let start = ContinuousClock.Instant.now
        if let source = CGImageSourceCreateWithData(bytes as CFData, nil) {
            let index = CGImageSourceGetPrimaryImageIndex(source)
            if let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                index,
                thumbnailOptions(maximumPixelExtent: maximumPixelExtent)
            ) {
                record.outputWidth = image.width
                record.outputHeight = image.height
                record.outputBytes = image.width * image.height * 4
            }
            record.decoderStatus = Int(
                CGImageSourceGetStatusAtIndex(source, index).rawValue
            )
        }
        record.wallMs = elapsedMilliseconds(since: start)
        return record
    }

    // MARK: - ImageIO helpers

    /// The exact option dictionary of `ContentPreview.renderRaster`
    /// (`kCGImageSourceShouldCacheImmediately` included): characterizing a
    /// different decoder configuration than the product runs would not be
    /// PLAY-TIER-1A evidence for THIS decoder.
    private static func thumbnailOptions(maximumPixelExtent: Int) -> CFDictionary {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelExtent,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return options as CFDictionary
    }

    /// Both primary-image pixel dimensions, or nil while the parser has not
    /// reached them (the honest "header not yet available" signal — no
    /// status-code guessing).
    private static func primaryPixelSize(
        of source: CGImageSource,
        index: Int
    ) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            index,
            nil
        ) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0,
            height > 0
        else { return nil }
        return (width, height)
    }

    /// One fresh unfinalized incremental source fed `bytes.prefix(count)` —
    /// the model of a caller that genuinely holds ONLY that prefix (there
    /// is no completion flag in a range-read world).
    private static func primaryPixelSizeFromIncrementalPrefix(
        _ bytes: Data,
        count: Int
    ) -> (width: Int, height: Int)? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, bytes.prefix(count) as CFData, false)
        let index = CGImageSourceGetPrimaryImageIndex(source)
        return primaryPixelSize(of: source, index: index)
    }

    private static func thumbnailFromIncrementalPrefix(
        _ bytes: Data,
        count: Int,
        maximumPixelExtent: Int
    ) -> (image: CGImage?, status: Int) {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, bytes.prefix(count) as CFData, false)
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            index,
            thumbnailOptions(maximumPixelExtent: maximumPixelExtent)
        )
        return (
            image,
            Int(CGImageSourceGetStatusAtIndex(source, index).rawValue)
        )
    }

    /// Exact minimum satisfying prefix by binary search with VERIFIED
    /// endpoints (the caller's anchor proved `totalBytes` satisfies; zero
    /// is probed, not assumed). Returns nil when even the full input fails.
    /// A property read need not stop at the file's dimension fields: ImageIO
    /// may require later data before publishing them. The range mode uses
    /// the coarser ladder because each probe is a real partial decode.
    private static func minimumSatisfyingPrefix(
        totalBytes: Int,
        isSatisfied: (Int) -> Bool
    ) -> (satisfied: Int, failing: Int)? {
        guard isSatisfied(totalBytes) else { return nil }
        guard !isSatisfied(0) else { return (satisfied: 0, failing: -1) }
        var failing = 0
        var satisfied = totalBytes
        while satisfied - failing > 1 {
            let mid = failing + (satisfied - failing) / 2
            if isSatisfied(mid) {
                satisfied = mid
            } else {
                failing = mid
            }
        }
        return (satisfied: satisfied, failing: failing)
    }

    /// Milliseconds on the continuous clock between `start` and now — the
    /// `Instant.duration(to:)` receiver rule of `ThumbnailStore`'s
    /// measurement helper.
    private static func elapsedMilliseconds(
        since start: ContinuousClock.Instant
    ) -> Double {
        let components = start
            .duration(to: ContinuousClock.Instant.now)
            .components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

/// Opt-in JSONL persistence for probe records — the `ThumbnailMeasurement`
/// posture (Sources/PresentationUI/ThumbnailStore.swift) minus the
/// running-app envelope: this probe is driven by the test lane, not the
/// app, so activation is a single absolute-path environment key
/// (`CLIPY_PREVIEW_ACCESS_MEASUREMENT_PATH`); nothing in a product launch
/// reads it. Not `@MainActor`: the probe is synchronous and runs wherever
/// the owner test runs. File failures are observed-and-dropped (`try?`) —
/// measurement must never take down the lane, and a lost record surfaces
/// as the reader's own sampling-integrity gap.
///
/// NOT a ratchet: nothing here evaluates a threshold — G8 adjudication
/// stays with docs/06-cross-cutting.md §3 and V2-06's P3 record.
package final class PreviewAccessMeasurement {

    private let fileURL: URL
    private let start = ContinuousClock.Instant.now
    private let encoder: JSONEncoder
    private var handle: FileHandle?
    private var nextSeq = 0

    /// Owner-test seam: a sink pointed at one explicit file. Nothing is
    /// touched on disk until the first `record`.
    package init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        // Stable field order keeps evidence JSONL diff-friendly.
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    /// Activates the sink only for an absolute path (the
    /// `ThumbnailMeasurement.makeIfRequested` absolute-path gate; the
    /// running-app envelope does not apply to a test-lane probe). Creation
    /// is lazy: no file is touched until the first record.
    package static func makeIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PreviewAccessMeasurement? {
        guard let path = environment["CLIPY_PREVIEW_ACCESS_MEASUREMENT_PATH"],
              path.hasPrefix("/")
        else { return nil }
        return PreviewAccessMeasurement(
            fileURL: URL(fileURLWithPath: path).standardizedFileURL
        )
    }

    /// Assigns `seq`/`monotonicMs` and appends exactly one JSON line.
    /// `package` (not `internal`, unlike `ThumbnailMeasurement.record`)
    /// because the pure probe has no product owner that could write on its
    /// behalf — the owner test lane is the only writer.
    package func record(_ record: inout PreviewAccessRecord) {
        nextSeq += 1
        record.seq = nextSeq
        record.monotonicMs = elapsedMilliseconds
        guard let line = try? encoder.encode(record) else { return }
        append(line + Data([0x0A]))
    }

    private var elapsedMilliseconds: Int64 {
        let components = start.duration(to: ContinuousClock.Instant.now).components
        return Int64(components.seconds) * 1_000
            + Int64(components.attoseconds / 1_000_000_000_000_000)
    }

    private func append(_ data: Data) {
        if handle == nil {
            // Create-on-first-use: evidence lanes point the sink at a
            // directory they created beforehand.
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try? Data().write(to: fileURL)
            }
            handle = try? FileHandle(forWritingTo: fileURL)
        }
        guard let handle else { return }
        // Unbuffered appends: every completed line is visible to a polling
        // reader without a flush.
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: data)
    }
}
#endif
