/// Missing or malformed authoritative configuration is never bootstrapped
/// over existing SQLite History/Gateway facts (V2-09 §4).
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SingletonShapeStartupClassifierTests {
    enum Damage: CaseIterable, Sendable {
        case deletePosition, deleteConfig, wrongKeyPosition, extraWrongKeyPosition, wrongKeyConfig, extraWrongKeyConfig
    }
    enum SurvivingFact: CaseIterable, Sendable { case item, content, representation }

    @Test(arguments: Damage.allCases)
    func nonFreshConfigurationDamageFailsWithoutRepair(damage: Damage) async throws {
        let url = WSSupport.tempStoreURL("sqlite-singleton-damage")
        defer { WSSupport.removeStore(url) }
        try await Self.seed(at: url)
        do {
            let database = try SQLiteDatabase(url: url)
            try database.execute("PRAGMA ignore_check_constraints = ON")
            switch damage {
            case .deletePosition: try database.execute("DELETE FROM history_state")
            case .deleteConfig: try database.execute("DELETE FROM retention_policies")
            case .wrongKeyPosition: try database.execute("UPDATE history_state SET key = 'wrong-position'")
            case .extraWrongKeyPosition:
                try database.execute("INSERT INTO history_state SELECT 'wrong-position',changePosition,maximumUnpinnedItems,retainedItemCount,pinnedItemCount,canonicalBytes,revisionBytes FROM history_state")
            case .wrongKeyConfig: try database.execute("UPDATE retention_policies SET key = 'wrong-config'")
            case .extraWrongKeyConfig:
                try database.execute("INSERT INTO retention_policies SELECT 'wrong-config',ageMaxSeconds,storageMaxBytes,revisionMaxCount,revisionMaxBytes FROM retention_policies")
            }
        }
        let before = try Self.snapshot(at: url)
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) { try await WSSupport.openHistory(storeURL: url) }
        #expect(try Self.snapshot(at: url) == before)
    }

    @Test(arguments: SurvivingFact.allCases)
    func anySurvivingHistoryFactPreventsFreshDefaults(fact: SurvivingFact) async throws {
        let url = WSSupport.tempStoreURL("sqlite-singleton-surviving-fact")
        defer { WSSupport.removeStore(url) }
        try await Self.seed(at: url)
        do {
            let database = try SQLiteDatabase(url: url)
            // Fault injection isolates each table's surviving fact instead of
            // allowing FK cascade to erase the very evidence under test.
            try database.execute("PRAGMA foreign_keys = OFF")
            try Self.removeLaterConfiguration(in: database)
            try database.execute("DELETE FROM history_state")
            try database.execute("DELETE FROM retention_policies")
            switch fact {
            case .item:
                try database.execute("DELETE FROM representations"); try database.execute("DELETE FROM contents")
            case .content:
                try database.execute("DELETE FROM representations"); try database.execute("DELETE FROM history_items")
            case .representation:
                try database.execute("DELETE FROM contents"); try database.execute("DELETE FROM history_items")
            }
        }
        let before = try Self.snapshot(at: url)
        #expect(before.positions.isEmpty && before.policies.isEmpty)
        #expect(!before.itemIDs.isEmpty || !before.contentIDs.isEmpty || !before.representations.isEmpty)
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) { try await WSSupport.openHistory(storeURL: url) }
        #expect(try Self.snapshot(at: url) == before)
    }

    @Test(arguments: [false, true])
    func clearedHistoryStillCannotBootstrapMissingConfiguration(removePolicies: Bool) async throws {
        let url = WSSupport.tempStoreURL("sqlite-singleton-cleared")
        defer { WSSupport.removeStore(url) }
        try await Self.seed(at: url, clear: true)
        do {
            let database = try SQLiteDatabase(url: url)
            try Self.removeLaterConfiguration(in: database)
            if removePolicies { try database.execute("DELETE FROM retention_policies") }
        }
        let before = try Self.snapshot(at: url)
        #expect(before.itemIDs.isEmpty && before.contentIDs.isEmpty && before.representations.isEmpty)
        #expect(before.positions.first?[1] == .blob(sqliteUInt64(2)))
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) { try await WSSupport.openHistory(storeURL: url) }
        #expect(try Self.snapshot(at: url) == before)
    }

    @Test func gatewayOnlyStatePreventsMissingPositionRepair() async throws {
        let url = WSSupport.tempStoreURL("sqlite-singleton-gateway-only")
        defer { WSSupport.removeStore(url) }
        _ = try await WSSupport.openHistory(storeURL: url)
        do {
            let database = try SQLiteDatabase(url: url)
            try database.execute("DELETE FROM history_state")
            try database.execute("DELETE FROM retention_policies")
        }
        let before = try Self.snapshot(at: url)
        #expect(before.itemIDs.isEmpty && !before.gateway.connections.isEmpty)
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) { try await WSSupport.openHistory(storeURL: url) }
        #expect(try Self.snapshot(at: url) == before)
    }

    private static func seed(at url: URL, clear: Bool = false) async throws {
        let history = try await WSSupport.openHistory(storeURL: url)
        _ = try await history.perform(.capture(WSSupport.textCapture("retained singleton evidence")))
        if clear { _ = try await history.perform(.clear(.all)) }
    }

    private static func removeLaterConfiguration(in database: SQLiteDatabase) throws {
        for table in ["grants", "operation_records", "connections", "gateway_config", "history_change_records", "journal_config"] {
            try database.execute("DELETE FROM \(table)")
        }
    }

    private struct Snapshot: Equatable {
        let positions: [[SQLiteValue]]
        let policies: [[SQLiteValue]]
        let itemIDs: [String]
        let contentIDs: [String]
        let representations: [[SQLiteValue]]
        let gateway: GatewayStoreSnapshot
    }

    private static func snapshot(at url: URL) throws -> Snapshot {
        let database = try SQLiteDatabase(url: url, readOnly: true)
        return try database.readTransaction {
            let position = try database.prepare("SELECT key,changePosition,maximumUnpinnedItems,retainedItemCount,pinnedItemCount,canonicalBytes,revisionBytes FROM history_state ORDER BY key")
            defer { position.finalize() }
            var positions: [[SQLiteValue]] = []
            while try position.step() {
                positions.append(try [.text(position.text(at: 0)), .blob(position.blob(at: 1)), .integer(position.integer(at: 2)),
                    .integer(position.integer(at: 3)), .integer(position.integer(at: 4)), .integer(position.integer(at: 5)), .integer(position.integer(at: 6))])
            }
            let policy = try database.prepare("SELECT key,ageMaxSeconds,storageMaxBytes,revisionMaxCount,revisionMaxBytes FROM retention_policies ORDER BY key")
            defer { policy.finalize() }
            var policies: [[SQLiteValue]] = []
            while try policy.step() {
                policies.append(try [.text(policy.text(at: 0)),
                    policy.isNull(at: 1) ? .null : .real(policy.real(at: 1)),
                    policy.isNull(at: 2) ? .null : .integer(policy.integer(at: 2)),
                    policy.isNull(at: 3) ? .null : .integer(policy.integer(at: 3)),
                    policy.isNull(at: 4) ? .null : .integer(policy.integer(at: 4))])
            }
            let itemQuery = try database.prepare("SELECT id FROM history_items ORDER BY id")
            defer { itemQuery.finalize() }
            var itemIDs: [String] = []
            while try itemQuery.step() { itemIDs.append(try itemQuery.text(at: 0)) }
            let contentQuery = try database.prepare("SELECT id FROM contents ORDER BY id")
            defer { contentQuery.finalize() }
            var contentIDs: [String] = []
            while try contentQuery.step() { contentIDs.append(try contentQuery.text(at: 0)) }
            let representationQuery = try database.prepare("SELECT contentID,ordinal,inlineBytes,blobID FROM representations ORDER BY contentID,ordinal")
            defer { representationQuery.finalize() }
            var representations: [[SQLiteValue]] = []
            while try representationQuery.step() {
                representations.append(try [.text(representationQuery.text(at: 0)), .integer(representationQuery.integer(at: 1)),
                    representationQuery.optionalBlob(at: 2).map(SQLiteValue.blob) ?? .null,
                    representationQuery.optionalText(at: 3).map(SQLiteValue.text) ?? .null])
            }
            return try Snapshot(positions: positions, policies: policies, itemIDs: itemIDs, contentIDs: contentIDs,
                                representations: representations, gateway: GatewayStoreSnapshot.read(in: database))
        }
    }
}
