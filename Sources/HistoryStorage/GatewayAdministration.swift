/// X.4 connection/grant current-state ownership.
/// Owning spec: `V2-05` §4.1/§4.2/§4.5 and roadmap X.4/GW3.
///
/// This owner validates/projects current state and implements the four
/// Authority-internal admin mutations. Every admitted attempt delegates its
/// immutable record to `GatewayAuditStore` inside the same transaction; this
/// file never inserts/deletes audit rows or advances audit counters itself.
import Foundation
import HistoryCore
import SwiftData

/// Immutable, bounded projection of the validated Gateway authorization
/// state. SwiftData models never leave the owning context.
internal struct GatewayCurrentState: Sendable {
    internal let connections: [ConnectionDTO]
    internal let grants: [GrantDTO]
}

/// Owns the closed connection/grant rules independently of request-operation
/// admission. A grant can be valid for a connection kind without admitting
/// every operation classified by `ExternalAccessPolicy`.
internal enum GatewayAdministration {
    /// The schema's deterministic composite key. It encodes the actual pair
    /// directly and deliberately contains no hash or hash-derived identity.
    internal static func canonicalGrantKey(
        connectionID: UUID,
        capability: ExternalCapability
    ) -> String {
        "\(connectionID.uuidString):\(capability.rawValue)"
    }

    /// Closed grant-admission matrix (`V2-05` §0.2/§3.2). Constructible
    /// capability vocabulary is wider than what either connection kind may
    /// receive; notably `.reviseContent` remains unadmitted.
    internal static func isGrantable(
        _ capability: ExternalCapability,
        to connectionKind: ConnectionEnrollKind
    ) -> Bool {
        switch connectionKind {
        case .appIntents:
            switch capability {
            case .browse, .readContent, .manage:
                true
            case .browsePreview,
                 .readEffectiveContent,
                 .organize,
                 .deleteItem,
                 .reviseContent:
                false
            }

        case .localAutomation:
            switch capability {
            case .browsePreview,
                 .readEffectiveContent,
                 .organize,
                 .deleteItem:
                true
            case .browse,
                 .readContent,
                 .manage,
                 .reviseContent:
                false
            }
        }
    }

    /// Loads every bounded current-state row, validates its primitive and
    /// relational shape, and projects only immutable `HistoryCore` DTOs.
    ///
    /// Fetch limits use the configured maximum plus one so an oversized table
    /// is distinguishable without loading an unbounded registry. Unknown raw
    /// or schema values and non-finite timestamps are corrupt stored values;
    /// count, lifecycle, key, uniqueness, and reference failures are invariant
    /// violations. The durable default App Intents identity may remain active
    /// or be coherently revoked; startup must not reactivate it.
    internal static func loadCurrentState(
        appIntentsConnectionID: UUID,
        in context: ModelContext,
        limits: ExternalLimits = .standard
    ) throws -> GatewayCurrentState {
        let connectionFetchLimit = limits.maximumConnections
            .addingReportingOverflow(1)
        guard !connectionFetchLimit.overflow else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        var connectionDescriptor = FetchDescriptor<ConnectionRow>()
        connectionDescriptor.fetchLimit = connectionFetchLimit.partialValue

        let maximumGrantRows = limits.maximumConnections
            .multipliedReportingOverflow(
                by: limits.maximumGrantRowsPerConnection
            )
        let grantFetchLimit = maximumGrantRows.partialValue
            .addingReportingOverflow(1)
        guard !maximumGrantRows.overflow,
              !grantFetchLimit.overflow else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        var grantDescriptor = FetchDescriptor<GrantRow>()
        grantDescriptor.fetchLimit = grantFetchLimit.partialValue

        let connectionRows: [ConnectionRow]
        let grantRows: [GrantRow]
        do {
            connectionRows = try context.fetch(connectionDescriptor)
            grantRows = try context.fetch(grantDescriptor)
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }

        guard connectionRows.count <= limits.maximumConnections,
              grantRows.count <= maximumGrantRows.partialValue else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        var connectionFacts: [(
            id: UUID,
            kind: ConnectionEnrollKind,
            status: ConnectionStatus
        )] = []
        connectionFacts.reserveCapacity(connectionRows.count)
        var connectionDTOs: [ConnectionDTO] = []
        connectionDTOs.reserveCapacity(connectionRows.count)

        for row in connectionRows {
            guard row.configSchemaVersion
                    == HistoryAuthority.gatewayConfigSchemaVersion,
                  let enrollKind = ConnectionEnrollKind(
                    rawValue: row.enrollKindRaw
                  ),
                  let status = ConnectionStatus(rawValue: row.statusRaw),
                  row.enrolledAt.timeIntervalSinceReferenceDate.isFinite,
                  row.revokedAt?.timeIntervalSinceReferenceDate.isFinite
                    ?? true else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            guard row.displayNameRaw.utf8.count
                    <= limits.maximumDisplayNameUTF8Bytes,
                  !connectionFacts.contains(where: { $0.id == row.id }),
                  Self.isLifecycleCoherent(
                    status: status,
                    enrolledAt: row.enrolledAt,
                    revokedAt: row.revokedAt
                  ) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }

            connectionFacts.append((
                id: row.id,
                kind: enrollKind,
                status: status
            ))
            connectionDTOs.append(ConnectionDTO(
                id: ExternalConnectionID(rawValue: row.id),
                displayName: row.displayNameRaw,
                enrollKind: enrollKind,
                status: status,
                enrolledAt: row.enrolledAt,
                revokedAt: row.revokedAt
            ))
        }

