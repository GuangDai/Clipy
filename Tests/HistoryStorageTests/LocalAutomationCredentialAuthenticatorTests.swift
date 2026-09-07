/// F1 in-process authentication proofs using real current Authority state and
/// private server credential files. Only explicit custody failures are injected.
import Foundation
import HistoryCore
import Synchronization
import Testing
@testable import HistoryStorage

@Suite("Local Automation credential authentication kernel (F1)")
struct LocalAutomationCredentialAuthenticatorTests {
    private static let appIntentsID = UUID(
        uuidString: "00000000-0000-0000-0000-00000000A361"
    )!
    private static let connection = ExternalConnectionID(rawValue: UUID(
        uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"
    )!)
    private static let secret = Data((0..<32).map { UInt8(0x80 + $0) })

    private struct Fixture {
        let authority: HistoryAuthority
        let credential: LocalAutomationCredential
        let credentials: CredentialStore
        let root: URL
        var serverDirectory: URL { root.appendingPathComponent("ServerCredentials") }
    }

    private final class UUIDSource: Sendable {
        private let values: Mutex<[UUID]>

        init(_ values: [UUID]) {
            self.values = Mutex(values)
        }

        func next() -> UUID {
            values.withLock { $0.removeFirst() }
        }
    }

    private static func makeFixture(
        enroll: Bool = true
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identifiers = UUIDSource([appIntentsID])
        let authority = try HistoryAuthority(
            storeLocation: try HistoryStoreLocation(persistence: .temporary),
            gatewayConnectionIDSource: { identifiers.next() }
        )
        try await authority.performStartup(initialMaximumUnpinnedItems: 200)
        if enroll {
            try await authority.publishVerifiedLocalAutomationEnrollment(
                connection,
                displayName: "Authentication fixture"
            )
        }
        let credential = try LocalAutomationCredential(connection: connection, secret: secret)
        let credentials = CredentialStore(directoryURL: root.appendingPathComponent("ServerCredentials"))
        try await credentials.storeCredential(credential.exactBytes, for: connection)
        return Fixture(
            authority: authority,
            credential: credential, credentials: credentials, root: root
        )
    }

    private static func authenticator(
        _ fixture: Fixture,
        credentials: CredentialStore? = nil
    ) -> LocalAutomationCredentialAuthenticator {
        LocalAutomationCredentialAuthenticator(
            credentialStore: credentials ?? fixture.credentials,
            authority: fixture.authority
        )
    }

    @Test("exact active and revoked credentials retain the durable ID")
    func exactActiveAndRevokedCredentialsAuthenticateWithoutAudit() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let authenticator = Self.authenticator(fixture)
        let before = try await GatewayStoreSnapshot.read(from: fixture.authority)

