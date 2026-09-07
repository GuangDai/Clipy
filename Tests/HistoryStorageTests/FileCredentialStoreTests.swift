import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct FileCredentialStoreTests {
    private static let first = ExternalConnectionID(rawValue: UUID(
        uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"
    )!)
    private static let second = ExternalConnectionID(rawValue: UUID(
        uuidString: "11223344-5566-7788-99AA-BBCCDDEEFF00"
    )!)

    private struct Fixture {
        let root: URL
        var serverDirectory: URL { root.appendingPathComponent("server", isDirectory: true) }
        var store: CredentialStore { CredentialStore(directoryURL: serverDirectory) }

        func directory(for id: ExternalConnectionID) -> URL {
            serverDirectory.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
        }

        func file(for id: ExternalConnectionID) -> URL {
            directory(for: id).appendingPathComponent(LocalAutomationClientCredentialCustody.credentialFileName)
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clipy-server-credentials-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return Fixture(root: root)
    }

    private func bytes(for id: ExternalConnectionID, secret: UInt8 = 0xA5) throws -> Data {
        try LocalAutomationCredential(connection: id, secret: Data(repeating: secret, count: 32)).exactBytes
    }

    private func mode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    @Test func realFileSurvivesStoreRecreationAndDuplicateCannotReplaceIt() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try bytes(for: Self.first)
        let writer = fixture.store
        #expect(try await writer.loadCredential(for: Self.first) == nil)
        try await writer.storeCredential(original, for: Self.first)

        let reader = fixture.store
        #expect(try await reader.loadCredential(for: Self.first) == original)
        #expect(try Data(contentsOf: fixture.file(for: Self.first)) == original)
        #expect(try mode(at: fixture.serverDirectory) == 0o700)
        #expect(try mode(at: fixture.directory(for: Self.first)) == 0o700)
        #expect(try mode(at: fixture.file(for: Self.first)) == 0o600)
        #expect(try await reader.connectionIDs() == [Self.first])

        let replacement = try bytes(for: Self.first, secret: 0x5A)
        await #expect(throws: CredentialStoreFailure.duplicateCredential) {
            try await reader.storeCredential(replacement, for: Self.first)
        }
        #expect(try await fixture.store.loadCredential(for: Self.first) == original)
    }

    @Test(arguments: [false, true])
    func malformedFileLengthOrWrongConnectionIsRejected(wrongConnection: Bool) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try bytes(for: Self.first)
        try await fixture.store.storeCredential(original, for: Self.first)
        let damaged: Data
        if wrongConnection {
            damaged = try bytes(for: Self.second)
        } else {
            damaged = Data(original.dropLast())
        }
        try damaged.write(to: fixture.file(for: Self.first))

        await #expect(throws: CredentialStoreFailure.corruptStoredValue) {
            try await fixture.store.loadCredential(for: Self.first)
        }
    }

    @Test(arguments: [false, true])
    func serverRootAndCredentialFileRejectBroaderPermissions(damageRoot: Bool) async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.storeCredential(bytes(for: Self.first), for: Self.first)
        let target = damageRoot ? fixture.serverDirectory : fixture.file(for: Self.first)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: damageRoot ? 0o755 : 0o644)], ofItemAtPath: target.path
        )
        await #expect(throws: CredentialStoreFailure.unavailable) {
            try await fixture.store.loadCredential(for: Self.first)
        }
        #expect(try mode(at: target) == (damageRoot ? 0o755 : 0o644))
    }

    @Test func connectionDirectorySymlinkCannotReadOrDeleteItsTarget() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Store a different connection to create the real owner-only root.
        try await fixture.store.storeCredential(bytes(for: Self.second), for: Self.second)
        let target = fixture.root.appendingPathComponent("outside", isDirectory: true)
        let custody = LocalAutomationClientCredentialCustody(directoryURL: target)
        let original = try bytes(for: Self.first)
        try custody.installCredential(original)
        try FileManager.default.createSymbolicLink(at: fixture.directory(for: Self.first), withDestinationURL: target)

        await #expect(throws: CredentialStoreFailure.unavailable) {
            try await fixture.store.loadCredential(for: Self.first)
        }
        await #expect(throws: CredentialStoreFailure.unavailable) {
            try await fixture.store.deleteCredential(for: Self.first)
        }
        #expect(try custody.loadCredential() == original)
        #expect(try await fixture.store.loadCredential(for: Self.second) == bytes(for: Self.second))
    }

    @Test func deletionAndEnumerationTouchOnlyExactCredentialFiles() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.store
        try await store.storeCredential(bytes(for: Self.first), for: Self.first)
        try await store.storeCredential(bytes(for: Self.second), for: Self.second)
        let sentinel = Data("unrelated".utf8)
        let rootFile = fixture.serverDirectory.appendingPathComponent("notes.txt")
        let sibling = fixture.directory(for: Self.first).appendingPathComponent("keep.txt")
        try sentinel.write(to: rootFile)
        try sentinel.write(to: sibling)
        #expect(Set(try await store.connectionIDs()) == Set([Self.first, Self.second]))

        try await store.deleteCredential(for: Self.first)
        try await store.deleteCredential(for: Self.first)
        #expect(try await fixture.store.loadCredential(for: Self.first) == nil)
        #expect(try await fixture.store.connectionIDs() == [Self.second])
        #expect(try await fixture.store.loadCredential(for: Self.second) == bytes(for: Self.second))
        #expect(try Data(contentsOf: rootFile) == sentinel)
        #expect(try Data(contentsOf: sibling) == sentinel)
        #expect(FileManager.default.fileExists(atPath: fixture.serverDirectory.path))
    }

    @Test func enableCleansRealServerOrphanWithoutAClientCredential() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let credentials = fixture.store
        try await credentials.storeCredential(bytes(for: Self.first), for: Self.first)
        let history = try await SwiftDataHistory.open(configuration: HistoryConfiguration(persistence: .memory))
        let ingress = LocalAutomationIngress(
            authority: history.authority, gateway: history.externalGateway, credentialStore: credentials
        )
        let clientDirectory = fixture.root.appendingPathComponent("client", isDirectory: true)
        let enabled = try await ingress.enable(clientDirectory: clientDirectory)
        let connection = try #require(enabled.connection)
        #expect(connection != Self.first)
        #expect(enabled.grants.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(for: Self.first).path))
        #expect(try await fixture.store.connectionIDs() == [connection])
        let client = LocalAutomationClientCredentialCustody(directoryURL: clientDirectory)
        let clientBytes = try #require(try client.loadCredential())
        #expect(try await fixture.store.loadCredential(for: connection) == clientBytes)
        #expect(try await history.connections().filter { $0.enrollKind == .localAutomation }.map(\.id) == [connection])
    }
}
