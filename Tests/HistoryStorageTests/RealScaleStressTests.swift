/// Real-scale storage stress slice (fixture suite B): the walking-skeleton
/// semantics of docs/06-cross-cutting.md §8 re-proven against the real-scale
/// `clipy-fixtures-v1` payloads instead of hand-written strings — bulk text
/// capture at ~180 commits, the 256 KiB stored-search-body boundary, the
/// 1,024-byte stored-title boundary, 4K/8K thumbnail production, and a
/// 120-capture retention storm against a cap of 50.
///
/// Owning spec sections per test are cited inline: docs/02-domain.md §10/§12/
/// §13 (coalescing, retention, one position advance per commit),
/// docs/03b-instruction-set.md §8/§9 (frozen search behavior, thumbnail DTO),
/// docs/05-authority-kernel.md §14.2/§15 (search corpus snapshot, projection
/// truncation), docs/06-cross-cutting.md §2 (the fixed bounds table).
///
/// Fixture payloads come from the `clipy-fixtures-v1` release tree (see
/// `Support/FixtureCatalog.swift` in this target). The whole suite is gated
/// with `.enabled(if: FixtureCatalog.available, …)` so a fresh clone's
/// `swift test` stays green without the tree (06 §8 test-independence
/// spirit); CI always fetches the tree via `scripts/fetch_fixtures.sh` and
/// the fetch step fails the job on any download/checksum problem, so a
/// silent skip on CI is impossible. `.serialized` keeps the suite's peak
/// memory independent of other suites' timing.
///
/// Row-level assertions use an INDEPENDENT second `ModelContainer` over the
/// same on-disk store (the `WSSupport` stance): mutations always cross the
/// public `ClipboardHistory` facade; the second container only reads.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite(
    "HistoryStorage real-scale stress (fixtures-v1)",
    .enabled(
        if: FixtureCatalog.available,
        "clipy-fixtures-v1 tree absent (CLIPY_FIXTURES_DIR unset)"
    ),
    .serialized
)
struct RealScaleStressTests {

// MARK: - Suite-local helpers

/// The nine real-scale text fixtures, in manifest order (see
/// `scripts/generate_fixtures.py` TEXT_TARGETS). Total decoded size is
/// ≈ 9.6 MB — loaded once per test and released with it, never held across
/// tests.
private static let textFixturePaths = [
    "text/code-swift-200kb.txt",
    "text/json-1mb.json",
    "text/markdown-300kb.md",
    "text/cjk-500kb.txt",
    "text/emoji-150kb.txt",
    "text/longlines-2mb.txt",
    "text/lorem-5mb.txt",
    "text/searchbody-300kb.txt",
    "text/title-over-1kib.txt",
]

/// The PNG file signature (first four bytes of every PNG file).
private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

/// Loads and decodes all nine text fixtures as UTF-8.
private static func loadTextFixtures() throws -> [String] {
    try textFixturePaths.map { try FixtureCatalog.text($0) }
}

/// A `length`-Character window of `text` whose start advances by `length`
/// per round (mod the available window), so repeated rounds over one fixture
/// produce different slices. Whole-text slices for fixtures shorter than
/// `length`; grapheme-cluster indices keep the multibyte fixtures (CJK,
/// emoji) intact.
private static func slice(of text: String, round: Int, length: Int) -> String {
    let sliceLength = min(length, text.count)
    let window = text.count - sliceLength
    let startOffset = window > 0 ? (round * length) % window : 0
    let start = text.index(text.startIndex, offsetBy: startOffset)
    let end = text.index(start, offsetBy: sliceLength)
    return String(text[start..<end])
}

/// The first newline-free `length`-Character window at or after `offset`.
/// The pinned fixtures contain long newline-free prose runs, so this
/// terminates quickly; a newline-free term keeps exact-search assertions
/// independent of line structure (03b §8).
private static func newlineFreeWindow(
    in text: String,
    from offset: Int,
    length: Int
) -> String {
    var start = text.index(text.startIndex, offsetBy: offset)
    while true {
        let end = text.index(start, offsetBy: length)
        let window = String(text[start..<end])
        if !window.contains("\n") { return window }
        start = text.index(after: start)
    }
}

/// Counts non-overlapping literal occurrences of `needle` in `haystack`.
/// Used only in arrange-time preconditions: they pin the fixture-derived
/// terms deterministically instead of trusting the generator's statistics.
private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
    var count = 0
    var start = haystack.startIndex
    while let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
        count += 1
        start = range.upperBound
    }
    return count
}

