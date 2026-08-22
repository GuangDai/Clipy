#if DEBUG
/// X-HCR.2 transaction-window proofs through the real persistent Authority.
/// Owning spec: `V2-roadmap` X-HCR.2 and `V2-03` §5.1/§17 WS-J1-5.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("HCR transaction boundaries (X-HCR.2)")
struct HCRTransactionBoundaryTests {
    private struct JournalConfigSnapshot: Equatable, Sendable {
        let key: String
        let compactionFloorRaw: UInt64
        let journalBytes: UInt64
        let configSchemaVersion: UInt16

        init(_ row: JournalConfigRow) {
            key = row.key
            compactionFloorRaw = row.compactionFloorRaw
            journalBytes = row.journalBytes
            configSchemaVersion = row.configSchemaVersion
        }
    }

    private struct RecordSnapshot: Equatable, Sendable {
        let sequence: UInt64
        let changePositionRaw: UInt64
        let changeKindRaw: Int16
        let affectedItemsBlob: Data
        let createdAt: Date

        init(_ row: HistoryChangeRecordRow) {
            sequence = row.sequence
            changePositionRaw = row.changePositionRaw
            changeKindRaw = row.changeKindRaw
            affectedItemsBlob = row.affectedItemsBlob
            createdAt = row.createdAt
        }
    }

    /// `TransactionStoreSnapshot` carries every item/blob/projection,
    /// RetainedBytes, position, and retention-config scalar. The two arrays
    /// below add the complete X-HCR singleton and record columns.
    private struct DurableSnapshot: Equatable, Sendable {
        let history: TransactionStoreSnapshot
        let journalConfigs: [JournalConfigSnapshot]
        let records: [RecordSnapshot]

        static func read(from storeURL: URL) throws -> DurableSnapshot {
            let history = try TransactionStoreSnapshot.read(from: storeURL)
            let container = try WSSupport.makeContainer(storeURL: storeURL)
            let context = ModelContext(container)
            let configs = try context.fetch(FetchDescriptor<JournalConfigRow>())
                .map(JournalConfigSnapshot.init)
                .sorted { $0.key < $1.key }
            let records = try context.fetch(FetchDescriptor<
                HistoryChangeRecordRow
            >(sortBy: [SortDescriptor(\.sequence)]))
                .map(RecordSnapshot.init)
            return DurableSnapshot(
                history: history,
                journalConfigs: configs,
                records: records
            )
        }
    }

    @Test("pre-HCR failure rolls back exact durable state and is one-shot")
    func preHCRFailureRollsBackAndIsOneShot() async throws {
        try await Self.expectRollbackAndOneShot(
            injection: .beforeHCRAppend,
            label: "hcr-boundary-before-append"
        )
    }

    @Test("post-HCR failure remains rollback-safe and one-shot")
    func postHCRFailureRollsBackAndIsOneShot() async throws {
        try await Self.expectRollbackAndOneShot(
            injection: .beforeSingletonUpdate,
            label: "hcr-boundary-after-append"
        )
    }

    private static func expectRollbackAndOneShot(
        injection: InjectedTransactionFailure,
        label: String
    ) async throws {
        let storeURL = WSSupport.tempStoreURL(label)
        defer { WSSupport.removeStore(storeURL) }

        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let captured = try await history.perform(.capture(
            WSSupport.textCapture(
                "\(label) retained item",
                observedAt: Date(timeIntervalSinceReferenceDate: 904_000_000)
            )
        ))
        guard case .committed(let captureCommit) = captured,
              case .inserted(let reference) = captureCommit.outcome else {
            Issue.record("expected initial committed insert")
            return
        }

        let before = try DurableSnapshot.read(from: storeURL)
        await history.authority.setTransactionFailureInjection(injection)
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            _ = try await history.perform(
                .placePinned(reference.id, at: .first)
            )
        }
        #expect(try DurableSnapshot.read(from: storeURL) == before)

        // No re-arm: the identical commit now succeeds only if the matching
        // injection was consumed exactly once by the rejected transaction.
        let retry = try await history.perform(
            .placePinned(reference.id, at: .first)
        )
        guard case .committed(let pinCommit) = retry,
              case .placedPinned(let pinnedID) = pinCommit.outcome else {
            Issue.record("expected one-shot retry to commit pin")
            return
        }
        #expect(pinnedID == reference.id)
        #expect(pinCommit.position.rawValue == 2)

        let afterRetry = try DurableSnapshot.read(from: storeURL)
        #expect(afterRetry.history.positions.map(\.rawValue) == [2])
        #expect(afterRetry.history.items.map(\.pinOrdinal) == [0])
        #expect(afterRetry.records.map(\.sequence) == [1, 2])
        #expect(
            afterRetry.records.last?.changeKindRaw
                == HistoryChangeKindRawV1.pin.rawValue
        )
        let pinRecord = try #require(afterRetry.records.last)
        #expect(
            try AffectedItemsBlobCodec.decode(
                pinRecord.affectedItemsBlob,
                for: .pin
            ) == [reference.id]
        )
        let journal = try #require(afterRetry.journalConfigs.first)
        #expect(afterRetry.journalConfigs.count == 1)
        #expect(journal.key == HCRBootstrap.configKey)
        #expect(journal.configSchemaVersion == HCRBootstrap.configSchemaVersion)
        #expect(journal.compactionFloorRaw == 0)
        #expect(
            journal.journalBytes == afterRetry.records.reduce(UInt64(0)) {
                $0 + UInt64($1.affectedItemsBlob.count)
            }
        )
    }
}
#endif
