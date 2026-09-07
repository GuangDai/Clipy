/// DC-25/J.3 atomic History Change Record append proofs through the real
/// Authority and temporary SQLite store.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite("HCR atomic append (J.3)")
struct HCRAtomicAppendTests {
    private struct SeedRecord: Sendable {
        let sequence: UInt64
        let itemID: HistoryItemID
        let createdAt: Date
    }

    private struct StoredJournalState: Sendable {
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
        history: SQLiteHistory,
        authority: HistoryAuthority
    ) {
        let history = try await SQLiteHistory.open(configuration:
            HistoryConfiguration(persistence: .temporary)
        )
        return (history, history.authority)
    }

    private static func snapshot(
        in authority: HistoryAuthority
    ) async throws -> JournalSnapshot {
        let state = try await authority.hcrTestSnapshot()
        let config = try #require(state.configs.first)
        return JournalSnapshot(
            position: state.position,
            floor: config.compactionFloorRaw,
            journalBytes: config.journalBytes,
            records: state.records.map {
                JournalSnapshot.Record(
                    sequence: $0.sequence,
                    changePosition: $0.changePositionRaw,
                    kindRaw: $0.changeKindRaw,
                    affectedItemsBlob: $0.affectedItemsBlob
                )
            },
            items: state.items.map { JournalSnapshot.Item(id: $0.id, pinOrdinal: $0.pinOrdinal) }
        )
    }

    private static func makeJournalStore(
        _ seeds: [SeedRecord],
        limits: JournalLimits
    ) async throws -> HistoryAuthority {
        let history = try await SQLiteHistory.open(configuration:
            HistoryConfiguration(persistence: .temporary)
        )
        try await history.authority.withTestDatabase { authority in
            try authority.database.writeTransaction {
                var logicalBytes: UInt64 = 0
                for seed in seeds {
                    let blob = try AffectedItemsBlobCodec.encode(
                        .explicit([seed.itemID]), for: .insert, limits: limits
                    )
                    logicalBytes += UInt64(blob.count)
                    try authority.database.execute("""
                        INSERT INTO history_change_records
                            (sequence, changePositionRaw, changeKindRaw, affectedItemsBlob, createdAt)
                        VALUES (?, ?, ?, ?, ?)
                        """, bindings: [
                            .blob(sqliteUInt64(seed.sequence)), .blob(sqliteUInt64(seed.sequence)),
                            .integer(Int64(HistoryChangeKindRawV1.insert.rawValue)), .blob(blob),
                            .real(seed.createdAt.timeIntervalSinceReferenceDate)
                        ])
                }
                try authority.database.execute(
                    "UPDATE journal_config SET journalBytes = ?",
                    bindings: [.blob(sqliteUInt64(logicalBytes))]
                )
                try authority.database.execute(
                    "UPDATE history_state SET changePosition = ?",
                    bindings: [.blob(sqliteUInt64(seeds.last?.sequence ?? 0))]
                )
            }
        }
        return history.authority
    }

    private static func append(
        sequence: UInt64,
        itemID: HistoryItemID,
        createdAt: Date,
        limits: JournalLimits,
        in authority: HistoryAuthority
    ) async throws {
        try await authority.withTestDatabase { authority in
            try authority.database.writeTransaction {
                try HCRStore.append(
                    HistoryChangeRecordPayload(
                        sequence: sequence,
                        changePositionRaw: sequence,
                        changeKind: .insert,
                        affectedItems: .explicit([itemID]),
                        createdAt: createdAt
                    ),
                    expectedPreviousPosition: ChangePosition(rawValue: sequence - 1),
                    in: authority.database,
                    limits: limits
                )
                try authority.database.execute(
                    "UPDATE history_state SET changePosition = ?",
                    bindings: [.blob(sqliteUInt64(sequence))]
                )
            }
        }
    }

    private static func journalRows(
        in authority: HistoryAuthority
    ) async throws -> StoredJournalState {
        let state = try await authority.hcrTestSnapshot()
        let config = try #require(state.configs.first)
        return StoredJournalState(
            floor: config.compactionFloorRaw,
            bytes: config.journalBytes,
            sequences: state.records.map(\.sequence),
            blobByteCounts: state.records.map { $0.affectedItemsBlob.count }
        )
    }