/// Extracts the substring at `range` from `text` via the UTF-16 view (03b §8:
/// matched ranges are UTF-16 offsets into the title or the snippet).
private static func substring(_ text: String, utf16Range: UTF16TextRange) -> String {
    let view = text.utf16
    let start = view.index(view.startIndex, offsetBy: utf16Range.location)
    let end = view.index(start, offsetBy: utf16Range.length)
    return String(decoding: view[start..<end], as: UTF16.self)
}

/// Captures one text payload through the public facade and returns the
/// inserted reference (arrange helper; a non-insert receipt is a test
/// harness failure — record and trap, the WS17 arrange-helper stance).
private static func captureText(
    _ history: SwiftDataHistory,
    text: String,
    observedAt: Date,
    source: String
) async throws -> HistoryItemReference {
    let receipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: observedAt, source: source)
    ))
    guard case let .committed(commit) = receipt,
          case let .inserted(reference) = commit.outcome else {
        Issue.record("realscale arrange: expected .committed(.inserted), got \(receipt)")
        fatalError("realscale arrange: unreachable")
    }
    return reference
}

// MARK: - (1) Bulk text capture

/// Real-scale WS1/WS2 stress (docs/06-cross-cutting.md §8 WS1/WS2;
/// docs/02-domain.md §13 D6): 180 distinct real-text captures — cycling all
/// nine text fixtures with advancing slices — commit in order at Change
/// Positions 1…180 (one advance per commit, no retention below the 200-item
/// policy), and a byte-identical re-capture of the first payload COALESCES
/// (02 §10): `.coalesced` at position 181 naming the EXISTING item, no new
/// row, occurrence count 2, `lastCopiedAt` advanced.
///
/// Distinctness cannot rely on fixture statistics alone (a periodic source
/// could repeat a slice), so every payload carries a unique trailing marker
/// line; the re-capture replays the marker byte-for-byte, which is exactly
/// the two-stage dedup lane (xxh3 signature candidate, then byte-exact
/// confirmation — 01 §3).
@Test func bulkTextCapturesCommitInOrderAndDuplicateRecaptureCoalesces() async throws {
    let storeURL = WSSupport.tempStoreURL("realscale-bulk-text")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL, maximumUnpinned: 200)
    let texts = try Self.loadTextFixtures()

    let captureCount = 180
    let source = "com.example.realscale.bulk"
    let baseTime = 700_300_000.0
    var references: [HistoryItemReference] = []
    references.reserveCapacity(captureCount)
    var firstPayload = ""
    for index in 0..<captureCount {
        let fixture = texts[index % texts.count]
        let payload = Self.slice(of: fixture, round: index / texts.count, length: 2_048)
            + "\nclipy-realscale-bulk-\(index)"
        if index == 0 { firstPayload = payload }
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            payload,
            observedAt: Date(timeIntervalSinceReferenceDate: baseTime + Double(index)),
            source: source
        )))
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome
        else {
            Issue.record("realscale bulk: expected .committed(.inserted) at \(index), got \(receipt)")
            return
        }
        // 02 §13 (D6): exactly one position advance per non-empty commit.
        #expect(commit.position.rawValue == UInt64(index) + 1)
        references.append(reference)
    }

    // WS2 (06 §8; 02 §10): a byte-identical re-capture coalesces onto the
    // retained item instead of inserting a duplicate.
    let recaptureObservedAt = Date(timeIntervalSinceReferenceDate: baseTime + 1_000)
    let recaptureReceipt = try await history.perform(.capture(WSSupport.textCapture(
        firstPayload,
        observedAt: recaptureObservedAt,
        source: source
    )))
    guard case let .committed(recaptureCommit) = recaptureReceipt,
          case let .coalesced(winner) = recaptureCommit.outcome
    else {
        Issue.record("realscale bulk: expected .committed(.coalesced), got \(recaptureReceipt)")
        return
    }
    #expect(winner.id == references[0].id)
    #expect(recaptureCommit.position.rawValue == UInt64(captureCount) + 1)

    // Storage side, through the INDEPENDENT container (WSSupport stance).
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    // 180 inserts, one coalesce: still exactly 180 rows.
    #expect(rows.count == captureCount)
    #expect(try WSSupport.fetchPosition(container).rawValue == UInt64(captureCount) + 1)
    // 02 §10: the coalesced winner carries occurrence count 2 and the new
    // `lastCopiedAt`; `firstCopiedAt` is the original observation.
    let firstRow = try #require(rows.first { $0.id == references[0].id.rawValue })
    #expect(firstRow.copyCount == 2)
    #expect(firstRow.lastCopiedAt == recaptureObservedAt)
    #expect(firstRow.firstCopiedAt == Date(timeIntervalSinceReferenceDate: baseTime))
}

