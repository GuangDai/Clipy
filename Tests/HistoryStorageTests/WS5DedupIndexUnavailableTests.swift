/// WS5 — Candidate proof unavailable (docs/06-cross-cutting.md §8 WS5):
/// with the Signature Index not ready for the current retained set and a
/// complete rebuild impossible, capture must fail CLOSED — a typed failure,
/// and no row, position, receipt, or invalidation is produced.
///
/// Storage-side proof, not a public-facade path (the same stance as
/// `TransactionBoundaryProofTests`): the forced state is an over-bound
/// retained store written behind the Authority's back, which requires direct
/// row insertion plus a directly constructed Authority and the real
/// `IngestPreparationActor` (see `WSSupport.makeAuthority`). The two rows are
/// hand-crafted but fully valid v1 rows — every blob is produced by the
/// production codecs over a real prepared bundle.
///
/// FAILURE-CASE VOCABULARY: 06 §8 WS5, docs/05-authority-kernel.md §16, and
/// docs/02-domain.md §5.1 all name `.temporarilyUnavailable(.dedupIndexRebuild)`
/// as the capture-path producer for an unprovable Signature Index, and that is
/// what this test asserts. (History: an earlier `loadFacts` revision ran the
/// §7.1-step-5 inventory load before the step-1 readiness resolution, so the
/// over-bound store was rejected as `.persistence(.invariantViolation)` and the
/// `.dedupIndexRebuild` mapping was unreachable. The loader now resolves
/// readiness first against an id-only scalar fetch; an over-bound retained set
/// always forces the rebuild path, whose bound check produces
/// `.dedupIndexRebuild`.)
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData
import Testing
@testable import HistoryStorage

