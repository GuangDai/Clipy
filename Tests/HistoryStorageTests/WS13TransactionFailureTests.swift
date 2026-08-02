/// WS13 — Transaction failure (docs/06-cross-cutting.md §8 WS13): inject a
/// failure inside the `ModelContext.transaction` closure AFTER row mutation
/// but BEFORE the singleton position update. The caller observes
/// `.persistence(.transaction)` — the documented producer for a closure
/// failure (docs/05-authority-kernel.md §16, Part V) — and the failed
/// closure commits NOTHING: durable rows and position are unchanged, the
/// Signature Index is unchanged (no rebuild, no stale delta — the very next
/// capture commits cleanly), no invalidation is published, and no receipt
/// exists for the failed attempt (docs/05-authority-kernel.md §10: "Closure
/// failure commits nothing. There is no receipt, index delta, or
/// invalidation.").
///
/// Storage-side proof, not a public-facade path (the same stance as WS5 and
/// `TransactionBoundaryProofTests`): the injection seam
/// (`HistoryAuthority.setTransactionFailureInjection` /
/// `InjectedTransactionFailure.beforeSingletonUpdate`, docs/roadmap/
/// 03-historystorage.md step 5) is Authority-internal, so the test drives a
/// directly constructed Authority and the real `IngestPreparationActor`
/// (see `WSSupport.makeAuthority`). Arming is ONE-SHOT: the first
/// transaction closure entered after arming throws at the injection point
/// and disarms, so the third capture below is unaffected — that property is
/// itself part of the proof (the index and position need no recovery).
///
/// Deferral (docs/roadmap/README.md §3 WS-clause phasing note): NONE. WS13
/// names no public-read or observation clause — every clause (typed failure,
/// unchanged rows/position, unchanged Signature Index, no invalidation, no
/// receipt) is commit/storage-side and is closed here.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS13TransactionFailureTests {