// MARK: - (2) Stored-search-body and stored-title boundaries

/// The 256 KiB stored-search-body boundary (docs/06-cross-cutting.md §2;
/// docs/05-authority-kernel.md §15, §14.2; docs/03b-instruction-set.md §8).
///
/// `text/searchbody-300kb.txt` is 300 KiB of pure-ASCII prose (pinned by the
/// manifest checksum), so its stored search body is exactly the first
/// 262,144 bytes. A distinctive term near the START of the file is found by
/// exact search as a BODY match (the title is only the first line), with a
/// snippet and a UTF-16 range that extracts the term. A distinctive term
/// from BEYOND the stored prefix is NOT found: 03b §8 freezes exact search
/// as a scan of the bounded STORED `searchBody`, and 05 §15 truncates that
/// projection at the hard bound — content past the prefix remains durably
/// retained in Canonical Content (asserted below) but is not searchable.
/// That asymmetry is the contract, not a defect.
@Test func searchBodyBeyondTheStoredPrefixIsNotSearchable() async throws {
    let storeURL = WSSupport.tempStoreURL("realscale-searchbody-boundary")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let fullText = try FixtureCatalog.text("text/searchbody-300kb.txt")
    let bound = HistoryLimits.standard.maximumStoredSearchBodyUTF8Bytes
    // Fixture preconditions (pinned by manifest sha256): 300 KiB > 256 KiB,
    // pure ASCII so Character offsets equal UTF-8 byte offsets.
    try #require(fullText.utf8.count > bound)
    try #require(fullText.utf8.count == fullText.count)
    let storedPrefix = String(fullText.prefix(bound))

    // A distinctive 48-Character term near the START (inside the stored
    // prefix, past the title line, occurring there exactly once).
    let startTerm = Self.newlineFreeWindow(in: fullText, from: 2_000, length: 48)
    try #require(Self.occurrenceCount(of: startTerm, in: storedPrefix) == 1)
    let titleEnd = try #require(fullText.firstIndex(of: "\n"))
    let titleLine = String(fullText[..<titleEnd])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    try #require(!titleLine.contains(startTerm))

    // A distinctive 48-Character term near the END — BEYOND the 256 KiB
    // stored prefix and absent from it.
    let endTerm = Self.newlineFreeWindow(
        in: fullText,
        from: fullText.count - 2_000,
        length: 48
    )
    try #require(Self.occurrenceCount(of: endTerm, in: storedPrefix) == 0)

    let reference = try await Self.captureText(
        history,
        text: fullText,
        observedAt: Date(timeIntervalSinceReferenceDate: 700_310_000),
        source: "com.example.realscale.searchbody"
    )

    // 03b §8 (exact): the START term is a body match — one row, a non-empty
    // snippet, and a UTF-16 range that extracts the term from the snippet.
    let startPage = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: startTerm, mode: .exact),
        limit: 10
    ))
    #expect(startPage.rows.count == 1)
    let startRow = try #require(startPage.rows.first)
    #expect(startRow.item.id == reference.id)
    let search = try #require(startRow.search)
    let snippet = try #require(search.snippet)
    #expect(search.matchedRanges.count == 1)
    let range = try #require(search.matchedRanges.first)
    #expect(Self.substring(snippet, utf16Range: range) == startTerm)

    // 03b §8 + 05 §15: exact search scans the bounded STORED body only, so
    // the END term — present in the retained Canonical bytes but truncated
    // out of the stored projection — yields no row.
    let endPage = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: endTerm, mode: .exact),
        limit: 10
    ))
    #expect(endPage.rows.isEmpty)

    // Storage side: the stored projection obeys its bounds exactly (05 §15
    // truncation at a deterministic Unicode boundary; ASCII ⇒ a full
    // 262,144-byte body), while the Canonical representation retains ALL
    // 307,200 bytes (05 §14.3 detail hydration; the projection never
    // rewrites content).
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let row = try #require(
        try WSSupport.fetchRows(container).first { $0.id == reference.id.rawValue }
    )
    #expect(row.searchBody.utf8.count == bound)
    #expect(row.title.utf8.count <= HistoryLimits.standard.maximumStoredTitleUTF8Bytes)
    let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
    #expect(canonical.representations.map(\.content.bytes) == [Data(fullText.utf8)])
}

