/// X.3 Gateway bootstrap proof through the persistent SQLiteHistory seam.
/// Corrupt fixtures use an Authority-owned connection without running startup;
/// independent read-only snapshots prove rejected reopen commits no repair.
import Foundation
import HistoryCore
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

    private enum Damage: CaseIterable, Sendable {
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
        case mismatchedConnectionIdentity
        case knownWrongEnrollKind
        case unknownEnrollKind
        case revokedConnectionWithoutRevokedAt
        case unknownStatus
        case activeConnectionWithRevokedAt
        case displayNameMismatch
        case oversizedDisplayName
        case connectionVersion
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

    private static func makeAuthority(at storeURL: URL) throws -> HistoryAuthority {
        try HistoryAuthority(storeLocation: HistoryStoreLocation(
            persistence: .persistent(storeURL: storeURL)
        ))
    }

    private static func openPublicly(at storeURL: URL) async throws {
        _ = try await SQLiteHistory.open(configuration: HistoryConfiguration(
            persistence: .persistent(storeURL: storeURL),
            initialMaximumUnpinnedItems: 321
        ))
    }

    private static func insertGrant(in database: SQLiteDatabase, connectionID: UUID) throws {
        try database.execute("""
            INSERT INTO grants
                (grantKey, connectionIDRaw, capabilityRaw, grantedAt, revokedAt, configSchemaVersion)
            VALUES (?, ?, ?, ?, NULL, 1)
            """, bindings: [
                .text("\(connectionID.uuidString):1"), .text(connectionID.uuidString),
                .integer(Int64(ExternalCapability.browse.rawValue)), .real(800_000_100)
            ])
    }

    private static func insertOperation(in database: SQLiteDatabase, connectionID: UUID) throws {
        try database.execute("""
            INSERT INTO operation_records
                (auditSequence, connectionIDRaw, capabilityRaw, operationKindRaw, outcomeRaw,
                 failureKindRaw, denialReasonRaw, payloadBlob, requestedAt, committedAt,
                 changePositionRaw, auditSchemaVersion)
            VALUES (?, ?, ?, ?, 1, NULL, NULL, ?, ?, ?, NULL, 1)
            """, bindings: [
                .blob(sqliteUInt64(1)), .text(connectionID.uuidString),
                .integer(Int64(ExternalCapability.browse.rawValue)),
                .integer(Int64(ExternalOperationKind.readRecent.rawValue)),
                .blob(Data([0x01])), .real(800_000_101), .real(800_000_101)
            ])
    }

    private static func damage(_ damage: Damage, at storeURL: URL) async throws {
        let authority = try makeAuthority(at: storeURL)
        try await authority.withTestDatabase { owner in
            let database = owner.database
            let state = try GatewayStoreSnapshot.read(in: database)
            let connection = try #require(state.connections.first)
            let connectionID = connection.id
            // Only deliberately malformed fixtures bypass schema constraints.
            try database.execute("PRAGMA foreign_keys = OFF")
            try database.execute("PRAGMA ignore_check_constraints = ON")
            defer {
                try? database.execute("PRAGMA foreign_keys = ON")
                try? database.execute("PRAGMA ignore_check_constraints = OFF")
            }
            try database.writeTransaction {
                switch damage {
                case .missingConfigWithConnection:
                    try database.execute("DELETE FROM gateway_config")
                case .missingConfigWithOrphanGrant:
                    try database.execute("DELETE FROM gateway_config")
                    try database.execute("DELETE FROM connections")
                    try insertGrant(in: database, connectionID: connectionID)
                case .missingConfigWithOrphanOperation:
                    try database.execute("DELETE FROM gateway_config")
                    try database.execute("DELETE FROM connections")
                    try insertOperation(in: database, connectionID: connectionID)
                case .wrongConfigKey:
                    try database.execute("UPDATE gateway_config SET key = 'wrong-gateway'")
                case .extraConfig:
                    try database.execute("""
                        INSERT INTO gateway_config
                            (key, appIntentsConnectionID, nextAuditSequence, auditBytes, compactionFloor, configSchemaVersion)
                        VALUES ('extra-gateway', ?, ?, ?, ?, 1)
                        """, bindings: [.text(UUID().uuidString), .blob(sqliteUInt64(1)),
                            .blob(sqliteUInt64(0)), .blob(sqliteUInt64(1))])
                case .configVersion:
                    try database.execute("UPDATE gateway_config SET configSchemaVersion = 2")
                case .nextAuditSequence:
                    try database.execute("UPDATE gateway_config SET nextAuditSequence = ?",
                        bindings: [.blob(sqliteUInt64(2))])
                case .auditBytes:
                    try database.execute("UPDATE gateway_config SET auditBytes = ?",
                        bindings: [.blob(sqliteUInt64(1))])
                case .compactionFloor:
                    try database.execute("UPDATE gateway_config SET compactionFloor = ?",
                        bindings: [.blob(sqliteUInt64(0))])
                case .missingConnection:
                    try database.execute("DELETE FROM connections")
                case .mismatchedConnectionIdentity:
                    try database.execute("UPDATE gateway_config SET appIntentsConnectionID = ?",
                        bindings: [.text(UUID().uuidString)])
                case .knownWrongEnrollKind:
                    try database.execute("UPDATE connections SET enrollKindRaw = ?",
                        bindings: [.integer(Int64(ConnectionEnrollKind.localAutomation.rawValue))])
                case .unknownEnrollKind:
                    try database.execute("UPDATE connections SET enrollKindRaw = 0")
                case .revokedConnectionWithoutRevokedAt:
                    try database.execute("UPDATE connections SET statusRaw = ?, revokedAt = NULL",
                        bindings: [.integer(Int64(ConnectionStatus.revoked.rawValue))])
                case .unknownStatus:
                    try database.execute("UPDATE connections SET statusRaw = 0")
                case .activeConnectionWithRevokedAt:
                    try database.execute("UPDATE connections SET revokedAt = enrolledAt")
                case .displayNameMismatch:
                    try database.execute("UPDATE connections SET displayNameRaw = 'Shortcuts'")
                case .oversizedDisplayName:
                    try database.execute("UPDATE connections SET displayNameRaw = ?",
                        bindings: [.text(String(repeating: "a", count: 257))])
                case .connectionVersion:
                    try database.execute("UPDATE connections SET configSchemaVersion = 2")
                case .operationPresent:
                    try insertOperation(in: database, connectionID: connectionID)
                }
            }
        }
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
        let expectedEnrolledAt = Date(
            timeIntervalSinceReferenceDate: 800_000_000
        )
        let authority = try HistoryAuthority(
            storeLocation: HistoryStoreLocation(persistence: .temporary),
            storageClock: FixedStorageClock(expectedEnrolledAt),
            gatewayConnectionIDSource: { expectedConnectionID }
        )

        try await authority.performStartup(initialMaximumUnpinnedItems: 321)

        let state = try await GatewayStoreSnapshot.read(from: authority)
        let config = try #require(state.configs.first)
        let connection = try #require(state.connections.first)
        #expect(config.appIntentsConnectionID == expectedConnectionID)
        #expect(connection.id == expectedConnectionID)
        #expect(connection.enrolledAt == expectedEnrolledAt)
    }

    @Test("a coherently revoked durable App Intents identity survives reopen")
    func coherentlyRevokedDefaultIdentitySurvivesReopen() async throws {
        let storeURL = WSSupport.tempStoreURL("gateway-revoked-reopen")
        defer { WSSupport.removeStore(storeURL) }

        try await Self.openPublicly(at: storeURL)
        do {
            let authority = try Self.makeAuthority(at: storeURL)
            try await authority.withTestDatabase { owner in
                try owner.database.execute("UPDATE connections SET statusRaw = ?, revokedAt = enrolledAt + 1",
                    bindings: [.integer(Int64(ConnectionStatus.revoked.rawValue))])
            }
        }
        let expected = try GatewayStoreSnapshot.read(from: storeURL)

        try await Self.openPublicly(at: storeURL)

        #expect(try GatewayStoreSnapshot.read(from: storeURL) == expected)
    }

    @Test("an existing valid X.4 audit interval survives public reopen")
    func existingAuditIntervalSurvivesReopen() async throws {
        let storeURL = WSSupport.tempStoreURL("gateway-audit-reopen")
        defer { WSSupport.removeStore(storeURL) }

        try await Self.openPublicly(at: storeURL)
        do {
            let authority = try Self.makeAuthority(at: storeURL)
            try await authority.withTestDatabase { owner in
                let context = owner.database
                let statement = try context.prepare("SELECT \(GatewayConfigRow.columns) FROM gateway_config")
                defer { statement.finalize() }
                #expect(try statement.step())
                let config = try GatewayConfigRow(statement: statement)
                statement.finalize()
                try context.writeTransaction {
                    let timestamp = Date(timeIntervalSinceReferenceDate: 800_000_200)
                    _ = try GatewayAuditStore.append(
                        OperationRecordPayload(
                            connectionID: ExternalConnectionID(
                                rawValue: config.appIntentsConnectionID
                            ),
                            capability: .browse,
                            operationKind: .readRecent,
                            outcome: .succeeded,
                            failureKind: nil,
                            denialReason: nil,
                            requestSummary: .recent(limit: 1),
                            resultSummary: .page(
                                returnedCount: 0,
                                hasMore: false
                            ),
                            requestedAt: timestamp,
                            committedAt: timestamp,
                            changePosition: nil
                        ),
                        config: config,
                        in: context
                    )
                }
            }
        }
        let expected = try GatewayStoreSnapshot.read(from: storeURL)

        try await Self.openPublicly(at: storeURL)

        #expect(try GatewayStoreSnapshot.read(from: storeURL) == expected)
    }

    @Test("every malformed bootstrap relation fails closed without durable repair")
    func malformedBootstrapRelationsFailClosedWithoutRepair() async throws {
        for damage in Damage.allCases {
            let storeURL = WSSupport.tempStoreURL(
                "gateway-bootstrap-\(damage.label)"
            )
            defer { WSSupport.removeStore(storeURL) }
            try await Self.openPublicly(at: storeURL)
            try await Self.damage(damage, at: storeURL)
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