        guard connectionFacts.contains(where: {
                $0.id == appIntentsConnectionID && $0.kind == .appIntents
              }),
              connectionRows.first(where: {
                $0.id == appIntentsConnectionID
              })?.displayNameRaw
                == HistoryAuthority.gatewayConnectionDisplayName else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        var grantPairs: [(
            connectionID: UUID,
            capability: ExternalCapability
        )] = []
        grantPairs.reserveCapacity(grantRows.count)
        var grantDTOs: [GrantDTO] = []
        grantDTOs.reserveCapacity(grantRows.count)

        for row in grantRows {
            guard row.configSchemaVersion
                    == HistoryAuthority.gatewayConfigSchemaVersion,
                  let capability = ExternalCapability(
                    rawValue: row.capabilityRaw
                  ),
                  row.grantedAt.timeIntervalSinceReferenceDate.isFinite,
                  row.revokedAt?.timeIntervalSinceReferenceDate.isFinite
                    ?? true else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            guard let connection = connectionFacts.first(where: {
                $0.id == row.connectionIDRaw
            }) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }

            let expectedKey = canonicalGrantKey(
                connectionID: row.connectionIDRaw,
                capability: capability
            )
            let existingPair = grantPairs.contains(where: {
                $0.connectionID == row.connectionIDRaw
                    && $0.capability == capability
            })
            let priorCount = grantPairs.lazy.filter {
                $0.connectionID == row.connectionIDRaw
            }.count
            guard row.grantKey == expectedKey,
                  !existingPair,
                  priorCount < limits.maximumGrantRowsPerConnection,
                  isGrantable(capability, to: connection.kind),
                  connection.status == .active || row.revokedAt != nil else {
                throw HistoryFailure.persistence(.invariantViolation)
            }

            grantPairs.append((
                connectionID: row.connectionIDRaw,
                capability: capability
            ))
            grantDTOs.append(GrantDTO(
                connectionID: ExternalConnectionID(
                    rawValue: row.connectionIDRaw
                ),
                capability: capability,
                grantedAt: row.grantedAt,
                revokedAt: row.revokedAt
            ))
        }

        connectionDTOs.sort {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
        grantDTOs.sort {
            let leftID = $0.connectionID.rawValue.uuidString
            let rightID = $1.connectionID.rawValue.uuidString
            if leftID != rightID { return leftID < rightID }
            return $0.capability.rawValue < $1.capability.rawValue
        }

        return GatewayCurrentState(
            connections: connectionDTOs,
            grants: grantDTOs
        )
    }

    /// Re-activation is a current-row update. Immutable grant/revoke/re-grant
    /// event history belongs exclusively to the audit store.
    internal static func regrantCurrentRow(
        _ row: GrantRow,
        at grantedAt: Date
    ) {
        row.grantedAt = grantedAt
        row.revokedAt = nil
    }

    private static func isLifecycleCoherent(
        status: ConnectionStatus,
        enrolledAt: Date,
        revokedAt: Date?
    ) -> Bool {
        switch status {
        case .active:
            revokedAt == nil
        case .revoked:
            if let revokedAt {
                revokedAt >= enrolledAt
            } else {
                false
            }
        }
    }
}

