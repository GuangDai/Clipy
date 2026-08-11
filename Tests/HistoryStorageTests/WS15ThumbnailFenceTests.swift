/// WS15 — Thumbnail version fence (docs/06-cross-cutting.md §8 WS15;
/// docs/04-coherence.md §9 thumbnail single-flight; §16 failure
/// translation): the version-fence semantics of the
/// `SwiftDataHistory.thumbnail(for:pixels:)` pipeline driven through the
/// PUBLIC facade and the real `HistoryAuthority` + `ThumbnailService`.
///
/// The fence (04 §9): steps 2–3 of the thumbnail pipeline run inside one
/// non-suspending Authority interval — the version check and Effective-Content
/// derivation cannot be interleaved by a commit. The fence is about the
/// off-Authority decode (step 6): if the item changes during decode, the result
/// is still correctly tagged with the verified OLD reference, and the caller
/// applies it only if its row still carries that reference. A request whose
/// reference was already stale BEFORE step 2 fails there with
/// `.staleContent`; current bytes are never returned under an old key.
///
/// The mid-decode interleaving uses the `ThumbnailServiceSuspensionPoint.decodeEntry`
/// seam (`"ThumbnailService.thumbnail.entry"`) — the legal suspension point
/// after the creator's Authority fence returned immutable source bytes and the
/// source-inclusive flight was installed, but before ImageIO decode
/// (ThumbnailService.swift). The deterministic concurrency
/// harness (`SuspensionGate` in ConcurrencyHarness/) drives the exact
/// interleaving: the thumbnail Task parks at `.decodeEntry`, a revision commits
/// during the park, the Task resumes and completes — its payload still carries
/// the OLD reference. No clause defers: every WS15 clause is asserted here.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS15ThumbnailFenceTests {

// MARK: - Latch (one-shot park control for the suspension handler)

/// Re-armable one-shot latch for the `.decodeEntry` suspension handler —
/// mirrors the WS12 `ParkLatch` pattern. `consume()` returns `true` when armed
/// and disarms in the same atomic step, so the handler parks exactly one
/// arrival at the seam. `SuspensionGate.park(at:)` forbids two tasks parked at
/// one named point, so the handler must let every non-armed arrival pass.
private actor ParkLatch {
    private var armed: Bool

    init(armed: Bool) {
        self.armed = armed
    }

    func consume() -> Bool {
        let wasArmed = armed
        armed = false
        return wasArmed
    }

    func rearm() {
        armed = true
    }
}

// MARK: - Fixtures

/// Standard 1×1 transparent PNG (base64). A well-known minimal valid PNG.
private static let png1x1TransparentBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

/// Standard 1×1 white PNG (base64). Byte-different from the transparent PNG
/// above, also a well-known minimal valid PNG.
private static let png1x1WhiteBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="

/// The PNG file signature (first four bytes of every PNG file).
private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

// MARK: - Helpers

/// Installs a suspension handler on `thumbnailService` that parks at
/// `.decodeEntry` only when the latch is armed. The latch controls which
/// `.decodeEntry` arrival parks; every other arrival and every other suspension
/// point passes through.
private static func installDecodeEntryPark(
    on thumbnailService: ThumbnailService,
    gate: SuspensionGate,
    latch: ParkLatch
) async {
    await thumbnailService.setSuspensionHandler { point in
        guard point == .decodeEntry else { return }
        let shouldPark = await latch.consume()
        guard shouldPark else { return }
        await gate.park(at: point.rawValue)
    }
}

/// A `.replace` draft request (docs/03a-instruction-set.md §5) that substitutes
/// `secondPng` bytes for BOTH Canonical representations (`public.png` and
/// `public.utf8-plain-text`), based on the OCC token `expected`. Both decisions
/// are `.replace(bytes:)` with the second PNG — the effective content bytes
/// change, so this is a content-changing revision that advances Content
/// Version (docs/02-domain.md §11).
private static func replaceBothWithSecondPngRequest(
    itemID: HistoryItemID,
    expected: ContentVersion,
    secondPng: Data
) -> RevisionRequest {
    RevisionRequest(
        itemID: itemID,
        expected: expected,
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(
                typeIdentifier: "public.png",
                action: .replace(bytes: secondPng)
            ),
            RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .replace(bytes: secondPng)
            ),
        ]))
    )
}

