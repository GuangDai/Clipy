/// X.5 targeted external authorization and audited denial entry points.
/// Owning spec: `V2-05` §3.1/§5.1/§5.2 and D33–D35.
///
/// Both methods run as one non-suspending `HistoryAuthority` interval over a
/// fresh operation-local context. The Gateway may use a prior snapshot as a
/// fast-fail hint, but only this live targeted fetch is authoritative.
import Foundation
import HistoryCore
import SwiftData

/// The complete content-free classification needed to authorize and audit one
/// closed external operation. It carries no query text or returned content.
internal struct ExternalOperationDescriptor: Sendable {
    internal let capability: ExternalCapability
    internal let operationKind: ExternalOperationKind
    internal let requestSummary: RequestSummaryV1

    internal init(
        capability: ExternalCapability,
        operationKind: ExternalOperationKind,
        requestSummary: RequestSummaryV1
    ) {
        self.capability = capability
        self.operationKind = operationKind
        self.requestSummary = requestSummary
    }

    internal var requestMatchesOperation: Bool {
        switch (requestSummary, operationKind) {
        case (.recent, .readRecent),
             (.search, .readSearch),
             (.details, .readDetails),
             (.pastePayload, .readPastePayload),
             (.pin, .managePin),
             (.unpin, .manageUnpin),
             (.remove, .manageRemove),
             (.readEffectiveContent, .readEffectiveContent):
            true
        case (.enroll, _),
             (.grant, _),
             (.revokeConnection, _),
             (.rebase, _),
             (.compact, _),
             (.revokeCapability, _),
             (.readConnections, _),
             (.readGrants, _),
             (.readAudit, _),
             (.recent, _),
             (.search, _),
             (.details, _),
             (.pastePayload, _),
             (.pin, _),
             (.unpin, _),
             (.remove, _),
             (.readEffectiveContent, _):
            false
        }
    }
}

extension HistoryAuthority {
    /// Re-fetches and validates exactly one connection plus at most nine
    /// per-connection grant rows. Unknown connections and forbidden
    /// connection-kind/capability/operation triples are rejected before an
    /// audit row can attribute them to a known admitted connection.
    ///
    /// A known revoked connection or a known active connection without the
    /// requested live grant crosses the mandatory denied-audit publication
    /// barrier before its typed failure is released. Success writes nothing.
    internal func authorizeExternal(
        _ descriptor: ExternalOperationDescriptor,
        as connection: ExternalConnectionID
    ) throws {
        let requestedAt = storageClock.now()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let config = try Self.loadGatewayConfig(in: context)

        guard let current = try Self.loadExternalConnection(
            connection,
            config: config,
            in: context
        ) else {
            throw ExternalFailure.unauthorized(
                requestedCapability: descriptor.capability,
                connectionID: connection
            )
        }
        guard current.status == .active else {
            let failure = ExternalFailure.connectionRevoked(
                connectionID: connection
            )
            try commitGatewayAudit(
                Self.deniedExternalPayload(
                    descriptor,
                    connection: connection,
                    requestedAt: requestedAt,
                    failure: failure
                ),
                config: config,
                in: context
            )
            throw failure
        }
        let hasLiveGrant = try Self.hasValidatedLiveGrant(
            descriptor.capability,
            for: current,
            connection: connection,
            in: context
        )
        guard hasLiveGrant else {
            let failure = ExternalFailure.unauthorized(
                requestedCapability: descriptor.capability,
                connectionID: connection
            )
            try commitGatewayAudit(
                Self.deniedExternalPayload(
                    descriptor,
                    connection: connection,
                    requestedAt: requestedAt,
                    failure: failure
                ),
                config: config,
                in: context
            )
            throw failure
        }
    }

    /// Commits the process-local rate limiter's denial before publishing it.
    /// Rate denial intentionally precedes grant/status policy: only a known,
    /// structurally valid connection and admitted descriptor are required.
    internal func commitExternalRateDenial(
        _ descriptor: ExternalOperationDescriptor,
        as connection: ExternalConnectionID
    ) throws {
        let requestedAt = storageClock.now()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let config = try Self.loadGatewayConfig(in: context)

        guard try Self.loadExternalConnection(
            connection,
            config: config,
            in: context
        ) != nil else {
            throw ExternalFailure.unauthorized(
                requestedCapability: descriptor.capability,
                connectionID: connection
            )
        }
        let failure = ExternalFailure.requestDenied(.rateLimited)
        try commitGatewayAudit(
            Self.deniedExternalPayload(
                descriptor,
                connection: connection,
                requestedAt: requestedAt,
                failure: failure
            ),
            config: config,
            in: context
        )
    }

    /// Runs the X.4 maintenance primitive on the X.5 actor-owned dispatch
    /// cadence. The context and transaction stay inside the sole writer.
    internal func compactExternalAuditIfNeeded(
        limits: ExternalLimits
    ) throws {
        let now = storageClock.now()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let config = try Self.loadGatewayConfig(in: context)
        do {
            try context.transaction {
                _ = try GatewayAuditStore.compactIfNeeded(
                    now: now,
                    config: config,
                    in: context,
                    limits: limits
                )
            }
        } catch let failure as ExternalFailure {
            throw failure
        } catch {
            throw ExternalFailure.persistence(.transaction)
        }
    }
}

private extension HistoryAuthority {
    struct ValidatedExternalConnection {
        let kind: ConnectionEnrollKind
        let status: ConnectionStatus
        let enrolledAt: Date
    }

