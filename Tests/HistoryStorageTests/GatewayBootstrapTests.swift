/// X.3 Gateway bootstrap proof (`V2-roadmap` §10 X.3; `V2-05` §4.6).
///
/// The production seam is persistent `SwiftDataHistory.open`: a first open
/// must durably publish one deny-by-default App Intents connection together
/// with its config singleton, and a reopen must preserve that one-time
/// identity. Corruption fixtures are installed through an independent V3
/// container; after the public reopen rejects them, a second independent
/// container supplies the durable before/after oracle. The oracle proves no
/// repair was committed. It does not claim that SwiftData attempted no work.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Gateway bootstrap (X.3)")
struct GatewayBootstrapTests {
    private static let injectedConnectionID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000503"
    )!

    private struct FixedStorageClock: StorageClock {
        let fixed: Date

        init(_ fixed: Date) {
            self.fixed = fixed
        }

        func now() -> Date { fixed }
    }

    private enum Damage: CaseIterable {
        case missingConfigWithConnection
        case missingConfigWithOrphanGrant
        case missingConfigWithOrphanOperation
        case wrongConfigKey
        case extraConfig
        case configVersion
        case nextAuditSequence
        case auditBytes
        case compactionFloor
        case missingConnection
        case extraConnection
        case mismatchedConnectionIdentity
        case knownWrongEnrollKind
        case unknownEnrollKind
        case knownWrongStatus
        case unknownStatus
        case activeConnectionWithRevokedAt
        case displayNameMismatch
        case oversizedDisplayName
        case connectionVersion
        case grantPresent
        case operationPresent

        var expectedFailure: HistoryFailure {
            switch self {
            case .configVersion, .unknownEnrollKind, .unknownStatus,
                    .connectionVersion:
                return .persistence(.corruptStoredValue)
            default:
                return .persistence(.invariantViolation)
            }
        }

        var label: String { String(describing: self) }
    }

    private static func makePersistentContainer(
        at storeURL: URL
    ) throws -> ModelContainer {
        let schema = Schema(versionedSchema: HistorySchemaV3.self)
        return try ModelContainer(
            for: schema,
            migrationPlan: HistoryMigrationPlan.self,
            configurations: [ModelConfiguration(
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )]
        )
    }

    private static func openPublicly(at storeURL: URL) async throws {
        _ = try await SwiftDataHistory.open(configuration: HistoryConfiguration(
            persistence: .persistent(storeURL: storeURL),
            initialMaximumUnpinnedItems: 321
        ))
    }

    private static func insertGrant(
        in context: ModelContext,
        connectionID: UUID
    ) {
        context.insert(GrantRow(
            grantKey: "\(connectionID.uuidString):1",
            connectionIDRaw: connectionID,
            capabilityRaw: ExternalCapability.browse.rawValue,
            grantedAt: Date(timeIntervalSinceReferenceDate: 800_000_100),
            revokedAt: nil,
            configSchemaVersion: 1
        ))
    }

    private static func insertOperation(
        in context: ModelContext,
        connectionID: UUID
    ) {
        let timestamp = Date(timeIntervalSinceReferenceDate: 800_000_101)
        context.insert(OperationRecordRow(
            auditSequence: 1,
            connectionIDRaw: connectionID,
            capabilityRaw: ExternalCapability.browse.rawValue,
            operationKindRaw: ExternalOperationKind.readRecent.rawValue,
            outcomeRaw: 1,
            failureKindRaw: nil,
            denialReasonRaw: nil,
            payloadBlob: Data([0x01]),
            requestedAt: timestamp,
            committedAt: timestamp,
            changePositionRaw: nil,
            auditSchemaVersion: 1
        ))
    }

    private static func damage(_ damage: Damage, at storeURL: URL) throws {
        let context = ModelContext(try makePersistentContainer(at: storeURL))
        context.autosaveEnabled = false
        let config = try #require(
            context.fetch(FetchDescriptor<GatewayConfigRow>()).first
        )
        let connection = try #require(
            context.fetch(FetchDescriptor<ConnectionRow>()).first
        )
        let connectionID = connection.id

        switch damage {
        case .missingConfigWithConnection:
            context.delete(config)
        case .missingConfigWithOrphanGrant:
            context.delete(config)
            context.delete(connection)
            insertGrant(in: context, connectionID: connectionID)
        case .missingConfigWithOrphanOperation:
            context.delete(config)
            context.delete(connection)
            insertOperation(in: context, connectionID: connectionID)
        case .wrongConfigKey:
            config.key = "wrong-gateway"
        case .extraConfig:
            context.insert(GatewayConfigRow(
                key: "extra-gateway",
                appIntentsConnectionID: UUID(),
                nextAuditSequence: 1,
                auditBytes: 0,
                compactionFloor: 1,
                configSchemaVersion: 1
            ))
        case .configVersion:
            config.configSchemaVersion = 2
        case .nextAuditSequence:
            config.nextAuditSequence = 2
        case .auditBytes:
            config.auditBytes = 1
        case .compactionFloor:
            config.compactionFloor = 0
        case .missingConnection:
            context.delete(connection)
        case .extraConnection:
            context.insert(ConnectionRow(
                id: UUID(),
                displayNameRaw: "extra",
                enrollKindRaw: ConnectionEnrollKind.localAutomation.rawValue,
                statusRaw: ConnectionStatus.active.rawValue,
                enrolledAt: connection.enrolledAt,
                revokedAt: nil,
                configSchemaVersion: 1
            ))
        case .mismatchedConnectionIdentity:
            config.appIntentsConnectionID = UUID()
        case .knownWrongEnrollKind:
            connection.enrollKindRaw = ConnectionEnrollKind.localAutomation.rawValue
        case .unknownEnrollKind:
            connection.enrollKindRaw = 0
        case .knownWrongStatus:
            connection.statusRaw = ConnectionStatus.revoked.rawValue
            connection.revokedAt = connection.enrolledAt
        case .unknownStatus:
            connection.statusRaw = 0
        case .activeConnectionWithRevokedAt:
            connection.revokedAt = connection.enrolledAt
        case .displayNameMismatch:
            connection.displayNameRaw = "Shortcuts"
        case .oversizedDisplayName:
            connection.displayNameRaw = String(repeating: "a", count: 257)
        case .connectionVersion:
            connection.configSchemaVersion = 2
        case .grantPresent:
            insertGrant(in: context, connectionID: connection.id)
        case .operationPresent:
            insertOperation(in: context, connectionID: connection.id)
        }
        try context.save()
    }

    @Test("first public open atomically bootstraps deny-by-default state and reopen preserves it")
    func firstOpenBootstrapsAndReopenPreservesIdentity() async throws {
        let storeURL = WSSupport.tempStoreURL("gateway-bootstrap-public")
        defer { WSSupport.removeStore(storeURL) }

        try await Self.openPublicly(at: storeURL)
        let first = try GatewayStoreSnapshot.read(from: storeURL)
        try first.expectX3DenyByDefaultBootstrap()

        try await Self.openPublicly(at: storeURL)
        #expect(try GatewayStoreSnapshot.read(from: storeURL) == first)
    }

    @Test("internal UUID source makes the one-time durable identity deterministic")
    func internalUUIDSourceIsDeterministic() async throws {
        let expectedConnectionID = Self.injectedConnectionID
        let schema = Schema(versionedSchema: HistorySchemaV3.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
        let expectedEnrolledAt = Date(
            timeIntervalSinceReferenceDate: 800_000_000
        )
        let authority = HistoryAuthority(
            container: container,
            storageClock: FixedStorageClock(expectedEnrolledAt),
            gatewayConnectionIDSource: { expectedConnectionID }
        )

        try await authority.performStartup(initialMaximumUnpinnedItems: 321)

        let context = ModelContext(container)
        let config = try #require(
            context.fetch(FetchDescriptor<GatewayConfigRow>()).first
        )
        let connection = try #require(
            context.fetch(FetchDescriptor<ConnectionRow>()).first
        )
        #expect(config.appIntentsConnectionID == expectedConnectionID)
        #expect(connection.id == expectedConnectionID)
        #expect(connection.enrolledAt == expectedEnrolledAt)
    }

    @Test("every malformed bootstrap relation fails closed without durable repair")
    func malformedBootstrapRelationsFailClosedWithoutRepair() async throws {
        for damage in Damage.allCases {
            let storeURL = WSSupport.tempStoreURL(
                "gateway-bootstrap-\(damage.label)"
            )
            defer { WSSupport.removeStore(storeURL) }
            try await Self.openPublicly(at: storeURL)
            try Self.damage(damage, at: storeURL)
            let before = try GatewayStoreSnapshot.read(from: storeURL)

            do {
                try await Self.openPublicly(at: storeURL)
                Issue.record("expected public open to reject \(damage.label)")
            } catch let failure as HistoryFailure {
                #expect(failure == damage.expectedFailure)
            } catch {
                Issue.record("unexpected error for \(damage.label): \(error)")
            }

            #expect(try GatewayStoreSnapshot.read(from: storeURL) == before)
        }
    }
}
