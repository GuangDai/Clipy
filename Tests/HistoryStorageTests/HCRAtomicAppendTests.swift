/// DC-25/J.3 atomic History Change Record append proofs through the real
/// Authority and in-memory V4 store.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("HCR atomic append (J.3)")
struct HCRAtomicAppendTests {
    private struct SeedRecord {
        let sequence: UInt64
        let itemID: HistoryItemID
        let createdAt: Date
    }

    private struct StoredJournalState {
        let floor: UInt64
        let bytes: UInt64
        let sequences: [UInt64]
        let blobByteCounts: [Int]
    }

    private struct JournalSnapshot: Equatable {
        struct Record: Equatable {
            let sequence: UInt64
            let changePosition: UInt64
            let kindRaw: Int16
            let affectedItemsBlob: Data
        }

        struct Item: Equatable {
            let id: UUID
            let pinOrdinal: Int?
        }

        let position: UInt64
        let floor: UInt64
        let journalBytes: UInt64
        let records: [Record]
        let items: [Item]
    }

    private static func makeHistory() async throws -> (
        history: SwiftDataHistory,
        container: ModelContainer
    ) {
        let history = try await SwiftDataHistory.open(configuration:
            HistoryConfiguration(persistence: .memory)
        )
        let container = await history.authority.container
        return (history, container)
    }

