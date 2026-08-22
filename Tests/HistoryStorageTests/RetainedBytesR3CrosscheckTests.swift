/// DATA-2 R3 slow-path proofs: a `RetainedBytesRow` can satisfy every scalar
/// bound and relation while disagreeing with the durable Canonical/revision
/// lineage. The policy sweep may use scalars to select exceeding items, but
/// once it hydrates such an item it must require exact correspondence before
/// destructive planning or transaction entry.
///
/// Each fixture damages one plausible scalar behind the Authority's back,
/// makes that row exceed the requested R3 policy, and crosses the public
/// `.setRetentionPolicies` seam. The unchanged store snapshot plus the still-
/// armed transaction injection prove the typed rejection precedes every
/// write. `RetentionPolicySweepTests` separately proves a non-exceeding
/// plausible mismatch remains untouched and its lineage is never decoded.
///
/// Owning evidence: `docs/reviews/2026-08-22-clipy-maccy-deep-review/
/// 01-findings.md` DATA-2; `docs/05-authority-kernel.md` §7.3;
/// `docs/v2/V2-02-retention.md` §3.3b, §4.4 and `RET-PERF-2`.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("RetainedBytesRow R3 exact cross-check (DATA-2)")
struct RetainedBytesR3CrosscheckTests {
    struct ProjectionScalars: Equatable, Sendable {
        let canonicalBytes: Int
        let revisionCount: Int
        let revisionBytes: Int
    }

    enum Mismatch: CaseIterable, Sendable {
        case canonicalBytes
        case revisionCount
        case revisionBytes

        var label: String {
            switch self {
            case .canonicalBytes: "canonical"
            case .revisionCount: "revision-count"
            case .revisionBytes: "revision-bytes"
            }
        }

        var replacement: ProjectionScalars {
            switch self {
            case .canonicalBytes:
                ProjectionScalars(
                    canonicalBytes: 29,
                    revisionCount: 2,
                    revisionBytes: 20
                )
            case .revisionCount:
                ProjectionScalars(
                    canonicalBytes: 30,
                    revisionCount: 3,
                    revisionBytes: 20
                )
            case .revisionBytes:
                ProjectionScalars(
                    canonicalBytes: 30,
                    revisionCount: 2,
                    revisionBytes: 19
                )
            }
        }

        var policy: HistoryRetentionPolicies {
            switch self {
            case .canonicalBytes:
                HistoryRetentionPolicies(
                    age: nil,
                    storage: nil,
                    revisions: RevisionRetention(
                        maxRevisionsPerItem: 1,
                        maxRevisionBytesPerItem: nil
                    )
                )
            case .revisionCount:
                HistoryRetentionPolicies(
                    age: nil,
                    storage: nil,
                    revisions: RevisionRetention(
                        maxRevisionsPerItem: 2,
                        maxRevisionBytesPerItem: nil
                    )
                )
            case .revisionBytes:
                HistoryRetentionPolicies(
                    age: nil,
                    storage: nil,
                    revisions: RevisionRetention(
                        maxRevisionsPerItem: nil,
                        maxRevisionBytesPerItem: 18
                    )
                )
            }
        }
    }

    @discardableResult
    private static func capture(
        _ text: String,
        in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text,
            observedAt: Date(timeIntervalSinceReferenceDate: 701_100_000),
            source: "com.example.data2.r3"
        )))
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome else {
            Issue.record("DATA-2 R3 setup expected an insert, got \(receipt)")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return reference
    }

    private static func revise(
        _ reference: HistoryItemReference,
        byte: UInt8,
        in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let request = RevisionRequest(
            itemID: reference.id,
            expected: reference.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .replace(bytes: Data(repeating: byte, count: 10))
            )]))
        )
        let receipt = try await history.perform(.revise(request))
        guard case let .committed(commit) = receipt,
              case let .revised(next) = commit.outcome else {
            Issue.record("DATA-2 R3 setup expected a revision, got \(receipt)")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return next
    }

    private static func replaceProjection(
        for itemID: HistoryItemID,
        at storeURL: URL,
        with replacement: ProjectionScalars
    ) throws -> ProjectionScalars {
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let rawID = itemID.rawValue
        let row = try #require(try context.fetch(FetchDescriptor<RetainedBytesRow>(
            predicate: #Predicate { row in row.itemID == rawID }
        )).first)
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

    @Test(
        "R3 rejects each plausible projected scalar mismatch before transaction",
        arguments: Mismatch.allCases
    )
    func rejectsPlausibleMismatchBeforeTransaction(
        _ mismatch: Mismatch
    ) async throws {
        let storeURL = WSSupport.tempStoreURL("data2-r3-\(mismatch.label)")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        var target = try await Self.capture(
            String(repeating: "c", count: 30),
            in: history
        )
        target = try await Self.revise(target, byte: 0x61, in: history)
        target = try await Self.revise(target, byte: 0x62, in: history)

        let original = try Self.replaceProjection(
            for: target.id,
            at: storeURL,
            with: mismatch.replacement
        )
        #expect(original == ProjectionScalars(
            canonicalBytes: 30,
            revisionCount: 2,
            revisionBytes: 20
        ))
        let corrupted = try TransactionStoreSnapshot.read(from: storeURL)
        await history.authority.setTransactionFailureInjection(
            .beforeSingletonUpdate
        )

        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            _ = try await history.perform(.setRetentionPolicies(mismatch.policy))
        }
        #expect(try TransactionStoreSnapshot.read(from: storeURL) == corrupted)

        _ = try Self.replaceProjection(
            for: target.id,
            at: storeURL,
            with: original
        )
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            _ = try await history.perform(.setRetentionPolicies(mismatch.policy))
        }
    }
}