// MARK: - Authority-internal admin mutations

extension HistoryAuthority {
    /// Enrolls one non-Local-Automation connection with no implicit grants.
    /// Local Automation can publish only through the custody-verified,
    /// preassigned-ID method below; reject the generic Authority bypass before
    /// clock, audit, state reads, or connection-ID minting (`V2-05` §0.3).
    internal func enrollConnection(
        kind: ConnectionEnrollKind,
        displayName: String,
        credential: Data?
    ) async throws -> ExternalConnectionID {
        guard kind != .localAutomation else {
            throw ExternalFailure.requestDenied(.invalidInput)
        }
        return try await publishConnectionEnrollment(
            kind: kind,
            displayName: displayName,
            credentialWasProvided: credential != nil,
            preassignedConnectionID: nil
        )
    }

    /// Authority-last F1 publication after the coordinator has verified exact
    /// client and server custody readbacks. Secret bytes do not cross this
    /// seam. The preassigned Local Automation row and its truthful successful
    /// audit are one transaction and the new connection receives zero grants
    /// (`V2-05` §0.3).
    internal func publishVerifiedLocalAutomationEnrollment(
        _ id: ExternalConnectionID,
        displayName: String
    ) async throws {
        _ = try await publishConnectionEnrollment(
            kind: .localAutomation,
            displayName: displayName,
            credentialWasProvided: true,
            preassignedConnectionID: id
        )
    }

    /// Shared atomic connection+audit publisher. Oversized names are rejected
    /// before audit admission because the frozen codec cannot truthfully encode
    /// their out-of-bound byte count. Unverified credential-bearing requests
    /// and the 501st connection are admitted denials and cross the audit barrier
    /// (`V2-05` §0.3/§4.4).
    private func publishConnectionEnrollment(
        kind: ConnectionEnrollKind,
        displayName: String,
        credentialWasProvided: Bool,
        preassignedConnectionID: ExternalConnectionID?
    ) async throws -> ExternalConnectionID {
        let displayNameByteCount = displayName.utf8.count
        guard displayNameByteCount
                <= ExternalLimits.standard.maximumDisplayNameUTF8Bytes else {
            throw ExternalFailure.requestDenied(.invalidInput)
        }

        let now = storageClock.now()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let config = try Self.loadGatewayConfig(in: context)
        let state = try Self.loadGatewayState(
            appIntentsConnectionID: config.appIntentsConnectionID,
            in: context
        )
        let request = RequestSummaryV1.enroll(
            kind: kind,
            displayNameUTF8ByteCount: UInt16(displayNameByteCount),
            credentialWasProvided: credentialWasProvided
        )

        guard !credentialWasProvided || preassignedConnectionID != nil else {
            try commitGatewayAudit(
                Self.deniedAdminPayload(
                    connectionID: nil,
                    capability: nil,
                    operationKind: .adminEnroll,
                    request: request,
                    at: now,
                    failureKind: .requestDenied,
                    denialReason: .invalidInput
                ),
                config: config,
                in: context
            )
            throw ExternalFailure.requestDenied(.invalidInput)
        }
        guard state.connections.count
                < ExternalLimits.standard.maximumConnections else {
            try commitGatewayAudit(
                Self.deniedAdminPayload(
                    connectionID: nil,
                    capability: nil,
                    operationKind: .adminEnroll,
                    request: request,
                    at: now,
                    failureKind: .requestDenied,
                    denialReason: .invalidInput
                ),
                config: config,
                in: context
            )
            throw ExternalFailure.requestDenied(.invalidInput)
        }

        let connectionID = preassignedConnectionID ?? ExternalConnectionID(
            rawValue: gatewayConnectionIDSource()
        )
        guard !state.connections.contains(where: {
            $0.id == connectionID
        }) else {
            try commitGatewayAudit(
                OperationRecordPayload(
                    connectionID: nil,
                    capability: nil,
                    operationKind: .adminEnroll,
                    outcome: .failed,
                    failureKind: .persistence,
                    denialReason: nil,
                    requestSummary: request,
                    resultSummary: .none,
                    requestedAt: now,
                    committedAt: now,
                    changePosition: nil
                ),
                config: config,
                in: context
            )
            throw ExternalFailure.persistence(.invariantViolation)
        }

        let row = ConnectionRow(
            id: connectionID.rawValue,
            displayNameRaw: displayName,
            enrollKindRaw: kind.rawValue,
            statusRaw: ConnectionStatus.active.rawValue,
            enrolledAt: now,
            revokedAt: nil,
            configSchemaVersion: Self.gatewayConfigSchemaVersion
        )
        let payload = OperationRecordPayload(
            connectionID: connectionID,
            capability: nil,
            operationKind: .adminEnroll,
            outcome: .succeeded,
            failureKind: nil,
            denialReason: nil,
            requestSummary: request,
            resultSummary: .enrolled(connectionID: connectionID.rawValue),
            requestedAt: now,
            committedAt: now,
            changePosition: nil
        )
        try commitGatewayMutation(
            config: config,
            payload: payload,
            in: context
        ) { committedAt in
            row.enrolledAt = committedAt
            context.insert(row)
        }
        return connectionID
    }

