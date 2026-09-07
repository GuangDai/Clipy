/// DC-25 X-HCR bootstrap/startup validation and fixed-prefix compaction proofs.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite("X-HCR bootstrap and startup validation")
struct HCRBootstrapTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 903_000_000)

    @Test("real Authority startup creates the exact empty config after Gateway")
    func authorityStartupWiresBootstrap() async throws {
        let authority = try await Self.makeAuthority()
        let state = try await authority.hcrTestSnapshot()
        let config = try #require(state.configs.first)
        #expect(state.configs.count == 1)
        #expect(config.key == "change-journal")
        #expect(config.compactionFloorRaw == 0)
        #expect(config.journalBytes == 0)
        #expect(config.configSchemaVersion == 1)
        #expect(state.records.isEmpty)
    }

    private enum SurvivingHistoryFact: Equatable, Sendable {
        case item, record
    }

    @Test("position zero cannot recreate a journal singleton over surviving history facts",
          arguments: [SurvivingHistoryFact.item, .record])
    private func zeroPositionWithHistoryFactsFailsClosed(_ fact: SurvivingHistoryFact) async throws {
        let history = try await SQLiteHistory.open(configuration:
            HistoryConfiguration(persistence: .temporary)
        )
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "journal current item", observedAt: Self.now, source: nil
        )))
        let authority = history.authority
        try await authority.withTestDatabase { owner in
            try owner.database.writeTransaction {
                try owner.database.execute("DELETE FROM journal_config")
                try owner.database.execute(
                    "UPDATE history_state SET changePosition = ?",
                    bindings: [.blob(sqliteUInt64(0))]
                )
                switch fact {
                case .item:
                    try owner.database.execute("DELETE FROM history_change_records")
                case .record:
                    try owner.database.execute("DELETE FROM history_items")
                }
            }
        }
        let before = try await Self.snapshot(in: authority)
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try await Self.bootstrap(authority)
        }
        #expect(try await Self.snapshot(in: authority) == before)
        #expect(before.configCount == 0)
        #expect(before.itemCount == (fact == .item ? 1 : 0))
        #expect(before.sequences.count == (fact == .record ? 1 : 0))
    }

    @Test("Gateway validation failure occurs before absent HCR bootstrap")
    func gatewayValidationPrecedesHCRBootstrap() async throws {
        let authority = try await Self.makeAuthority()
        try await authority.withTestDatabase { owner in
            try owner.database.writeTransaction {
                try owner.database.execute("DELETE FROM journal_config")
                try owner.database.execute("UPDATE gateway_config SET configSchemaVersion = 2")
            }
        }
        let before = try await Self.snapshot(in: authority)
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await authority.performStartup(initialMaximumUnpinnedItems: 200)
        }
        #expect(try await Self.snapshot(in: authority) == before)
        #expect(before.configCount == 0)
    }

    @Test("HCR startup rejection preserves item content and merged byte accounting")
    func hcrValidationPreservesContentAndAccounting() async throws {
        let history = try await SQLiteHistory.open(configuration:
            HistoryConfiguration(persistence: .temporary)
        )
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "hcr-open-order", observedAt: Self.now
        )))
        let authority = history.authority
        let before = try await Self.itemContentAndAccounting(in: authority)
        try await authority.withTestDatabase { owner in
            try owner.database.execute("UPDATE journal_config SET configSchemaVersion = 2")
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await authority.performStartup(initialMaximumUnpinnedItems: 200)
        }
        let after = try await Self.itemContentAndAccounting(in: authority)
        #expect(after.content == before.content)
        #expect(after.canonicalBytes == before.canonicalBytes)
        #expect(after.revisionCount == before.revisionCount)
        #expect(after.revisionBytes == before.revisionBytes)
    }

    @Test("missing journal config at a committed position fails even when all records and items are gone",
          arguments: [UInt64(1), 19])
    func committedPositionCannotRecreateMissingJournalConfig(_ position: UInt64) async throws {
        let authority = try await Self.makeAuthority()
        try await authority.withTestDatabase { owner in
            try owner.database.writeTransaction {
                try owner.database.execute("DELETE FROM journal_config")
                try owner.database.execute("UPDATE history_state SET changePosition = ?",
                    bindings: [.blob(sqliteUInt64(position))])
            }
        }
        let before = try await Self.snapshot(in: authority)
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try await Self.bootstrap(authority)
        }
        #expect(try await Self.snapshot(in: authority) == before)
        #expect(before.configCount == 0)
        #expect(before.positions.map(\.rawValue) == [position])
        #expect(before.sequences.isEmpty)
    }

    @Test("coherent retained suffix reopens unchanged")
    func coherentSuffixIsAccepted() async throws {
        let authority = try await Self.makeSuffixFixture(position: 3, floor: 0)
        let before = try await Self.snapshot(in: authority)
        try await Self.bootstrap(authority)
        #expect(try await Self.snapshot(in: authority) == before)
    }

    @Test("startup compacts only the fixed oldest prefix and revalidates")
    func startupPrefixCompaction() async throws {
        let authority = try await Self.ageFixture()
        try await Self.bootstrap(authority, limits: Self.ageLimits())
        let state = try await Self.snapshot(in: authority)
        #expect(state.floor == 1)
        #expect(state.sequences == [2, 3])
        #expect(state.journalBytes == 40)
    }

    @Test("failure inside age-prefix compaction commits no delete or floor change")
    func startupPrefixCompactionRollsBack() async throws {
        let authority = try await Self.ageFixture()
        let before = try await Self.snapshot(in: authority)
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await Self.bootstrap(authority, limits: Self.ageLimits(), failCompaction: true)
        }
        // A separate reader observes only committed SQLite state.
        let storeURL = await authority.withTestDatabase { $0.storeLocation.databaseURL }
        let database = try SQLiteDatabase(url: storeURL, readOnly: true)
        let after = try database.readTransaction { try Self.snapshot(in: database) }
        #expect(after == before)
    }

    @Test("byte-over-cap durable state fails closed instead of startup repair")
    func byteCapViolationFailsClosed() async throws {
        let authority = try await Self.makeSuffixFixture(position: 3, floor: 0)
        let limits = try #require(JournalLimits(
            maxAffectedItemsPerRecord: 5_001, maxJournalRecordCount: 10,
            maxJournalAgeSeconds: 10, maxJournalBytes: 40, compactionCadenceCommits: 2
        ))
        let before = try await Self.snapshot(in: authority)
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try await Self.bootstrap(authority, limits: limits)
        }
        #expect(try await Self.snapshot(in: authority) == before)
    }

    @Test("missing config with a surviving HCR fails without repair")
    func missingConfigWithRecordFailsClosed() async throws {
        let authority = try await Self.makeSuffixFixture(position: 1, floor: 0)
        try await authority.withTestDatabase { owner in
            try owner.database.execute("DELETE FROM journal_config")
        }
        let before = try await Self.snapshot(in: authority)
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try await Self.bootstrap(authority)
        }
        #expect(try await Self.snapshot(in: authority) == before)
    }

    @Test("config scalar and retained interval corruption fail without repair")
    func corruptShapesFailClosed() async throws {
        try await Self.expectDamage(expected: .persistence(.invariantViolation),
            sql: "UPDATE journal_config SET key = ?", bindings: [.text("wrong-journal")])
        try await Self.expectDamage(expected: .persistence(.corruptStoredValue),
            sql: "UPDATE journal_config SET configSchemaVersion = 2")
        try await Self.expectDamage(expected: .persistence(.invariantViolation),
            sql: "UPDATE journal_config SET compactionFloorRaw = ?", bindings: [.blob(sqliteUInt64(4))])
        try await Self.expectDamage(expected: .persistence(.invariantViolation),
            sql: "UPDATE journal_config SET journalBytes = ?", bindings: [.blob(sqliteUInt64(61))])
        try await Self.expectDamage(expected: .persistence(.invariantViolation),
            sql: "DELETE FROM history_change_records WHERE sequence = ?", bindings: [.blob(sqliteUInt64(2))])
        try await Self.expectDamage(expected: .persistence(.invariantViolation),
            sql: "UPDATE history_change_records SET changePositionRaw = ? WHERE sequence = ?",
            bindings: [.blob(sqliteUInt64(99)), .blob(sqliteUInt64(2))])
        try await Self.expectDamage(expected: .persistence(.corruptStoredValue),
            sql: "UPDATE history_change_records SET changeKindRaw = 0 WHERE sequence = ?",
            bindings: [.blob(sqliteUInt64(2))])
        try await Self.expectDamage(expected: .persistence(.corruptStoredValue),
            sql: "UPDATE history_change_records SET affectedItemsBlob = ? WHERE sequence = ?",
            bindings: [.blob(Data([0, 2, 0, 0])), .blob(sqliteUInt64(2))])
        try await Self.expectDamage(expected: .persistence(.corruptStoredValue),
            sql: "UPDATE history_change_records SET createdAt = ? WHERE sequence = ?",
            bindings: [.real(.infinity), .blob(sqliteUInt64(2))])
    }

    @Test("strict post-commit count cap rejects an impossible overflow")
    func countOverflowFailsBeforeCompaction() async throws {
        let authority = try await Self.makeSuffixFixture(position: 3, floor: 0)
        let limits = try #require(JournalLimits(
            maxAffectedItemsPerRecord: 5_001, maxJournalRecordCount: 2,
            maxJournalAgeSeconds: 10, maxJournalBytes: 80 * 1_048_576, compactionCadenceCommits: 2
        ))
        let before = try await Self.snapshot(in: authority)
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try await Self.bootstrap(authority, limits: limits)
        }
        #expect(try await Self.snapshot(in: authority) == before)
    }

    private enum EarlierOwnerDamage: CaseIterable, Equatable, Sendable {
        case position, retention, gateway
    }

    @Test("surviving HCR facts prevent earlier singleton repair")
    func hcrFactsRejectMissingEarlierOwnersWithoutRepair() async throws {
        for damage in EarlierOwnerDamage.allCases {
            let authority = try await Self.makeSuffixFixture(position: 1, floor: 0)
            try await authority.withTestDatabase { owner in
                try owner.database.writeTransaction {
                    try owner.database.execute("DELETE FROM gateway_config")
                    try owner.database.execute("DELETE FROM connections")
                    if damage != .gateway {
                        try owner.database.execute("DELETE FROM retention_policies")
                    }
                    if damage == .position {
                        try owner.database.execute("DELETE FROM history_state")
                    }
                }
            }
            let before = try await Self.snapshot(in: authority)
            await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
                try await authority.performStartup(initialMaximumUnpinnedItems: 200)
            }
            #expect(try await Self.snapshot(in: authority) == before)
        }
    }

    private struct Snapshot: Equatable, Sendable {
        struct Position: Equatable, Sendable {
            let key: String
            let rawValue: UInt64
            let maximumUnpinnedItems: Int64
        }
        let positions: [Position]
        let retentionConfigCount: Int64
        let gatewayConfigCount: Int64
        let connectionCount: Int64
        let itemCount: Int64
        let configCount: Int
        let floor: UInt64?
        let journalBytes: UInt64?
        let sequences: [UInt64]
        let rawConfigs: [[SQLiteValue]]
        let rawRecords: [[SQLiteValue]]
    }

    private static func makeAuthority() async throws -> HistoryAuthority {
        let history = try await SQLiteHistory.open(configuration:
            HistoryConfiguration(persistence: .temporary)
        )
        return history.authority
    }

    private static func makeSuffixFixture(
        position: UInt64, floor: UInt64, createdAt: [Date]? = nil
    ) async throws -> HistoryAuthority {
        let authority = try await makeAuthority()
        try await authority.withTestDatabase { owner in
            try owner.database.writeTransaction {
                try owner.database.execute("UPDATE history_state SET changePosition = ?",
                    bindings: [.blob(sqliteUInt64(position))])
                var journalBytes: UInt64 = 0
                if floor < position {
                    for sequence in (floor + 1)...position {
                        let blob = try AffectedItemsBlobCodec.encode([itemID(Int(sequence))], for: .insert)
                        journalBytes += UInt64(blob.count)
                        let date = createdAt?[Int(sequence - floor - 1)] ?? now
                        try owner.database.execute("""
                            INSERT INTO history_change_records
                                (sequence, changePositionRaw, changeKindRaw, affectedItemsBlob, createdAt)
                            VALUES (?, ?, ?, ?, ?)
                            """, bindings: [
                                .blob(sqliteUInt64(sequence)), .blob(sqliteUInt64(sequence)),
                                .integer(Int64(HistoryChangeKindRawV1.insert.rawValue)), .blob(blob),
                                .real(date.timeIntervalSinceReferenceDate)
                            ])
                    }
                }
                try owner.database.execute("""
                    UPDATE journal_config SET compactionFloorRaw = ?, journalBytes = ?
                    """, bindings: [.blob(sqliteUInt64(floor)), .blob(sqliteUInt64(journalBytes))])
            }
        }
        return authority
    }

    private static func ageFixture() async throws -> HistoryAuthority {
        try await makeSuffixFixture(position: 3, floor: 0, createdAt: [
            now.addingTimeInterval(-11), now.addingTimeInterval(-5), now
        ])
    }

    private static func ageLimits() throws -> JournalLimits {
        try #require(JournalLimits(
            maxAffectedItemsPerRecord: 5_001, maxJournalRecordCount: 10,
            maxJournalAgeSeconds: 10, maxJournalBytes: 80, compactionCadenceCommits: 2
        ))
    }

    private static func bootstrap(
        _ authority: HistoryAuthority, limits: JournalLimits = .standard,
        failCompaction: Bool = false
    ) async throws {
        struct InjectedFailure: Error {}
        try await authority.withTestDatabase { owner in
            try owner.database.writeTransaction {
                try HCRBootstrap.ensureReady(
                    in: owner.database, now: now, journalLimits: limits,
                    compactionInjection: {
                        if failCompaction { throw InjectedFailure() }
                    }
                )
            }
        }
    }

    private static func expectDamage(
        expected: HistoryFailure, sql: String, bindings: [SQLiteValue] = []
    ) async throws {
        let authority = try await makeSuffixFixture(position: 3, floor: 0)
        try await authority.withTestDatabase { owner in
            // Corruption injection bypasses SQL CHECK only for this edit. The
            // production decoder must reject the resulting durable value.
            try owner.database.execute("PRAGMA ignore_check_constraints = ON")
            defer { try? owner.database.execute("PRAGMA ignore_check_constraints = OFF") }
            try owner.database.execute(sql, bindings: bindings)
        }
        let before = try await snapshot(in: authority)
        await #expect(throws: expected) { try await bootstrap(authority) }
        #expect(try await snapshot(in: authority) == before)
    }

    private static func snapshot(in authority: HistoryAuthority) async throws -> Snapshot {
        try await authority.withTestDatabase { owner in
            try owner.database.readTransaction { try snapshot(in: owner.database) }
        }
    }

    private static func snapshot(in database: SQLiteDatabase) throws -> Snapshot {
        let positionQuery = try database.prepare(
            "SELECT key, changePosition, maximumUnpinnedItems FROM history_state ORDER BY key"
        )
        defer { positionQuery.finalize() }
        var positions: [Snapshot.Position] = []
        while try positionQuery.step() {
            positions.append(.init(
                key: try positionQuery.text(at: 0),
                rawValue: try sqliteUInt64(positionQuery.blob(at: 1)),
                maximumUnpinnedItems: try positionQuery.integer(at: 2)
            ))
        }
        let configs = try HCRBootstrap.loadConfigs(in: database)
        let records = try HCRBootstrap.loadRecords(in: database, limit: 100)
        func count(_ sql: String) throws -> Int64 {
            let statement = try database.prepare(sql)
            defer { statement.finalize() }
            #expect(try statement.step())
            return try statement.integer(at: 0)
        }
        return Snapshot(
            positions: positions,
            retentionConfigCount: try count("SELECT count(*) FROM retention_policies"),
            gatewayConfigCount: try count("SELECT count(*) FROM gateway_config"),
            connectionCount: try count("SELECT count(*) FROM connections"),
            itemCount: try count("SELECT count(*) FROM history_items"),
            configCount: configs.count,
            floor: configs.first?.compactionFloorRaw,
            journalBytes: configs.first?.journalBytes,
            sequences: records.map(\.sequence),
            rawConfigs: configs.map {
                [.text($0.key), .blob(sqliteUInt64($0.compactionFloorRaw)),
                 .blob(sqliteUInt64($0.journalBytes)), .integer(Int64($0.configSchemaVersion))]
            },
            rawRecords: records.map {
                [.blob(sqliteUInt64($0.sequence)), .blob(sqliteUInt64($0.changePositionRaw)),
                 .integer(Int64($0.changeKindRaw)), .blob($0.affectedItemsBlob),
                 .real($0.createdAt.timeIntervalSinceReferenceDate)]
            }
        )
    }

    private static func itemContentAndAccounting(
        in authority: HistoryAuthority
    ) async throws -> (content: Data, canonicalBytes: Int64, revisionCount: Int64, revisionBytes: Int64) {
        try await authority.withTestDatabase { owner in
            let statement = try owner.database.prepare("""
                SELECT representations.inlineBytes, history_items.canonicalBytes,
                    history_items.revisionCount, history_items.revisionBytes
                FROM history_items
                JOIN representations ON representations.contentID = history_items.currentContentID
                """)
            defer { statement.finalize() }
            #expect(try statement.step())
            return (
                try statement.blob(at: 0), try statement.integer(at: 1),
                try statement.integer(at: 2), try statement.integer(at: 3)
            )
        }
    }

    private static func itemID(_ value: Int) -> HistoryItemID {
        HistoryItemID(rawValue: UUID(uuidString:
            String(format: "00000000-0000-0000-0000-%012d", value)
        )!)
    }
}
