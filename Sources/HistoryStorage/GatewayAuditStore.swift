/// Central X.4 audit persistence owner (`V2-05` §4.3–§4.6).
///
/// These synchronous operations run only on an Authority-owned ModelContext.
/// The caller supplies the transaction boundary so an external History/admin
/// mutation, its audit append, and any triggered trim share one commit. This
/// file is the sole owner of OperationRecordRow insertion/deletion and of the
/// three durable audit-counter mutations.
import Foundation
import HistoryCore
import SwiftData

internal struct OperationRecordPayload: Sendable {
    internal let connectionID: ExternalConnectionID?
    internal let capability: ExternalCapability?
    internal let operationKind: ExternalOperationKind
    internal let outcome: ExternalOutcome
    internal let failureKind: ExternalFailureKindRaw?
    internal let denialReason: ExternalDenialReason?
    internal let requestSummary: RequestSummaryV1
    internal let resultSummary: ResultSummaryV1
    internal let requestedAt: Date
    internal let committedAt: Date
    internal let changePosition: ChangePosition?

    internal init(
        connectionID: ExternalConnectionID?,
        capability: ExternalCapability?,
        operationKind: ExternalOperationKind,
        outcome: ExternalOutcome,
        failureKind: ExternalFailureKindRaw?,
        denialReason: ExternalDenialReason?,
        requestSummary: RequestSummaryV1,
        resultSummary: ResultSummaryV1,
        requestedAt: Date,
        committedAt: Date,
        changePosition: ChangePosition?
    ) {
        self.connectionID = connectionID
        self.capability = capability
        self.operationKind = operationKind
        self.outcome = outcome
        self.failureKind = failureKind
        self.denialReason = denialReason
        self.requestSummary = requestSummary
        self.resultSummary = resultSummary
        self.requestedAt = requestedAt
        self.committedAt = committedAt
        self.changePosition = changePosition
    }

    internal func committing(at committedAt: Date) -> Self {
        Self(
            connectionID: connectionID,
            capability: capability,
            operationKind: operationKind,
            outcome: outcome,
            failureKind: failureKind,
            denialReason: denialReason,
            requestSummary: requestSummary,
            resultSummary: resultSummary,
            requestedAt: requestedAt,
            committedAt: committedAt,
            changePosition: changePosition
        )
    }
}

internal enum GatewayAuditStore {
    private static let auditSchemaVersion: UInt16 = 1

    /// Validates and stages every fallible calculation before inserting N and
    /// advancing the singleton to N+1. The enclosing Authority transaction is
    /// the save boundary (`V2-05` §5.4, D34/D36).
    @discardableResult
    internal static func append(
        _ payload: OperationRecordPayload,
        config: GatewayConfigRow,
        in context: ModelContext,
        limits: ExternalLimits = .standard
    ) throws -> UInt64 {
        do {
            let prepared = try prepareAppend(
                payload,
                config: config,
                limits: limits
            )
            applyAppend(prepared, config: config, in: context)
            return prepared.sequence
        } catch let rejection as StoreRejection {
            throw rejection.externalFailure
        }
    }