/// The 1,024-byte stored-title boundary (docs/06-cross-cutting.md §2;
/// docs/05-authority-kernel.md §15): `text/title-over-1kib.txt` is one
/// 1,200-byte ASCII line, so the projected title is its first 1,024 bytes —
/// truncated at a deterministic Unicode boundary (06 §2), never more. Both
/// the durable row and the public browse read agree on the truncated value.
@Test func storedTitleIsTruncatedAtThe1024ByteBound() async throws {
    let storeURL = WSSupport.tempStoreURL("realscale-title-boundary")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let fullText = try FixtureCatalog.text("text/title-over-1kib.txt")
    let bound = HistoryLimits.standard.maximumStoredTitleUTF8Bytes
    // Fixture preconditions (pinned by manifest sha256): one ASCII line
    // longer than the stored-title bound.
    try #require(!fullText.contains("\n"))
    try #require(fullText.utf8.count > bound)
    try #require(fullText.utf8.count == fullText.count)

    let reference = try await Self.captureText(
        history,
        text: fullText,
        observedAt: Date(timeIntervalSinceReferenceDate: 700_320_000),
        source: "com.example.realscale.title"
    )

    // 05 §15: the title is the first eligible line, truncated to ≤ 1,024
    // UTF-8 bytes at a Character boundary — for this ASCII fixture, exactly
    // the first 1,024 bytes.
    let expectedTitle = String(fullText.prefix(bound))
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let row = try #require(
        try WSSupport.fetchRows(container).first { $0.id == reference.id.rawValue }
    )
    #expect(row.title.utf8.count == bound)
    #expect(row.title == expectedTitle)

    // The public read path (03b §8) reports the same bounded title.
    let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
    let publicRow = try #require(page.rows.first { $0.item.id == reference.id })
    #expect(publicRow.title == expectedTitle)
}

// MARK: - (3) 4K/8K thumbnails

/// Captures one image fixture through the public facade as a single
/// representation of the given type identifier (arrange helper).
private static func captureImage(
    _ history: SwiftDataHistory,
    path: String,
    typeIdentifier: String,
    observedAt: Date,
    source: String
) async throws -> HistoryItemReference {
    let bytes = try FixtureCatalog.data(path)
    let receipt = try await history.perform(.capture(ClipboardCapture(
        representations: [CapturedRepresentation(typeIdentifier: typeIdentifier, bytes: bytes)],
        origin: CopyOriginObservation(sourceApplication: source, lineageHint: nil),
        observedAt: observedAt
    )))
    guard case let .committed(commit) = receipt,
          case let .inserted(reference) = commit.outcome else {
        Issue.record("realscale arrange: expected .committed(.inserted) for \(path), got \(receipt)")
        fatalError("realscale arrange: unreachable")
    }
    return reference
}

/// Asserts the 04 §9/06 §2 thumbnail payload invariants: requested
/// reference and pixel size echoed, PNG format and signature, non-trivial
/// size, and the 16 MiB encoded-output bound.
private static func expectThumbnailPayload(
    _ payload: ThumbnailPayload?,
    reference: HistoryItemReference,
    pixels: PixelSize,
    minimumBytes: Int
) throws {
    let payload = try #require(payload)
    #expect(payload.item == reference)
    #expect(payload.pixels == pixels)
    // 03b §9: the v1 encoded format is PNG.
    #expect(payload.format == .png)
    #expect(payload.encodedBytes.starts(with: Self.pngSignature))
    #expect(payload.encodedBytes.count > minimumBytes)
    // 06 §2: encoded thumbnail output ≤ 16 MiB.
    #expect(
        payload.encodedBytes.count <= HistoryLimits.standard.maximumEncodedThumbnailBytes
    )
}

