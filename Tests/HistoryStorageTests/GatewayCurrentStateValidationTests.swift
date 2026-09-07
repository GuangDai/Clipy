/// X.4 current-state validation before the first Gateway admin writer.
/// Owning spec: `V2-05` §4.1/§4.2/§4.5 and roadmap X.4/GW3.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite("Gateway current-state validation (X.4)")
struct GatewayCurrentStateValidationTests {
    private static let appIntentsID = UUID(
        uuidString: "A0B1C2D3-E4F5-4678-9012-3456789ABCDE"
    )!
    private static let localAutomationID = UUID(
        uuidString: "B0C1D2E3-F4A5-4678-9012-3456789ABCDE"
    )!
    private static let enrolledAt = Date(
        timeIntervalSinceReferenceDate: 800_100_000
    )

    private enum Damage: CaseIterable, Sendable {
        case connectionVersion
        case connectionKindRaw
        case connectionStatusRaw
        case connectionEnrolledAt
        case connectionRevokedAt
        case grantVersion
        case grantCapabilityRaw
        case grantGrantedAt
        case grantRevokedAt

        var expectedFailure: HistoryFailure {
            switch self {
            case .connectionVersion,
                 .connectionKindRaw,
                 .connectionStatusRaw,
                 .grantVersion,
                 .grantCapabilityRaw:
                .persistence(.corruptStoredValue)
            case .connectionEnrolledAt,
                 .connectionRevokedAt,
                 .grantGrantedAt,
                 .grantRevokedAt:
                .persistence(.corruptStoredValue)
            }
        }
    }

    private static func makeAuthority() throws -> HistoryAuthority {
        try HistoryAuthority(storeLocation: HistoryStoreLocation(persistence: .temporary))
    }

    private static func resetFixture(in context: SQLiteDatabase) throws {
        try context.execute("DELETE FROM grants")
        try context.execute("DELETE FROM connections")
    }