    private static func capture(
        _ text: String,
        in history: SQLiteHistory
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
        #expect(try await Self.snapshot(in: fixture.authority) == JournalSnapshot(
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

        let snapshot = try await Self.snapshot(in: fixture.authority)
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
        ) == .explicit([reference.id]))
    }

    @Test("unchanged planner result appends no HCR and advances no counter")
    func noOpAppendsNothing() async throws {
        let fixture = try await Self.makeHistory()
        let reference = try await Self.capture("hcr no-op", in: fixture.history)
        _ = try await fixture.history.perform(.placePinned(reference.id, at: .first))
        let before = try await Self.snapshot(in: fixture.authority)

        let receipt = try await fixture.history.perform(
            .placePinned(reference.id, at: .first)
        )

        guard case .unchanged = receipt else {
            Issue.record("expected unchanged repeated pin, got \(receipt)")
            return
        }
        #expect(try await Self.snapshot(in: fixture.authority) == before)
    }

    @Test("WS13 failure rolls back item, HCR, journal bytes, and position")
    func transactionFailureRollsBackWholeCommit() async throws {
        let fixture = try await Self.makeHistory()
        let reference = try await Self.capture(
            "hcr rollback",
            in: fixture.history
        )
        let before = try await Self.snapshot(in: fixture.authority)
        await fixture.history.authority.setTransactionFailureInjection(
            .beforeSingletonUpdate
        )

        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            _ = try await fixture.history.perform(
                .placePinned(reference.id, at: .first)
            )
        }

        #expect(try await Self.snapshot(in: fixture.authority) == before)
    }

    @Test("bulk clear and scoped HCR roll back together in both transaction windows",
          arguments: [ClearScope.all, .unpinned])
    func bulkClearRollsBackWithJournal(scope: ClearScope) async throws {
        let fixture = try await Self.makeHistory()
        let pinned = try await Self.capture("bulk pinned survivor", in: fixture.history)
        _ = try await fixture.history.perform(.placePinned(pinned.id, at: .first))
        _ = try await Self.capture("bulk unpinned victim", in: fixture.history)
        let before = try await Self.snapshot(in: fixture.authority)

        for injection in [InjectedTransactionFailure.beforeHCRAppend, .beforeSingletonUpdate] {
            await fixture.authority.setTransactionFailureInjection(injection)
            await #expect(throws: HistoryFailure.persistence(.transaction)) {
                _ = try await fixture.history.perform(.clear(scope))
            }
            #expect(try await Self.snapshot(in: fixture.authority) == before)
        }

        let receipt = try await fixture.history.perform(.clear(scope))
        guard case .committed(let commit) = receipt else {
            Issue.record("expected bulk clear after one-shot injections were consumed")
            return
        }
        let expectedCount = scope == .all ? 2 : 1
        guard case .cleared(let actualCount) = commit.outcome else {
            Issue.record("expected a clear receipt")
            return
        }
        #expect(actualCount == expectedCount)
        let after = try await Self.snapshot(in: fixture.authority)
        #expect(after.position == before.position + 1)
        #expect(after.records.count == before.records.count + 1)
        #expect(after.items.count == (scope == .all ? 0 : 1))
        if scope == .unpinned {
            #expect(after.items.map(\.id) == [pinned.id.rawValue])
        }
        let record = try #require(after.records.last)
        let kind: HistoryChangeKindRawV1 = scope == .all ? .clearAll : .clearUnpinned
        #expect(record.kindRaw == kind.rawValue)
        let expected: HistoryAffectedItems = scope == .all
            ? .all(retiredItems: expectedCount) : .unpinned(retiredItems: expectedCount)
        #expect(try AffectedItemsBlobCodec.decode(record.affectedItemsBlob, for: kind) == expected)
    }

    @Test("count cap trims exactly the oldest prefix in the append transaction")
    func countCapTrimsOldestPrefix() async throws {
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
        let container = try await Self.makeJournalStore([
            SeedRecord(sequence: 1, itemID: ids[0], createdAt: epoch),
            SeedRecord(sequence: 2, itemID: ids[1], createdAt: epoch),
        ], limits: limits)

        try await Self.append(
            sequence: 3,
            itemID: ids[2],
            createdAt: epoch,
            limits: limits,
            in: container
        )

        let state = try await Self.journalRows(in: container)
        #expect(state.floor == 1)
        #expect(state.sequences == [2, 3])
        #expect(state.bytes == state.blobByteCounts.reduce(UInt64(0)) {
            $0 + UInt64($1)
        })
    }

    @Test("byte cap trims the oldest rows until the exact counter is admitted")
    func byteCapTrimsOldestPrefix() async throws {
        let limits = try #require(JournalLimits(
            maxAffectedItemsPerRecord: 3,
            maxJournalRecordCount: 10,
            maxJournalAgeSeconds: 1_000,
            maxJournalBytes: UInt64(try AffectedItemsBlobCodec.encode(
                .explicit([HistoryItemID(rawValue: UUID())]), for: .insert
            ).count),
            compactionCadenceCommits: 50
        ))
        let epoch = Date(timeIntervalSinceReferenceDate: 902_200_000)
        let oldID = HistoryItemID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000B71"
        )!)
        let newID = HistoryItemID(rawValue: UUID(
            uuidString: "00000000-0000-0000-0000-000000000B72"
        )!)
        let container = try await Self.makeJournalStore([
            SeedRecord(sequence: 1, itemID: oldID, createdAt: epoch),
        ], limits: limits)

        try await Self.append(
            sequence: 2,
            itemID: newID,
            createdAt: epoch,
            limits: limits,
            in: container
        )

        let state = try await Self.journalRows(in: container)
        #expect(state.floor == 1)
        #expect(state.sequences == [2])
        #expect(state.bytes == UInt64(try #require(state.blobByteCounts.first)))
    }

    @Test("age expiry scans only on the configured ChangePosition cadence")
    func ageExpiryUsesPositionCadence() async throws {
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
        let cadenceContainer = try await Self.makeJournalStore([
            SeedRecord(sequence: 1, itemID: oldID, createdAt: epoch),
        ], limits: cadenceLimits)

        try await Self.append(
            sequence: 2,
            itemID: newID,
            createdAt: epoch.addingTimeInterval(11),
            limits: cadenceLimits,
            in: cadenceContainer
        )

        let cadenceState = try await Self.journalRows(in: cadenceContainer)
        #expect(cadenceState.floor == 1)
        #expect(cadenceState.sequences == [2])

        let deferredLimits = try #require(JournalLimits(
            maxAffectedItemsPerRecord: 3,
            maxJournalRecordCount: 10,
            maxJournalAgeSeconds: 10,
            maxJournalBytes: 1_000,
            compactionCadenceCommits: 3
        ))
        let deferredContainer = try await Self.makeJournalStore([
            SeedRecord(sequence: 1, itemID: oldID, createdAt: epoch),
        ], limits: deferredLimits)
        try await Self.append(
            sequence: 2,
            itemID: newID,
            createdAt: epoch.addingTimeInterval(11),
            limits: deferredLimits,
            in: deferredContainer
        )
        let deferredState = try await Self.journalRows(in: deferredContainer)
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