// MARK: - Test 1: revision during decode leaves the result tagged with the old reference

/// WS15 (docs/06-cross-cutting.md §8; 04 §9): "Start a thumbnail request for
/// one reference, revise the item during decode, and verify the old result
/// remains tagged with the old reference and cannot be applied to the new row."
///
/// The `.decodeEntry` seam parks `ThumbnailService` AFTER the Authority's
/// version fence returned immutable source bytes (first PNG) and AFTER the
/// source-inclusive flight was installed, but BEFORE ImageIO decode. A revision
/// committing during the park advances the item to Content Version 2, but the
/// decode completes using the already-fetched source bytes and the result is
/// tagged with the verified OLD reference (version 1) — it cannot be applied
/// to the new row (04 §9).
@Test func revisionDuringDecodeLeavesResultTaggedWithTheOldReference() async throws {
    let storeURL = WSSupport.tempStoreURL("ws15-thumbnail-fence-decode")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Fixtures: two byte-different valid PNGs.
    let firstPng = try #require(Data(base64Encoded: Self.png1x1TransparentBase64))
    let secondPng = try #require(Data(base64Encoded: Self.png1x1WhiteBase64))

    // Capture a text+png item — version 1, reference R1 (04 §9 step 2: the
    // Authority fetches the item and verifies the requested Content Version).
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_040_000)
    let source = "com.example.ws15.decode"
    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws15 fence decode item",
            observedAt: observedAt,
            source: source,
            extra: [("public.png", [UInt8](firstPng))]
        )
    ))
    guard case let .committed(captureCommit) = captureReceipt else {
        Issue.record("WS15-1: expected a .committed capture receipt, got \(captureReceipt)")
        return
    }
    guard case let .inserted(R1) = captureCommit.outcome else {
        Issue.record("WS15-1: expected .inserted(reference), got \(captureCommit.outcome)")
        return
    }
    #expect(R1.contentVersion.rawValue == 1)

    // Install the suspension handler parking at .decodeEntry (first arrival
    // only — the latch is armed).
    let gate = SuspensionGate()
    let latch = ParkLatch(armed: true)
    await Self.installDecodeEntryPark(
        on: history.thumbnailService,
        gate: gate,
        latch: latch
    )

    // Start the thumbnail request in a child Task. The Authority validates the
    // dimensions, verifies Content Version 1, derives Effective Content, selects
    // the public.png representation, and returns the FIRST png bytes — all inside
    // one non-suspending interval (04 §9 steps 2–4). ThumbnailService then parks
    // at .decodeEntry after installing the flight and before ImageIO decode.
    let requestedPixels = PixelSize(width: 32, height: 32)
    let task = Task { () -> ThumbnailPayload? in
        try await history.thumbnail(for: R1, pixels: requestedPixels)
    }

    // WS15: wait until the ThumbnailService is parked at the decodeEntry seam.
    await gate.waitForPark(ThumbnailServiceSuspensionPoint.decodeEntry.rawValue)

    // WS15: "revise the item during decode" — a byte-changing revision that
    // replaces BOTH Canonical types' effective bytes with the SECOND png. The
    // item advances from Content Version 1 to 2 (docs/02-domain.md §11).
    let reviseReceipt = try await history.perform(.revise(
        Self.replaceBothWithSecondPngRequest(
            itemID: R1.id,
            expected: R1.contentVersion,
            secondPng: secondPng
        )
    ))
    guard case let .committed(reviseCommit) = reviseReceipt else {
        Issue.record("WS15-1: expected a .committed revise receipt, got \(reviseReceipt)")
        return
    }
    guard case let .revised(R2) = reviseCommit.outcome else {
        Issue.record("WS15-1: expected .revised(reference), got \(reviseCommit.outcome)")
        return
    }
    #expect(R2.contentVersion.rawValue == 2)

    // The old-key flight is still parked with its already-verified source.
    // A request that begins after the revision must cross its own lightweight
    // join fence and fail stale; it cannot receive the creator's old bytes.
    await #expect(throws: HistoryFailure.staleContent(
        expected: R1.contentVersion,
        current: R2.contentVersion
    )) {
        try await history.thumbnail(for: R1, pixels: requestedPixels)
    }

    // WS15: resume — the parked decode completes using the already-fetched FIRST
    // png bytes; the result is tagged with the OLD reference R1 (04 §9).
    await gate.resume(ThumbnailServiceSuspensionPoint.decodeEntry.rawValue)

    // WS15: "the old result remains tagged with the old reference" — the payload
    // carries R1 (Content Version 1), NOT R2 (Content Version 2).
    let payloadOptional = try await task.value
    let payload = try #require(payloadOptional)

    // WS15: the payload's item IS the request's reference — the verified OLD one.
    #expect(payload.item == R1, "WS15-1: payload must be tagged with the old reference R1")
    #expect(payload.pixels == requestedPixels)
    #expect(payload.format == .png)

    // WS15: the encoded bytes are a valid PNG (starts with the PNG signature)
    // and within the Part VI output bound (06 §2: 16 MiB).
    #expect(payload.encodedBytes.starts(with: Self.pngSignature))
    #expect(
        payload.encodedBytes.count <= HistoryLimits.standard.maximumEncodedThumbnailBytes
    )

    // WS15: "and cannot be applied to the new row" — the item's CURRENT Content
    // Version (2, via details) differs from the payload's (1, R1), so the
    // caller must reject this payload for the current row (04 §9 coherence).
    let currentDetails = try await history.details(for: R1.id)
    #expect(
        currentDetails.item.contentVersion != payload.item.contentVersion,
        "WS15-1: the payload names the old state (v1) and cannot be applied to the new row (v2)"
    )
}