    @discardableResult
    private static func insertConnection(
        id: UUID = appIntentsID,
        kind: ConnectionEnrollKind = .appIntents,
        status: ConnectionStatus = .active,
        revokedAt: Date? = nil,
        in context: SQLiteDatabase
    ) throws -> ConnectionRow {
        let row = ConnectionRow(
            id: id,
            displayNameRaw: id == appIntentsID
                ? HistoryAuthority.gatewayConnectionDisplayName
                : "Local automation",
            enrollKindRaw: kind.rawValue,
            statusRaw: status.rawValue,
            enrolledAt: enrolledAt,
            revokedAt: revokedAt,
            configSchemaVersion: HistoryAuthority.gatewayConfigSchemaVersion
        )
        try context.execute("""
            INSERT INTO connections (id, displayNameRaw, enrollKindRaw, statusRaw, enrolledAt, revokedAt, configSchemaVersion)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, bindings: [
                .text(row.id.uuidString), .text(row.displayNameRaw),
                .integer(Int64(row.enrollKindRaw)), .integer(Int64(row.statusRaw)),
                .real(row.enrolledAt.timeIntervalSinceReferenceDate),
                row.revokedAt.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null,
                .integer(Int64(row.configSchemaVersion))
            ])
        return row
    }

    @discardableResult
    private static func insertGrant(
        connectionID: UUID = appIntentsID,
        capability: ExternalCapability = .browse,
        grantedAt: Date = Date(timeIntervalSinceReferenceDate: 800_100_010),
        revokedAt: Date? = nil,
        in context: SQLiteDatabase
    ) throws -> GrantRow {
        let row = GrantRow(
            grantKey: GatewayAdministration.canonicalGrantKey(
                connectionID: connectionID,
                capability: capability
            ),
            connectionIDRaw: connectionID,
            capabilityRaw: capability.rawValue,
            grantedAt: grantedAt,
            revokedAt: revokedAt,
            configSchemaVersion: HistoryAuthority.gatewayConfigSchemaVersion
        )
        try context.execute("""
            INSERT INTO grants (grantKey, connectionIDRaw, capabilityRaw, grantedAt, revokedAt, configSchemaVersion)
            VALUES (?, ?, ?, ?, ?, ?)
            """, bindings: [
                .text(row.grantKey), .text(row.connectionIDRaw.uuidString), .integer(Int64(row.capabilityRaw)),
                .real(row.grantedAt.timeIntervalSinceReferenceDate),
                row.revokedAt.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null,
                .integer(Int64(row.configSchemaVersion))
            ])
        return row
    }

    private static func makeLimits(
        maximumConnections: Int = 500,
        maximumGrantRowsPerConnection: Int = 8
    ) -> ExternalLimits {
        ExternalLimits(
            maximumDisplayNameUTF8Bytes: 256,
            maximumConnections: maximumConnections,
            maximumGrantRowsPerConnection: maximumGrantRowsPerConnection,
            maxAffectedItemsPerRecord: 32,
            maxAuditLogSize: 64 * 1_048_576,
            auditRecordAccountingOverheadBytes: 128,
            maximumAuditPayloadBlobBytes: 16 * 1_024,
            maxAuditAgeSeconds: 31_536_000,
            compactionCadenceOps: 100,
            maxAuditReadBatchSize: 500,
            externalBrowseLimitLowerBound: 1,
            externalBrowseLimitUpperBound: 500
        )!
    }

    private static func expectFailure(
        _ expected: HistoryFailure,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("expected current-state validation to fail")
        } catch let failure as HistoryFailure {
            #expect(failure == expected)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("valid rows produce bounded deterministic immutable projections")
    func validRowsProjectDeterministically() async throws {
        let authority = try Self.makeAuthority()
        try await authority.withTestDatabase { owner in
            let context = owner.database
            try context.writeTransaction { try SQLiteHistorySchema.create(in: context) }
            try Self.resetFixture(in: context)
            try Self.insertConnection(
                id: Self.localAutomationID,
                kind: .localAutomation,
                in: context
            )
            try Self.insertConnection(in: context)
            try Self.insertGrant(
                connectionID: Self.localAutomationID,
                capability: .organize,
                in: context
            )
            try Self.insertGrant(capability: .manage, in: context)

            let state = try GatewayAdministration.loadCurrentState(
                appIntentsConnectionID: Self.appIntentsID,
                in: context,
                limits: Self.makeLimits(
                    maximumConnections: 2,
                    maximumGrantRowsPerConnection: 1
                )
            )

            #expect(state.connections.map(\.id.rawValue) == [
                Self.appIntentsID,
                Self.localAutomationID,
            ])
            #expect(state.connections.map(\.enrollKind) == [
                .appIntents,
                .localAutomation,
            ])
            #expect(state.grants.map(\.connectionID.rawValue) == [
                Self.appIntentsID,
                Self.localAutomationID,
            ])
            #expect(state.grants.map(\.capability) == [.manage, .organize])
        }
    }

    @Test("the durable default App Intents identity may be coherently revoked")
    func revokedDefaultIdentityIsValidCurrentState() async throws {
        let authority = try Self.makeAuthority()
        try await authority.withTestDatabase { owner in
            let context = owner.database
            try context.writeTransaction { try SQLiteHistorySchema.create(in: context) }
            try Self.resetFixture(in: context)
            let revokedAt = Date(timeIntervalSinceReferenceDate: 800_100_020)
            try Self.insertConnection(
                status: .revoked,
                revokedAt: revokedAt,
                in: context
            )
            try Self.insertGrant(revokedAt: revokedAt, in: context)

            let state = try GatewayAdministration.loadCurrentState(
                appIntentsConnectionID: Self.appIntentsID,
                in: context
            )

            #expect(state.connections.count == 1)
            #expect(state.connections[0].status == .revoked)
            #expect(state.connections[0].revokedAt == revokedAt)
            #expect(state.grants[0].revokedAt == revokedAt)
        }
    }

    @Test("connection and grant raw values, versions, and timestamps fail closed")
    func primitiveStoredValuesFailClosed() async throws {
        let authority = try Self.makeAuthority()
        try await authority.withTestDatabase { owner in
            let context = owner.database
            try context.writeTransaction { try SQLiteHistorySchema.create(in: context) }
            for damage in Damage.allCases {
                try Self.resetFixture(in: context)
                var connection = try Self.insertConnection(in: context)
                var grant = try Self.insertGrant(in: context)

                switch damage {
                case .connectionVersion:
                    connection.configSchemaVersion = 2
                case .connectionKindRaw:
                    connection.enrollKindRaw = 0
                case .connectionStatusRaw:
                    connection.statusRaw = 0
                case .connectionEnrolledAt:
                    connection.enrolledAt = Date(
                        timeIntervalSinceReferenceDate: .infinity
                    )
                case .connectionRevokedAt:
                    connection.statusRaw = ConnectionStatus.revoked.rawValue
                    connection.revokedAt = Date(
                        timeIntervalSinceReferenceDate: .infinity
                    )
                    grant.revokedAt = Self.enrolledAt
                case .grantVersion:
                    grant.configSchemaVersion = 2
                case .grantCapabilityRaw:
                    grant.capabilityRaw = 0
                case .grantGrantedAt:
                    grant.grantedAt = Date(
                        timeIntervalSinceReferenceDate: -.infinity
                    )
                case .grantRevokedAt:
                    grant.revokedAt = Date(
                        timeIntervalSinceReferenceDate: .infinity
                    )
                }

                try context.execute("""
                    UPDATE connections SET configSchemaVersion = ?, enrollKindRaw = ?, statusRaw = ?, enrolledAt = ?, revokedAt = ?
                    """, bindings: [
                        .integer(Int64(connection.configSchemaVersion)), .integer(Int64(connection.enrollKindRaw)),
                        .integer(Int64(connection.statusRaw)), .real(connection.enrolledAt.timeIntervalSinceReferenceDate),
                        connection.revokedAt.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null
                    ])
                try context.execute("""
                    UPDATE grants SET configSchemaVersion = ?, capabilityRaw = ?, grantedAt = ?, revokedAt = ?
                    """, bindings: [
                        .integer(Int64(grant.configSchemaVersion)), .integer(Int64(grant.capabilityRaw)),
                        .real(grant.grantedAt.timeIntervalSinceReferenceDate),
                        grant.revokedAt.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null
                    ])
                Self.expectFailure(damage.expectedFailure) {
                    _ = try GatewayAdministration.loadCurrentState(
                        appIntentsConnectionID: Self.appIntentsID,
                        in: context
                    )
                }
            }
        }
    }

    @Test("connection status and revokedAt must describe the same lifecycle state")
    func connectionStatusIsCoherentWithRevokedAt() async throws {
        let authority = try Self.makeAuthority()
        try await authority.withTestDatabase { owner in
            let context = owner.database
            try context.writeTransaction { try SQLiteHistorySchema.create(in: context) }
            let revokedAt = Date(timeIntervalSinceReferenceDate: 800_100_020)

            for (status, storedRevokedAt) in [
                (ConnectionStatus.active, Optional(revokedAt)),
                (ConnectionStatus.revoked, Optional<Date>.none),
                (
                    ConnectionStatus.revoked,
                    Optional(Date(timeIntervalSinceReferenceDate: 800_099_999))
                ),
            ] {
                try Self.resetFixture(in: context)
                try Self.insertConnection(
                    status: status,
                    revokedAt: storedRevokedAt,
                    in: context
                )

                Self.expectFailure(.persistence(.invariantViolation)) {
                    _ = try GatewayAdministration.loadCurrentState(
                        appIntentsConnectionID: Self.appIntentsID,
                        in: context
                    )
                }
            }
        }
    }

    @Test("the durable default identity must still identify App Intents")
    func defaultIdentityRelationFailsClosed() async throws {
        let authority = try Self.makeAuthority()
        try await authority.withTestDatabase { owner in
            let context = owner.database
            try context.writeTransaction { try SQLiteHistorySchema.create(in: context) }
            for damage in 0..<2 {
                try Self.resetFixture(in: context)
                if damage == 0 {
                    try Self.insertConnection(
                        id: Self.localAutomationID,
                        kind: .localAutomation,
                        in: context
                    )
                } else {
                    try Self.insertConnection(
                        id: Self.appIntentsID,
                        kind: .localAutomation,
                        in: context
                    )
                }

                Self.expectFailure(.persistence(.invariantViolation)) {
                    _ = try GatewayAdministration.loadCurrentState(
                        appIntentsConnectionID: Self.appIntentsID,
                        in: context
                    )
                }
            }
        }
    }

    @Test("connection count and per-connection grant count are bounded")
    func rowCountsAreBounded() async throws {
        let authority = try Self.makeAuthority()
        try await authority.withTestDatabase { owner in
            let context = owner.database
            try context.writeTransaction { try SQLiteHistorySchema.create(in: context) }
            do {
                try Self.resetFixture(in: context)
                try Self.insertConnection(in: context)
                try Self.insertConnection(
                    id: Self.localAutomationID,
                    kind: .localAutomation,
                    in: context
                )
                Self.expectFailure(.persistence(.invariantViolation)) {
                    _ = try GatewayAdministration.loadCurrentState(
                        appIntentsConnectionID: Self.appIntentsID,
                        in: context,
                        limits: Self.makeLimits(maximumConnections: 1)
                    )
                }
            }

            do {
                try Self.resetFixture(in: context)
                try Self.insertConnection(in: context)
                try Self.insertGrant(capability: .browse, in: context)
                try Self.insertGrant(capability: .manage, in: context)
                Self.expectFailure(.persistence(.invariantViolation)) {
                    _ = try GatewayAdministration.loadCurrentState(
                        appIntentsConnectionID: Self.appIntentsID,
                        in: context,
                        limits: Self.makeLimits(
                            maximumGrantRowsPerConnection: 1
                        )
                    )
                }
            }
        }
    }

    @Test("grant keys are canonical strings derived directly from pair values")
    func grantKeyIsCanonicalAndMismatchFailsClosed() async throws {
        let authority = try Self.makeAuthority()
        try await authority.withTestDatabase { owner in
            let context = owner.database
            try context.writeTransaction { try SQLiteHistorySchema.create(in: context) }
            let expected = "A0B1C2D3-E4F5-4678-9012-3456789ABCDE:3"
            #expect(GatewayAdministration.canonicalGrantKey(
                connectionID: Self.appIntentsID,
                capability: .manage
            ) == expected)

            try Self.resetFixture(in: context)
            try Self.insertConnection(in: context)
            let grant = try Self.insertGrant(capability: .manage, in: context)
            try context.execute("UPDATE grants SET grantKey = ? WHERE grantKey = ?",
                bindings: [.text("opaque-or-hashed-key"), .text(grant.grantKey)])

            Self.expectFailure(.persistence(.invariantViolation)) {
                _ = try GatewayAdministration.loadCurrentState(
                    appIntentsConnectionID: Self.appIntentsID,
                    in: context
                )
            }
        }
    }

    @Test("duplicate pairs and orphan grants fail closed")
    func duplicateAndOrphanRelationsFailClosed() async throws {
        let authority = try Self.makeAuthority()
        try await authority.withTestDatabase { owner in
            let context = owner.database
            try context.writeTransaction { try SQLiteHistorySchema.create(in: context) }
            do {
                try Self.resetFixture(in: context)
                try Self.insertConnection(in: context)
                try Self.insertGrant(in: context)
                let before = try GatewayStoreSnapshot.read(in: context)
                do {
                    try Self.insertGrant(in: context)
                    Issue.record("expected SQL uniqueness to reject a duplicate grant pair")
                } catch let failure as SQLiteFailure {
                    #expect(failure.isConstraint)
                }
                #expect(try GatewayStoreSnapshot.read(in: context) == before)
                let state = try GatewayAdministration.loadCurrentState(
                    appIntentsConnectionID: Self.appIntentsID, in: context
                )
                #expect(state.grants.count == 1)
            }

            do {
                try Self.resetFixture(in: context)
                try Self.insertConnection(in: context)
                try context.execute("PRAGMA foreign_keys = OFF")
                try Self.insertGrant(
                    connectionID: Self.localAutomationID,
                    capability: .organize,
                    in: context
                )
                try context.execute("PRAGMA foreign_keys = ON")

                Self.expectFailure(.persistence(.invariantViolation)) {
                    _ = try GatewayAdministration.loadCurrentState(
                        appIntentsConnectionID: Self.appIntentsID,
                        in: context
                    )
                }
            }
        }
    }

    @Test("revoked connections cannot retain a live grant")
    func revokedConnectionCannotRetainLiveGrant() async throws {
        let authority = try Self.makeAuthority()
        try await authority.withTestDatabase { owner in
            let context = owner.database
            try context.writeTransaction { try SQLiteHistorySchema.create(in: context) }
            try Self.resetFixture(in: context)
            try Self.insertConnection(
                status: .revoked,
                revokedAt: Self.enrolledAt,
                in: context
            )
            try Self.insertGrant(in: context)

            Self.expectFailure(.persistence(.invariantViolation)) {
                _ = try GatewayAdministration.loadCurrentState(
                    appIntentsConnectionID: Self.appIntentsID,
                    in: context
                )
            }
        }
    }

    @Test("known but cross-kind and unadmitted capabilities are not grantable")
    func grantabilityIsASeparateClosedDecision() {
        let appIntentsGrantable: [ExternalCapability] = [
            .browse, .readContent, .manage,
        ]
        let localAutomationGrantable: [ExternalCapability] = [
            .browsePreview, .readEffectiveContent, .organize, .deleteItem, .reviseContent,
        ]
        let allCapabilities: [ExternalCapability] = [
            .browse,
            .readContent,
            .manage,
            .browsePreview,
            .readEffectiveContent,
            .organize,
            .deleteItem,
            .reviseContent,
        ]

        for capability in allCapabilities {
            #expect(GatewayAdministration.isGrantable(
                capability,
                to: .appIntents
            ) == appIntentsGrantable.contains(capability))
            #expect(GatewayAdministration.isGrantable(
                capability,
                to: .localAutomation
            ) == localAutomationGrantable.contains(capability))
        }

        // Grantability is not inferred by asking whether an arbitrary
        // operation is admitted for the pair.
        #expect(GatewayAdministration.isGrantable(.manage, to: .appIntents))
        #expect(!ExternalAccessPolicy.admits(
            connectionKind: .appIntents,
            capability: .manage,
            operation: .readDetails
        ))
    }

    @Test("a stored cross-kind grant fails current-state validation")
    func crossKindGrantFailsClosed() async throws {
        let authority = try Self.makeAuthority()
        try await authority.withTestDatabase { owner in
            let context = owner.database
            try context.writeTransaction { try SQLiteHistorySchema.create(in: context) }
            try Self.resetFixture(in: context)
            try Self.insertConnection(in: context)
            try Self.insertGrant(capability: .organize, in: context)

            Self.expectFailure(.persistence(.invariantViolation)) {
                _ = try GatewayAdministration.loadCurrentState(
                    appIntentsConnectionID: Self.appIntentsID,
                    in: context
                )
            }
        }
    }

    @Test("regrant updates the one current row and does not create event history")
    func regrantUpdatesExistingCurrentRow() async throws {
        let authority = try Self.makeAuthority()
        try await authority.withTestDatabase { owner in
            let context = owner.database
            try context.writeTransaction { try SQLiteHistorySchema.create(in: context) }
            try Self.resetFixture(in: context)
            try Self.insertConnection(in: context)
            let firstGrantedAt = Date(
                timeIntervalSinceReferenceDate: 800_100_010
            )
            let revokedAt = Date(timeIntervalSinceReferenceDate: 800_100_020)
            let row = try Self.insertGrant(
                grantedAt: firstGrantedAt,
                revokedAt: revokedAt,
                in: context
            )

            let regrantedAt = Date(timeIntervalSinceReferenceDate: 800_100_030)
            let updated = GatewayAdministration.regrantCurrentRow(row, at: regrantedAt)
            try context.execute("UPDATE grants SET grantedAt = ?, revokedAt = NULL WHERE grantKey = ?",
                bindings: [.real(updated.grantedAt.timeIntervalSinceReferenceDate), .text(updated.grantKey)])

            let snapshot = try GatewayStoreSnapshot.read(in: context)
            let grants = snapshot.grants
            let operations = snapshot.operations
            #expect(grants.count == 1)
            #expect(grants[0].grantedAt == regrantedAt)
            #expect(grants[0].revokedAt == nil)
            #expect(operations.isEmpty)
        }
    }
}
