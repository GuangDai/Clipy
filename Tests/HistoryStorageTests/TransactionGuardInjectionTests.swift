/// Direct deterministic proofs for the five defensive §10 transaction
/// guards named by V1V-03B. Public actions cannot naturally reach these
/// branches: fact load, planning, stamping, and transaction application run
/// in one serialized Authority interval. The existing one-shot transaction
/// seam therefore simulates each guard's observed local condition at the
/// guard itself, without inserting corrupt durable rows or exposing the
/// private executor.
///
/// Every test drives the normal Authority commit API and asserts the uniform
/// §16 `.persistence(.transaction)` boundary mapping, rollback of rows and
/// Change Position, and exactly zero publications in the failed operation's
/// one-publication-maximum window. `PageCursorCodecTests` independently owns
/// the cursor half of
/// `defensive-transaction-guards-and-cursor-codec-untested-cluster`.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct TransactionGuardInjectionTests {

private enum SetupFailure: Error {
    case expectedInsertedReceipt
}

private static func insertText(
    _ text: String,
    observedAt: Date,
    authority: HistoryAuthority,
    preparation: IngestPreparationActor
) async throws -> HistoryItemReference {
    let bundle = try await preparation.prepare(
        WSSupport.textCapture(text, observedAt: observedAt)
    )
    let receipt = try await authority.commitCapture(bundle)
    guard case let .committed(commit) = receipt,
          case let .inserted(reference) = commit.outcome
    else {
        Issue.record("transaction-guard setup expected .committed(.inserted), got \(receipt)")
        throw SetupFailure.expectedInsertedReceipt
    }
    #expect(commit.position.rawValue == 1)
    return reference
}

private static func expectCreateGuardRollback(
    _ injection: InjectedTransactionFailure,
    storeLabel: String
) async throws {
    let storeURL = WSSupport.tempStoreURL(storeLabel)
    defer { WSSupport.removeStore(storeURL) }

    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)
    let preparation = IngestPreparationActor()
    let bundle = try await preparation.prepare(
        WSSupport.textCapture(
            "\(storeLabel) rejected create",
            observedAt: Date(timeIntervalSinceReferenceDate: 700_031_000)
        )
    )

    await authority.setTransactionFailureInjection(injection)
    let publicationProbe = await SingleOperationInvalidationPublicationProbe.begin(
        on: authority
    )
    await #expect(throws: HistoryFailure.persistence(.transaction)) {
        try await authority.commitCapture(bundle)
    }
    let publications = try await publicationProbe.finish(on: authority)
    #expect(publications.count == 0)

    let verification = try WSSupport.makeContainer(storeURL: storeURL)
    #expect(try WSSupport.fetchRows(verification).isEmpty)
    #expect(try WSSupport.fetchPosition(verification).rawValue == 0)
}

/// The singleton comparison executes its actual
/// `StorageInvariant.positionChanged` throw and the transaction catch maps it
/// uniformly; no create or position successor persists.
@Test func positionChangedGuardMapsToTransactionAndRollsBack() async throws {
    try await Self.expectCreateGuardRollback(
        .positionChanged,
        storeLabel: "tx-guard-position-changed"
    )
}

/// A create reaches the actual duplicate-ID rejection branch after the
/// operation-local lookup; the seam changes only that guard's local result.
@Test func duplicateCreateIDGuardMapsToTransactionAndRollsBack() async throws {
    try await Self.expectCreateGuardRollback(
        .duplicateCreateID,
        storeLabel: "tx-guard-duplicate-create"
    )
}

