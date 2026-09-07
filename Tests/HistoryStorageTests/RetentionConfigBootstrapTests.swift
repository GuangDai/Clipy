import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// V2-02 §8.3 / V2-09 §6: NULL disables a policy; defaults belong only to new stores.
@Suite("Retention config bootstrap")
struct RetentionConfigBootstrapTests {
    private func makeDatabase() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(url: nil)
        try SQLiteHistorySchema.create(in: database)
        try database.execute("""
            INSERT INTO history_state (key, changePosition, maximumUnpinnedItems)
            VALUES ('retained-history', ?, 200)
            """, bindings: [.blob(sqliteUInt64(0))])
        return database
    }

    private func insert(_ values: [SQLiteValue], in database: SQLiteDatabase) throws {
        try database.execute("""
            INSERT INTO retention_policies
                (key, ageMaxSeconds, storageMaxBytes, revisionMaxCount, revisionMaxBytes)
            VALUES ('retention-expansion', ?, ?, ?, ?)
            """, bindings: values)
    }

    private func assertDisabled(in database: SQLiteDatabase) throws {
        let row = try database.prepare("""
            SELECT key, ageMaxSeconds, storageMaxBytes, revisionMaxCount, revisionMaxBytes
            FROM retention_policies
            """)
        defer { row.finalize() }
        #expect(try row.step())
        #expect(try row.text(at: 0) == "retention-expansion")
        for column in Int32(1)...Int32(4) { #expect(try row.isNull(at: column)) }
        #expect(try !row.step())
    }

    @Test("committed defaults are visible on an independent connection")
    func absentConfigCreatesExactlyOneAllDisabledRow() throws {
        let location = try HistoryStoreLocation(persistence: .temporary)
        let writer = try SQLiteDatabase(url: location.databaseURL)
        try writer.writeTransaction {
            try SQLiteHistorySchema.create(in: writer)
            try writer.execute("""
                INSERT INTO history_state (key, changePosition, maximumUnpinnedItems)
                VALUES ('retained-history', ?, 200)
                """, bindings: [.blob(sqliteUInt64(0))])
            try HistoryAuthority.ensureRetentionExpansionConfig(in: writer)
        }
        let reader = try SQLiteDatabase(url: location.databaseURL, readOnly: true)
        try assertDisabled(in: reader)
        try reader.close()
        try writer.close()
        withExtendedLifetime(location) {}
    }

    @Test func validDisabledRowIsUnchanged() throws {
        let database = try makeDatabase()
        try insert([.null, .null, .null, .null], in: database)
        try HistoryAuthority.ensureRetentionExpansionConfig(in: database)
        try assertDisabled(in: database)
    }

    @Test("retention defaults roll back with the enclosing startup transaction")
    func defaultsRollbackWithStartupFailure() throws {
        enum StartupFailure: Error { case laterOwner }
        let database = try makeDatabase()
        #expect(throws: StartupFailure.self) {
            try database.writeTransaction {
                try HistoryAuthority.ensureRetentionExpansionConfig(in: database)
                throw StartupFailure.laterOwner
            }
        }
        let row = try database.prepare("SELECT count(*) FROM retention_policies")
        #expect(try row.step())
        #expect(try row.integer(at: 0) == 0)
        row.finalize()
        try database.writeTransaction {
            try HistoryAuthority.ensureRetentionExpansionConfig(in: database)
        }
        try assertDisabled(in: database)
    }

    @Test("interior and inclusive endpoint thresholds remain unchanged")
    func validEnabledRowsAreUnchanged() throws {
        let cases: [[SQLiteValue]] = [
            [.real(86_400), .integer(536_870_912), .integer(20), .integer(16_777_216)],
            [.real(1), .integer(1), .integer(1), .integer(1)],
            [.real(315_360_000), .integer(2_013_265_920_000), .integer(100), .integer(268_435_456)],
            [.null, .null, .integer(20), .null],
            [.null, .null, .null, .integer(16_777_216)],
        ]
        for values in cases {
            let database = try makeDatabase()
            try insert(values, in: database)
            try HistoryAuthority.ensureRetentionExpansionConfig(in: database)
            let row = try database.prepare("""
                SELECT ageMaxSeconds, storageMaxBytes, revisionMaxCount, revisionMaxBytes
                FROM retention_policies
                """)
            defer { row.finalize() }
            #expect(try row.step())
            for (index, expected) in values.enumerated() {
                let column = Int32(index)
                switch expected {
                case .null: #expect(try row.isNull(at: column))
                case .real(let value): #expect(try row.real(at: column) == value)
                case .integer(let value): #expect(try row.integer(at: column) == value)
                default: Issue.record("unexpected fixture value")
                }
            }
            #expect(try !row.step())
        }
    }

    @Test("non-finite ages cannot silently become disabled policies")
    func nonFiniteAgeFailsClosed() throws {
        let database = try makeDatabase()
        // SQLite otherwise stores NaN as NULL, which would disable the policy.
        #expect(throws: SQLiteFailure.self) {
            try insert([.real(.nan), .null, .null, .null], in: database)
        }
        for age in [Double.infinity, -Double.infinity] {
            try database.execute("PRAGMA ignore_check_constraints = ON")
            try insert([.real(age), .null, .null, .null], in: database)
            try database.execute("PRAGMA ignore_check_constraints = OFF")
            #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
                try HistoryAuthority.ensureRetentionExpansionConfig(in: database)
            }
            try database.execute("DELETE FROM retention_policies")
        }
    }

    @Test func outOfRangeValuesFailClosed() throws {
        let cases: [[SQLiteValue]] = [
            [.real(0.5), .null, .null, .null],
            [.real(315_360_001), .null, .null, .null],
            [.null, .integer(0), .null, .null],
            [.null, .integer(2_013_265_920_001), .null, .null],
            [.null, .null, .integer(0), .null],
            [.null, .null, .integer(101), .null],
            [.null, .null, .null, .integer(0)],
            [.null, .null, .null, .integer(268_435_457)],
        ]
        for values in cases {
            let database = try makeDatabase()
            try database.execute("PRAGMA ignore_check_constraints = ON")
            try insert(values, in: database)
            try database.execute("PRAGMA ignore_check_constraints = OFF")
            #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
                try HistoryAuthority.ensureRetentionExpansionConfig(in: database)
            }
        }
    }

    @Test("SQLite rejects duplicate configuration and nonpositive thresholds")
    func constraintsRejectInvalidWrites() throws {
        let database = try makeDatabase()
        let cases: [[SQLiteValue]] = [
            [.real(0), .null, .null, .null],
            [.null, .integer(0), .null, .null],
            [.null, .null, .integer(0), .null],
            [.null, .null, .null, .integer(0)],
        ]
        for values in cases {
            #expect(throws: SQLiteFailure.self) { try insert(values, in: database) }
        }
        try insert([.null, .null, .null, .null], in: database)
        #expect(throws: SQLiteFailure.self) {
            try insert([.null, .null, .null, .null], in: database)
        }
        try assertDisabled(in: database)
    }

    @Test func missingConfigurationInUsedStoreIsNotRepaired() throws {
        let database = try makeDatabase()
        try database.execute("UPDATE history_state SET changePosition = ?",
                             bindings: [.blob(sqliteUInt64(1))])
        #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try database.writeTransaction {
                try HistoryAuthority.ensureRetentionExpansionConfig(in: database)
            }
        }
        let row = try database.prepare("SELECT count(*) FROM retention_policies")
        defer { row.finalize() }
        #expect(try row.step())
        #expect(try row.integer(at: 0) == 0)
    }
}