/// Real-scale 4K thumbnail production (docs/04-coherence.md §9;
/// docs/03b-instruction-set.md §9; docs/06-cross-cutting.md §2): a real
/// 3840×2160 `public.png` capture (fixture `images/photo4k-a.png`, 848 KiB)
/// thumbnails successfully at the TOP of the permitted dimension range
/// (2,048×2,048 — 06 §2 `thumbnailDimensionRange` 1…2,048) and at a
/// list-row scale (72×72); the larger request produces the larger payload.
@Test func fourKThumbnailAtTheMaximumAndListRowDimensions() async throws {
    let storeURL = WSSupport.tempStoreURL("realscale-thumbnail-4k")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let reference = try await Self.captureImage(
        history,
        path: "images/photo4k-a.png",
        typeIdentifier: "public.png",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_330_000),
        source: "com.example.realscale.thumb4k"
    )

    // 06 §2: 2,048 is the INCLUSIVE upper bound of the thumbnail dimension
    // range — the request must be admitted, not rejected as invalid.
    let maximum = PixelSize(width: 2_048, height: 2_048)
    let large = try await history.thumbnail(for: reference, pixels: maximum)
    try Self.expectThumbnailPayload(
        large, reference: reference, pixels: maximum, minimumBytes: 10_000
    )

    let listRow = PixelSize(width: 72, height: 72)
    let small = try await history.thumbnail(for: reference, pixels: listRow)
    try Self.expectThumbnailPayload(
        small, reference: reference, pixels: listRow, minimumBytes: 100
    )

    // Downsampling monotonicity at this scale gap: the 2,048-px payload
    // encodes strictly more pixels than the 72-px one.
    let largeBytes = try #require(large).encodedBytes.count
    let smallBytes = try #require(small).encodedBytes.count
    #expect(largeBytes > smallBytes)
}

/// Real-scale 8K thumbnail downsampling (docs/04-coherence.md §9 step 6):
/// fixture `images/huge-8k.png` (7680×4320, 3.1 MiB — the largest raster in
/// the tree) yields a valid 256×256 PNG thumbnail. `ThumbnailService`
/// downsamples through `CGImageSourceCreateThumbnailAtIndex`, so the source
/// is never fully decoded at native size.
@Test func eightKImageYieldsA256PixelThumbnail() async throws {
    let storeURL = WSSupport.tempStoreURL("realscale-thumbnail-8k")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let reference = try await Self.captureImage(
        history,
        path: "images/huge-8k.png",
        typeIdentifier: "public.png",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_340_000),
        source: "com.example.realscale.thumb8k"
    )

    let pixels = PixelSize(width: 256, height: 256)
    let payload = try await history.thumbnail(for: reference, pixels: pixels)
    try Self.expectThumbnailPayload(
        payload, reference: reference, pixels: pixels, minimumBytes: 1_000
    )
}

/// 04 §9 step 4 at real scale: a text-only item (a real 2 KiB markdown
/// slice) has no representation in the frozen v1 image-UTI set, so the
/// thumbnail request completes with `nil` rather than a decode attempt.
@Test func textOnlyItemYieldsNilThumbnail() async throws {
    let storeURL = WSSupport.tempStoreURL("realscale-thumbnail-textonly")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let markdown = try FixtureCatalog.text("text/markdown-300kb.md")
    let reference = try await Self.captureText(
        history,
        text: Self.slice(of: markdown, round: 0, length: 2_048),
        observedAt: Date(timeIntervalSinceReferenceDate: 700_350_000),
        source: "com.example.realscale.thumbtext"
    )

    let payload = try await history.thumbnail(
        for: reference,
        pixels: PixelSize(width: 256, height: 256)
    )
    #expect(payload == nil)
}

// MARK: - (5) Retention stress

