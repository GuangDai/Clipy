/// Persistent proofs for the package-only bounded performance-fixture seeder.
/// The seam is setup infrastructure, not a fake storage implementation: raw
/// captures use production ingest preparation/codecs and the writable
/// SQLite connection remains owned by `HistoryAuthority`.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct PerformanceFixtureSeedingTests {
    private static let batchedFixtureBodyBytes = 128

    @Test func boundedSeedReopensAndSupportsPublicCoalesceInsertAndReads() async throws {
        let storeURL = WSSupport.tempStoreURL("performance-fixture-seed")
        defer { WSSupport.removeStore(storeURL) }

        // Small inline payloads isolate batch/commit semantics; the admission
        // smoke exercises 1,000 rows with 256-KiB file-backed payloads.
        try await Self.exerciseBatchedFixture(storeURL: storeURL)
    }

    private static func exerciseBatchedFixture(storeURL: URL) async throws {
        let seeded = try await Self.seedBatchedFixture(storeURL: storeURL)
        #expect(seeded.retainedRows == 65)
        #expect(seeded.transactionCount == 2)
        #expect(seeded.batchSize == 64)
        #expect(seeded.position.rawValue == 2)

        let validated = try await Self.validateBatchedFixture(storeURL: storeURL)
        #expect(validated.coalescedPosition.rawValue == 3)
        #expect(validated.insertedPosition.rawValue == 4)

        // An independent SQL connection reads the committed metadata and
        // exact canonical representations, returning immutable proof values.
        let stored = try Self.storedProof(
            storeURL: storeURL,
            itemID: validated.coalescedReference.id
        )
        #expect(stored.rowCount == 66)
        #expect(stored.revisionCount == 0)
        #expect(stored.isCanonicalActive)
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
            Self.capture(index: 0, bodyBytes: Self.batchedFixtureBodyBytes)
        ))
        guard case .committed(let finalCommit) = reopenedCoalesce,
              case .coalesced(let finalReference) = finalCommit.outcome
        else {
            Issue.record("expected durable signature candidates to coalesce seeded content")
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
        // Keep this transaction proof inline; blob publication/failure has
        // separate real-file tests. Rows, candidates and position roll back.
        let history = try await WSSupport.openHistory(
            storeURL: storeURL,
            maximumUnpinned: 10
        )
        await history.authority.setTransactionFailureInjection(
            .beforeSingletonUpdate
        )

        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await history.seedPerformanceFixture(rowCount: 3) { index in
                Self.capture(index: index, bodyBytes: Self.batchedFixtureBodyBytes)
            }
        }

        do {
            let failedContainer = try WSSupport.makeDatabase(storeURL: storeURL)
            #expect(try WSSupport.fetchRows(failedContainer).isEmpty)
            #expect(try WSSupport.fetchPosition(failedContainer).rawValue == 0)
        }

        let retry = try await history.seedPerformanceFixture(rowCount: 3) { index in
            Self.capture(index: index, bodyBytes: Self.batchedFixtureBodyBytes)
        }
        #expect(retry.retainedRows == 3)
        #expect(retry.transactionCount == 1)
        #expect(retry.position.rawValue == 1)

        let coalesced = try await history.perform(.capture(
            Self.capture(index: 0, bodyBytes: Self.batchedFixtureBodyBytes)
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
        let isCanonicalActive: Bool
        let effectiveTypes: [String]
    }

    private enum FixtureTestError: Error {
        case unexpectedReceipt
        case missingStoredRow
    }

    /// The facade and its database connection leave scope before validation opens
    /// the same persistent store, matching an independent setup process.
    private static func seedBatchedFixture(
        storeURL: URL
    ) async throws -> PerformanceFixtureSeedReceipt {
        let history = try await WSSupport.openHistory(
            storeURL: storeURL,
            maximumUnpinned: 200
        )
        return try await history.seedPerformanceFixture(rowCount: 65) { index in
            Self.capture(index: index, bodyBytes: Self.batchedFixtureBodyBytes)
        }
    }

    /// Reopen first, then force the seeded-index coalesce, ordinary insert,
    /// scalar browse, details, and paste paths over the durable seeded bytes.
    private static func validateBatchedFixture(
        storeURL: URL
    ) async throws -> PublicValidation {
        let history = try await WSSupport.openHistory(
            storeURL: storeURL,
            maximumUnpinned: 200
        )
        let coalescedReceipt = try await history.perform(.capture(
            Self.capture(index: 0, bodyBytes: Self.batchedFixtureBodyBytes)
        ))
        guard case .committed(let coalescedCommit) = coalescedReceipt,
              case .coalesced(let coalescedReference) = coalescedCommit.outcome
        else {
            throw FixtureTestError.unexpectedReceipt
        }

        let insertedReceipt = try await history.perform(.capture(
            Self.capture(index: 65, bodyBytes: Self.batchedFixtureBodyBytes)
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
        let canonicalType = try #require(details.canonical.first?.typeIdentifier)
        let canonicalBytes = try await history.representation(.init(
            item: details.item, basis: .canonical, typeIdentifier: canonicalType
        )).bytes
        #expect(canonicalBytes.count == Self.batchedFixtureBodyBytes)
        let payload = try await history.pastePayload(for: coalescedReference.id)
        #expect(payload.representations.first?.bytes == canonicalBytes)

        return PublicValidation(
            coalescedReference: coalescedReference,
            coalescedPosition: coalescedCommit.position,
            insertedPosition: insertedCommit.position
        )
    }

    /// An independent SQL connection verifies stored representation bytes
    /// and candidate facts without inventing an aggregate blob fixture.
    private static func storedProof(
        storeURL: URL,
        itemID: HistoryItemID
    ) throws -> StoredProof {
        let database = try WSSupport.makeDatabase(storeURL: storeURL)
        let rows = try WSSupport.fetchRows(database)
        guard let row = rows.first(where: { $0.id == itemID.rawValue }),
              row.currentContentID == row.canonicalContentID else {
            throw FixtureTestError.missingStoredRow
        }
        let canonical = try WSSupport.fetchCanonical(itemID: itemID.rawValue, in: database)
        let signatures = try WSSupport.fetchSignatureEntries(
            itemID: itemID.rawValue, in: database
        )
        try SignatureBlobCodec.validateCoverage(
            canonical: canonical,
            entries: signatures
        )
        let effectiveTypes = try EffectiveTypeIdentifiersBlobCodec.decode(
            row.effectiveTypeIdentifiersBlob
        )
        return StoredProof(
            rowCount: rows.count,
            revisionCount: row.revisionCount,
            isCanonicalActive: row.currentContentID == row.canonicalContentID,
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