// MARK: - Test 2: stale reference fails before decode rather than returning current bytes under an old key

/// WS15 (docs/06-cross-cutting.md §8; 04 §9): "A request begun with an already
/// stale reference fails rather than returning current bytes under an old key."
///
/// After the item is revised to Content Version 2, a thumbnail request carrying
/// the version-1 reference fails at the Authority's version fence (§9 step 2)
/// with `.staleContent(expected: 1, current: 2)` — current bytes are never
/// returned under an old key.
@Test func staleReferenceFailsBeforeDecodeRatherThanReturningCurrentBytesUnderOldKey() async throws {
    let storeURL = WSSupport.tempStoreURL("ws15-thumbnail-fence-stale")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let firstPng = try #require(Data(base64Encoded: Self.png1x1TransparentBase64))
    let secondPng = try #require(Data(base64Encoded: Self.png1x1WhiteBase64))

    // Capture text+png → version 1, reference R1.
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_041_000)
    let source = "com.example.ws15.stale"
    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws15 fence stale item",
            observedAt: observedAt,
            source: source,
            extra: [("public.png", [UInt8](firstPng))]
        )
    ))
    guard case let .committed(captureCommit) = captureReceipt else {
        Issue.record("WS15-2: expected a .committed capture receipt, got \(captureReceipt)")
        return
    }
    guard case let .inserted(R1) = captureCommit.outcome else {
        Issue.record("WS15-2: expected .inserted(reference), got \(captureCommit.outcome)")
        return
    }
    let version1 = R1.contentVersion
    #expect(version1.rawValue == 1)

    // Revise to version 2 (byte-changing: both types → second png).
    let reviseReceipt = try await history.perform(.revise(
        Self.replaceBothWithSecondPngRequest(
            itemID: R1.id,
            expected: version1,
            secondPng: secondPng
        )
    ))
    guard case let .committed(reviseCommit) = reviseReceipt else {
        Issue.record("WS15-2: expected a .committed revise receipt, got \(reviseReceipt)")
        return
    }
    guard case let .revised(R2) = reviseCommit.outcome else {
        Issue.record("WS15-2: expected .revised(reference), got \(reviseCommit.outcome)")
        return
    }
    let version2 = R2.contentVersion
    #expect(version2.rawValue == 2)

    // WS15: a thumbnail request with the STALE version-1 reference fails at the
    // Authority's version fence (§9 step 2) — `.staleContent(expected: 1,
    // current: 2)`. No suspension handler is installed; the failure is
    // immediate, before any decode.
    await #expect(throws: HistoryFailure.staleContent(expected: version1, current: version2)) {
        try await history.thumbnail(for: R1, pixels: PixelSize(width: 32, height: 32))
    }
}