        #expect(try await authenticator.authenticate(
            fixture.credential.exactBytes
        ) == Self.connection)
        #expect(try await GatewayStoreSnapshot.read(from: fixture.authority) == before)

        try await fixture.authority.revokeConnection(Self.connection)
        let revokedBefore = try await GatewayStoreSnapshot.read(from: fixture.authority)
        #expect(try await authenticator.authenticate(
            fixture.credential.exactBytes
        ) == Self.connection)
        #expect(try await GatewayStoreSnapshot.read(from: fixture.authority) == revokedBefore)
        let reopenedCredentials = CredentialStore(directoryURL: fixture.serverDirectory)
        #expect(try await reopenedCredentials.loadCredential(for: Self.connection) == fixture.credential.exactBytes)
        let reopenedAuthenticator = Self.authenticator(fixture, credentials: reopenedCredentials)
        #expect(try await reopenedAuthenticator.authenticate(fixture.credential.exactBytes) == Self.connection)
        #expect(try await GatewayStoreSnapshot.read(from: fixture.authority) == revokedBefore)
    }

    @Test("malformed, missing, wrong, and orphan credentials reject unaudited")
    func rejectedPresentationsNeverReachGatewayOrAudit() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exact = fixture.credential.exactBytes
        let missing = Self.authenticator(fixture, credentials: CredentialStore(
            directoryURL: fixture.root.appendingPathComponent("MissingCredentials")
        ))
        let wrong = Self.authenticator(fixture)
        var wrongBytes = exact
        wrongBytes[LocalAutomationCredential.byteCount - 1] ^= 0x01
        let before = try await GatewayStoreSnapshot.read(from: fixture.authority)

        #expect(try await missing.authenticate(exact) == nil)
        #expect(try await wrong.authenticate(Data(exact.dropLast())) == nil)
        #expect(try await wrong.authenticate(wrongBytes) == nil)
        #expect(try await GatewayStoreSnapshot.read(from: fixture.authority) == before)

        let orphan = try await Self.makeFixture(enroll: false)
        defer { try? FileManager.default.removeItem(at: orphan.root) }
        let orphanAuthenticator = Self.authenticator(orphan)
        let orphanBefore = try await GatewayStoreSnapshot.read(from: orphan.authority)
        #expect(try await orphanAuthenticator.authenticate(
            orphan.credential.exactBytes
        ) == nil)
        #expect(try await GatewayStoreSnapshot.read(from: orphan.authority) == orphanBefore)
    }

    @Test("fixed traversal rejects a difference at every secret edge")
    func fixedTraversalComparisonRejectsSecretDifferences() throws {
        let exact = try LocalAutomationCredential(
            connection: Self.connection,
            secret: Self.secret
        ).exactBytes
        #expect(LocalAutomationCredentialComparison.matches(exact, exact))
        for index in [16, 31, 47] {
            var changed = exact
            changed[index] ^= 0x01
            #expect(!LocalAutomationCredentialComparison.matches(
                exact,
                changed
            ))
        }
        #expect(!LocalAutomationCredentialComparison.matches(
            exact,
            Data(exact.dropLast())
        ))
    }

    @Test("server custody failures stay typed and unaudited")
    func serverCustodyFailuresNeverBecomeAuthenticationDenials() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let corrupt = Self.authenticator(
            fixture,
            credentials: CredentialStore(operations: AuthenticationMemoryCredentialOperations(
                values: [Self.connection: Data(fixture.credential.exactBytes.dropLast())]
            ))
        )
        let unavailable = LocalAutomationCredentialAuthenticator(
            credentialStore: CredentialStore(
                operations: AuthenticationMemoryCredentialOperations(
                    forcedCopyResult: .unavailable
                )
            ),
            authority: fixture.authority
        )
        let before = try await GatewayStoreSnapshot.read(from: fixture.authority)

        await #expect(throws: CredentialStoreFailure.corruptStoredValue) {
            _ = try await corrupt.authenticate(
                fixture.credential.exactBytes
            )
        }
        await #expect(throws: CredentialStoreFailure.unavailable) {
            _ = try await unavailable.authenticate(
                fixture.credential.exactBytes
            )
        }
        #expect(try await GatewayStoreSnapshot.read(from: fixture.authority) == before)
    }
}

private struct AuthenticationMemoryCredentialOperations:
    CredentialStoreExternalOperations
{
    private var values: [ExternalConnectionID: Data]
    private let forcedCopyResult: CredentialStoreCopyResult?

    init(
        values: [ExternalConnectionID: Data] = [:],
        forcedCopyResult: CredentialStoreCopyResult? = nil
    ) {
        self.values = values
        self.forcedCopyResult = forcedCopyResult
    }

    func connectionIDs() throws -> [ExternalConnectionID] {
        Array(values.keys)
    }

    mutating func addCredential(
        _ data: Data,
        for connection: ExternalConnectionID
    ) -> CredentialStoreAddResult {
        guard values[connection] == nil else { return .duplicate }
        values[connection] = data
        return .stored
    }

    mutating func copyCredential(
        for connection: ExternalConnectionID
    ) -> CredentialStoreCopyResult {
        if let forcedCopyResult { return forcedCopyResult }
        return values[connection].map(CredentialStoreCopyResult.value)
            ?? .missing
    }

    mutating func deleteCredential(
        for connection: ExternalConnectionID
    ) -> CredentialStoreDeleteResult {
        values.removeValue(forKey: connection)
        return .deletedOrMissing
    }
}
