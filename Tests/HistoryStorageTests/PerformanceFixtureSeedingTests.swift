/// Persistent proofs for the package-only bounded performance-fixture seeder.
/// The seam is setup infrastructure, not a fake storage implementation: raw
/// captures use production ingest preparation/codecs and every writable
/// ModelContext remains owned by `HistoryAuthority`.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

struct PerformanceFixtureSeedingTests {
    @Test func boundedSeedReopensAndSupportsPublicCoalesceInsertAndReads() async throws {
        let storeURL = WSSupport.tempStoreURL("performance-fixture-seed")
        defer { WSSupport.removeStore(storeURL) }

        // Keep every external-data-owning facade/container inside a nested
        // frame. It unwinds before the outer defer removes the store support
        // directory, so CoreData never tries to detach a blob after its
        // source files have already been deleted.
        try await Self.exerciseLargeFixture(storeURL: storeURL)
    }

    private static func exerciseLargeFixture(storeURL: URL) async throws {
        let seeded = try await Self.seedLargeFixture(storeURL: storeURL)
        #expect(seeded.retainedRows == 65)
        #expect(seeded.transactionCount == 2)
        #expect(seeded.batchSize == 64)
        #expect(seeded.position.rawValue == 2)

        let validated = try await Self.validateLargeFixture(storeURL: storeURL)
        #expect(validated.coalescedPosition.rawValue == 3)
        #expect(validated.insertedPosition.rawValue == 4)

        // Decode every stored value while its ModelContext is alive, then
        // return only immutable proof values. Returning `@Model` rows from a
        // short-lived context makes CoreData clone external references into
        // `.LINKS` and is not a valid actor/context-boundary test pattern.
        let stored = try Self.storedProof(
            storeURL: storeURL,
            itemID: validated.coalescedReference.id
        )
        #expect(stored.rowCount == 66)
        #expect(stored.revisionCount == 0)
        #expect(stored.activeRevisionID == nil)
        #expect(stored.effectiveTypes == ["public.utf8-plain-text"])

        let reopened = try await WSSupport.openHistory(
            storeURL: storeURL,
            maximumUnpinned: 200
        )
        let reopenedPage = try await reopened.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: 100
        ))
        #expect(reopenedPage.position == validated.insertedPosition)
        #expect(reopenedPage.rows.count == 66)

        let reopenedCoalesce = try await reopened.perform(.capture(
            Self.capture(index: 0, bodyBytes: 256 * 1_024)
        ))
        guard case .committed(let finalCommit) = reopenedCoalesce,
              case .coalesced(let finalReference) = finalCommit.outcome
        else {
            Issue.record("expected rebuilt startup index to coalesce seeded content")
            return
        }
        #expect(finalReference.id == validated.coalescedReference.id)
        #expect(finalCommit.position.rawValue == 5)
    }

    @Test func secondSeedRejectsBeforeMutatingNonemptyStore() async throws {
        let storeURL = WSSupport.tempStoreURL("performance-fixture-nonempty")
        defer { WSSupport.removeStore(storeURL) }

        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let first = try await history.seedPerformanceFixture(rowCount: 1) { index in
            Self.capture(index: index, bodyBytes: 128)
        }

        await #expect(throws: PerformanceFixtureSeedError.storeNotEmpty) {
            try await history.seedPerformanceFixture(rowCount: 1) { index in
                Self.capture(index: index + 1, bodyBytes: 128)
            }
        }
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: 10
        ))
        #expect(page.rows.count == 1)
        #expect(page.position == first.position)
    }

    @Test func failedMultirowBatchRollsBackRowsPositionAndIndex() async throws {
        let storeURL = WSSupport.tempStoreURL("performance-fixture-rollback")
        defer { WSSupport.removeStore(storeURL) }

        try await Self.exerciseMultirowRollback(storeURL: storeURL)
    }

    private static func exerciseMultirowRollback(storeURL: URL) async throws {
        let history = try await WSSupport.openHistory(
            storeURL: storeURL,
            maximumUnpinned: 10
        )
        await history.authority.setTransactionFailureInjection(
            .beforeSingletonUpdate
        )

        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await history.seedPerformanceFixture(rowCount: 3) { index in
                Self.capture(index: index, bodyBytes: 256 * 1_024)
            }
        }

        do {
            let failedContainer = try WSSupport.makeContainer(storeURL: storeURL)
            #expect(try WSSupport.fetchRows(failedContainer).isEmpty)
            #expect(try WSSupport.fetchPosition(failedContainer).rawValue == 0)
        }

        let retry = try await history.seedPerformanceFixture(rowCount: 3) { index in
            Self.capture(index: index, bodyBytes: 256 * 1_024)
        }
        #expect(retry.retainedRows == 3)
        #expect(retry.transactionCount == 1)
        #expect(retry.position.rawValue == 1)

        let coalesced = try await history.perform(.capture(
            Self.capture(index: 0, bodyBytes: 256 * 1_024)
        ))
        guard case .committed(let commit) = coalesced,
              case .coalesced = commit.outcome
        else {
            Issue.record("expected retry's seeded index to coalesce")
            return
        }
        #expect(commit.position.rawValue == 2)
    }

    private struct PublicValidation: Sendable {
        let coalescedReference: HistoryItemReference
        let coalescedPosition: ChangePosition
        let insertedPosition: ChangePosition
    }

    private struct StoredProof: Sendable {
        let rowCount: Int
        let revisionCount: Int
        let activeRevisionID: RevisionID?
        let effectiveTypes: [String]
    }

    private enum FixtureTestError: Error {
        case unexpectedReceipt
        case missingStoredRow
    }

    /// The facade and its ModelContainer leave scope before validation opens
    /// the same persistent store, matching an independent setup process.
    private static func seedLargeFixture(
        storeURL: URL
    ) async throws -> PerformanceFixtureSeedReceipt {
        let history = try await WSSupport.openHistory(
            storeURL: storeURL,
            maximumUnpinned: 200
        )
        return try await history.seedPerformanceFixture(rowCount: 65) { index in
            Self.capture(index: index, bodyBytes: 256 * 1_024)
        }
    }

    /// Reopen first, then force the seeded-index coalesce, ordinary insert,
    /// scalar browse, details, and paste paths over full external bytes.
    private static func validateLargeFixture(
        storeURL: URL
    ) async throws -> PublicValidation {
        let history = try await WSSupport.openHistory(
            storeURL: storeURL,
            maximumUnpinned: 200
        )
        let coalescedReceipt = try await history.perform(.capture(
            Self.capture(index: 0, bodyBytes: 256 * 1_024)
        ))
        guard case .committed(let coalescedCommit) = coalescedReceipt,
              case .coalesced(let coalescedReference) = coalescedCommit.outcome
        else {
            throw FixtureTestError.unexpectedReceipt
        }

        let insertedReceipt = try await history.perform(.capture(
            Self.capture(index: 65, bodyBytes: 256 * 1_024)
        ))
        guard case .committed(let insertedCommit) = insertedReceipt,
              case .inserted = insertedCommit.outcome
        else {
            throw FixtureTestError.unexpectedReceipt
        }

        let page = try await history.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: 100
        ))
        #expect(page.position == insertedCommit.position)
        #expect(page.rows.count == 66)
        #expect(Set(page.rows.map(\.item.id)).count == 66)

        let details = try await history.details(for: coalescedReference.id)
        let canonicalBytes = try #require(details.canonical.first?.bytes)
        #expect(canonicalBytes.count == 256 * 1_024)
        let payload = try await history.pastePayload(for: coalescedReference.id)
        #expect(payload.representations.first?.bytes == canonicalBytes)

        return PublicValidation(
            coalescedReference: coalescedReference,
            coalescedPosition: coalescedCommit.position,
            insertedPosition: insertedCommit.position
        )
    }

    /// An independent container verifies durable codecs without allowing an
    /// `@Model`, `ModelContext`, or external-data reference to escape scope.
    private static func storedProof(
        storeURL: URL,
        itemID: HistoryItemID
    ) throws -> StoredProof {
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let rowCount = try context.fetchCount(FetchDescriptor<HistoryItemRow>())
        let uuid = itemID.rawValue
        var descriptor = FetchDescriptor<HistoryItemRow>(
            predicate: #Predicate { $0.id == uuid }
        )
        descriptor.fetchLimit = 2
        let rows = try context.fetch(descriptor)
        guard rows.count == 1, let row = rows.first else {
            throw FixtureTestError.missingStoredRow
        }
        let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
        let revisionState = try RevisionStateBlobCodec.decode(
            row.revisionStateBlob,
            canonical: canonical
        )
        let signatures = try SignatureBlobCodec.decode(
            row.canonicalSignatureBlob
        )
        try SignatureBlobCodec.validateCoverage(
            canonical: canonical,
            entries: signatures
        )
        let effectiveTypes = try EffectiveTypeIdentifiersBlobCodec.decode(
            row.effectiveTypeIdentifiersBlob
        )
        return StoredProof(
            rowCount: rowCount,
            revisionCount: revisionState.revisions.count,
            activeRevisionID: revisionState.activeRevisionID,
            effectiveTypes: effectiveTypes
        )
    }

    private static func capture(index: Int, bodyBytes: Int) -> ClipboardCapture {
        let prefix = Data("fixture-row-\(index)-".utf8)
        let suffix = Data("-tail-\(index)".utf8)
        precondition(prefix.count + suffix.count <= bodyBytes)
        var bytes = Data(repeating: 0x78, count: bodyBytes)
        bytes.replaceSubrange(0..<prefix.count, with: prefix)
        bytes.replaceSubrange(
            (bytes.count - suffix.count)..<bytes.count,
            with: suffix
        )
        return ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: bytes
            )],
            origin: CopyOriginObservation(
                sourceApplication: "performance-fixture-test",
                lineageHint: nil
            ),
            observedAt: Date(timeIntervalSinceReferenceDate: 650_000_000)
        )
    }
}