    /// Decodes at most one admitted page from the caller's frozen exclusive
    /// head. The audit entry describing this read is appended only after this
    /// immutable page has been built, so it cannot recursively appear here.
    internal static func readPage(
        since: UInt64,
        snapshotHead: UInt64,
        config: GatewayConfigRow,
        in context: ModelContext,
        limits: ExternalLimits = .standard
    ) throws -> [OperationRecordDTO] {
        do {
            try validateConfig(config)
            guard since >= config.compactionFloor else {
                throw ExternalFailure.auditCompactedBefore(
                    floor: config.compactionFloor
                )
            }
            guard snapshotHead >= config.compactionFloor,
                  snapshotHead <= config.nextAuditSequence else {
                throw StoreRejection.invariantViolation
            }

            let lower = max(since, config.compactionFloor)
            guard lower < snapshotHead else { return [] }
            let rows = try fetchRows(
                lowerBound: lower,
                upperBound: snapshotHead,
                limit: limits.maxAuditReadBatchSize,
                in: context
            )

            var expected = lower
            var result: [OperationRecordDTO] = []
            result.reserveCapacity(rows.count)
            for row in rows {
                guard row.auditSequence == expected else {
                    throw StoreRejection.invariantViolation
                }
                result.append(try decodeDTO(
                    row,
                    config: config,
                    limits: limits
                ))
                expected = try checkedIncrement(expected)
            }

            // A short page before the frozen head is a durable gap. A full
            // page may have a valid continuation and remains bounded.
            if rows.count < limits.maxAuditReadBatchSize,
               expected < snapshotHead {
                throw StoreRejection.invariantViolation
            }
            return result
        } catch let failure as ExternalFailure {
            throw failure
        } catch let rejection as StoreRejection {
            throw rejection.externalFailure
        }
    }

    /// Startup's bounded retained-state walk. Only one sequence-keyed batch
    /// and one decoded payload exist at a time; no DTO array or whole-log
    /// materialization is created. Startup deliberately maps through the
    /// established HistoryFailure boundary rather than leaking ExternalFailure.
    internal static func validateRetainedState(
        config: GatewayConfigRow,
        in context: ModelContext,
        limits: ExternalLimits = .standard
    ) throws {
        do {
            try validateConfig(config)
            try requireNoRowsOutsideRetainedInterval(
                config: config,
                in: context
            )
            let total = try validateInterval(
                lowerBound: config.compactionFloor,
                upperBound: config.nextAuditSequence,
                config: config,
                in: context,
                limits: limits
            )
            guard total == config.auditBytes else {
                throw StoreRejection.invariantViolation
            }
        } catch let rejection as StoreRejection {
            throw rejection.historyFailure
        }
    }

