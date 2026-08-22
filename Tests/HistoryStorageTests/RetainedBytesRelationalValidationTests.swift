/// DATA-2 regression proofs: scalar bounds alone do not make a
/// `RetainedBytesRow` possible. Canonical content contains at least one
/// non-empty representation, and every stored revision contains at least one
/// non-empty representation, so the loader must also reject impossible
/// relations before any mutation enters `ModelContext.transaction`.
///
/// Seam: every test invokes the real public `SwiftDataHistory.perform`
/// action. Corruption is injected only during setup through an independent
/// container. The existing one-shot transaction failure is armed before the
/// corrupt action; after restoring the exact projection scalars, the next
/// otherwise-valid action must still consume that injection. That proves the
/// corruption rejection happened before transaction entry, while a direct
/// persisted-column snapshot proves the rejected action performed no repair.
///
/// Owning evidence: `docs/reviews/2026-08-22-clipy-maccy-deep-review/
/// 01-findings.md` DATA-2; `04-tdd-remediation-playbook.md` Card 2A;
/// `docs/v2/V2-02-retention.md` §3.3b projection coherence and §4.2.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("RetainedBytesRow relational validation (DATA-2)")
struct RetainedBytesRelationalValidationTests {
    private struct ProjectionScalars: Equatable, Sendable {
        let canonicalBytes: Int
        let revisionCount: Int
        let revisionBytes: Int
    }

    private static func snapshot(
        at storeURL: URL
    ) throws -> TransactionStoreSnapshot {
        try autoreleasepool {
            try TransactionStoreSnapshot.read(from: storeURL)
        }
    }

    @discardableResult
    private static func capture(
        _ text: String,
        at seconds: Double,
        in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text,
            observedAt: Date(timeIntervalSinceReferenceDate: seconds),
            source: "com.example.data2"
        )))
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome else {
            Issue.record("DATA-2 setup expected an inserted commit, got \(receipt)")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return reference
    }

    private static func replaceProjectionScalars(
        for itemID: HistoryItemID,
        at storeURL: URL,
        with replacement: ProjectionScalars
    ) throws -> ProjectionScalars {
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let rawID = itemID.rawValue
        let rows = try context.fetch(FetchDescriptor<RetainedBytesRow>(
            predicate: #Predicate { row in row.itemID == rawID }
        ))
        let row = try #require(rows.first)
        let original = ProjectionScalars(
            canonicalBytes: row.canonicalBytes,
            revisionCount: row.revisionCount,
            revisionBytes: row.revisionBytes
        )
        row.canonicalBytes = replacement.canonicalBytes
        row.revisionCount = replacement.revisionCount
        row.revisionBytes = replacement.revisionBytes
        try context.save()
        return original
    }

    @Test("capture rejects canonicalBytes == 0 before transaction and performs no repair")
    func captureRejectsZeroCanonicalBytesBeforeTransaction() async throws {
        let storeURL = WSSupport.tempStoreURL("data2-zero-canonical")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let retained = try await Self.capture(
            "DATA-2 retained item",
            at: 701_000_000,
            in: history
        )
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            storage: StorageRetention(maxTotalBytes: 1_073_741_824)
        )
        let original = try Self.replaceProjectionScalars(
            for: retained.id,
            at: storeURL,
            with: ProjectionScalars(
                canonicalBytes: 0,
                revisionCount: 0,
                revisionBytes: 0
            )
        )
        let corrupted = try Self.snapshot(at: storeURL)
        await history.authority.setTransactionFailureInjection(.beforeSingletonUpdate)

        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            _ = try await Self.capture(
                "DATA-2 rejected capture",
                at: 701_000_100,
                in: history
            )
        }
        #expect(try Self.snapshot(at: storeURL) == corrupted)

        _ = try Self.replaceProjectionScalars(
            for: retained.id,
            at: storeURL,
            with: original
        )
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            _ = try await Self.capture(
                "DATA-2 transaction probe",
                at: 701_000_200,
                in: history
            )
        }
    }

    @Test("revise rejects a positive revision count with zero bytes before transaction")
    func reviseRejectsPositiveCountWithZeroBytesBeforeTransaction() async throws {
        let storeURL = WSSupport.tempStoreURL("data2-positive-count-zero-bytes")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let target = try await Self.capture(
            "DATA-2 revise target",
            at: 701_001_000,
            in: history
        )
        let sibling = try await Self.capture(
            "DATA-2 corrupt sibling",
            at: 701_001_100,
            in: history
        )
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            storage: StorageRetention(maxTotalBytes: 1_073_741_824)
        )
        let original = try Self.replaceProjectionScalars(
            for: sibling.id,
            at: storeURL,
            with: ProjectionScalars(
                canonicalBytes: 10,
                revisionCount: 1,
                revisionBytes: 0
            )
        )
        let corrupted = try Self.snapshot(at: storeURL)
        await history.authority.setTransactionFailureInjection(.beforeSingletonUpdate)
        let request = RevisionRequest(
            itemID: target.id,
            expected: target.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .replace(bytes: Data("DATA-2 revised text".utf8))
            )]))
        )

        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            _ = try await history.perform(.revise(request))
        }
        #expect(try Self.snapshot(at: storeURL) == corrupted)

        _ = try Self.replaceProjectionScalars(
            for: sibling.id,
            at: storeURL,
            with: original
        )
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            _ = try await history.perform(.revise(request))
        }
    }

    @Test("policy sweep rejects revisionBytes below revisionCount before transaction")
    func policySweepRejectsBytesBelowCountBeforeTransaction() async throws {
        let storeURL = WSSupport.tempStoreURL("data2-revision-bytes-below-count")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let retained = try await Self.capture(
            "DATA-2 policy item",
            at: 701_002_000,
            in: history
        )
        let original = try Self.replaceProjectionScalars(
            for: retained.id,
            at: storeURL,
            with: ProjectionScalars(
                canonicalBytes: 10,
                revisionCount: 2,
                revisionBytes: 1
            )
        )
        let corrupted = try Self.snapshot(at: storeURL)
        await history.authority.setTransactionFailureInjection(.beforeSingletonUpdate)
        let policies = HistoryRetentionPolicies(
            age: nil,
            storage: nil,
            revisions: RevisionRetention(
                maxRevisionsPerItem: 100,
                maxRevisionBytesPerItem: nil
            )
        )

        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            _ = try await history.perform(.setRetentionPolicies(policies))
        }
        #expect(try Self.snapshot(at: storeURL) == corrupted)

        _ = try Self.replaceProjectionScalars(
            for: retained.id,
            at: storeURL,
            with: original
        )
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            _ = try await history.perform(.setRetentionPolicies(policies))
        }
    }
}