struct WS5DedupIndexUnavailableTests {

/// `HistoryLimits` with the hard retained-item bound squeezed to 1 and every
/// other value copied from `.standard` (the checked public init rejects
/// inconsistent combinations, so `userMaximumUnpinnedRange` and
/// `defaultMaximumUnpinnedItems` collapse to the only values compatible with
/// a hard bound of 1: `1...1` and `1`).
private static func overBoundRetainedLimits() -> HistoryLimits {
    let standard = HistoryLimits.standard
    // The force unwrap cannot fail: every value is `.standard`'s except the
    // three the init's own consistency checks tie together (hard bound 1,
    // user range 1...1, default 1), which satisfy those checks by
    // construction — the same justification `HistoryLimits.standard` uses.
    return HistoryLimits(
        maximumRepresentationsPerCaptureOrRevision: standard.maximumRepresentationsPerCaptureOrRevision,
        maximumTypeIdentifierUTF8Bytes: standard.maximumTypeIdentifierUTF8Bytes,
        maximumRepresentationBytes: standard.maximumRepresentationBytes,
        maximumCaptureBytes: standard.maximumCaptureBytes,
        maximumProposedRevisionBytes: standard.maximumProposedRevisionBytes,
        maximumRevisionsPerItem: standard.maximumRevisionsPerItem,
        maximumTotalRevisionBytesPerItem: standard.maximumTotalRevisionBytesPerItem,
        hardMaximumRetainedItems: 1,
        userMaximumUnpinnedRange: 1...1,
        defaultMaximumUnpinnedItems: 1,
        maximumSourceApplicationObservationUTF8Bytes: standard.maximumSourceApplicationObservationUTF8Bytes,
        maximumStoredTitleUTF8Bytes: standard.maximumStoredTitleUTF8Bytes,
        maximumStoredSearchBodyUTF8Bytes: standard.maximumStoredSearchBodyUTF8Bytes,
        pageRowLimitRange: standard.pageRowLimitRange,
        maximumSearchTermUTF8Bytes: standard.maximumSearchTermUTF8Bytes,
        maximumRegexpPatternCharacters: standard.maximumRegexpPatternCharacters,
        maximumFuzzyQueryCharacters: standard.maximumFuzzyQueryCharacters,
        maximumFuzzyTitleBodyPrefixCharacters: standard.maximumFuzzyTitleBodyPrefixCharacters,
        maximumRegexpTitleBodyPrefixCharacters: standard.maximumRegexpTitleBodyPrefixCharacters,
        maximumBodySearchSnippetCharacters: standard.maximumBodySearchSnippetCharacters,
        thumbnailDimensionRange: standard.thumbnailDimensionRange,
        maximumEncodedThumbnailBytes: standard.maximumEncodedThumbnailBytes
    )!
}

/// Builds a fully valid v1 `HistoryItemRow` from a real prepared capture:
/// every blob comes from the production codecs over the bundle's validated
/// values (Canonical Content, signature entries, empty revision lineage for a
/// Canonical-state item, and the §15 projection), and the row id is the
/// bundle's freshly minted candidate ID.
private static func makeRow(
    from bundle: PreparedCaptureBundle,
    observedAt: Date,
    source: String?
) throws -> HistoryItemRow {
    try HistoryItemRow(
        id: bundle.domain.candidateID.rawValue,
        contentVersionRaw: 1,
        canonicalBlob: CanonicalBlobCodec.encode(bundle.domain.canonical),
        revisionStateBlob: RevisionStateBlobCodec.encode(revisions: [], activeRevisionID: nil),
        canonicalSignatureBlob: SignatureBlobCodec.encode(bundle.signatureEntries),
        projectionSchemaVersion: bundle.projection.schemaVersion,
        title: bundle.projection.title,
        searchBody: bundle.projection.searchBody,
        effectiveTypeIdentifiersBlob: EffectiveTypeIdentifiersBlobCodec
            .encode(bundle.projection.effectiveTypeIdentifiers),
        firstCopiedAt: observedAt,
        lastCopiedAt: observedAt,
        copyCount: 1,
        firstSource: source,
        lastSource: source,
        pinOrdinal: nil
    )
}

/// WS5 (docs/06-cross-cutting.md §8): with the Signature Index stale behind
/// an over-bound retained store, capture fails CLOSED — the Authority throws
/// before planning, and no row, position, receipt, or invalidation is
/// produced. See the file header for the exact failure-case vocabulary note.
@Test func overBoundRetainedStoreFailsCaptureClosedWithoutRowPositionReceiptOrInvalidation() async throws {
    let storeURL = WSSupport.tempStoreURL("ws5-dedup-index-unavailable")
    defer { WSSupport.removeStore(storeURL) }

    // Startup runs on an EMPTY store: the singleton is created at position 0
    // and the Signature Index is built ready over zero retained rows.
    let authority = try await WSSupport.makeAuthority(
        storeURL: storeURL,
        limits: Self.overBoundRetainedLimits(),
        maximumUnpinned: 1
    )
    let preparation = IngestPreparationActor()

    // Arrange: TWO fully valid rows written directly into the store — one
    // more than the hard bound of 1, and invisible to the Authority's
    // startup-built Signature Index, so the next capture must re-prove
    // candidacy against a retained set it cannot bring within the bound.
    let firstObservedAt = Date(timeIntervalSinceReferenceDate: 700_010_000)
    let secondObservedAt = Date(timeIntervalSinceReferenceDate: 700_010_500)
    let firstText = "ws5 seeded row one"
    let secondText = "ws5 seeded row two"
    let firstBundle = try await preparation.prepare(
        WSSupport.textCapture(firstText, observedAt: firstObservedAt, source: "com.example.ws5.one")
    )
    let secondBundle = try await preparation.prepare(
        WSSupport.textCapture(secondText, observedAt: secondObservedAt, source: "com.example.ws5.two")
    )
    let seedContainer = try WSSupport.makeContainer(storeURL: storeURL)
    let seedContext = ModelContext(seedContainer)
    seedContext.insert(try Self.makeRow(from: firstBundle, observedAt: firstObservedAt, source: "com.example.ws5.one"))
    seedContext.insert(try Self.makeRow(from: secondBundle, observedAt: secondObservedAt, source: "com.example.ws5.two"))
    try seedContext.save()

    // The no-invalidation probe, registered BEFORE the capture attempt
    // (docs/04-coherence.md §5 ordering); it is finished and drained below,
    // so a publish during the rejected attempt would surface deterministically.
    let registration = await authority.registerInvalidationSubscriber()

    // Act: a fresh capture prepared by the real IngestPreparationActor and
    // committed through the real capture path.
    let captureBundle = try await preparation.prepare(
        WSSupport.textCapture(
            "ws5 rejected capture",
            observedAt: Date(timeIntervalSinceReferenceDate: 700_011_000)
        )
    )
    // WS5: the capture is REJECTED before planning with the spec's typed
    // failure — `.temporarilyUnavailable(.dedupIndexRebuild)` (06 §8 WS5,
    // 05 §16, 02 §5.1).
    await #expect(throws: HistoryFailure.temporarilyUnavailable(.dedupIndexRebuild)) {
        try await authority.commitCapture(captureBundle)
    }

