import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// The actual WAL connection owns the temporary directory through SQLite
/// close. These tests release creator scopes instead of manually arranging
/// close-before-location-release at each caller.
struct SQLiteStoreLifetimeTests {
    @Test func writerKeepsItsFilesAfterTheCreatingLocationScopeReturns() throws {
        var fixture = try Self.makeWriter()
        #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-wal"))
        do {
            let writer: SQLiteDatabase = try #require(fixture.database)
            try writer.execute("INSERT INTO lifetime_values VALUES (2)")
        }
        fixture.database = nil
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test func statementKeepsConnectionAndDirectoryUntilItsOwnRelease() throws {
        var fixture = try Self.makeStatement()
        #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
        do {
            let statement: SQLiteStatement = try #require(fixture.statement)
            #expect(try statement.step())
            #expect(try statement.integer(at: 0) == 1)
        }
        fixture.statement = nil
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @MainActor
    @Test func independentReaderSurvivesAuthorityReleaseThenCleansTheDirectory() async throws {
        var fixture = try await Self.makeReaderAfterAuthorityRelease()
        #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
        do {
            let reader: SQLiteDatabase = try #require(fixture.database)
            try reader.readTransaction {
                let row: SQLiteStatement = try reader.prepare("SELECT count(*) FROM history_state")
                defer { row.finalize() }
                #expect(try row.step())
                #expect(try row.integer(at: 0) == 1)
            }
        }
        fixture.database = nil
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @MainActor
    @Test func releasedAuthorityStillRemovesItsDisposableStoreWithoutAReader() async throws {
        let directory = try await Self.makeAndReleaseAuthority()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    private struct ConnectionFixture {
        let directory: URL
        let databaseURL: URL
        var database: SQLiteDatabase?
    }

    private struct StatementFixture {
        let directory: URL
        var statement: SQLiteStatement?
    }

    private static func makeWriter() throws -> ConnectionFixture {
        let location = try HistoryStoreLocation(persistence: .temporary)
        let database = try SQLiteDatabase(storeLocation: location)
        try database.execute("CREATE TABLE lifetime_values (value INTEGER NOT NULL)")
        try database.execute("INSERT INTO lifetime_values VALUES (1)")
        return ConnectionFixture(directory: location.ownedDirectoryURL, databaseURL: location.databaseURL,
                                 database: database)
    }

    private static func makeStatement() throws -> StatementFixture {
        let location = try HistoryStoreLocation(persistence: .temporary)
        let database = try SQLiteDatabase(storeLocation: location)
        try database.execute("CREATE TABLE lifetime_values (value INTEGER NOT NULL)")
        try database.execute("INSERT INTO lifetime_values VALUES (1)")
        let statement = try database.prepare("SELECT value FROM lifetime_values")
        return StatementFixture(directory: location.ownedDirectoryURL, statement: statement)
    }

    @MainActor
    private static func makeReaderAfterAuthorityRelease() async throws -> ConnectionFixture {
        let location = try HistoryStoreLocation(persistence: .temporary)
        var authority: HistoryAuthority? = try HistoryAuthority(storeLocation: location)
        do {
            let writer: HistoryAuthority = try #require(authority)
            try await writer.performStartup(initialMaximumUnpinnedItems: 200)
        }
        let reader = try SQLiteDatabase(storeLocation: location, readOnly: true)
        authority = nil
        return ConnectionFixture(directory: location.ownedDirectoryURL, databaseURL: location.databaseURL,
                                 database: reader)
    }

    @MainActor
    private static func makeAndReleaseAuthority() async throws -> URL {
        let location = try HistoryStoreLocation(persistence: .temporary)
        let authority = try HistoryAuthority(storeLocation: location)
        try await authority.performStartup(initialMaximumUnpinnedItems: 200)
        return location.ownedDirectoryURL
    }
}