    /// Revokes one active connection and every live grant in the same save
    /// boundary as its audit record. Repeating the operation is an audited
    /// no-op, not a second lifecycle transition.
    internal func revokeConnection(
        _ id: ExternalConnectionID
    ) async throws {
        let now = storageClock.now()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let config = try Self.loadGatewayConfig(in: context)
        let state = try Self.loadGatewayState(
            appIntentsConnectionID: config.appIntentsConnectionID,
            in: context
        )
        let request = RequestSummaryV1.revokeConnection(
            connectionID: id.rawValue
        )
        guard let connection = state.connections.first(where: {
            $0.id == id
        }) else {
            try commitGatewayAudit(
                Self.deniedAdminPayload(
                    connectionID: id,
                    capability: nil,
                    operationKind: .adminRevoke,
                    request: request,
                    at: now,
                    failureKind: .requestDenied,
                    denialReason: .invalidInput
                ),
                config: config,
                in: context
            )
            throw ExternalFailure.requestDenied(.invalidInput)
        }

        guard connection.status == .active else {
            try commitGatewayAudit(
                OperationRecordPayload(
                    connectionID: id,
                    capability: nil,
                    operationKind: .adminRevoke,
                    outcome: .noOp,
                    failureKind: nil,
                    denialReason: nil,
                    requestSummary: request,
                    resultSummary: .connectionRevoked(revokedGrantCount: 0),
                    requestedAt: now,
                    committedAt: now,
                    changePosition: nil
                ),
                config: config,
                in: context
            )
            return
        }

        let connectionRow = try Self.fetchConnectionRow(id, in: context)
        let liveGrantRows = try Self.fetchGrantRows(
            connectionID: id,
            in: context
        ).filter { $0.revokedAt == nil }
        guard let revokedCount = UInt16(exactly: liveGrantRows.count) else {
            throw ExternalFailure.persistence(.invariantViolation)
        }
        let payload = OperationRecordPayload(
            connectionID: id,
            capability: nil,
            operationKind: .adminRevoke,
            outcome: .succeeded,
            failureKind: nil,
            denialReason: nil,
            requestSummary: request,
            resultSummary: .connectionRevoked(
                revokedGrantCount: revokedCount
            ),
            requestedAt: now,
            committedAt: now,
            changePosition: nil
        )
        try commitGatewayMutation(
            config: config,
            payload: payload,
            in: context
        ) { committedAt in
            connectionRow.statusRaw = ConnectionStatus.revoked.rawValue
            connectionRow.revokedAt = committedAt
            for grantRow in liveGrantRows {
                grantRow.revokedAt = committedAt
            }
        }
    }