    static func loadExternalConnection(
        _ connection: ExternalConnectionID,
        config: GatewayConfigRow,
        in context: ModelContext
    ) throws -> ValidatedExternalConnection? {
        let rawID = connection.rawValue
        var descriptor = FetchDescriptor<ConnectionRow>(
            predicate: #Predicate { row in row.id == rawID }
        )
        descriptor.fetchLimit = 2
        let rows: [ConnectionRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw ExternalFailure.persistence(.transaction)
        }
        guard rows.count <= 1 else {
            throw ExternalFailure.persistence(.invariantViolation)
        }
        guard let row = rows.first else { return nil }

        guard row.configSchemaVersion == gatewayConfigSchemaVersion,
              let kind = ConnectionEnrollKind(rawValue: row.enrollKindRaw),
              let status = ConnectionStatus(rawValue: row.statusRaw),
              row.enrolledAt.timeIntervalSinceReferenceDate.isFinite,
              row.revokedAt?.timeIntervalSinceReferenceDate.isFinite ?? true
        else {
            throw ExternalFailure.persistence(.corruptStoredValue)
        }
        guard row.displayNameRaw.utf8.count
                <= ExternalLimits.standard.maximumDisplayNameUTF8Bytes,
              Self.connectionLifecycleIsCoherent(
                status: status,
                enrolledAt: row.enrolledAt,
                revokedAt: row.revokedAt
              ),
              rawID != config.appIntentsConnectionID
                || kind == .appIntents
                    && row.displayNameRaw == gatewayConnectionDisplayName
        else {
            throw ExternalFailure.persistence(.invariantViolation)
        }
        return ValidatedExternalConnection(
            kind: kind,
            status: status,
            enrolledAt: row.enrolledAt
        )
    }

    static func hasValidatedLiveGrant(
        _ requestedCapability: ExternalCapability,
        for connectionFacts: ValidatedExternalConnection,
        connection: ExternalConnectionID,
        in context: ModelContext
    ) throws -> Bool {
        let rawID = connection.rawValue
        let requestedRaw = requestedCapability.rawValue
        let impliedRaw = requestedCapability == .browse
            ? ExternalCapability.manage.rawValue
            : requestedRaw
        var descriptor = FetchDescriptor<GrantRow>(
            predicate: #Predicate { row in
                row.connectionIDRaw == rawID
                    && (row.capabilityRaw == requestedRaw
                        || row.capabilityRaw == impliedRaw)
            }
        )
        // At most the exact capability plus manage-implies-browse may match;
        // a third row proves a duplicate without loading unrelated grants.
        descriptor.fetchLimit = 3
        let rows: [GrantRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw ExternalFailure.persistence(.transaction)
        }
        guard rows.count
                <= ExternalLimits.standard.maximumGrantRowsPerConnection else {
            throw ExternalFailure.persistence(.invariantViolation)
        }

        var decodedCapabilities: [ExternalCapability] = []
        decodedCapabilities.reserveCapacity(rows.count)
        var hasLiveGrant = false
        for row in rows {
            guard row.configSchemaVersion == gatewayConfigSchemaVersion,
                  let capability = ExternalCapability(
                    rawValue: row.capabilityRaw
                  ),
                  row.grantedAt.timeIntervalSinceReferenceDate.isFinite,
                  row.revokedAt?.timeIntervalSinceReferenceDate.isFinite
                    ?? true else {
                throw ExternalFailure.persistence(.corruptStoredValue)
            }
            guard !decodedCapabilities.contains(capability),
                  row.grantKey == GatewayAdministration.canonicalGrantKey(
                    connectionID: rawID,
                    capability: capability
                  ),
                  GatewayAdministration.isGrantable(
                    capability,
                    to: connectionFacts.kind
                  ),
                  row.grantedAt >= connectionFacts.enrolledAt,
                  row.revokedAt.map({ $0 >= row.grantedAt }) ?? true
            else {
                throw ExternalFailure.persistence(.invariantViolation)
            }
            decodedCapabilities.append(capability)
            let capabilitySatisfiesRequest = capability == requestedCapability
                || requestedCapability == .browse && capability == .manage
            if capabilitySatisfiesRequest, row.revokedAt == nil {
                hasLiveGrant = true
            }
        }
        return hasLiveGrant
    }

    static func connectionLifecycleIsCoherent(
        status: ConnectionStatus,
        enrolledAt: Date,
        revokedAt: Date?
    ) -> Bool {
        switch status {
        case .active:
            revokedAt == nil
        case .revoked:
            revokedAt.map { $0 >= enrolledAt } ?? false
        }
    }

    static func deniedExternalPayload(
        _ descriptor: ExternalOperationDescriptor,
        connection: ExternalConnectionID,
        requestedAt: Date,
        failure: ExternalFailure
    ) -> OperationRecordPayload {
        let failureKind: ExternalFailureKindRaw
        let denialReason: ExternalDenialReason?
        switch failure {
        case .unauthorized:
            failureKind = .unauthorized
            denialReason = nil
        case .connectionRevoked:
            failureKind = .connectionRevoked
            denialReason = nil
        case .requestDenied(let reason):
            failureKind = .requestDenied
            denialReason = reason
        case .notFound,
             .history,
             .temporarilyUnavailable,
             .persistence,
             .auditCompactedBefore:
            preconditionFailure("external denial payload requires a denial")
        }
        return OperationRecordPayload(
            connectionID: connection,
            capability: descriptor.capability,
            operationKind: descriptor.operationKind,
            outcome: .denied,
            failureKind: failureKind,
            denialReason: denialReason,
            requestSummary: descriptor.requestSummary,
            resultSummary: .none,
            requestedAt: requestedAt,
            committedAt: requestedAt,
            changePosition: nil
        )
    }
}
