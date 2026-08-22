/// X.4 audited Gateway administration reads and healthy-store rebase.
/// Owning spec: `V2-05` §4.3/§4.4/§5.4–§5.6 and roadmap X.4/GW3.
///
/// Every read first constructs an immutable DTO array or typed failure. The
/// Authority then crosses the mandatory audit transaction before publishing
/// either value. `GatewayAuditStore` remains the sole audit row/counter owner.
import Foundation
import HistoryCore
import SwiftData

extension HistoryAuthority {
    /// Returns the bounded validated connection projection after committing
    /// one global raw-17 administration-read record.
    internal func connections() async throws -> [ConnectionDTO] {
        let now = storageClock.now()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let config = try Self.loadGatewayConfig(in: context)
        let request = RequestSummaryV1.readConnections

        let result: [ConnectionDTO]
        do {
            result = try Self.loadGatewayState(
                appIntentsConnectionID: config.appIntentsConnectionID,
                in: context
            ).connections
        } catch {
            let failure = Self.gatewayReadFailure(from: error)
            try commitGatewayAudit(
                Self.failedAdminReadPayload(
                    connectionID: nil,
                    operationKind: .adminReadConnections,
                    request: request,
                    failure: failure,
                    at: now
                ),
                config: config,
                in: context
            )
            throw failure
        }

        guard let count = UInt16(exactly: result.count) else {
            let failure = ExternalFailure.persistence(.invariantViolation)
            try commitGatewayAudit(
                Self.failedAdminReadPayload(
                    connectionID: nil,
                    operationKind: .adminReadConnections,
                    request: request,
                    failure: failure,
                    at: now
                ),
                config: config,
                in: context
            )
            throw failure
        }
        try commitGatewayAudit(
            Self.succeededAdminReadPayload(
                connectionID: nil,
                operationKind: .adminReadConnections,
                request: request,
                result: .connections(returnedCount: count),
                at: now
            ),
            config: config,
            in: context
        )
        return result
    }

    /// Returns the bounded validated current grants for one connection after
    /// committing one target-attributed, capability-free raw-18 record.
    internal func grants(
        for id: ExternalConnectionID
    ) async throws -> [GrantDTO] {
        let now = storageClock.now()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let config = try Self.loadGatewayConfig(in: context)
        let request = RequestSummaryV1.readGrants(
            connectionID: id.rawValue
        )

        let state: GatewayCurrentState
        do {
            state = try Self.loadGatewayState(
                appIntentsConnectionID: config.appIntentsConnectionID,
                in: context
            )
        } catch {
            let failure = Self.gatewayReadFailure(from: error)
            try commitGatewayAudit(
                Self.failedAdminReadPayload(
                    connectionID: id,
                    operationKind: .adminReadGrants,
                    request: request,
                    failure: failure,
                    at: now
                ),
                config: config,
                in: context
            )
            throw failure
        }

        guard state.connections.contains(where: { $0.id == id }) else {
            let failure = ExternalFailure.requestDenied(.invalidInput)
            try commitGatewayAudit(
                Self.failedAdminReadPayload(
                    connectionID: id,
                    operationKind: .adminReadGrants,
                    request: request,
                    failure: failure,
                    at: now
                ),
                config: config,
                in: context
            )
            throw failure
        }
        let result = state.grants.filter { $0.connectionID == id }
        guard let count = UInt16(exactly: result.count) else {
            let failure = ExternalFailure.persistence(.invariantViolation)
            try commitGatewayAudit(
                Self.failedAdminReadPayload(
                    connectionID: id,
                    operationKind: .adminReadGrants,
                    request: request,
                    failure: failure,
                    at: now
                ),
                config: config,
                in: context
            )
            throw failure
        }
        try commitGatewayAudit(
            Self.succeededAdminReadPayload(
                connectionID: id,
                operationKind: .adminReadGrants,
                request: request,
                result: .grants(returnedCount: count),
                at: now
            ),
            config: config,
            in: context
        )
        return result
    }

    /// Captures the exclusive audit head before decoding the fixed-size page,
    /// then commits the global raw-19 record before publishing the page or its
    /// typed failure. The new record therefore cannot appear in its own DTOs.
    internal func auditLog(
        since auditSequence: UInt64
    ) async throws -> [OperationRecordDTO] {
        let now = storageClock.now()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let config = try Self.loadGatewayConfig(in: context)
        let snapshotHead = config.nextAuditSequence
        let limit = ExternalLimits.standard.maxAuditReadBatchSize
        guard let encodedLimit = UInt16(exactly: limit) else {
            throw ExternalFailure.persistence(.invariantViolation)
        }
        let request = RequestSummaryV1.readAudit(
            since: auditSequence,
            limit: encodedLimit
        )
        guard auditSequence <= snapshotHead else {
            let failure = ExternalFailure.requestDenied(.invalidInput)
            try commitGatewayAudit(
                Self.failedAdminReadPayload(
                    connectionID: nil,
                    operationKind: .adminReadAudit,
                    request: request,
                    failure: failure,
                    at: now
                ),
                config: config,
                in: context
            )
            throw failure
        }

        let result: [OperationRecordDTO]
        do {
            result = try GatewayAuditStore.readPage(
                since: auditSequence,
                snapshotHead: snapshotHead,
                config: config,
                in: context
            )
        } catch {
            let failure = Self.gatewayReadFailure(from: error)
            try commitGatewayAudit(
                Self.failedAdminReadPayload(
                    connectionID: nil,
                    operationKind: .adminReadAudit,
                    request: request,
                    failure: failure,
                    at: now
                ),
                config: config,
                in: context
            )
            throw failure
        }

        guard let count = UInt16(exactly: result.count) else {
            let failure = ExternalFailure.persistence(.invariantViolation)
            try commitGatewayAudit(
                Self.failedAdminReadPayload(
                    connectionID: nil,
                    operationKind: .adminReadAudit,
                    request: request,
                    failure: failure,
                    at: now
                ),
                config: config,
                in: context
            )
            throw failure
        }
        try commitGatewayAudit(
            Self.succeededAdminReadPayload(
                connectionID: nil,
                operationKind: .adminReadAudit,
                request: request,
                result: .auditPage(
                    returnedCount: count,
                    snapshotHead: snapshotHead
                ),
                at: now
            ),
            config: config,
            in: context
        )
        return result
    }

