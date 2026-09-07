import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct LocalAutomationFileCredentialHostedTests {
    /// The default app-private file custody is exercised directly. Only this
    /// fresh connection's UUID directory may be cleaned; the default root and
    /// every other connection remain untouched.
    @Test func defaultFileCredentialPersistsAcrossActorsAndDeletesExactlyItsEntry() async throws {
        // Hosted code cannot mint package-scoped IDs. An isolated real store
        // supplies a fresh bootstrap UUID through its public admin read.
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let connection = try #require(try await history.connections().first).id
        let credential = try LocalAutomationCredential(
            connection: connection, secret: Data((0..<32).map { UInt8($0) })
        )
        let directory = CredentialStore.defaultDirectoryURL
            .appendingPathComponent(connection.rawValue.uuidString, isDirectory: true)
        try #require(!FileManager.default.fileExists(atPath: directory.path))
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("local-automation.credential")
        let store = CredentialStore()
        try await store.storeCredential(credential.exactBytes, for: connection)
        #expect(try Data(contentsOf: file) == credential.exactBytes)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let reopened = CredentialStore()
        #expect(try await reopened.loadCredential(for: connection) == credential.exactBytes)
        #expect(try await reopened.connectionIDs().contains(connection))
        try await reopened.deleteCredential(for: connection)
        #expect(try await store.loadCredential(for: connection) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: CredentialStore.defaultDirectoryURL.path))
    }
}