    /// Inserts, reactivates, or no-ops the canonical current grant pair.
    /// Event history is represented only by the mandatory audit append.
    internal func grantCapability(
        _ capability: ExternalCapability,
        to id: ExternalConnectionID
    ) async throws {
        let now = storageClock.now()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let config = try Self.loadGatewayConfig(in: context)
        let state = try Self.loadGatewayState(
            appIntentsConnectionID: config.appIntentsConnectionID,
            in: context
        )
        let request = RequestSummaryV1.grant(
            connectionID: id.rawValue,
            capability: capability
        )
        guard let connection = state.connections.first(where: {
            $0.id == id
        }) else {
            try commitGatewayAudit(
                Self.deniedAdminPayload(
                    connectionID: id,
                    capability: capability,
                    operationKind: .adminGrant,
                    request: request,
                    at: now,
                    failureKind: .requestDenied,
                    denialReason: .invalidInput
                ),
                config: config,
                in: context
            )
            throw ExternalFailure.requestDenied(.invalidInput)
        }
        guard GatewayAdministration.isGrantable(
            capability,
            to: connection.enrollKind
        ) else {
            try commitGatewayAudit(
                Self.deniedAdminPayload(
                    connectionID: id,
                    capability: capability,
                    operationKind: .adminGrant,
                    request: request,
                    at: now,
                    failureKind: .requestDenied,
                    denialReason: .invalidInput
                ),
                config: config,
                in: context
            )
            throw ExternalFailure.requestDenied(.invalidInput)
        }
        guard connection.status == .active else {
            try commitGatewayAudit(
                Self.deniedAdminPayload(
                    connectionID: id,
                    capability: capability,
                    operationKind: .adminGrant,
                    request: request,
                    at: now,
                    failureKind: .connectionRevoked,
                    denialReason: nil
                ),
                config: config,
                in: context
            )
            throw ExternalFailure.connectionRevoked(connectionID: id)
        }

        let pair = state.grants.first(where: {
            $0.connectionID == id && $0.capability == capability
        })
        if pair?.revokedAt == nil, pair != nil {
            try commitGatewayAudit(
                OperationRecordPayload(
                    connectionID: id,
                    capability: capability,
                    operationKind: .adminGrant,
                    outcome: .noOp,
                    failureKind: nil,
                    denialReason: nil,
                    requestSummary: request,
                    resultSummary: .grantChanged(false),
                    requestedAt: now,
                    committedAt: now,
                    changePosition: nil
                ),
                config: config,
                in: context
            )
            return
        }

        let payload = OperationRecordPayload(
            connectionID: id,
            capability: capability,
            operationKind: .adminGrant,
            outcome: .succeeded,
            failureKind: nil,
            denialReason: nil,
            requestSummary: request,
            resultSummary: .grantChanged(true),
            requestedAt: now,
            committedAt: now,
            changePosition: nil
        )
        if pair != nil {
            let grantRow = try Self.fetchGrantRow(
                connectionID: id,
                capability: capability,
                in: context
            )
            try commitGatewayMutation(
                config: config,
                payload: payload,
                in: context
            ) { committedAt in
                GatewayAdministration.regrantCurrentRow(
                    grantRow,
                    at: committedAt
                )
            }
        } else {
            let existingGrantCount = state.grants.lazy.filter {
                $0.connectionID == id
            }.count
            guard existingGrantCount
                    < ExternalLimits.standard.maximumGrantRowsPerConnection
            else {
                try commitGatewayAudit(
                    Self.deniedAdminPayload(
                        connectionID: id,
                        capability: capability,
                        operationKind: .adminGrant,
                        request: request,
                        at: now,
                        failureKind: .requestDenied,
                        denialReason: .invalidInput
                    ),
                    config: config,
                    in: context
                )
                throw ExternalFailure.requestDenied(.invalidInput)
            }
            let grantRow = GrantRow(
                grantKey: GatewayAdministration.canonicalGrantKey(
                    connectionID: id.rawValue,
                    capability: capability
                ),
                connectionIDRaw: id.rawValue,
                capabilityRaw: capability.rawValue,
                grantedAt: now,
                revokedAt: nil,
                configSchemaVersion: Self.gatewayConfigSchemaVersion
            )
            try commitGatewayMutation(
                config: config,
                payload: payload,
                in: context
            ) { committedAt in
                grantRow.grantedAt = committedAt
                context.insert(grantRow)
            }
        }
    }

