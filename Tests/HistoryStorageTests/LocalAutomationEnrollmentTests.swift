import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct LocalAutomationEnrollmentTests {
    @Test func disabledStatusDoesNotRequireServerCustodyAccess() async throws {
        let fixture = try await fixture(credentials: CredentialStore(
            operations: EnrollmentCredentialOperations(refusesEnumeration: true)
        ))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let state = try await fixture.ingress.state(clientDirectory: fixture.directory)
        #expect(state.connection == nil)
        #expect(state.grants.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        await #expect(throws: CredentialStoreFailure.unavailable) {
            _ = try await fixture.ingress.enable(clientDirectory: fixture.directory)
        }
        #expect(try fixture.custody.loadCredential() == nil)
    }

    @Test func enablePublishesZeroGrantsAndRepeatedEnableKeepsTheCredential() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let disabled = try await fixture.ingress.state(clientDirectory: fixture.directory)
        #expect(disabled.connection == nil)
        let enabled = try await fixture.ingress.enable(clientDirectory: fixture.directory)
        let connection = try #require(enabled.connection)
        #expect(enabled.grants.isEmpty)
        let bytes = try #require(try fixture.custody.loadCredential())
        #expect(try await fixture.credentials.loadCredential(for: connection) == bytes)
        let reopenedCredentials = CredentialStore(directoryURL: fixture.serverDirectory)
        #expect(try await reopenedCredentials.loadCredential(for: connection) == bytes)
        let reopenedIngress = LocalAutomationIngress(
            authority: fixture.history.authority, gateway: fixture.history.externalGateway,
            credentialStore: reopenedCredentials
        )
        #expect(try await reopenedIngress.state(clientDirectory: fixture.directory) == enabled)
        #expect(try await fixture.ingress.enable(clientDirectory: fixture.directory) == enabled)
        #expect(try fixture.custody.loadCredential() == bytes)
        await #expect(throws: ExternalFailure.unauthorized(requestedCapability: .browsePreview, connectionID: connection)) {
            _ = try await fixture.ingress.execute(.recent(limit: 10, cursor: nil), presenting: bytes)
        }
    }

    @Test func grantsAreIndependentAndRevocationKeepsTheServerVerifier() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let enabled = try await fixture.ingress.enable(clientDirectory: fixture.directory)
        let connection = try #require(enabled.connection)
        let bytes = try #require(try fixture.custody.loadCredential())
        let capabilities: [ExternalCapability] = [.browsePreview, .readEffectiveContent, .organize, .deleteItem]
        for capability in capabilities {
            let granted = try await fixture.ingress.setCapability(
                capability, enabled: true, clientDirectory: fixture.directory
            )
            #expect(granted.grants == [capability])
            let withdrawn = try await fixture.ingress.setCapability(
                capability, enabled: false, clientDirectory: fixture.directory
            )
            #expect(withdrawn.grants.isEmpty)
        }
        _ = try await fixture.ingress.setCapability(.browsePreview, enabled: true, clientDirectory: fixture.directory)
        let revoked = try await fixture.ingress.revoke(clientDirectory: fixture.directory)
        #expect(revoked.connection == nil)
        #expect(try fixture.custody.loadCredential() == nil)
        #expect(try await fixture.credentials.loadCredential(for: connection) == bytes)
        #expect(try await fixture.history.grants(for: connection).allSatisfy { $0.revokedAt != nil })
        await #expect(throws: ExternalFailure.connectionRevoked(connectionID: connection)) {
            _ = try await fixture.ingress.execute(.recent(limit: 10, cursor: nil), presenting: bytes)
        }
        // A second actor reads the surviving verifier from disk after the
        // client file is gone. Authentication preserves the durable ID so
        // the actual Gateway still publishes the truthful revoked outcome.
        let reopenedCredentials = CredentialStore(directoryURL: fixture.serverDirectory)
        let reopenedAuthenticator = LocalAutomationCredentialAuthenticator(
            credentialStore: reopenedCredentials, authority: fixture.history.authority
        )
        #expect(try await reopenedAuthenticator.authenticate(bytes) == connection)
        let reopenedIngress = LocalAutomationIngress(
            authority: fixture.history.authority, gateway: fixture.history.externalGateway,
            credentialStore: reopenedCredentials
        )
        await #expect(throws: ExternalFailure.connectionRevoked(connectionID: connection)) {
            _ = try await reopenedIngress.execute(.recent(limit: 10, cursor: nil), presenting: bytes)
        }
        let reenrolled = try await fixture.ingress.enable(clientDirectory: fixture.directory)
        #expect(reenrolled.connection != connection)
        #expect(reenrolled.grants.isEmpty)
        #expect(try await reopenedCredentials.loadCredential(for: connection) == bytes)
    }

    @Test(arguments: [false, true])
    func failedServerCustodyNeverPublishesAndRemovesClientCopy(missingReadback: Bool) async throws {
        let credentials = CredentialStore(operations: EnrollmentCredentialOperations(
            refusesAdd: !missingReadback, hidesReadback: missingReadback
        ))
        let fixture = try await fixture(credentials: credentials)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.ingress.enable(clientDirectory: fixture.directory)
        }
        #expect(try await fixture.history.connections().allSatisfy { $0.enrollKind != .localAutomation })
        #expect(try fixture.custody.loadCredential() == nil)
        #expect(try await credentials.connectionIDs().isEmpty)
    }

    @Test func enableRemovesPowerlessServerOrphansEvenWithoutAClientFile() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let retained = try await fixture.ingress.enable(clientDirectory: fixture.directory)
        let retainedID = try #require(retained.connection)
        let retainedBytes = try #require(try fixture.custody.loadCredential())
        _ = try await fixture.ingress.revoke(clientDirectory: fixture.directory)
        let orphan = ExternalConnectionID(rawValue: UUID())
        let bytes = try LocalAutomationCredential(connection: orphan, secret: Data(repeating: 1, count: 32)).exactBytes
        try await fixture.credentials.storeCredential(bytes, for: orphan)
        #expect(try fixture.custody.loadCredential() == nil)
        #expect(try await fixture.ingress.state(clientDirectory: fixture.directory).connection == nil)
        let enabled = try await fixture.ingress.enable(clientDirectory: fixture.directory)
        #expect(enabled.connection != orphan)
        #expect(try await fixture.credentials.loadCredential(for: orphan) == nil)
        #expect(enabled.grants.isEmpty)
        let reopenedCredentials = CredentialStore(directoryURL: fixture.serverDirectory)
        #expect(try await reopenedCredentials.loadCredential(for: retainedID) == retainedBytes)
        let enabledID = try #require(enabled.connection)
        #expect(Set(try await reopenedCredentials.connectionIDs()) == [retainedID, enabledID])
        #expect(try await fixture.history.connections().first { $0.id == retainedID }?.status == .revoked)
    }

    @Test func lostClientFileCanStillRevokeDurableAccess() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let enabled = try await fixture.ingress.enable(clientDirectory: fixture.directory)
        let connection = try #require(enabled.connection)
        #expect(fixture.custody.removeCredential())
        await #expect(throws: LocalAutomationEnrollmentFailure.self) {
            _ = try await fixture.ingress.state(clientDirectory: fixture.directory)
        }
        let revoked = try await fixture.ingress.revoke(clientDirectory: fixture.directory)
        #expect(revoked.connection == nil)
        #expect(try await fixture.history.connections().first { $0.id == connection }?.status == .revoked)
    }

    @Test func clientCleanupFailureCannotUndoRevocation() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let enabled = try await fixture.ingress.enable(clientDirectory: fixture.directory)
        let connection = try #require(enabled.connection)
        let bytes = try #require(try fixture.custody.loadCredential())
        try FileManager.default.removeItem(at: fixture.custody.credentialFileURL)
        try FileManager.default.createDirectory(at: fixture.custody.credentialFileURL, withIntermediateDirectories: false)
        let revoked = try await fixture.ingress.revoke(clientDirectory: fixture.directory)
        #expect(revoked.connection == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.custody.credentialFileURL.path))
        await #expect(throws: ExternalFailure.connectionRevoked(connectionID: connection)) {
            _ = try await fixture.ingress.execute(.recent(limit: 10, cursor: nil), presenting: bytes)
        }
    }

    private struct Fixture {
        let history: SwiftDataHistory
        let credentials: CredentialStore
        let ingress: LocalAutomationIngress
        let root: URL
        var directory: URL { root.appendingPathComponent("LocalAutomation") }
        var serverDirectory: URL { root.appendingPathComponent("ServerCredentials") }
        var custody: LocalAutomationClientCredentialCustody { .init(directoryURL: directory) }
    }

    private func fixture(credentials: CredentialStore? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = try await SwiftDataHistory.open(configuration: HistoryConfiguration(persistence: .memory))
        let credentials = credentials ?? CredentialStore(directoryURL: root.appendingPathComponent("ServerCredentials"))
        return Fixture(
            history: history, credentials: credentials,
            ingress: LocalAutomationIngress(authority: history.authority, gateway: history.externalGateway, credentialStore: credentials),
            root: root
        )
    }
}

/// Fault injection only: successful custody uses the real private files.
/// Every durable connection, grant, denial and revoke uses HistoryAuthority.
private struct EnrollmentCredentialOperations: CredentialStoreExternalOperations {
    var values: [ExternalConnectionID: Data] = [:]
    var refusesAdd = false
    var hidesReadback = false
    var refusesEnumeration = false

    func connectionIDs() throws -> [ExternalConnectionID] {
        if refusesEnumeration { throw CredentialStoreFailure.unavailable }
        return Array(values.keys)
    }

    mutating func addCredential(_ data: Data, for connection: ExternalConnectionID) -> CredentialStoreAddResult {
        if refusesAdd { return .unavailable }
        guard values[connection] == nil else { return .duplicate }
        values[connection] = data
        return .stored
    }

    func copyCredential(for connection: ExternalConnectionID) -> CredentialStoreCopyResult {
        if hidesReadback { return .missing }
        return values[connection].map(CredentialStoreCopyResult.value) ?? .missing
    }

    mutating func deleteCredential(for connection: ExternalConnectionID) -> CredentialStoreDeleteResult {
        values.removeValue(forKey: connection)
        return .deletedOrMissing
    }
}