/// Copy Coalescing stamps an occurrence update for the retained row. The
/// injected absence is consumed by `requireRow`, exercising the actual
/// `.missingRow` rejection without deleting or corrupting the durable row.
@Test func missingRowGuardMapsToTransactionAndRollsBack() async throws {
    let storeURL = WSSupport.tempStoreURL("tx-guard-missing-row")
    defer { WSSupport.removeStore(storeURL) }

    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)
    let preparation = IngestPreparationActor()
    let originalText = "transaction guard retained row"
    let originalObservedAt = Date(timeIntervalSinceReferenceDate: 700_031_100)
    let reference = try await Self.insertText(
        originalText,
        observedAt: originalObservedAt,
        authority: authority,
        preparation: preparation
    )
    let coalesceBundle = try await preparation.prepare(
        WSSupport.textCapture(
            originalText,
            observedAt: Date(timeIntervalSinceReferenceDate: 700_031_200)
        )
    )

    await authority.setTransactionFailureInjection(.missingRow)
    let publicationProbe = await SingleOperationInvalidationPublicationProbe.begin(
        on: authority
    )
    await #expect(throws: HistoryFailure.persistence(.transaction)) {
        try await authority.commitCapture(coalesceBundle)
    }
    let publications = try await publicationProbe.finish(on: authority)
    #expect(publications.count == 0)

    let verification = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(verification)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.id == reference.id.rawValue)
    #expect(row.copyCount == 1)
    #expect(row.lastCopiedAt == originalObservedAt)
    #expect(try WSSupport.fetchPosition(verification).rawValue == 1)
}

/// A changing revision passes both public OCC checks, then the transaction's
/// own version guard observes the injected mismatch. The revision blob,
/// projection, Content Version, and Change Position all remain unchanged.
@Test func contentVersionMismatchGuardMapsToTransactionAndRollsBack() async throws {
    let storeURL = WSSupport.tempStoreURL("tx-guard-version-mismatch")
    defer { WSSupport.removeStore(storeURL) }

    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)
    let ingestion = IngestPreparationActor()
    let canonicalText = "transaction guard canonical"
    let reference = try await Self.insertText(
        canonicalText,
        observedAt: Date(timeIntervalSinceReferenceDate: 700_031_300),
        authority: authority,
        preparation: ingestion
    )
    let request = RevisionRequest(
        itemID: reference.id,
        expected: reference.contentVersion,
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .replace(bytes: Data("transaction guard revised".utf8))
            ),
        ]))
    )
    let snapshot = try await authority.revisionPreparationSnapshot(request)
    let revisionPreparation = RevisionPreparationActor()
    let bundle = try await revisionPreparation.prepare(request, from: snapshot)

    await authority.setTransactionFailureInjection(.contentVersionMismatch)
    let publicationProbe = await SingleOperationInvalidationPublicationProbe.begin(
        on: authority
    )
    await #expect(throws: HistoryFailure.persistence(.transaction)) {
        try await authority.commitRevision(request, bundle)
    }
    let publications = try await publicationProbe.finish(on: authority)
    #expect(publications.count == 0)

    let verification = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(verification)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.id == reference.id.rawValue)
    #expect(row.contentVersionRaw == reference.contentVersion.rawValue)
    #expect(row.title == canonicalText)
    let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
    let lineage = try RevisionStateBlobCodec.decode(
        row.revisionStateBlob,
        canonical: canonical
    )
    #expect(lineage.revisions.isEmpty)
    #expect(lineage.activeRevisionID == nil)
    #expect(try WSSupport.fetchPosition(verification).rawValue == 1)
}

/// Pinning first writes ordinal zero in the transaction. The validator then
/// adds one impossible value only to its local scalar proof, making the real
/// contiguity guard throw; rollback restores the durable nil ordinal.
@Test func finalPinOrderGuardMapsToTransactionAndRollsBack() async throws {
    let storeURL = WSSupport.tempStoreURL("tx-guard-final-pin-order")
    defer { WSSupport.removeStore(storeURL) }

    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)
    let preparation = IngestPreparationActor()
    let reference = try await Self.insertText(
        "transaction guard pin target",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_031_400),
        authority: authority,
        preparation: preparation
    )

    await authority.setTransactionFailureInjection(.finalPinOrderViolated)
    let publicationProbe = await SingleOperationInvalidationPublicationProbe.begin(
        on: authority
    )
    await #expect(throws: HistoryFailure.persistence(.transaction)) {
        try await authority.commitPinnedPlacement(reference.id, .last)
    }
    let publications = try await publicationProbe.finish(on: authority)
    #expect(publications.count == 0)

    let verification = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(verification)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.id == reference.id.rawValue)
    #expect(row.pinOrdinal == nil)
    #expect(try WSSupport.fetchPosition(verification).rawValue == 1)
}
}