/// Real-scale WS9/WS21 retention storm (docs/06-cross-cutting.md §8 WS9;
/// docs/02-domain.md §12/§13): with the user policy lowered to 50 unpinned,
/// 120 distinct real-text captures retire the oldest unpinned item inside
/// each committing capture (never the primary, never a pinned item — D13/
/// D19), leaving exactly 50 unpinned survivors — the NEWEST 50 unpinned
/// captures — plus the 3 items pinned mid-way. Position accounting: the
/// policy commit (1) + 120 capture commits + 3 pin commits each advance
/// `ChangePosition` exactly once (02 §13), so the singleton ends at 124.
@Test func retentionStressRetiresOldestUnpinnedFirstAndSparesPinned() async throws {
    let storeURL = WSSupport.tempStoreURL("realscale-retention-storm")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL, maximumUnpinned: 200)
    let texts = try Self.loadTextFixtures()

    // WS21 (06 §8): lowering the policy is one commit even with nothing to
    // retire — `.retentionPolicySet(removedCount: 0)` at position 1.
    let policyReceipt = try await history.perform(
        .setRetentionPolicy(maximumUnpinnedItems: 50)
    )
    guard case let .committed(policyCommit) = policyReceipt,
          case let .retentionPolicySet(removedCount) = policyCommit.outcome
    else {
        Issue.record("realscale retention: expected .retentionPolicySet, got \(policyReceipt)")
        return
    }
    #expect(policyCommit.position.rawValue == 1)
    #expect(removedCount == 0)

    // Capture 120 distinct items (unique marker per payload, as in the bulk
    // suite) with strictly increasing observedAt, so eviction order
    // (lastCopiedAt ascending, 02 §12) is the insertion order.
    let captureCount = 120
    let source = "com.example.realscale.retention"
    let baseTime = 700_360_000.0
    var references: [HistoryItemReference] = []
    references.reserveCapacity(captureCount)
    for index in 0..<captureCount {
        let payload = Self.slice(of: texts[index % texts.count], round: index / texts.count, length: 2_048)
            + "\nclipy-realscale-retention-\(index)"
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            payload,
            observedAt: Date(timeIntervalSinceReferenceDate: baseTime + Double(index)),
            source: source
        )))
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome
        else {
            Issue.record("realscale retention: expected .inserted at \(index), got \(receipt)")
            return
        }
        references.append(reference)

        // Pin three items mid-way (after capture 60): indices 25, 35, 45
        // are all still retained — only captures 0…9 have retired so far.
        if index == 59 {
            for pinIndex in [25, 35, 45] {
                let pinReceipt = try await history.perform(
                    .placePinned(references[pinIndex].id, at: .last)
                )
                guard case .committed = pinReceipt else {
                    Issue.record("realscale retention: pin \(pinIndex) not committed: \(pinReceipt)")
                    return
                }
            }
        }
    }

    // Storage side, through the INDEPENDENT container.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)

    // Exactly 53 rows survive: 50 unpinned + 3 pinned (02 §12, D13).
    #expect(rows.count == 53)
    let retainedIDs = Set(rows.map(\.id))

    // The pinned trio survives, with contiguous ordinals in pin order (D12).
    let pinnedIndices = [25, 35, 45]
    for (ordinal, pinIndex) in pinnedIndices.enumerated() {
        let row = try #require(
            rows.first { $0.id == references[pinIndex].id.rawValue }
        )
        #expect(row.pinOrdinal == ordinal)
    }

    // Oldest-first retirement (02 §12): the unpinned survivors are exactly
    // the NEWEST 50 unpinned captures — indices 70…119 (the pinned trio at
    // 25/35/45 is exempt, so unpinned 0…69 retired in insertion order).
    let expectedUnpinnedIDs = Set(references[70..<captureCount].map { $0.id.rawValue })
    let actualUnpinnedIDs = Set(rows.filter { $0.pinOrdinal == nil }.map(\.id))
    #expect(actualUnpinnedIDs == expectedUnpinnedIDs)
    for index in 0..<70 where !pinnedIndices.contains(index) {
        #expect(!retainedIDs.contains(references[index].id.rawValue))
    }

    // 02 §13: 1 + 120 + 3 non-empty commits, one position advance each.
    #expect(try WSSupport.fetchPosition(container).rawValue == 124)
}
}
