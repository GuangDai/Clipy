import Foundation
import SQLite3
import Testing
@testable import HistoryStorage

struct SQLiteInterruptionScopeTests {
    enum Scope: CaseIterable, Sendable, Equatable {
        case readTransaction, writeTransaction, standaloneStatement
    }

    @Test(arguments: Scope.allCases)
    func cancellationScopeRestoresAnExistingReadDeadline(scope: Scope) throws {
        let database = try SQLiteDatabase(url: nil)
        try database.execute("CREATE TABLE values_test (value INTEGER)")
        try database.setReadInterruptionDeadline(ContinuousClock().now)
        // A short statement does not reach the 1,000-instruction callback.
        // The following recursive query does, so losing the previous handler
        // changes the observable result from SQLITE_INTERRUPT to success.
        switch scope {
        case .readTransaction:
            try database.readTransaction(checkingCancellation: true) {
                try database.execute("SELECT 1")
            }
        case .writeTransaction:
            try database.writeTransaction(checkingCancellation: true) {
                try database.execute("INSERT INTO values_test VALUES (7)")
            }
        case .standaloneStatement:
            try database.executeCancellable("SELECT 1")
        }
        #expect(throws: SQLiteFailure(code: SQLITE_INTERRUPT)) {
            try database.execute(Self.recursiveQuery)
        }
        try database.setReadInterruptionDeadline(nil)
        let values = try database.prepare("SELECT value FROM values_test")
        defer { values.finalize() }
        if scope == .writeTransaction {
            #expect(try values.step())
            #expect(try values.integer(at: 0) == 7)
        }
        #expect(try !values.step())
    }

    @Test func expiredReadDeadlineAllowsRollbackAndLaterTransactions() throws {
        let database = try SQLiteDatabase(url: nil)
        try database.execute("CREATE TABLE values_test (value INTEGER)")
        try database.setReadInterruptionDeadline(ContinuousClock().now)
        #expect(throws: SQLiteFailure(code: SQLITE_INTERRUPT)) {
            try database.readTransaction(checkingCancellation: true) {
                try database.execute(Self.recursiveQuery)
            }
        }
        try database.setReadInterruptionDeadline(nil)
        // A failed read must leave autocommit restored. A fresh write is an
        // observable proof that rollback was not interrupted by its deadline.
        try database.writeTransaction {
            try database.execute("INSERT INTO values_test VALUES (9)")
        }
        let values = try database.prepare("SELECT value FROM values_test")
        defer { values.finalize() }
        #expect(try values.step())
        #expect(try values.integer(at: 0) == 9)
        #expect(try !values.step())
    }

    private static let recursiveQuery = """
        WITH RECURSIVE numbers(value) AS (
            VALUES(0) UNION ALL SELECT value + 1 FROM numbers WHERE value < 1000
        ) SELECT sum(value) FROM numbers
        """
}