/// Raw durable journal values for owner tests; reads do not invoke bootstrap.
struct HCRTestSnapshot: Sendable {
    struct Item: Sendable {
        let id: UUID
        let pinOrdinal: Int?
    }
    let position: UInt64
    let configs: [JournalConfigRow]
    let records: [HistoryChangeRecordRow]
    let items: [Item]

    static func read(in database: SQLiteDatabase) throws -> Self {
        let position = try database.prepare("SELECT changePosition FROM history_state LIMIT 2")
        defer { position.finalize() }
        #expect(try position.step())
        let rawPosition = try sqliteUInt64(position.blob(at: 0))
        #expect(try !position.step())
        let itemQuery = try database.prepare("SELECT id, pinOrdinal FROM history_items ORDER BY id")
        defer { itemQuery.finalize() }
        var items: [Item] = []
        while try itemQuery.step() {
            let id = try #require(UUID(uuidString: itemQuery.text(at: 0)))
            let ordinal = try itemQuery.isNull(at: 1) ? nil : Int(itemQuery.integer(at: 1))
            items.append(Item(id: id, pinOrdinal: ordinal))
        }
        return Self(
            position: rawPosition,
            configs: try HCRBootstrap.loadConfigs(in: database),
            records: try HCRBootstrap.loadRecords(
                in: database, limit: JournalLimits.standard.maxJournalRecordCount + 1
            ),
            items: items
        )
    }
}

extension HistoryAuthority {
    func hcrTestSnapshot() throws -> HCRTestSnapshot {
        try database.readTransaction { try HCRTestSnapshot.read(in: database) }
    }
}