// MARK: - Test 3: text-only item yields nil thumbnail

/// WS15 (docs/06-cross-cutting.md §8; 04 §9 step 4): "If no supported image
/// representation exists, return `nil`." A text-only item has no
/// representation whose type identifier is in the frozen v1 image set, so
/// the already-installed source-to-decode flight completes with `nil`.
@Test func textOnlyItemYieldsNilThumbnail() async throws {
    let storeURL = WSSupport.tempStoreURL("ws15-thumbnail-fence-text-only")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let observedAt = Date(timeIntervalSinceReferenceDate: 700_042_000)
    let source = "com.example.ws15.textonly"
    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws15 text only item",
            observedAt: observedAt,
            source: source
        )
    ))
    guard case let .committed(captureCommit) = captureReceipt else {
        Issue.record("WS15-3: expected a .committed capture receipt, got \(captureReceipt)")
        return
    }
    guard case let .inserted(reference) = captureCommit.outcome else {
        Issue.record("WS15-3: expected .inserted(reference), got \(captureCommit.outcome)")
        return
    }

    // WS15 (§9 step 4): no supported image representation → nil.
    let payload = try await history.thumbnail(
        for: reference,
        pixels: PixelSize(width: 32, height: 32)
    )
    #expect(payload == nil, "WS15-3: a text-only item must yield a nil thumbnail")
}

// MARK: - Test 4: out-of-range pixel dimensions throw invalidPixelSize

/// WS15 (docs/06-cross-cutting.md §8; 04 §9 step 2; §16): "Validate positive
/// bounded dimensions." Both a zero dimension and a dimension above the Part VI
/// `thumbnailDimensionRange` upper bound (06 §2: 1–2,048) throw
/// `HistoryFailure.invalidInput(.invalidPixelSize)` at the Authority's
/// dimension check, before any row is fetched.
@Test func outOfRangePixelDimensionsThrowInvalidPixelSize() async throws {
    let storeURL = WSSupport.tempStoreURL("ws15-thumbnail-fence-pixels")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let firstPng = try #require(Data(base64Encoded: Self.png1x1TransparentBase64))

    // Capture a text+png item so the reference is valid (the dimension check
    // fails before the row fetch, but a valid reference keeps the test clean).
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_043_000)
    let source = "com.example.ws15.pixels"
    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws15 pixel size item",
            observedAt: observedAt,
            source: source,
            extra: [("public.png", [UInt8](firstPng))]
        )
    ))
    guard case let .committed(captureCommit) = captureReceipt else {
        Issue.record("WS15-4: expected a .committed capture receipt, got \(captureReceipt)")
        return
    }
    guard case let .inserted(reference) = captureCommit.outcome else {
        Issue.record("WS15-4: expected .inserted(reference), got \(captureCommit.outcome)")
        return
    }

    // WS15 (§9 step 2): a zero dimension is outside the 1–2,048 range (06 §2).
    await #expect(throws: HistoryFailure.invalidInput(.invalidPixelSize)) {
        try await history.thumbnail(for: reference, pixels: PixelSize(width: 0, height: 32))
    }

    // WS15 (§9 step 2): a dimension one above the upper bound is outside the
    // range (06 §2: thumbnailDimensionRange is 1...2_048).
    let aboveUpperBound = HistoryLimits.standard.thumbnailDimensionRange.upperBound + 1
    await #expect(throws: HistoryFailure.invalidInput(.invalidPixelSize)) {
        try await history.thumbnail(for: reference, pixels: PixelSize(width: aboveUpperBound, height: 32))
    }
}
}