    // WS5: "no … invalidation is produced" (docs/04-coherence.md §4: no
    // invalidation for a failed commit). Finish the stream, then drain it.
    await authority.unregisterInvalidationSubscriber(registration.subscription)
    var publishedCount = 0
    for try await _ in registration.stream {
        publishedCount += 1
    }
    #expect(publishedCount == 0)

    // WS5: "no row … is produced" — still exactly the two seeded rows, each
    // with its Canonical bytes and signature metadata intact (the §4 codecs
    // still decode them: the seeded rows are valid, so the rejection is the
    // over-bound retained count, never blob corruption).
    let verification = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(verification)
    #expect(rows.count == 2)
    let expectedTextByID: [UUID: String] = [
        firstBundle.domain.candidateID.rawValue: firstText,
        secondBundle.domain.candidateID.rawValue: secondText,
    ]
    for row in rows {
        let expectedText = try #require(expectedTextByID[row.id])
        #expect(row.contentVersionRaw == 1)
        #expect(row.copyCount == 1)
        let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
        #expect(canonical.representations.map(\.content.bytes) == [Data(expectedText.utf8)])
        let entries = try SignatureBlobCodec.decode(row.canonicalSignatureBlob)
        #expect(entries.map(\.typeIdentifier) == ["public.utf8-plain-text"])
    }

    // WS5: "no … position … is produced" — the singleton never advanced past
    // its startup value (a receipt exists only for a committed capture).
    let position = try WSSupport.fetchPosition(verification)
    #expect(position.rawValue == 0)
}

/// Control for the no-invalidation clause: the same registration/drain probe
/// used above DOES observe exactly one invalidation for a successful capture
/// commit — the zero count in the WS5 test is a genuine absence of a
/// publish, not a broken probe (docs/05-authority-kernel.md §11 step 2).
@Test func invalidationProbeObservesExactlyOnePublishForACommittedCapture() async throws {
    let storeURL = WSSupport.tempStoreURL("ws5-invalidation-control")
    defer { WSSupport.removeStore(storeURL) }

    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)
    let preparation = IngestPreparationActor()

    let registration = await authority.registerInvalidationSubscriber()
    let bundle = try await preparation.prepare(
        WSSupport.textCapture(
            "ws5 control capture",
            observedAt: Date(timeIntervalSinceReferenceDate: 700_012_000)
        )
    )
    let receipt = try await authority.commitCapture(bundle)
    guard case let .committed(commit) = receipt else {
        Issue.record("WS5 control: expected a .committed receipt, got \(receipt)")
        return
    }
    #expect(commit.position.rawValue == 1)

    await authority.unregisterInvalidationSubscriber(registration.subscription)
    var published: [HistoryInvalidation] = []
    for try await invalidation in registration.stream {
        published.append(invalidation)
    }
    // §11 step 2: exactly one synchronous invalidation per successful History
    // Commit, carrying the commit's position.
    #expect(published.map(\.latestPosition.rawValue) == [1])
}

/// WS5 mechanism, build seam (docs/05-authority-kernel.md §12, §7.1 step 1):
/// `SignatureIndex.build` refuses a signature set larger than the hard
/// retained-item bound with the exact over-bound rejection the capture-time
/// rebuild maps to `.temporarilyUnavailable(.dedupIndexRebuild)`.
@Test func signatureIndexBuildRejectsRetainedInputOverTheHardBound() throws {
    let limits = Self.overBoundRetainedLimits()
    let signatures: [HistoryItemID: [ContentSignatureEntry]] = [
        HistoryItemID(rawValue: UUID()): [ContentSignatureEntry(
            typeIdentifier: "public.utf8-plain-text",
            fingerprint: ContentFingerprint(rawValue: 0x5EED_0001),
            byteCount: 17
        )],
        HistoryItemID(rawValue: UUID()): [ContentSignatureEntry(
            typeIdentifier: "public.utf8-plain-text",
            fingerprint: ContentFingerprint(rawValue: 0x5EED_0002),
            byteCount: 17
        )],
    ]

    // Two retained items against a hard bound of one: construction cannot
    // prove completeness and rejects with the exact found/bound payload.
    #expect(throws: SignatureIndexRejection.retainedCountExceedsBound(found: 2, bound: 1)) {
        try SignatureIndex.build(from: signatures, limits: limits)
    }
}
}