    /// User-forced rebase discards the complete healthy retained prefix and
    /// leaves the central store's global marker as the new retained suffix.
    /// The ordinary facade cannot recover a store that normal open rejected;
    /// its `.corruptionDetected` spelling is therefore an audited denial.
    internal func rebaseAuditLog(
        reason: AuditRebaseReason
    ) async throws {
        let now = storageClock.now()

        switch reason {
        case .corruptionDetected:
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let config = try Self.loadGatewayConfig(in: context)
            let failure = ExternalFailure.requestDenied(.invalidInput)
            try commitGatewayAudit(
                Self.failedAdminReadPayload(
                    connectionID: nil,
                    operationKind: .adminRebase,
                    request: .rebase(reason: reason),
                    failure: failure,
                    at: now
                ),
                config: config,
                in: context
            )
            throw failure

        case .adminForced:
            let committedAt = storageClock.now()
            try commitAdminForcedRebase(
                requestedAt: now,
                committedAt: committedAt
            )
        }
    }
}

private extension HistoryAuthority {
    /// Private same-file bridge lets complete concurrency prove that the
    /// context-bound values never escape this Authority interval.
    @discardableResult
    func rebaseGatewayAudit(
        reason: AuditRebaseReason,
        newFloor: UInt64,
        requestedAt: Date,
        committedAt: Date,
        config: GatewayConfigRow,
        in context: ModelContext
    ) throws -> UInt64 {
        try GatewayAuditStore.rebase(
            reason: reason,
            newFloor: newFloor,
            requestedAt: requestedAt,
            committedAt: committedAt,
            config: config,
            in: context
        )
    }

    /// Keeps every context-bound value inside one synchronous actor interval.
    /// The async public witness owns no ModelContext or model row.
    func commitAdminForcedRebase(
        requestedAt: Date,
        committedAt: Date
    ) throws {
        do {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let config = try Self.loadGatewayConfig(in: context)
            let newFloor = config.nextAuditSequence
            try context.transaction {
                _ = try self.rebaseGatewayAudit(
                    reason: .adminForced,
                    newFloor: newFloor,
                    requestedAt: requestedAt,
                    committedAt: committedAt,
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
            let auditContext = ModelContext(container)
            auditContext.autosaveEnabled = false
            let auditConfig = try Self.loadGatewayConfig(in: auditContext)
            try commitGatewayAudit(
                Self.failedAdminReadPayload(
                    connectionID: nil,
                    operationKind: .adminRebase,
                    request: .rebase(reason: .adminForced),
                    failure: failure,
                    at: requestedAt
                ),
                config: auditConfig,
                in: auditContext
            )
            throw failure
        } catch {
            // A transaction/audit save failure is itself the publication
            // failure. It must not trigger a second append attempt.
            throw ExternalFailure.persistence(.transaction)
        }
    }

    static func succeededAdminReadPayload(
        connectionID: ExternalConnectionID?,
        operationKind: ExternalOperationKind,
        request: RequestSummaryV1,
        result: ResultSummaryV1,
        at timestamp: Date
    ) -> OperationRecordPayload {
        OperationRecordPayload(
            connectionID: connectionID,
            capability: nil,
            operationKind: operationKind,
            outcome: .succeeded,
            failureKind: nil,
            denialReason: nil,
            requestSummary: request,
            resultSummary: result,
            requestedAt: timestamp,
            committedAt: timestamp,
            changePosition: nil
        )
    }

    static func failedAdminReadPayload(
        connectionID: ExternalConnectionID?,
        operationKind: ExternalOperationKind,
        request: RequestSummaryV1,
        failure: ExternalFailure,
        at timestamp: Date
    ) -> OperationRecordPayload {
        OperationRecordPayload(
            connectionID: connectionID,
            capability: nil,
            operationKind: operationKind,
            outcome: failure.auditOutcome,
            failureKind: failure.auditFailureKind,
            denialReason: failure.auditDenialReason,
            requestSummary: request,
            resultSummary: .none,
            requestedAt: timestamp,
            committedAt: timestamp,
            changePosition: nil
        )
    }

    static func gatewayReadFailure(from error: any Error) -> ExternalFailure {
        if let failure = error as? ExternalFailure {
            return failure
        }
        return .persistence(.transaction)
    }
}

private extension ExternalFailure {
    var auditFailureKind: ExternalFailureKindRaw {
        switch self {
        case .unauthorized: .unauthorized
        case .connectionRevoked: .connectionRevoked
        case .requestDenied: .requestDenied
        case .notFound: .notFound
        case .history: .history
        case .temporarilyUnavailable: .temporarilyUnavailable
        case .persistence: .persistence
        case .auditCompactedBefore: .auditCompactedBefore
        }
    }

    var auditOutcome: ExternalOutcome {
        switch self {
        case .unauthorized, .connectionRevoked, .requestDenied:
            .denied
        case .notFound, .history, .temporarilyUnavailable, .persistence,
             .auditCompactedBefore:
            .failed
        }
    }

    var auditDenialReason: ExternalDenialReason? {
        if case .requestDenied(let reason) = self { return reason }
        return nil
    }
}