    /// Runs one caller-scheduled pass. A pass first proves the ordinary
    /// retained interval, then appends one content-free marker and trims one
    /// oldest prefix. X.5 owns process-local cadence; the caller's transaction
    /// provides rollback atomicity.
    @discardableResult
    internal static func compactIfNeeded(
        now: Date,
        config: GatewayConfigRow,
        in context: ModelContext,
        limits: ExternalLimits = .standard
    ) throws -> Bool {
        do {
            guard now.timeIntervalSinceReferenceDate.isFinite else {
                throw StoreRejection.invariantViolation
            }
            try validateConfig(config)
            try requireNoRowsOutsideRetainedInterval(
                config: config,
                in: context
            )
            let validatedBytes = try validateInterval(
                lowerBound: config.compactionFloor,
                upperBound: config.nextAuditSequence,
                config: config,
                in: context,
                limits: limits
            )
            guard validatedBytes == config.auditBytes else {
                throw StoreRejection.invariantViolation
            }
            guard config.compactionFloor < config.nextAuditSequence else {
                return false
            }

            let provisionalFloor = try checkedIncrement(
                config.compactionFloor
            )
            let placeholder = maintenancePayload(
                request: .compact,
                result: .compacted(
                    oldFloor: config.compactionFloor,
                    newFloor: provisionalFloor,
                    discardedCount: 1,
                    discardedPayloadBytes: 0
                ),
                kind: .adminCompact,
                outcome: .succeeded,
                requestedAt: now,
                committedAt: now
            )
            let markerContribution = try prepareAppend(
                placeholder,
                config: config,
                limits: limits
            ).contribution
            let maximumBytes = try checkedUInt64(limits.maxAuditLogSize)
            let maximumAge = TimeInterval(limits.maxAuditAgeSeconds)

            var newFloor = config.compactionFloor
            var discardedCount: UInt32 = 0
            var discardedLogicalBytes: UInt64 = 0
            var discardedPayloadBytes: UInt64 = 0
            var cursor = config.compactionFloor
            var shouldContinue = true

            while cursor < config.nextAuditSequence, shouldContinue {
                let rows = try fetchRows(
                    lowerBound: cursor,
                    upperBound: config.nextAuditSequence,
                    limit: limits.maxAuditReadBatchSize,
                    in: context
                )
                guard !rows.isEmpty else {
                    throw StoreRejection.invariantViolation
                }
                for row in rows {
                    let elapsed = max(0, now.timeIntervalSince(row.committedAt))
                    let expired = elapsed > maximumAge
                    let bytesBeforeTrim = try checkedAdd(
                        config.auditBytes,
                        markerContribution
                    )
                    let bytesAfterPriorTrim = try checkedSubtract(
                        bytesBeforeTrim,
                        discardedLogicalBytes
                    )
                    let needsSizeTrim = config.auditBytes > maximumBytes
                        && bytesAfterPriorTrim > maximumBytes
                    guard expired || needsSizeTrim else {
                        shouldContinue = false
                        break
                    }

                    let contribution = try logicalContribution(
                        payloadByteCount: row.payloadBlob.count,
                        limits: limits
                    )
                    discardedLogicalBytes = try checkedAdd(
                        discardedLogicalBytes,
                        contribution
                    )
                    discardedPayloadBytes = try checkedAdd(
                        discardedPayloadBytes,
                        try checkedUInt64(row.payloadBlob.count)
                    )
                    discardedCount = try checkedIncrement(discardedCount)
                    newFloor = try checkedIncrement(row.auditSequence)
                    cursor = newFloor
                }
            }

            guard discardedCount > 0 else { return false }
            let marker = maintenancePayload(
                request: .compact,
                result: .compacted(
                    oldFloor: config.compactionFloor,
                    newFloor: newFloor,
                    discardedCount: discardedCount,
                    discardedPayloadBytes: discardedPayloadBytes
                ),
                kind: .adminCompact,
                outcome: .succeeded,
                requestedAt: now,
                committedAt: now
            )
            let prepared = try prepareAppend(
                marker,
                config: config,
                limits: limits
            )
            let finalAuditBytes = try checkedSubtract(
                prepared.resultingAuditBytes,
                discardedLogicalBytes
            )

            // All validation and arithmetic precede mutation. Fetch/delete is
            // batched and remains protected by the caller's transaction.
            applyAppend(prepared, config: config, in: context)
            try deletePrefix(
                lowerBound: config.compactionFloor,
                upperBound: newFloor,
                in: context,
                batchSize: limits.maxAuditReadBatchSize
            )
            config.auditBytes = finalAuditBytes
            config.compactionFloor = newFloor
            return true
        } catch let rejection as StoreRejection {
            throw rejection.externalFailure
        }
    }

}