    /// Revokes only the addressed pair. An absent or already-revoked pair is
    /// an audited no-op; it never creates a tombstone row.
    internal func revokeCapability(
        _ capability: ExternalCapability,
        of id: ExternalConnectionID
    ) async throws {
        let now = storageClock.now()
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let config = try Self.loadGatewayConfig(in: context)
        let state = try Self.loadGatewayState(
            appIntentsConnectionID: config.appIntentsConnectionID,
            in: context
        )
        let request = RequestSummaryV1.revokeCapability(
            connectionID: id.rawValue,
            capability: capability
        )
        guard let connection = state.connections.first(where: {
            $0.id == id
        }), GatewayAdministration.isGrantable(
            capability,
            to: connection.enrollKind
        ) else {
            try commitGatewayAudit(
                Self.deniedAdminPayload(
                    connectionID: id,
                    capability: capability,
                    operationKind: .adminRevokeCapability,
                    request: request,
                    at: now,
                    failureKind: .requestDenied,
                    denialReason: .invalidInput
                ),
                config: config,
                in: context
            )
            throw ExternalFailure.requestDenied(.invalidInput)
        }

        guard let pair = state.grants.first(where: {
            $0.connectionID == id && $0.capability == capability
        }), pair.revokedAt == nil else {
            try commitGatewayAudit(
                OperationRecordPayload(
                    connectionID: id,
                    capability: capability,
                    operationKind: .adminRevokeCapability,
                    outcome: .noOp,
                    failureKind: nil,
                    denialReason: nil,
                    requestSummary: request,
                    resultSummary: .capabilityRevoked(false),
                    requestedAt: now,
                    committedAt: now,
                    changePosition: nil
                ),
                config: config,
                in: context
            )
            return
        }

        let grantRow = try Self.fetchGrantRow(
            connectionID: id,
            capability: capability,
            in: context
        )
        let payload = OperationRecordPayload(
            connectionID: id,
            capability: capability,
            operationKind: .adminRevokeCapability,
            outcome: .succeeded,
            failureKind: nil,
            denialReason: nil,
            requestSummary: request,
            resultSummary: .capabilityRevoked(true),
            requestedAt: now,
            committedAt: now,
            changePosition: nil
        )
        try commitGatewayMutation(
            config: config,
            payload: payload,
            in: context
        ) { committedAt in
            grantRow.revokedAt = committedAt
        }
    }

    // MARK: Operation-local composition

    internal static func loadGatewayConfig(
        in context: ModelContext
    ) throws -> GatewayConfigRow {
        var descriptor = FetchDescriptor<GatewayConfigRow>()
        descriptor.fetchLimit = 2
        let rows: [GatewayConfigRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw ExternalFailure.persistence(.transaction)
        }
        guard rows.count == 1,
              let config = rows.first,
              config.key == gatewayConfigKey else {
            throw ExternalFailure.persistence(.invariantViolation)
        }
        guard config.configSchemaVersion == gatewayConfigSchemaVersion else {
            throw ExternalFailure.persistence(.corruptStoredValue)
        }
        return config
    }

    internal static func loadGatewayState(
        appIntentsConnectionID: UUID,
        in context: ModelContext
    ) throws -> GatewayCurrentState {
        do {
            return try GatewayAdministration.loadCurrentState(
                appIntentsConnectionID: appIntentsConnectionID,
                in: context
            )
        } catch let failure as HistoryFailure {
            switch failure {
            case .persistence(let persistence):
                switch persistence {
                case .openStore, .storeAlreadyOpen:
                    // The facade is already published; an operation-local
                    // fetch failure is a transaction/read failure, never a
                    // second open failure (`V2-05` §7.3.1).
                    throw ExternalFailure.persistence(.transaction)
                case .corruptStoredValue,
                     .invariantViolation,
                     .transaction:
                    throw ExternalFailure.persistence(persistence)
                }
            default:
                throw ExternalFailure.persistence(.invariantViolation)
            }
        } catch {
            throw ExternalFailure.persistence(.transaction)
        }
    }

