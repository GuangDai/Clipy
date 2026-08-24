/// F1 in-process authentication kernel proofs. These use real V4 Authority
/// state and an injected in-memory Keychain boundary; no transport, peer
/// credential, signed Keychain profile, or Gateway result is claimed.
import Foundation
import HistoryCore
import SwiftData
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
        let container: ModelContainer
        let credential: LocalAutomationCredential
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
        let schema = Schema(versionedSchema: HistorySchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
        let identifiers = UUIDSource([appIntentsID])
        let authority = HistoryAuthority(
            container: container,
            gatewayConnectionIDSource: { identifiers.next() }
        )
        try await authority.performStartup(initialMaximumUnpinnedItems: 200)
        if enroll {
            try await authority.publishVerifiedLocalAutomationEnrollment(
                connection,
                displayName: "Authentication fixture"
            )
        }
        return Fixture(
            authority: authority,
            container: container,
            credential: try LocalAutomationCredential(
                connection: connection,
                secret: secret
            )
        )
    }

    private static func authenticator(
        _ fixture: Fixture,
        storedBytes: Data?
    ) -> LocalAutomationCredentialAuthenticator {
        let values = storedBytes.map { [Self.connection: $0] } ?? [:]
        return LocalAutomationCredentialAuthenticator(
            credentialStore: CredentialStore(
                operations: AuthenticationMemoryCredentialOperations(
                    values: values
                )
            ),
            authority: fixture.authority
        )
    }

    @Test("exact active and revoked credentials retain the durable ID")
    func exactActiveAndRevokedCredentialsAuthenticateWithoutAudit() async throws {
        let fixture = try await Self.makeFixture()
        let authenticator = Self.authenticator(
            fixture,
            storedBytes: fixture.credential.exactBytes
        )
        let before = try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        )

        #expect(try await authenticator.authenticate(
            fixture.credential.exactBytes
        ) == Self.connection)
        #expect(try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        ) == before)

        try await fixture.authority.revokeConnection(Self.connection)
        let revokedBefore = try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        )
        #expect(try await authenticator.authenticate(
            fixture.credential.exactBytes
        ) == Self.connection)
        #expect(try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        ) == revokedBefore)
    }

    @Test("malformed, missing, wrong, and orphan credentials reject unaudited")
    func rejectedPresentationsNeverReachGatewayOrAudit() async throws {
        let fixture = try await Self.makeFixture()
        let exact = fixture.credential.exactBytes
        let missing = Self.authenticator(fixture, storedBytes: nil)
        let wrong = Self.authenticator(fixture, storedBytes: exact)
        var wrongBytes = exact
        wrongBytes[LocalAutomationCredential.byteCount - 1] ^= 0x01
        let before = try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        )

        #expect(try await missing.authenticate(exact) == nil)
        #expect(try await wrong.authenticate(Data(exact.dropLast())) == nil)
        #expect(try await wrong.authenticate(wrongBytes) == nil)
        #expect(try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        ) == before)

        let orphan = try await Self.makeFixture(enroll: false)
        let orphanAuthenticator = Self.authenticator(
            orphan,
            storedBytes: orphan.credential.exactBytes
        )
        let orphanBefore = try GatewayStoreSnapshot.read(
            in: ModelContext(orphan.container)
        )
        #expect(try await orphanAuthenticator.authenticate(
            orphan.credential.exactBytes
        ) == nil)
        #expect(try GatewayStoreSnapshot.read(
            in: ModelContext(orphan.container)
        ) == orphanBefore)
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
        let corrupt = Self.authenticator(
            fixture,
            storedBytes: Data(fixture.credential.exactBytes.dropLast())
        )
        let unavailable = LocalAutomationCredentialAuthenticator(
            credentialStore: CredentialStore(
                operations: AuthenticationMemoryCredentialOperations(
                    forcedCopyResult: .unavailable
                )
            ),
            authority: fixture.authority
        )
        let before = try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        )

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
        #expect(try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        ) == before)
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
        values[connection].map(CredentialStoreCopyResult.value) ?? .missing
    }

    mutating func deleteCredential(
        for connection: ExternalConnectionID
    ) -> CredentialStoreDeleteResult {
        values.removeValue(forKey: connection)
        return .deletedOrMissing
    }
}