extension HistoryAuthority {
    /// Owns the complete rebase interval. Only Sendable values enter this
    /// actor method; its SwiftData context and rows are created, transacted,
    /// and released without crossing an actor or suspension boundary.
    @discardableResult
    internal func rebaseGatewayAudit(
        reason: AuditRebaseReason,
        newFloor requestedFloor: UInt64?,
        requestedAt: Date,
        committedAt: Date,
        limits: ExternalLimits = .standard
    ) throws -> UInt64 {
        let transactionInjection: InjectedTransactionFailure?
        switch injectedTransactionFailure {
        case .beforeSingletonUpdate, .insufficientDiskSpace:
            transactionInjection = injectedTransactionFailure
        default:
            transactionInjection = nil
        }

        do {
            return try Self.executeGatewayRebase(
                in: container,
                reason: reason,
                requestedFloor: requestedFloor,
                requestedAt: requestedAt,
                committedAt: committedAt,
                limits: limits,
                transactionInjection: transactionInjection
            )
        } catch let injection as InjectedTransactionFailure {
            _ = consumeTransactionFailureInjection(injection)
            if injection == .insufficientDiskSpace {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.Code.fileWriteOutOfSpace.rawValue
                )
            }
            throw injection
        }
    }

    /// The nonisolated executor creates every SwiftData value locally. The
    /// actor calls it synchronously with Sendable inputs, so the transaction
    /// closure never captures actor-isolated rows, contexts, or `self`.
    private static func executeGatewayRebase(
        in container: ModelContainer,
        reason: AuditRebaseReason,
        requestedFloor: UInt64?,
        requestedAt: Date,
        committedAt: Date,
        limits: ExternalLimits,
        transactionInjection: InjectedTransactionFailure?
    ) throws -> UInt64 {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let config = try Self.loadGatewayConfig(in: context)
        let newFloor = requestedFloor ?? config.nextAuditSequence
        let markerSequence = config.nextAuditSequence

        do {
            try context.transaction {
                guard requestedAt.timeIntervalSinceReferenceDate.isFinite,
                      committedAt.timeIntervalSinceReferenceDate.isFinite else {
                    throw GatewayAuditStore.StoreRejection.invariantViolation
                }
                try GatewayAuditStore.validateConfig(config)
                let oldFloor = config.compactionFloor
                guard newFloor >= oldFloor,
                      newFloor <= config.nextAuditSequence else {
                    throw GatewayAuditStore.StoreRejection.invariantViolation
                }

                // Recovery may discard corrupt prefix payloads, but it
                // publishes only after the retained suffix is typed and
                // contiguous.
                try GatewayAuditStore.requireNoRowsAtOrAboveHead(
                    config: config,
                    in: context
                )
                let suffixBytes = try GatewayAuditStore.validateInterval(
                    lowerBound: newFloor,
                    upperBound: config.nextAuditSequence,
                    config: config,
                    in: context,
                    limits: limits
                )
                let prefixBytes: UInt64
                switch reason {
                case .adminForced:
                    try GatewayAuditStore.requireNoRowsOutsideRetainedInterval(
                        config: config,
                        in: context
                    )
                    let fullBytes = try GatewayAuditStore.validateInterval(
                        lowerBound: oldFloor,
                        upperBound: config.nextAuditSequence,
                        config: config,
                        in: context,
                        limits: limits
                    )
                    guard fullBytes == config.auditBytes else {
                        throw GatewayAuditStore.StoreRejection.invariantViolation
                    }
                    prefixBytes = try GatewayAuditStore.accountRawInterval(
                        lowerBound: oldFloor,
                        upperBound: newFloor,
                        in: context,
                        limits: limits
                    )
                    let recomputedBytes = try GatewayAuditStore.checkedAdd(
                        prefixBytes,
                        suffixBytes
                    )
                    guard recomputedBytes == config.auditBytes else {
                        throw GatewayAuditStore.StoreRejection.invariantViolation
                    }
                case .corruptionDetected:
                    // V1 marker bytes define discardedCount as
                    // newFloor-oldFloor. X.4 can quarantine malformed prefix
                    // values, but not a gapped or duplicated prefix.
                    try GatewayAuditStore.requireNoRowsBelowFloor(
                        config: config,
                        in: context
                    )
                    prefixBytes = try GatewayAuditStore.accountRawInterval(
                        lowerBound: oldFloor,
                        upperBound: newFloor,
                        in: context,
                        limits: limits
                    )
                }

                let intervalWidth = newFloor - oldFloor
                guard let discardedCount = UInt32(exactly: intervalWidth) else {
                    throw GatewayAuditStore.StoreRejection.invariantViolation
                }
                let marker = GatewayAuditStore.maintenancePayload(
                    request: .rebase(reason: reason),
                    result: .rebased(
                        oldFloor: oldFloor,
                        newFloor: newFloor,
                        discardedCount: discardedCount
                    ),
                    kind: .adminRebase,
                    outcome: .succeeded,
                    requestedAt: requestedAt,
                    committedAt: committedAt
                )
                let prepared = try GatewayAuditStore.prepareAppend(
                    marker,
                    config: config,
                    limits: limits,
                    accountingBase: reason == .corruptionDetected
                        ? suffixBytes
                        : nil
                )
                let finalAuditBytes: UInt64
                switch reason {
                case .adminForced:
                    finalAuditBytes = try GatewayAuditStore.checkedSubtract(
                        prepared.resultingAuditBytes,
                        prefixBytes
                    )
                case .corruptionDetected:
                    finalAuditBytes = prepared.resultingAuditBytes
                }

                GatewayAuditStore.applyAppend(
                    prepared,
                    config: config,
                    in: context
                )
                try GatewayAuditStore.deletePrefix(
                    lowerBound: oldFloor,
                    upperBound: newFloor,
                    in: context,
                    batchSize: limits.maxAuditReadBatchSize
                )
                config.auditBytes = finalAuditBytes
                config.compactionFloor = newFloor

                if transactionInjection == .beforeSingletonUpdate {
                    throw InjectedTransactionFailure.beforeSingletonUpdate
                }
                if transactionInjection == .insufficientDiskSpace {
                    throw InjectedTransactionFailure.insufficientDiskSpace
                }
            }
            return markerSequence
        } catch let rejection as GatewayAuditStore.StoreRejection {
            throw rejection.externalFailure
        } catch let failure as ExternalFailure {
            throw failure
        }
    }
}