    private static func fetchConnectionRow(
        _ id: ExternalConnectionID,
        in context: ModelContext
    ) throws -> ConnectionRow {
        var descriptor = FetchDescriptor<ConnectionRow>()
        descriptor.fetchLimit = ExternalLimits.standard.maximumConnections + 1
        let rows: [ConnectionRow]
        do {
            rows = try context.fetch(descriptor).filter { $0.id == id.rawValue }
        } catch {
            throw ExternalFailure.persistence(.transaction)
        }
        guard rows.count == 1, let row = rows.first else {
            throw ExternalFailure.persistence(.invariantViolation)
        }
        return row
    }

    private static func fetchGrantRows(
        connectionID: ExternalConnectionID,
        in context: ModelContext
    ) throws -> [GrantRow] {
        let maximumRows = ExternalLimits.standard.maximumConnections
            * ExternalLimits.standard.maximumGrantRowsPerConnection
        var descriptor = FetchDescriptor<GrantRow>()
        descriptor.fetchLimit = maximumRows + 1
        let rows: [GrantRow]
        do {
            rows = try context.fetch(descriptor).filter {
                $0.connectionIDRaw == connectionID.rawValue
            }
        } catch {
            throw ExternalFailure.persistence(.transaction)
        }
        guard rows.count
                <= ExternalLimits.standard.maximumGrantRowsPerConnection else {
            throw ExternalFailure.persistence(.invariantViolation)
        }
        return rows
    }

    private static func fetchGrantRow(
        connectionID: ExternalConnectionID,
        capability: ExternalCapability,
        in context: ModelContext
    ) throws -> GrantRow {
        let rows = try fetchGrantRows(
            connectionID: connectionID,
            in: context
        ).filter { $0.capabilityRaw == capability.rawValue }
        guard rows.count == 1, let row = rows.first else {
            throw ExternalFailure.persistence(.invariantViolation)
        }
        return row
    }

    private static func deniedAdminPayload(
        connectionID: ExternalConnectionID?,
        capability: ExternalCapability?,
        operationKind: ExternalOperationKind,
        request: RequestSummaryV1,
        at timestamp: Date,
        failureKind: ExternalFailureKindRaw,
        denialReason: ExternalDenialReason?
    ) -> OperationRecordPayload {
        OperationRecordPayload(
            connectionID: connectionID,
            capability: capability,
            operationKind: operationKind,
            outcome: .denied,
            failureKind: failureKind,
            denialReason: denialReason,
            requestSummary: request,
            resultSummary: .none,
            requestedAt: timestamp,
            committedAt: timestamp,
            changePosition: nil
        )
    }

    internal func commitGatewayAudit(
        _ payload: OperationRecordPayload,
        config: GatewayConfigRow,
        in context: ModelContext
    ) throws {
        try commitGatewayMutation(
            config: config,
            payload: payload,
            in: context,
            mutation: { _ in }
        )
    }

    private func commitGatewayMutation(
        config: GatewayConfigRow,
        payload: OperationRecordPayload,
        in context: ModelContext,
        mutation: (Date) -> Void
    ) throws {
        let committedAt = storageClock.now()
        let committedPayload = payload.committing(at: committedAt)
        do {
            try context.transaction {
                mutation(committedAt)
                _ = try GatewayAuditStore.append(
                    committedPayload,
                    config: config,
                    in: context
                )
                if consumeTransactionFailureInjection(
                    .beforeSingletonUpdate
                ) {
                    throw InjectedTransactionFailure.beforeSingletonUpdate
                }
                if consumeTransactionFailureInjection(
                    .insufficientDiskSpace
                ) {
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: CocoaError.Code.fileWriteOutOfSpace.rawValue
                    )
                }
            }
        } catch let failure as ExternalFailure {
            throw failure
        } catch {
            throw ExternalFailure.persistence(.transaction)
        }
    }
}
