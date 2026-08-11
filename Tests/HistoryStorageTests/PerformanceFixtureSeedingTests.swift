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

        let history = try await WSSupport.openHistory(
            storeURL: storeURL,
            maximumUnpinned: 200
        )
        let seeded = try await history.seedPerformanceFixture(rowCount: 65) { index in
            Self.capture(index: index, bodyBytes: 256 * 1_024)
        }
        #expect(seeded.retainedRows == 65)
        #expect(seeded.transactionCount == 2)
        #expect(seeded.batchSize == 64)
        #expect(seeded.position.rawValue == 2)

        let coalescedReceipt = try await history.perform(.capture(
            Self.capture(index: 0, bodyBytes: 256 * 1_024)
        ))
        guard case .committed(let coalescedCommit) = coalescedReceipt,
              case .coalesced(let coalescedReference) = coalescedCommit.outcome
        else {
            Issue.record("expected seeded Canonical content to coalesce")
            return
        }
        #expect(coalescedCommit.position.rawValue == 3)

        let insertedReceipt = try await history.perform(.capture(
            Self.capture(index: 65, bodyBytes: 256 * 1_024)
        ))
        guard case .committed(let insertedCommit) = insertedReceipt,
              case .inserted = insertedCommit.outcome
        else {
            Issue.record("expected the distinct post-seed capture to insert")
            return
        }
        #expect(insertedCommit.position.rawValue == 4)

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

        let verificationContainer = try WSSupport.makeContainer(storeURL: storeURL)
        let rows = try WSSupport.fetchRows(verificationContainer)
        #expect(rows.count == 66)
        let stored = try #require(rows.first { $0.id == coalescedReference.id.rawValue })
        let canonical = try CanonicalBlobCodec.decode(stored.canonicalBlob)
        let revisionState = try RevisionStateBlobCodec.decode(
            stored.revisionStateBlob,
            canonical: canonical
        )
        #expect(revisionState.revisions.isEmpty)
        #expect(revisionState.activeRevisionID == nil)
        let signatures = try SignatureBlobCodec.decode(stored.canonicalSignatureBlob)
        try SignatureBlobCodec.validateCoverage(
            canonical: canonical,
            entries: signatures
        )
        let effectiveTypes = try EffectiveTypeIdentifiersBlobCodec.decode(
            stored.effectiveTypeIdentifiersBlob
        )
        #expect(effectiveTypes == ["public.utf8-plain-text"])

        let reopened = try await WSSupport.openHistory(
            storeURL: storeURL,
            maximumUnpinned: 200
        )
        let reopenedPage = try await reopened.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: 100
        ))
        #expect(reopenedPage.position == insertedCommit.position)
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
        #expect(finalReference.id == coalescedReference.id)
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