// MARK: - Validation and projection

fileprivate extension GatewayAuditStore {
    struct PreparedAppend {
        let sequence: UInt64
        let nextSequence: UInt64
        let contribution: UInt64
        let resultingAuditBytes: UInt64
        let row: OperationRecordRow
    }

    enum StoreRejection: Error {
        case corruptStoredValue
        case invariantViolation
        case persistenceRead

        var historyFailure: HistoryFailure {
            switch self {
            case .corruptStoredValue:
                .persistence(.corruptStoredValue)
            case .invariantViolation:
                .persistence(.invariantViolation)
            case .persistenceRead:
                .persistence(.openStore)
            }
        }

        var externalFailure: ExternalFailure {
            switch self {
            case .corruptStoredValue:
                .persistence(.corruptStoredValue)
            case .invariantViolation:
                .persistence(.invariantViolation)
            case .persistenceRead:
                .persistence(.transaction)
            }
        }
    }

    static func prepareAppend(
        _ payload: OperationRecordPayload,
        config: GatewayConfigRow,
        limits: ExternalLimits,
        accountingBase: UInt64? = nil
    ) throws -> PreparedAppend {
        try validateConfig(config)
        guard payload.requestedAt.timeIntervalSinceReferenceDate.isFinite,
              payload.committedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw StoreRejection.invariantViolation
        }

        let codecContext = OperationPayloadRecordContextV1(
            connectionID: payload.connectionID?.rawValue,
            capability: payload.capability,
            operationKind: payload.operationKind,
            outcome: payload.outcome,
            failureKind: payload.failureKind,
            denialReason: payload.denialReason,
            changePosition: payload.changePosition?.rawValue,
            auditSequence: config.nextAuditSequence,
            compactionFloor: config.compactionFloor,
            nextAuditSequence: config.nextAuditSequence
        )
        let blob: Data
        do {
            blob = try OperationPayloadBlobCodec.encode(
                OperationPayloadBlobV1(
                    request: payload.requestSummary,
                    result: payload.resultSummary
                ),
                context: codecContext,
                limits: limits
            )
        } catch {
            throw StoreRejection.invariantViolation
        }

        let sequence = config.nextAuditSequence
        let nextSequence = try checkedIncrement(sequence)
        let contribution = try logicalContribution(
            payloadByteCount: blob.count,
            limits: limits
        )
        let resultingAuditBytes = try checkedAdd(
            accountingBase ?? config.auditBytes,
            contribution
        )
        let row = OperationRecordRow(
            auditSequence: sequence,
            connectionIDRaw: payload.connectionID?.rawValue,
            capabilityRaw: payload.capability?.rawValue,
            operationKindRaw: payload.operationKind.rawValue,
            outcomeRaw: payload.outcome.rawValue,
            failureKindRaw: payload.failureKind?.rawValue,
            denialReasonRaw: payload.denialReason?.rawValue,
            payloadBlob: blob,
            requestedAt: payload.requestedAt,
            committedAt: payload.committedAt,
            changePositionRaw: payload.changePosition?.rawValue,
            auditSchemaVersion: auditSchemaVersion
        )
        return PreparedAppend(
            sequence: sequence,
            nextSequence: nextSequence,
            contribution: contribution,
            resultingAuditBytes: resultingAuditBytes,
            row: row
        )
    }

    static func applyAppend(
        _ prepared: PreparedAppend,
        config: GatewayConfigRow,
        in context: ModelContext
    ) {
        context.insert(prepared.row)
        config.nextAuditSequence = prepared.nextSequence
        config.auditBytes = prepared.resultingAuditBytes
    }

    static func validateConfig(_ config: GatewayConfigRow) throws {
        guard config.configSchemaVersion
                == HistoryAuthority.gatewayConfigSchemaVersion else {
            throw StoreRejection.corruptStoredValue
        }
        guard config.key == HistoryAuthority.gatewayConfigKey,
              config.compactionFloor >= 1,
              config.nextAuditSequence >= 1,
              config.compactionFloor <= config.nextAuditSequence else {
            throw StoreRejection.invariantViolation
        }
    }

    static func decodeDTO(
        _ row: OperationRecordRow,
        config: GatewayConfigRow,
        limits: ExternalLimits
    ) throws -> OperationRecordDTO {
        let decoded = try decodePayload(row, config: config, limits: limits)
        guard let operationKind = ExternalOperationKind(
            rawValue: row.operationKindRaw
        ), let outcome = ExternalOutcome(rawValue: row.outcomeRaw) else {
            throw StoreRejection.corruptStoredValue
        }
        let affectedItemIDs: [HistoryItemID]?
        if case .affectedItemIDs(let rawIDs) = decoded.result {
            affectedItemIDs = rawIDs.map(HistoryItemID.init(rawValue:))
        } else {
            affectedItemIDs = nil
        }
        return OperationRecordDTO(
            auditSequence: row.auditSequence,
            connectionID: row.connectionIDRaw.map(
                ExternalConnectionID.init(rawValue:)
            ),
            capability: row.capabilityRaw.flatMap {
                ExternalCapability(rawValue: $0)
            },
            operationKind: operationKind,
            outcome: outcome,
            requestedAt: row.requestedAt,
            committedAt: row.committedAt,
            changePosition: row.changePositionRaw.map(ChangePosition.init(rawValue:)),
            failureKind: row.failureKindRaw.flatMap {
                ExternalFailureKindRaw(rawValue: $0)
            },
            denialReason: row.denialReasonRaw.flatMap {
                ExternalDenialReason(rawValue: $0)
            },
            affectedItemIDs: affectedItemIDs
        )
    }

    @discardableResult
    static func decodePayload(
        _ row: OperationRecordRow,
        config: GatewayConfigRow,
        limits: ExternalLimits
    ) throws -> OperationPayloadBlobV1 {
        guard row.auditSchemaVersion == auditSchemaVersion,
              row.requestedAt.timeIntervalSinceReferenceDate.isFinite,
              row.committedAt.timeIntervalSinceReferenceDate.isFinite,
              let operationKind = ExternalOperationKind(
                rawValue: row.operationKindRaw
              ),
              let outcome = ExternalOutcome(rawValue: row.outcomeRaw) else {
            throw StoreRejection.corruptStoredValue
        }
        let capability: ExternalCapability?
        if let raw = row.capabilityRaw {
            guard let decoded = ExternalCapability(rawValue: raw) else {
                throw StoreRejection.corruptStoredValue
            }
            capability = decoded
        } else {
            capability = nil
        }
        let failureKind: ExternalFailureKindRaw?
        if let raw = row.failureKindRaw {
            guard let decoded = ExternalFailureKindRaw(rawValue: raw) else {
                throw StoreRejection.corruptStoredValue
            }
            failureKind = decoded
        } else {
            failureKind = nil
        }
        let denialReason: ExternalDenialReason?
        if let raw = row.denialReasonRaw {
            guard let decoded = ExternalDenialReason(rawValue: raw) else {
                throw StoreRejection.corruptStoredValue
            }
            denialReason = decoded
        } else {
            denialReason = nil
        }

        do {
            return try OperationPayloadBlobCodec.decode(
                row.payloadBlob,
                context: OperationPayloadRecordContextV1(
                    connectionID: row.connectionIDRaw,
                    capability: capability,
                    operationKind: operationKind,
                    outcome: outcome,
                    failureKind: failureKind,
                    denialReason: denialReason,
                    changePosition: row.changePositionRaw,
                    auditSequence: row.auditSequence,
                    compactionFloor: config.compactionFloor,
                    nextAuditSequence: config.nextAuditSequence
                ),
                limits: limits
            )
        } catch {
            throw StoreRejection.corruptStoredValue
        }
    }

    static func validateInterval(
        lowerBound: UInt64,
        upperBound: UInt64,
        config: GatewayConfigRow,
        in context: ModelContext,
        limits: ExternalLimits
    ) throws -> UInt64 {
        var cursor = lowerBound
        var total: UInt64 = 0
        while cursor < upperBound {
            let rows = try fetchRows(
                lowerBound: cursor,
                upperBound: upperBound,
                limit: limits.maxAuditReadBatchSize,
                in: context
            )
            guard !rows.isEmpty else {
                throw StoreRejection.invariantViolation
            }
            for row in rows {
                guard row.auditSequence == cursor else {
                    throw StoreRejection.invariantViolation
                }
                try decodePayload(row, config: config, limits: limits)
                total = try checkedAdd(
                    total,
                    try logicalContribution(
                        payloadByteCount: row.payloadBlob.count,
                        limits: limits
                    )
                )
                cursor = try checkedIncrement(cursor)
            }
        }
        return total
    }

    static func accountRawInterval(
        lowerBound: UInt64,
        upperBound: UInt64,
        in context: ModelContext,
        limits: ExternalLimits
    ) throws -> UInt64 {
        var cursor = lowerBound
        var total: UInt64 = 0
        while cursor < upperBound {
            let rows = try fetchRows(
                lowerBound: cursor,
                upperBound: upperBound,
                limit: limits.maxAuditReadBatchSize,
                in: context
            )
            guard !rows.isEmpty else { break }
            for row in rows {
                guard row.auditSequence == cursor else {
                    throw StoreRejection.invariantViolation
                }
                total = try checkedAdd(
                    total,
                    try logicalContribution(
                        payloadByteCount: row.payloadBlob.count,
                        limits: limits
                    )
                )
                cursor = try checkedIncrement(row.auditSequence)
            }
        }
        guard cursor == upperBound else {
            throw StoreRejection.invariantViolation
        }
        return total
    }

    static func requireNoRowsOutsideRetainedInterval(
        config: GatewayConfigRow,
        in context: ModelContext
    ) throws {
        try requireNoRowsBelowFloor(config: config, in: context)
        try requireNoRowsAtOrAboveHead(config: config, in: context)
    }

    static func requireNoRowsBelowFloor(
        config: GatewayConfigRow,
        in context: ModelContext
    ) throws {
        let floor = config.compactionFloor
        var below = FetchDescriptor<OperationRecordRow>(
            predicate: #Predicate { $0.auditSequence < floor }
        )
        below.fetchLimit = 1
        do {
            guard try context.fetch(below).isEmpty else {
                throw StoreRejection.invariantViolation
            }
        } catch let rejection as StoreRejection {
            throw rejection
        } catch {
            throw StoreRejection.persistenceRead
        }
    }

    static func requireNoRowsAtOrAboveHead(
        config: GatewayConfigRow,
        in context: ModelContext
    ) throws {
        let head = config.nextAuditSequence
        var above = FetchDescriptor<OperationRecordRow>(
            predicate: #Predicate { $0.auditSequence >= head }
        )
        above.fetchLimit = 1
        do {
            guard try context.fetch(above).isEmpty else {
                throw StoreRejection.invariantViolation
            }
        } catch let rejection as StoreRejection {
            throw rejection
        } catch {
            throw StoreRejection.persistenceRead
        }
    }

    static func fetchRows(
        lowerBound: UInt64,
        upperBound: UInt64,
        limit: Int,
        in context: ModelContext
    ) throws -> [OperationRecordRow] {
        guard limit > 0 else { throw StoreRejection.invariantViolation }
        let lower = lowerBound
        let upper = upperBound
        var descriptor = FetchDescriptor<OperationRecordRow>(
            predicate: #Predicate {
                $0.auditSequence >= lower && $0.auditSequence < upper
            },
            sortBy: [SortDescriptor(\.auditSequence)]
        )
        descriptor.fetchLimit = limit
        do {
            return try context.fetch(descriptor)
        } catch {
            throw StoreRejection.persistenceRead
        }
    }

    static func deletePrefix(
        lowerBound: UInt64,
        upperBound: UInt64,
        in context: ModelContext,
        batchSize: Int
    ) throws {
        guard lowerBound < upperBound else { return }
        while true {
            let rows = try fetchRows(
                lowerBound: lowerBound,
                upperBound: upperBound,
                limit: batchSize,
                in: context
            )
            guard !rows.isEmpty else { return }
            for row in rows { context.delete(row) }
        }
    }

    static func logicalContribution(
        payloadByteCount: Int,
        limits: ExternalLimits
    ) throws -> UInt64 {
        try checkedAdd(
            try checkedUInt64(payloadByteCount),
            try checkedUInt64(limits.auditRecordAccountingOverheadBytes)
        )
    }

    static func maintenancePayload(
        request: RequestSummaryV1,
        result: ResultSummaryV1,
        kind: ExternalOperationKind,
        outcome: ExternalOutcome,
        requestedAt: Date,
        committedAt: Date
    ) -> OperationRecordPayload {
        OperationRecordPayload(
            connectionID: nil,
            capability: nil,
            operationKind: kind,
            outcome: outcome,
            failureKind: nil,
            denialReason: nil,
            requestSummary: request,
            resultSummary: result,
            requestedAt: requestedAt,
            committedAt: committedAt,
            changePosition: nil
        )
    }

    static func checkedUInt64(_ value: Int) throws -> UInt64 {
        guard let converted = UInt64(exactly: value) else {
            throw StoreRejection.invariantViolation
        }
        return converted
    }

    static func checkedIncrement(_ value: UInt64) throws -> UInt64 {
        let result = value.addingReportingOverflow(1)
        guard !result.overflow else {
            throw StoreRejection.invariantViolation
        }
        return result.partialValue
    }

    static func checkedIncrement(_ value: UInt32) throws -> UInt32 {
        let result = value.addingReportingOverflow(1)
        guard !result.overflow else {
            throw StoreRejection.invariantViolation
        }
        return result.partialValue
    }

    static func checkedAdd(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else {
            throw StoreRejection.invariantViolation
        }
        return result.partialValue
    }

    static func checkedSubtract(
        _ left: UInt64,
        _ right: UInt64
    ) throws -> UInt64 {
        let result = left.subtractingReportingOverflow(right)
        guard !result.overflow else {
            throw StoreRejection.invariantViolation
        }
        return result.partialValue
    }
}
