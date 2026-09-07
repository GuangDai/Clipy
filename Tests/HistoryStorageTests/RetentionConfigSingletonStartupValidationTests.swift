import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// V2-09 §6: the public open validates the current policy unit and rolls back
/// startup on corruption. Used stores never receive replacement defaults.
struct RetentionConfigSingletonStartupValidationTests {
    private enum Corruption: String, CaseIterable, Sendable {
        case positiveInfiniteAge, negativeInfiniteAge
        case ageBelowRange, ageAboveRange, storageBelowRange, storageAboveRange
        case revisionCountBelowRange, revisionCountAboveRange
        case revisionBytesBelowRange, revisionBytesAboveRange
        case missingConfiguration

        var expectedFailure: HistoryFailure {
            switch self {
            case .positiveInfiniteAge, .negativeInfiniteAge:
                .persistence(.corruptStoredValue)
            default:
                .persistence(.invariantViolation)
            }
        }

        func apply(in database: SQLiteDatabase) throws {
            let column: String
            let value: SQLiteValue
            switch self {
            case .positiveInfiniteAge: (column, value) = ("ageMaxSeconds", .real(.infinity))
            case .negativeInfiniteAge: (column, value) = ("ageMaxSeconds", .real(-.infinity))
            case .ageBelowRange: (column, value) = ("ageMaxSeconds", .real(0.5))
            case .ageAboveRange: (column, value) = ("ageMaxSeconds", .real(315_360_001))
            case .storageBelowRange: (column, value) = ("storageMaxBytes", .integer(0))
            case .storageAboveRange: (column, value) = ("storageMaxBytes", .integer(2_013_265_920_001))
            case .revisionCountBelowRange: (column, value) = ("revisionMaxCount", .integer(0))
            case .revisionCountAboveRange: (column, value) = ("revisionMaxCount", .integer(101))
            case .revisionBytesBelowRange: (column, value) = ("revisionMaxBytes", .integer(0))
            case .revisionBytesAboveRange: (column, value) = ("revisionMaxBytes", .integer(268_435_457))
            case .missingConfiguration:
                try database.execute("DELETE FROM retention_policies")
                return
            }
            // Corruption fixture only: bypass CHECK to exercise the actual
            // startup decoder even for values ordinary SQL writes reject.
            try database.execute("PRAGMA ignore_check_constraints = ON")
            defer { try? database.execute("PRAGMA ignore_check_constraints = OFF") }
            try database.execute("UPDATE retention_policies SET \(column) = ?", bindings: [value])
        }
    }

    private struct StoredState: Equatable, Sendable {
        let policies: [SQLiteValue]
        let position: Data
        let maximumUnpinnedItems: Int64
        let retainedItemCount: Int64
        let canonicalBytes: Int64
        let items: [WSSupport.StoredItem]
        let journalRows: Int64
        let operationRows: Int64
        let gatewayRows: Int64
    }

    private static func readState(in database: SQLiteDatabase) throws -> StoredState {
        let config = try database.prepare("""
            SELECT ageMaxSeconds, storageMaxBytes, revisionMaxCount, revisionMaxBytes
            FROM retention_policies
            """)
        defer { config.finalize() }
        var policies: [SQLiteValue] = []
        if try config.step() {
            policies.append(try config.isNull(at: 0) ? .null : .real(config.real(at: 0)))
            for column in Int32(1)...Int32(3) {
                policies.append(try config.isNull(at: column) ? .null : .integer(config.integer(at: column)))
            }
            #expect(try !config.step())
        }
        let state = try database.prepare("""
            SELECT changePosition, maximumUnpinnedItems, retainedItemCount, canonicalBytes,
                (SELECT count(*) FROM history_change_records),
                (SELECT count(*) FROM operation_records),
                (SELECT count(*) FROM gateway_config)
            FROM history_state
            """)
        defer { state.finalize() }
        try #require(try state.step())
        return try StoredState(
            policies: policies, position: state.blob(at: 0),
            maximumUnpinnedItems: state.integer(at: 1),
            retainedItemCount: state.integer(at: 2), canonicalBytes: state.integer(at: 3),
            items: WSSupport.fetchRows(database), journalRows: state.integer(at: 4),
            operationRows: state.integer(at: 5), gatewayRows: state.integer(at: 6)
        )
    }

    private static func seedSingletons(
        at storeURL: URL, corruption: Corruption? = nil
    ) async throws -> StoredState {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(
            persistence: .persistent(storeURL: storeURL), initialMaximumUnpinnedItems: 321
        ))
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "retained item alpha", observedAt: Date(), source: "com.example.retention"
        )))
        return try await history.authority.withTestDatabase { authority in
            try authority.database.execute("""
                UPDATE retention_policies SET ageMaxSeconds = ?, storageMaxBytes = ?,
                    revisionMaxCount = ?, revisionMaxBytes = ?
                """, bindings: [
                    .real(86_400), .integer(536_870_912), .integer(20), .integer(16_777_216),
                ])
            try corruption?.apply(in: authority.database)
            return try readState(in: authority.database)
        }
    }

    @Test("invalid existing policy prevents publication without repair or unrelated writes")
    func invalidExistingConfigFailsClosedWithoutRepair() async throws {
        for corruption in Corruption.allCases {
            let storeURL = WSSupport.tempStoreURL("config-corrupt-\(corruption.rawValue)")
            defer { WSSupport.removeStore(storeURL) }
            let seeded = try await Self.seedSingletons(at: storeURL, corruption: corruption)
            do {
                _ = try await SQLiteHistory.open(configuration: HistoryConfiguration(
                    persistence: .persistent(storeURL: storeURL),
                    initialMaximumUnpinnedItems: 200
                ))
                Issue.record("\(corruption.rawValue): expected startup failure")
            } catch let failure as HistoryFailure {
                #expect(failure == corruption.expectedFailure)
            } catch {
                Issue.record("\(corruption.rawValue): unexpected error \(error)")
            }
            let database = try SQLiteDatabase(url: storeURL, readOnly: true)
            #expect(try Self.readState(in: database) == seeded)
            #expect(seeded.maximumUnpinnedItems == 321)
            #expect(seeded.retainedItemCount == 1)
            #expect(seeded.items.count == 1)
            try database.close()
        }
    }

    @Test("valid existing policy is published and never replaced by defaults")
    func validExistingConfigIsPreserved() async throws {
        let storeURL = WSSupport.tempStoreURL("config-valid-existing")
        defer { WSSupport.removeStore(storeURL) }
        let seeded = try await Self.seedSingletons(at: storeURL)
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(
            persistence: .persistent(storeURL: storeURL), initialMaximumUnpinnedItems: 200
        ))
        let published = try await history.retentionConfiguration()
        #expect(published.maximumUnpinnedItems == 321)
        #expect(published.policies == HistoryRetentionPolicies(
            age: AgeRetention(maxAge: 86_400),
            storage: StorageRetention(maxTotalBytes: 536_870_912),
            revisions: RevisionRetention(
                maxRevisionsPerItem: 20, maxRevisionBytesPerItem: 16_777_216
            )
        ))
        let persisted = try await history.authority.withTestDatabase { authority in
            try Self.readState(in: authority.database)
        }
        #expect(persisted == seeded)
    }
}
