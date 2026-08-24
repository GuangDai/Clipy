/// F1 credential-kind isolation proof (`V2-05` §0.2/§0.3).
/// Exact custody bytes do not let the durable App Intents bootstrap identity
/// cross into Local Automation, and rejection remains before Gateway audit.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Local Automation credential kind isolation")
struct LocalAutomationCredentialKindIsolationTests {
    private static let appIntentsID = ExternalConnectionID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000004305"
    )!)

    @Test("exact App Intents bytes cannot authenticate as Local Automation")
    func appIntentsCredentialRejectsWithoutGatewayEffects() async throws {
        let schema = Schema(versionedSchema: HistorySchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
        let authority = HistoryAuthority(
            container: container,
            gatewayConnectionIDSource: { Self.appIntentsID.rawValue }
        )
        try await authority.performStartup(initialMaximumUnpinnedItems: 200)

        let credential = try LocalAutomationCredential(
            connection: Self.appIntentsID,
            secret: Data((0..<32).map { UInt8($0) })
        )
        #expect(credential.exactBytes.count == LocalAutomationCredential.byteCount)

        let authenticator = LocalAutomationCredentialAuthenticator(
            credentialStore: CredentialStore(
                operations: KindIsolationCredentialOperations(values: [
                    Self.appIntentsID: credential.exactBytes,
                ])
            ),
            authority: authority
        )
        let before = try GatewayStoreSnapshot.read(
            in: ModelContext(container)
        )
        try before.expectX3DenyByDefaultBootstrap()

        #expect(try await authenticator.authenticate(
            credential.exactBytes
        ) == nil)
        #expect(try GatewayStoreSnapshot.read(
            in: ModelContext(container)
        ) == before)
    }
}

private struct KindIsolationCredentialOperations:
    CredentialStoreExternalOperations
{
    private var values: [ExternalConnectionID: Data]

    init(values: [ExternalConnectionID: Data]) {
        self.values = values
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
        values[connection].map(CredentialStoreCopyResult.value) ?? .missing
    }

    mutating func deleteCredential(
        for connection: ExternalConnectionID
    ) -> CredentialStoreDeleteResult {
        values.removeValue(forKey: connection)
        return .deletedOrMissing
    }
}
