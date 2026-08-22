/// DC-25/X-HCR same-process owner-release/reopen proof.
///
/// This test uses a real persistent StoreRoot and two sequential public
/// `SwiftDataHistory.open` owners. It proves durable HCR reconstruction across
/// that bounded reopen journey; it is not a child-process, crash, or power-loss
/// durability claim.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("HCR persistent reopen")
struct HCRRestartTests {
    private struct SeededReferences {
        let first: HistoryItemReference
        let second: HistoryItemReference
    }

    private struct Snapshot: Equatable {
        struct Record: Equatable {
            let sequence: UInt64
            let changePosition: UInt64
            let kind: HistoryChangeKindRawV1
            let affectedItemIDs: [HistoryItemID]
            let blobByteCount: Int
        }

        let position: UInt64
        let configKey: String
        let floor: UInt64
        let journalBytes: UInt64
        let configSchemaVersion: UInt16
        let records: [Record]
    }

    @Test("released owner reopens the exact HCR suffix and appends N+1")
    func releasedOwnerReopensAndContinuesJournal() async throws {
        let storeURL = WSSupport.tempStoreURL("hcr-owner-release-reopen")
        defer { WSSupport.removeStore(storeURL) }

        // The seeding helper returns only immutable HistoryCore values. Its
        // public facade, Authority actor, and ModelContainer owner leave scope
        // before the second public open begins.
        let seeded = try await Self.seedFirstOwner(at: storeURL)

        let reopened = try await SwiftDataHistory.open(configuration:
            HistoryConfiguration(persistence: .persistent(storeURL: storeURL))
        )
        let reopenedSnapshot = try Self.snapshot(at: storeURL)
        #expect(reopenedSnapshot.position == 3)
        #expect(reopenedSnapshot.configKey == HCRBootstrap.configKey)
        #expect(reopenedSnapshot.floor == 0)
        #expect(reopenedSnapshot.configSchemaVersion
            == HCRBootstrap.configSchemaVersion)
        #expect(reopenedSnapshot.records.map(\.sequence) == [1, 2, 3])
        #expect(reopenedSnapshot.records.map(\.changePosition) == [1, 2, 3])
        #expect(reopenedSnapshot.records.map(\.kind) == [
            .insert,
            .insert,
            .pin,
        ])
        #expect(reopenedSnapshot.records.map(\.affectedItemIDs) == [
            [seeded.first.id],
            [seeded.second.id],
            [seeded.first.id],
        ])
        #expect(reopenedSnapshot.journalBytes
            == reopenedSnapshot.records.reduce(UInt64(0)) { partial, record in
                partial + UInt64(record.blobByteCount)
            })

        let nextReceipt = try await reopened.perform(
            .unpin(seeded.first.id)
        )
        guard case .committed(let nextCommit) = nextReceipt,
              case .unpinned(let unpinnedID) = nextCommit.outcome else {
            Issue.record("expected the reopened owner to commit unpin")
            return
        }
        #expect(nextCommit.position.rawValue == 4)
        #expect(unpinnedID == seeded.first.id)

        let continuedSnapshot = try Self.snapshot(at: storeURL)
        #expect(continuedSnapshot.position == 4)
        #expect(continuedSnapshot.configKey == reopenedSnapshot.configKey)
        #expect(continuedSnapshot.floor == reopenedSnapshot.floor)
        #expect(continuedSnapshot.configSchemaVersion
            == reopenedSnapshot.configSchemaVersion)
        #expect(continuedSnapshot.records.map(\.sequence) == [1, 2, 3, 4])
        #expect(continuedSnapshot.records.map(\.changePosition) == [1, 2, 3, 4])
        #expect(continuedSnapshot.records.map(\.kind) == [
            .insert,
            .insert,
            .pin,
            .unpin,
        ])
        #expect(continuedSnapshot.records.map(\.affectedItemIDs) == [
            [seeded.first.id],
            [seeded.second.id],
            [seeded.first.id],
            [seeded.first.id],
        ])
        #expect(continuedSnapshot.journalBytes
            == continuedSnapshot.records.reduce(UInt64(0)) { partial, record in
                partial + UInt64(record.blobByteCount)
            })
    }

    private static func seedFirstOwner(
        at storeURL: URL
    ) async throws -> SeededReferences {
        let history = try await SwiftDataHistory.open(configuration:
            HistoryConfiguration(persistence: .persistent(storeURL: storeURL))
        )
        let first = try await capture(
            "hcr restart first",
            observedAt: Date(timeIntervalSinceReferenceDate: 780_000_001),
            in: history,
            expectedPosition: 1
        )
        let second = try await capture(
            "hcr restart second",
            observedAt: Date(timeIntervalSinceReferenceDate: 780_000_002),
            in: history,
            expectedPosition: 2
        )
        let pinReceipt = try await history.perform(
            .placePinned(first.id, at: .first)
        )
        guard case .committed(let pinCommit) = pinReceipt,
              case .placedPinned(let pinnedID) = pinCommit.outcome else {
            Issue.record("expected the first owner to commit pin")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(pinCommit.position.rawValue == 3)
        #expect(pinnedID == first.id)
        return SeededReferences(first: first, second: second)
    }

    private static func capture(
        _ text: String,
        observedAt: Date,
        in history: SwiftDataHistory,
        expectedPosition: UInt64
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(text, observedAt: observedAt)
        ))
        guard case .committed(let commit) = receipt,
              case .inserted(let reference) = commit.outcome else {
            Issue.record("expected the first owner to commit insert")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(commit.position.rawValue == expectedPosition)
        return reference
    }

    private static func snapshot(at storeURL: URL) throws -> Snapshot {
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let positions = try context.fetch(FetchDescriptor<LastChangePositionRow>())
        let configs = try context.fetch(FetchDescriptor<JournalConfigRow>())
        guard positions.count == 1,
              let position = positions.first,
              configs.count == 1,
              let config = configs.first else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let storedRows = try context.fetch(FetchDescriptor<HistoryChangeRecordRow>(
            sortBy: [SortDescriptor(\.sequence)]
        ))
        let records = try storedRows.map { row in
            guard let kind = HistoryChangeKindRawV1(rawValue: row.changeKindRaw)
            else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            return Snapshot.Record(
                sequence: row.sequence,
                changePosition: row.changePositionRaw,
                kind: kind,
                affectedItemIDs: try AffectedItemsBlobCodec.decode(
                    row.affectedItemsBlob,
                    for: kind
                ),
                blobByteCount: row.affectedItemsBlob.count
            )
        }
        return Snapshot(
            position: position.rawValue,
            configKey: config.key,
            floor: config.compactionFloorRaw,
            journalBytes: config.journalBytes,
            configSchemaVersion: config.configSchemaVersion,
            records: records
        )
    }
}