/// WS13 (docs/06-cross-cutting.md §8): one armed `.beforeSingletonUpdate`
/// injection turns the second capture's commit into a closure failure —
/// `.persistence(.transaction)` for the caller, durable state frozen at the
/// first capture's commit (position 1, exactly the first row intact), and
/// exactly one invalidation published in the whole scenario, for the THIRD
/// capture's successful commit at position 2 (Signature Index untouched by
/// the failed closure: docs/05-authority-kernel.md §11).
@Test func injectedClosureFailureCommitsNothingAndLeavesStoreAndIndexConsistent() async throws {
    let storeURL = WSSupport.tempStoreURL("ws13-transaction-failure")
    defer { WSSupport.removeStore(storeURL) }

    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)
    let preparation = IngestPreparationActor()

    // Arrange: one GOOD capture committed first (position 1), so the store
    // has known durable state the failed closure must provably not disturb.
    let firstText = "ws13 durable capture"
    let firstObservedAt = Date(timeIntervalSinceReferenceDate: 700_013_000)
    let firstSource = "com.example.ws13.one"
    let firstBundle = try await preparation.prepare(
        WSSupport.textCapture(firstText, observedAt: firstObservedAt, source: firstSource)
    )
    let firstReceipt = try await authority.commitCapture(firstBundle)
    guard case let .committed(firstCommit) = firstReceipt else {
        Issue.record("WS13: expected a .committed receipt for the setup capture, got \(firstReceipt)")
        return
    }
    #expect(firstCommit.position.rawValue == 1)

    // The invalidation probe, registered BEFORE the failed attempt
    // (docs/04-coherence.md §5 ordering). WS5's probe-control precedent
    // (`invalidationProbeObservesExactlyOnePublishForACommittedCapture`)
    // establishes this registration/drain probe detects every publish; here
    // the third capture's publish doubles as the in-scenario control.
    let registration = await authority.registerInvalidationSubscriber()

    // Arm the one-shot WS13 seam: the next transaction closure throws after
    // row mutation, immediately before the singleton position update.
    await authority.setTransactionFailureInjection(.beforeSingletonUpdate)

    // Act: a second, DISTINCT capture through the real preparation + commit
    // path. The armed injection fires inside its transaction closure.
    let rejectedBundle = try await preparation.prepare(
        WSSupport.textCapture(
            "ws13 rejected capture",
            observedAt: Date(timeIntervalSinceReferenceDate: 700_013_500)
        )
    )
    // WS13: "the caller observes `.persistence(.transaction)` — the
    // documented producer for a `ModelContext.transaction` closure failure"
    // (06 §8 WS13; 05 §16). No receipt exists for the failed attempt (05
    // §10) — the throw IS the outcome.
    await #expect(throws: HistoryFailure.persistence(.transaction)) {
        try await authority.commitCapture(rejectedBundle)
    }

    // WS13 (i): "unchanged durable rows and position" (06 §8) — still
    // exactly the first capture's row, with every field the commit stamped
    // intact, and the singleton never advanced past 1 (05 §10: closure
    // failure commits nothing).
    let verification = try WSSupport.makeContainer(storeURL: storeURL)
    let rowsAfterFailure = try WSSupport.fetchRows(verification)
    #expect(rowsAfterFailure.count == 1)
    let durableRow = try #require(rowsAfterFailure.first)
    #expect(durableRow.id == firstBundle.domain.candidateID.rawValue)
    #expect(durableRow.contentVersionRaw == 1)
    #expect(durableRow.firstCopiedAt == firstObservedAt)
    #expect(durableRow.lastCopiedAt == firstObservedAt)
    #expect(durableRow.copyCount == 1)
    #expect(durableRow.firstSource == firstSource)
    #expect(durableRow.lastSource == firstSource)
    #expect(durableRow.projectionSchemaVersion == 1)
    #expect(durableRow.title == firstText)
    #expect(durableRow.searchBody == firstText)
    #expect(durableRow.pinOrdinal == nil)
    let canonical = try CanonicalBlobCodec.decode(durableRow.canonicalBlob)
    #expect(canonical.representations.map(\.content.typeIdentifier) == ["public.utf8-plain-text"])
    #expect(canonical.representations.map(\.content.bytes) == [Data(firstText.utf8)])
    let signatureEntries = try SignatureBlobCodec.decode(durableRow.canonicalSignatureBlob)
    #expect(signatureEntries.map(\.typeIdentifier) == ["public.utf8-plain-text"])
    #expect(
        try EffectiveTypeIdentifiersBlobCodec.decode(durableRow.effectiveTypeIdentifiersBlob)
            == ["public.utf8-plain-text"]
    )
    let positionAfterFailure = try WSSupport.fetchPosition(verification)
    #expect(positionAfterFailure.rawValue == 1)

    // WS13 (ii): "unchanged Signature Index" (06 §8) — no rebuild and no
    // stale delta (05 §11: index mutation happens only after transaction
    // success). The operational proof: a THIRD distinct capture committed
    // immediately afterwards succeeds at position 2 without any recovery.
    // Arming is one-shot, so this commit's closure is unaffected.
    let thirdBundle = try await preparation.prepare(
        WSSupport.textCapture(
            "ws13 post-failure capture",
            observedAt: Date(timeIntervalSinceReferenceDate: 700_014_000)
        )
    )
    let thirdReceipt = try await authority.commitCapture(thirdBundle)
    guard case let .committed(thirdCommit) = thirdReceipt else {
        Issue.record("WS13: expected a .committed receipt for the post-failure capture, got \(thirdReceipt)")
        return
    }
    #expect(thirdCommit.position.rawValue == 2)
    let positionAfterRecovery = try WSSupport.fetchPosition(verification)
    #expect(positionAfterRecovery.rawValue == 2)

    // WS13 (iii): "no invalidation" for the failed attempt (06 §8; 04 §4: no
    // invalidation for a failed commit). Finish the stream, then drain it:
    // exactly ONE publish in the whole scenario, carrying the third
    // capture's position (05 §11 step 2: one synchronous invalidation per
    // successful History Commit).
    await authority.unregisterInvalidationSubscriber(registration.subscription)
    var published: [HistoryInvalidation] = []
    for try await invalidation in registration.stream {
        published.append(invalidation)
    }
    #expect(published.map(\.latestPosition.rawValue) == [2])
}
}
