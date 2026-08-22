/// X.4 current-state validation before the first Gateway admin writer.
/// Owning spec: `V2-05` §4.1/§4.2/§4.5 and roadmap X.4/GW3.
import Foundation
import HistoryCore
import SwiftData
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

    private enum Damage: CaseIterable {
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

    private static func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: HistorySchemaV3.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    @discardableResult
    private static func insertConnection(
        id: UUID = appIntentsID,
        kind: ConnectionEnrollKind = .appIntents,
        status: ConnectionStatus = .active,
        revokedAt: Date? = nil,
        in context: ModelContext
    ) -> ConnectionRow {
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
        context.insert(row)
        return row
    }

    @discardableResult
    private static func insertGrant(
        connectionID: UUID = appIntentsID,
        capability: ExternalCapability = .browse,
        grantedAt: Date = Date(timeIntervalSinceReferenceDate: 800_100_010),
        revokedAt: Date? = nil,
        in context: ModelContext
    ) -> GrantRow {
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
        context.insert(row)
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
    func validRowsProjectDeterministically() throws {
        let context = try Self.makeContext()
        Self.insertConnection(
            id: Self.localAutomationID,
            kind: .localAutomation,
            in: context
        )
        Self.insertConnection(in: context)
        Self.insertGrant(
            connectionID: Self.localAutomationID,
            capability: .organize,
            in: context
        )
        Self.insertGrant(capability: .manage, in: context)
        try context.save()

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

    @Test("the durable default App Intents identity may be coherently revoked")
    func revokedDefaultIdentityIsValidCurrentState() throws {
        let context = try Self.makeContext()
        let revokedAt = Date(timeIntervalSinceReferenceDate: 800_100_020)
        Self.insertConnection(
            status: .revoked,
            revokedAt: revokedAt,
            in: context
        )
        Self.insertGrant(revokedAt: revokedAt, in: context)
        try context.save()

        let state = try GatewayAdministration.loadCurrentState(
            appIntentsConnectionID: Self.appIntentsID,
            in: context
        )

        #expect(state.connections.count == 1)
        #expect(state.connections[0].status == .revoked)
        #expect(state.connections[0].revokedAt == revokedAt)
        #expect(state.grants[0].revokedAt == revokedAt)
    }

    @Test("connection and grant raw values, versions, and timestamps fail closed")
    func primitiveStoredValuesFailClosed() throws {
        for damage in Damage.allCases {
            let context = try Self.makeContext()
            let connection = Self.insertConnection(in: context)
            let grant = Self.insertGrant(in: context)

            switch damage {
            case .connectionVersion:
                connection.configSchemaVersion = 2
            case .connectionKindRaw:
                connection.enrollKindRaw = 0
            case .connectionStatusRaw:
                connection.statusRaw = 0
            case .connectionEnrolledAt:
                connection.enrolledAt = Date(
                    timeIntervalSinceReferenceDate: .nan
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
                    timeIntervalSinceReferenceDate: .nan
                )
            }

            Self.expectFailure(damage.expectedFailure) {
                _ = try GatewayAdministration.loadCurrentState(
                    appIntentsConnectionID: Self.appIntentsID,
                    in: context
                )
            }
        }
    }

    @Test("connection status and revokedAt must describe the same lifecycle state")
    func connectionStatusIsCoherentWithRevokedAt() throws {
        let revokedAt = Date(timeIntervalSinceReferenceDate: 800_100_020)

        for (status, storedRevokedAt) in [
            (ConnectionStatus.active, Optional(revokedAt)),
            (ConnectionStatus.revoked, Optional<Date>.none),
            (
                ConnectionStatus.revoked,
                Optional(Date(timeIntervalSinceReferenceDate: 800_099_999))
            ),
        ] {
            let context = try Self.makeContext()
            Self.insertConnection(
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

    @Test("the durable default identity must still identify App Intents")
    func defaultIdentityRelationFailsClosed() throws {
        for damage in 0..<2 {
            let context = try Self.makeContext()
            if damage == 0 {
                Self.insertConnection(
                    id: Self.localAutomationID,
                    kind: .localAutomation,
                    in: context
                )
            } else {
                Self.insertConnection(
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

    @Test("connection count and per-connection grant count are bounded")
    func rowCountsAreBounded() throws {
        do {
            let context = try Self.makeContext()
            Self.insertConnection(in: context)
            Self.insertConnection(
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
            let context = try Self.makeContext()
            Self.insertConnection(in: context)
            Self.insertGrant(capability: .browse, in: context)
            Self.insertGrant(capability: .manage, in: context)
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

    @Test("grant keys are canonical strings derived directly from pair values")
    func grantKeyIsCanonicalAndMismatchFailsClosed() throws {
        let expected = "A0B1C2D3-E4F5-4678-9012-3456789ABCDE:3"
        #expect(GatewayAdministration.canonicalGrantKey(
            connectionID: Self.appIntentsID,
            capability: .manage
        ) == expected)

        let context = try Self.makeContext()
        Self.insertConnection(in: context)
        let grant = Self.insertGrant(capability: .manage, in: context)
        grant.grantKey = "opaque-or-hashed-key"

        Self.expectFailure(.persistence(.invariantViolation)) {
            _ = try GatewayAdministration.loadCurrentState(
                appIntentsConnectionID: Self.appIntentsID,
                in: context
            )
        }
    }

    @Test("duplicate pairs and orphan grants fail closed")
    func duplicateAndOrphanRelationsFailClosed() throws {
        do {
            let context = try Self.makeContext()
            Self.insertConnection(in: context)
            Self.insertGrant(in: context)
            Self.insertGrant(in: context)

            Self.expectFailure(.persistence(.invariantViolation)) {
                _ = try GatewayAdministration.loadCurrentState(
                    appIntentsConnectionID: Self.appIntentsID,
                    in: context
                )
            }
        }

        do {
            let context = try Self.makeContext()
            Self.insertConnection(in: context)
            Self.insertGrant(
                connectionID: Self.localAutomationID,
                capability: .organize,
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

    @Test("revoked connections cannot retain a live grant")
    func revokedConnectionCannotRetainLiveGrant() throws {
        let context = try Self.makeContext()
        Self.insertConnection(
            status: .revoked,
            revokedAt: Self.enrolledAt,
            in: context
        )
        Self.insertGrant(in: context)

        Self.expectFailure(.persistence(.invariantViolation)) {
            _ = try GatewayAdministration.loadCurrentState(
                appIntentsConnectionID: Self.appIntentsID,
                in: context
            )
        }
    }

    @Test("known but cross-kind and unadmitted capabilities are not grantable")
    func grantabilityIsASeparateClosedDecision() {
        let appIntentsGrantable: [ExternalCapability] = [
            .browse, .readContent, .manage,
        ]
        let localAutomationGrantable: [ExternalCapability] = [
            .browsePreview, .readEffectiveContent, .organize, .deleteItem,
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
    func crossKindGrantFailsClosed() throws {
        let context = try Self.makeContext()
        Self.insertConnection(in: context)
        Self.insertGrant(capability: .organize, in: context)

        Self.expectFailure(.persistence(.invariantViolation)) {
            _ = try GatewayAdministration.loadCurrentState(
                appIntentsConnectionID: Self.appIntentsID,
                in: context
            )
        }
    }

    @Test("regrant updates the one current row and does not create event history")
    func regrantUpdatesExistingCurrentRow() throws {
        let context = try Self.makeContext()
        Self.insertConnection(in: context)
        let firstGrantedAt = Date(
            timeIntervalSinceReferenceDate: 800_100_010
        )
        let revokedAt = Date(timeIntervalSinceReferenceDate: 800_100_020)
        let row = Self.insertGrant(
            grantedAt: firstGrantedAt,
            revokedAt: revokedAt,
            in: context
        )
        try context.save()

        let regrantedAt = Date(timeIntervalSinceReferenceDate: 800_100_030)
        GatewayAdministration.regrantCurrentRow(row, at: regrantedAt)
        try context.save()

        let grants = try context.fetch(FetchDescriptor<GrantRow>())
        let operations = try context.fetch(
            FetchDescriptor<OperationRecordRow>()
        )
        #expect(grants.count == 1)
        #expect(grants[0].grantedAt == regrantedAt)
        #expect(grants[0].revokedAt == nil)
        #expect(operations.isEmpty)
    }
}
