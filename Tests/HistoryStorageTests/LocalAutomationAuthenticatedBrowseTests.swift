/// F1 server-side vertical proofs from exact credential authentication into
/// the unique Gateway's `.browsePreview` read lane. No ingress, transport,
/// peer identity, client file, or wire result is constructed here.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Local Automation authenticated browse", .serialized)
struct LocalAutomationAuthenticatedBrowseTests {
    private static let connection = ExternalConnectionID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000003902"
    )!)
    private static let secret = Data((0..<32).map { UInt8(0x40 + $0) })
    private static let capturedText = "batch39-authenticated-browse-sentinel"

    private struct Fixture {
        let history: SwiftDataHistory
        let container: ModelContainer
        let credential: LocalAutomationCredential
        let browse: LocalAutomationAuthenticatedBrowse
    }

    @Test("exact granted credential reads recent and search as browse preview")
    func exactCredentialUsesTheUniqueGatewayReadAndAuditLane() async throws {
        let fixture = try await Self.makeFixture(granted: true)
        let before = try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        )

        let recent = try #require(try await fixture.browse.browsePreview(
            .recent(limit: 10),
            presenting: fixture.credential.exactBytes
        ))
        let search = try #require(try await fixture.browse.browsePreview(
            .search(text: "authenticated-browse", mode: .exact, limit: 10),
            presenting: fixture.credential.exactBytes
        ))

        #expect(recent.rows.contains { $0.title == Self.capturedText })
        #expect(search.rows.contains { $0.title == Self.capturedText })

        let after = try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        )
        let appended = after.operations.suffix(
            after.operations.count - before.operations.count
        )
        #expect(appended.count == 2)
        #expect(appended.allSatisfy {
            $0.connectionIDRaw == Self.connection.rawValue
                && $0.capabilityRaw
                    == ExternalCapability.browsePreview.rawValue
                && $0.outcomeRaw == ExternalOutcome.succeeded.rawValue
                && $0.failureKindRaw == nil
                && $0.changePositionRaw == nil
        })
        #expect(appended.map(\.operationKindRaw) == [
            ExternalOperationKind.readRecent.rawValue,
            ExternalOperationKind.readSearch.rawValue,
        ])
        let operations = Array(appended)
        #expect(try Self.decodedPayload(
            operations[0],
            snapshot: after
        ) == OperationPayloadBlobV1(
            request: .recent(limit: 10),
            result: .page(returnedCount: 1, hasMore: false)
        ))
        #expect(try Self.decodedPayload(
            operations[1],
            snapshot: after
        ) == OperationPayloadBlobV1(
            request: .search(
                queryUTF8ByteCount: 20,
                mode: .exact,
                limit: 10
            ),
            result: .page(returnedCount: 1, hasMore: false)
        ))
    }

    @Test("wrong credential stops unaudited while exact no-grant is audited")
    func authenticationAndGatewayAuthorizationStayDistinct() async throws {
        let fixture = try await Self.makeFixture(granted: false)
        let before = try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        )
        var wrong = fixture.credential.exactBytes
        wrong[LocalAutomationCredential.byteCount - 1] ^= 0x01

        #expect(try await fixture.browse.browsePreview(
            .recent(limit: 1),
            presenting: wrong
        ) == nil)
        #expect(try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        ) == before)

        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .browsePreview,
            connectionID: Self.connection
        )) {
            _ = try await fixture.browse.browsePreview(
                .recent(limit: 1),
                presenting: fixture.credential.exactBytes
            )
        }

        let after = try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        )
        #expect(after.operations.dropLast() == before.operations[...])
        let denial = try #require(after.operations.last)
        #expect(denial.connectionIDRaw == Self.connection.rawValue)
        #expect(denial.capabilityRaw
            == ExternalCapability.browsePreview.rawValue)
        #expect(denial.operationKindRaw
            == ExternalOperationKind.readRecent.rawValue)
        #expect(denial.outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(denial.failureKindRaw
            == ExternalFailureKindRaw.unauthorized.rawValue)
        #expect(denial.denialReasonRaw == nil)
        #expect(denial.changePositionRaw == nil)
        #expect(try Self.decodedPayload(denial, snapshot: after)
            == OperationPayloadBlobV1(
                request: .recent(limit: 1),
                result: .none
            ))
    }

    @Test("retained server credential reaches audited revoked outcome")
    func revokedCredentialStillResolvesBeforeTheLiveGatewayGate() async throws {
        let fixture = try await Self.makeFixture(granted: true)
        try await fixture.history.revokeConnection(Self.connection)
        let before = try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        )

        await #expect(throws: ExternalFailure.connectionRevoked(
            connectionID: Self.connection
        )) {
            _ = try await fixture.browse.browsePreview(
                .recent(limit: 1),
                presenting: fixture.credential.exactBytes
            )
        }

        let after = try GatewayStoreSnapshot.read(
            in: ModelContext(fixture.container)
        )
        #expect(after.operations.dropLast() == before.operations[...])
        let denial = try #require(after.operations.last)
        #expect(denial.connectionIDRaw == Self.connection.rawValue)
        #expect(denial.capabilityRaw
            == ExternalCapability.browsePreview.rawValue)
        #expect(denial.operationKindRaw
            == ExternalOperationKind.readRecent.rawValue)
        #expect(denial.outcomeRaw == ExternalOutcome.denied.rawValue)
        #expect(denial.failureKindRaw
            == ExternalFailureKindRaw.connectionRevoked.rawValue)
        #expect(denial.denialReasonRaw == nil)
        #expect(denial.changePositionRaw == nil)
        #expect(try Self.decodedPayload(denial, snapshot: after)
            == OperationPayloadBlobV1(
                request: .recent(limit: 1),
                result: .none
            ))
    }

    private static func makeFixture(granted: Bool) async throws -> Fixture {
        let history = try await SwiftDataHistory.open(configuration:
            HistoryConfiguration(persistence: .memory)
        )
        let authority = history.authority
        try await authority.publishVerifiedLocalAutomationEnrollment(
            connection,
            displayName: "Authenticated browse fixture"
        )
        if granted {
            try await history.grantCapability(
                .browsePreview,
                to: connection
            )
        }
        _ = try await history.perform(.capture(WSSupport.textCapture(
            capturedText,
            observedAt: Date(timeIntervalSinceReferenceDate: 939_000_000)
        )))
        let credential = try LocalAutomationCredential(
            connection: connection,
            secret: secret
        )
        let store = CredentialStore(operations:
            AuthenticatedBrowseMemoryCredentialOperations(values: [
                connection: credential.exactBytes,
            ])
        )
        let authenticator = LocalAutomationCredentialAuthenticator(
            credentialStore: store,
            authority: authority
        )
        return Fixture(
            history: history,
            container: await authority.container,
            credential: credential,
            browse: LocalAutomationAuthenticatedBrowse(
                authenticator: authenticator,
                gateway: history.externalGateway
            )
        )
    }

    private static func decodedPayload(
        _ operation: GatewayStoreSnapshot.Operation,
        snapshot: GatewayStoreSnapshot
    ) throws -> OperationPayloadBlobV1 {
        try OperationPayloadBlobCodec.decode(
            operation.payloadBlob,
            context: OperationPayloadRecordContextV1(
                connectionID: operation.connectionIDRaw,
                capability: operation.capabilityRaw.flatMap(
                    ExternalCapability.init(rawValue:)
                ),
                operationKind: try #require(ExternalOperationKind(
                    rawValue: operation.operationKindRaw
                )),
                outcome: try #require(ExternalOutcome(
                    rawValue: operation.outcomeRaw
                )),
                failureKind: operation.failureKindRaw.flatMap(
                    ExternalFailureKindRaw.init(rawValue:)
                ),
                denialReason: operation.denialReasonRaw.flatMap(
                    ExternalDenialReason.init(rawValue:)
                ),
                changePosition: operation.changePositionRaw,
                auditSequence: operation.auditSequence,
                compactionFloor: snapshot.configs.first?.compactionFloor,
                nextAuditSequence: snapshot.configs.first?.nextAuditSequence
            )
        )
    }
}

private struct AuthenticatedBrowseMemoryCredentialOperations:
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