    private static func snapshot(
        in container: ModelContainer
    ) throws -> JournalSnapshot {
        let context = ModelContext(container)
        let position = try #require(
            context.fetch(FetchDescriptor<LastChangePositionRow>()).first
        )
        let config = try #require(
            context.fetch(FetchDescriptor<JournalConfigRow>()).first
        )
        let rows = try context.fetch(FetchDescriptor<HistoryChangeRecordRow>(
            sortBy: [SortDescriptor(\.sequence)]
        ))
        let items = try context.fetch(FetchDescriptor<HistoryItemRow>())
            .map { JournalSnapshot.Item(id: $0.id, pinOrdinal: $0.pinOrdinal) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return JournalSnapshot(
            position: position.rawValue,
            floor: config.compactionFloorRaw,
            journalBytes: config.journalBytes,
            records: rows.map {
                JournalSnapshot.Record(
                    sequence: $0.sequence,
                    changePosition: $0.changePositionRaw,
                    kindRaw: $0.changeKindRaw,
                    affectedItemsBlob: $0.affectedItemsBlob
                )
            },
            items: items
        )
    }

    private static func makeJournalStore(
        _ seeds: [SeedRecord],
        limits: JournalLimits
    ) throws -> ModelContainer {
        let schema = Schema(versionedSchema: HistorySchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var logicalBytes: UInt64 = 0
        for seed in seeds {
            let blob = try AffectedItemsBlobCodec.encode(
                [seed.itemID],
                for: .insert,
                limits: limits
            )
            logicalBytes += UInt64(blob.count)
            context.insert(HistoryChangeRecordRow(
                sequence: seed.sequence,
                changePositionRaw: seed.sequence,
                changeKindRaw: HistoryChangeKindRawV1.insert.rawValue,
                affectedItemsBlob: blob,
                createdAt: seed.createdAt
            ))
        }
        context.insert(JournalConfigRow(
            key: HCRBootstrap.configKey,
            compactionFloorRaw: 0,
            journalBytes: logicalBytes,
            configSchemaVersion: HCRBootstrap.configSchemaVersion
        ))
        try context.save()
        return container
    }

    private static func append(
        sequence: UInt64,
        itemID: HistoryItemID,
        createdAt: Date,
        limits: JournalLimits,
        in container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try context.transaction {
            try HCRStore.append(
                HistoryChangeRecordPayload(
                    sequence: sequence,
                    changePositionRaw: sequence,
                    changeKind: .insert,
                    affectedItemIDs: [itemID],
                    createdAt: createdAt
                ),
                expectedPreviousPosition: ChangePosition(
                    rawValue: sequence - 1
                ),
                in: context,
                limits: limits
            )
        }
    }

    private static func journalRows(
        in container: ModelContainer
    ) throws -> StoredJournalState {
        let context = ModelContext(container)
        let config = try #require(
            context.fetch(FetchDescriptor<JournalConfigRow>()).first
        )
        let rows = try context.fetch(FetchDescriptor<HistoryChangeRecordRow>(
            sortBy: [SortDescriptor(\.sequence)]
        ))
        return StoredJournalState(
            floor: config.compactionFloorRaw,
            bytes: config.journalBytes,
            sequences: rows.map(\.sequence),
            blobByteCounts: rows.map { $0.affectedItemsBlob.count }
        )
    }

    private static func capture(
        _ text: String,
        in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                text,
                observedAt: Date(timeIntervalSinceReferenceDate: 902_100_000),
                source: "com.example.hcr-atomic"
            )
        ))
        guard case .committed(let commit) = receipt,
              case .inserted(let reference) = commit.outcome else {
            Issue.record("expected committed insert, got \(receipt)")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return reference
    }

    @Test("capture mutation, HCR, counter, and position share one save boundary")
    func captureAppendsOneAtomicRecord() async throws {
        let fixture = try await Self.makeHistory()
        #expect(try Self.snapshot(in: fixture.container) == JournalSnapshot(
            position: 0,
            floor: 0,
            journalBytes: 0,
            records: [],
            items: []
        ))

        let reference = try await Self.capture(
            "hcr atomic insert",
            in: fixture.history
        )

        let snapshot = try Self.snapshot(in: fixture.container)
        #expect(snapshot.position == 1)
        #expect(snapshot.floor == 0)
        #expect(snapshot.records.count == 1)
        let record = try #require(snapshot.records.first)
        #expect(record.sequence == snapshot.position)
        #expect(record.changePosition == snapshot.position)
        #expect(record.kindRaw == HistoryChangeKindRawV1.insert.rawValue)
        #expect(snapshot.journalBytes == UInt64(record.affectedItemsBlob.count))
        #expect(try AffectedItemsBlobCodec.decode(
            record.affectedItemsBlob,
            for: .insert
        ) == [reference.id])
    }

    @Test("unchanged planner result appends no HCR and advances no counter")
    func noOpAppendsNothing() async throws {
        let fixture = try await Self.makeHistory()
        let reference = try await Self.capture("hcr no-op", in: fixture.history)
        _ = try await fixture.history.perform(.placePinned(reference.id, at: .first))
        let before = try Self.snapshot(in: fixture.container)

        let receipt = try await fixture.history.perform(
            .placePinned(reference.id, at: .first)
        )

        guard case .unchanged = receipt else {
            Issue.record("expected unchanged repeated pin, got \(receipt)")
            return
        }
        #expect(try Self.snapshot(in: fixture.container) == before)
    }

    @Test("WS13 failure rolls back item, HCR, journal bytes, and position")
    func transactionFailureRollsBackWholeCommit() async throws {
        let fixture = try await Self.makeHistory()
        let reference = try await Self.capture(
            "hcr rollback",
            in: fixture.history
        )
        let before = try Self.snapshot(in: fixture.container)
        await fixture.history.authority.setTransactionFailureInjection(
            .beforeSingletonUpdate
        )

        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            _ = try await fixture.history.perform(
                .placePinned(reference.id, at: .first)
            )
        }

        #expect(try Self.snapshot(in: fixture.container) == before)
    }

    @Test("count cap trims exactly the oldest prefix in the append transaction")
    func countCapTrimsOldestPrefix() throws {
        let limits = try #require(JournalLimits(
            maxAffectedItemsPerRecord: 3,
            maxJournalRecordCount: 2,
            maxJournalAgeSeconds: 1_000,
            maxJournalBytes: 1_000,
            compactionCadenceCommits: 50
        ))
        let epoch = Date(timeIntervalSinceReferenceDate: 902_200_000)
        let ids = (1...3).map { value in
            HistoryItemID(rawValue: UUID(
                uuidString: String(
                    format: "00000000-0000-0000-0000-%012d",
                    value
                )
            )!)
        }
        let container = try Self.makeJournalStore([
            SeedRecord(sequence: 1, itemID: ids[0], createdAt: epoch),
            SeedRecord(sequence: 2, itemID: ids[1], createdAt: epoch),
        ], limits: limits)

        try Self.append(
            sequence: 3,
            itemID: ids[2],
            createdAt: epoch,
            limits: limits,
            in: container
        )

        let state = try Self.journalRows(in: container)
        #expect(state.floor == 1)
        #expect(state.sequences == [2, 3])
        #expect(state.bytes == state.blobByteCounts.reduce(UInt64(0)) {
            $0 + UInt64($1)
        })
    }

    @Test("byte cap trims the oldest rows until the exact counter is admitted")
    func byteCapTrimsOldestPrefix() throws {
        let limits = try #require(JournalLimits(
            maxAffectedItemsPerRecord: 3,
            maxJournalRecordCount: 10,
            maxJournalAgeSeconds: 1_000,
            maxJournalBytes: 20,
            compactionCadenceCommits: 50
        ))
        let epoch = Date(timeIntervalSinceReferenceDate: 902_200_000)
        let oldID = HistoryItemID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000B71"
        )!)
        let newID = HistoryItemID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000B72"
        )!)
        let container = try Self.makeJournalStore([
            SeedRecord(sequence: 1, itemID: oldID, createdAt: epoch),
        ], limits: limits)

        try Self.append(
            sequence: 2,
            itemID: newID,
            createdAt: epoch,
            limits: limits,
            in: container
        )

        let state = try Self.journalRows(in: container)
        #expect(state.floor == 1)
        #expect(state.sequences == [2])
        #expect(state.bytes == UInt64(try #require(state.blobByteCounts.first)))
    }

    @Test("age expiry scans only on the configured ChangePosition cadence")
    func ageExpiryUsesPositionCadence() throws {
        let cadenceLimits = try #require(JournalLimits(
            maxAffectedItemsPerRecord: 3,
            maxJournalRecordCount: 10,
            maxJournalAgeSeconds: 10,
            maxJournalBytes: 1_000,
            compactionCadenceCommits: 2
        ))
        let epoch = Date(timeIntervalSinceReferenceDate: 902_200_000)
        let oldID = HistoryItemID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000B81"
        )!)
        let newID = HistoryItemID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000B82"
        )!)
        let cadenceContainer = try Self.makeJournalStore([
            SeedRecord(sequence: 1, itemID: oldID, createdAt: epoch),
        ], limits: cadenceLimits)

        try Self.append(
            sequence: 2,
            itemID: newID,
            createdAt: epoch.addingTimeInterval(11),
            limits: cadenceLimits,
            in: cadenceContainer
        )

        let cadenceState = try Self.journalRows(in: cadenceContainer)
        #expect(cadenceState.floor == 1)
        #expect(cadenceState.sequences == [2])

        let deferredLimits = try #require(JournalLimits(
            maxAffectedItemsPerRecord: 3,
            maxJournalRecordCount: 10,
            maxJournalAgeSeconds: 10,
            maxJournalBytes: 1_000,
            compactionCadenceCommits: 3
        ))
        let deferredContainer = try Self.makeJournalStore([
            SeedRecord(sequence: 1, itemID: oldID, createdAt: epoch),
        ], limits: deferredLimits)
        try Self.append(
            sequence: 2,
            itemID: newID,
            createdAt: epoch.addingTimeInterval(11),
            limits: deferredLimits,
            in: deferredContainer
        )
        let deferredState = try Self.journalRows(in: deferredContainer)
        #expect(deferredState.floor == 0)
        #expect(deferredState.sequences == [1, 2])
    }

    @Test("below count/byte bounds off cadence selects no prefix read")
    func noPressureSelectsNoPrefixRead() {
        #expect(HCRStore.prefixReadScope(
            minimumDeleteCount: 0,
            bytesAfterAppend: 19,
            scansAge: false,
            maxJournalBytes: 20
        ) == .none)

        // Equality is admitted: byte pressure begins only above the cap.
        #expect(HCRStore.prefixReadScope(
            minimumDeleteCount: 0,
            bytesAfterAppend: 20,
            scansAge: false,
            maxJournalBytes: 20
        ) == .none)
    }

    @Test("count-only pressure selects exactly the bounded oldest prefix")
    func countOnlySelectsBoundedPrefix() {
        #expect(HCRStore.prefixReadScope(
            minimumDeleteCount: 1,
            bytesAfterAppend: 20,
            scansAge: false,
            maxJournalBytes: 20
        ) == .oldestPrefix(count: 1))
        #expect(HCRStore.prefixReadScope(
            minimumDeleteCount: 3,
            bytesAfterAppend: 19,
            scansAge: false,
            maxJournalBytes: 20
        ) == .oldestPrefix(count: 3))
    }

    @Test("only age cadence or byte pressure selects the full suffix")
    func ageOrBytePressureSelectsFullSuffix() {
        #expect(HCRStore.prefixReadScope(
            minimumDeleteCount: 0,
            bytesAfterAppend: 20,
            scansAge: true,
            maxJournalBytes: 20
        ) == .fullSuffix)
        #expect(HCRStore.prefixReadScope(
            minimumDeleteCount: 0,
            bytesAfterAppend: 21,
            scansAge: false,
            maxJournalBytes: 20
        ) == .fullSuffix)
        #expect(HCRStore.prefixReadScope(
            minimumDeleteCount: 1,
            bytesAfterAppend: 21,
            scansAge: false,
            maxJournalBytes: 20
        ) == .fullSuffix)
    }
}
