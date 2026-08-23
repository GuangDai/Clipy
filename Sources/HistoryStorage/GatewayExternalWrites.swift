/// X.6 Authority-owned positive manage writes.
/// Owning spec: `V2-05` §5.1/§6.4 and roadmap X.6.
///
/// The external entry maps the closed request to the existing placement
/// fact→plan→stamp→transaction spine. Successful writes add only an optional
/// audit payload to that one stamped plan; no-op, denied, and failed attempts
/// publish one separate audit barrier because they produce no History Commit.
import Foundation
import HistoryCore
import SwiftData

internal struct ExternalWriteCommitContext: Sendable {
    internal let connection: ExternalConnectionID
    internal let descriptor: ExternalOperationDescriptor
    internal let requestedAt: Date
}

internal enum ExternalWriteGateRejection: Error, Sendable {
    case incoherentPlan
    case unknownConnection(
        requestedCapability: ExternalCapability,
        connectionID: ExternalConnectionID
    )
    case denied(ExternalFailure)
}

private struct ExternalWriteAuditBarrierFailure: Error, Sendable {
    let failure: ExternalFailure
}

extension HistoryAuthority {
    /// Performs one admitted App Intents manage write. The actor caller owns
    /// pure admission/rate limiting; this Authority method owns every durable
    /// fact, the save-boundary grant recheck, mutation, HCR, audit, and result.
    internal func commitExternal(
        request: ExternalRequest,
        connection: ExternalConnectionID,
        requestedAt: Date
    ) async throws -> ExternalResponse {
        let write = ExternalWriteCommitContext(
            connection: connection,
            descriptor: .forRequest(request),
            requestedAt: requestedAt
        )
        let receipt: HistoryReceipt
        do {
#if DEBUG
            if let injectedFailure = ExternalFailureDebugInstrumentation
                .injectedFailure {
                throw injectedFailure
            }
#endif

            switch request {
            case .pin(let itemID):
                receipt = try await commitPinnedPlacement(
                    itemID,
                    .first,
                    externalWrite: write
                )
            case .unpin(let itemID):
                receipt = try await commitUnpin(
                    itemID,
                    externalWrite: write
                )
            case .remove(let itemID):
                receipt = try await commitRemove(
                    itemID,
                    externalWrite: write
                )
            }
        } catch let barrier as ExternalWriteAuditBarrierFailure {
            throw barrier.failure
        } catch {
            let publication = Self.externalWriteFailurePublication(
                from: error,
                write: write
            )
            guard publication.shouldAudit else {
                throw publication.failure
            }
            let publishedFailure = try commitExternalWriteFailureAudit(
                publication,
                write: write
            )
            throw publishedFailure
        }
        return try Self.externalResponse(from: receipt, request: request)
    }

    /// Adds the successful OperationRecord payload to the already-stamped
    /// internal plan. `committedAt` is the same StorageClock sample used by
    /// the HCR createdAt value.
    internal static func attachExternalWriteAudit(
        to stamped: StampedCommitPlan,
        write: ExternalWriteCommitContext,
        committedAt: Date
    ) throws -> StampedCommitPlan {
        guard let requestedID = write.descriptor.requestSummary.itemID else {
            throw StampingRejection.incoherentPlan
        }
        let itemID: UUID
        switch stamped.receiptOutcome {
        case .placedPinned(let id), .unpinned(let id):
            guard id.rawValue == requestedID else {
                throw StampingRejection.incoherentPlan
            }
            itemID = id.rawValue
        case .removed(let count):
            guard count == 1 else {
                throw StampingRejection.incoherentPlan
            }
            itemID = requestedID
        case .inserted, .coalesced, .cleared, .revised,
             .retentionPolicySet, .retentionPoliciesSet:
            throw StampingRejection.incoherentPlan
        }
        return try stamped.attachingAuditAppend(OperationRecordPayload(
            connectionID: write.connection,
            capability: write.descriptor.capability,
            operationKind: write.descriptor.operationKind,
            outcome: .succeeded,
            failureKind: nil,
            denialReason: nil,
            requestSummary: write.descriptor.requestSummary,
            resultSummary: .affectedItemIDs([itemID]),
            requestedAt: write.requestedAt,
            committedAt: committedAt,
            changePosition: stamped.position
        ))
    }

    /// Mandatory publication barrier for a planner no-op. It intentionally
    /// runs in its own small transaction and advances no History position.
    internal func commitExternalWriteNoOpAudit(
        _ write: ExternalWriteCommitContext,
        in context: ModelContext
    ) throws {
        let committedAt = storageClock.now()
        var publishedFailure: ExternalFailure?
        do {
            try context.transaction {
                let config = try Self.loadGatewayConfig(in: context)
                let decision = try Self.targetedExternalAuthorizationDecision(
                    write.descriptor,
                    connection: write.connection,
                    config: config,
                    in: context
                )
                let payload: OperationRecordPayload
                switch decision {
                case .authorized:
                    payload = Self.externalWriteNoOpPayload(
                        write,
                        committedAt: committedAt
                    )
                case .unknownConnection:
                    throw ExternalWriteGateRejection.unknownConnection(
                        requestedCapability: write.descriptor.capability,
                        connectionID: write.connection
                    )
                case .denied(let failure):
                    publishedFailure = failure
                    payload = Self.externalWriteFailurePayload(
                        write,
                        publication: Self.externalWriteFailurePublication(
                            from: ExternalWriteGateRejection.denied(failure),
                            write: write
                        ),
                        committedAt: committedAt
                    )
                }
                _ = try GatewayAuditStore.append(
                    payload,
                    config: config,
                    in: context
                )
            }
            if let publishedFailure {
                throw ExternalWriteAuditBarrierFailure(
                    failure: publishedFailure
                )
            }
        } catch let rejection as ExternalWriteGateRejection {
            let publication = Self.externalWriteFailurePublication(
                from: rejection,
                write: write
            )
            throw ExternalWriteAuditBarrierFailure(
                failure: publication.failure
            )
        } catch let barrier as ExternalWriteAuditBarrierFailure {
            throw barrier
        } catch let failure as ExternalFailure {
            throw ExternalWriteAuditBarrierFailure(failure: failure)
        } catch {
            throw ExternalWriteAuditBarrierFailure(
                failure: .persistence(.transaction)
            )
        }
    }

    /// Mandatory failure barrier. The live gate and the selected failed or
    /// denied record share this small transaction; no History fact or mutation
    /// is evaluated here.
    private func commitExternalWriteFailureAudit(
        _ original: ExternalWriteFailurePublication,
        write: ExternalWriteCommitContext
    ) throws -> ExternalFailure {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let committedAt = storageClock.now()
        var publishedFailure = original.failure
        do {
            try context.transaction {
                let config = try Self.loadGatewayConfig(in: context)
                let decision = try Self.targetedExternalAuthorizationDecision(
                    write.descriptor,
                    connection: write.connection,
                    config: config,
                    in: context
                )
                let publication: ExternalWriteFailurePublication
                switch decision {
                case .authorized:
                    publication = original
                case .unknownConnection:
                    throw ExternalWriteGateRejection.unknownConnection(
                        requestedCapability: write.descriptor.capability,
                        connectionID: write.connection
                    )
                case .denied(let failure):
                    publishedFailure = failure
                    publication = Self.externalWriteFailurePublication(
                        from: ExternalWriteGateRejection.denied(failure),
                        write: write
                    )
                }
                _ = try GatewayAuditStore.append(
                    Self.externalWriteFailurePayload(
                        write,
                        publication: publication,
                        committedAt: committedAt
                    ),
                    config: config,
                    in: context
                )
            }
        } catch let rejection as ExternalWriteGateRejection {
            let publication = Self.externalWriteFailurePublication(
                from: rejection,
                write: write
            )
            return publication.failure
        } catch let failure as ExternalFailure {
            throw failure
        } catch {
            throw ExternalFailure.persistence(.transaction)
        }
        return publishedFailure
    }
}

private extension HistoryAuthority {
    struct ExternalWriteFailurePublication: Sendable {
        let failure: ExternalFailure
        let shouldAudit: Bool
        let failureKind: ExternalFailureKindRaw
        let denialReason: ExternalDenialReason?
    }

    static func externalResponse(
        from receipt: HistoryReceipt,
        request: ExternalRequest
    ) throws -> ExternalResponse {
        switch receipt {
        case .unchanged:
            return .unchanged
        case .committed(let commit):
            switch (request, commit.outcome) {
            case (.pin(let requested), .placedPinned(let committed))
                    where requested == committed:
                return .pin(committed)
            case (.unpin(let requested), .unpinned(let committed))
                    where requested == committed:
                return .unpin(committed)
            case (.remove, .removed(let count)) where count == 1:
                return .removed(count: count)
            default:
                throw ExternalFailure.persistence(.invariantViolation)
            }
        }
    }

    static func externalWriteFailurePublication(
        from error: any Error,
        write: ExternalWriteCommitContext
    ) -> ExternalWriteFailurePublication {
        if let rejection = error as? ExternalWriteGateRejection {
            switch rejection {
            case .unknownConnection(let capability, let connectionID):
                return ExternalWriteFailurePublication(
                    failure: .unauthorized(
                        requestedCapability: capability,
                        connectionID: connectionID
                    ),
                    shouldAudit: false,
                    failureKind: .unauthorized,
                    denialReason: nil
                )
            case .denied(let failure):
                return ExternalWriteFailurePublication(
                    failure: failure,
                    shouldAudit: true,
                    failureKind: failure.auditFacts.kind,
                    denialReason: failure.auditFacts.denialReason
                )
            case .incoherentPlan:
                return ExternalWriteFailurePublication(
                    failure: .persistence(.invariantViolation),
                    shouldAudit: true,
                    failureKind: .persistence,
                    denialReason: nil
                )
            }
        }
        let failure: ExternalFailure
        let failureKind: ExternalFailureKindRaw
        let denialReason: ExternalDenialReason?
        if let external = error as? ExternalFailure {
            failure = external
            let facts = external.auditFacts
            failureKind = facts.kind
            denialReason = facts.denialReason
        } else if let history = error as? HistoryFailure {
            if let operation = write.descriptor.manageOperationContext {
                let mapping = mapExternalHistoryFailure(
                    history,
                    for: operation
                )
                failure = mapping.failure
                failureKind = mapping.auditFailureKind
                denialReason = mapping.auditDenialReason
            } else {
                failure = .persistence(.invariantViolation)
                failureKind = .persistence
                denialReason = nil
            }
        } else {
            failure = .persistence(.transaction)
            failureKind = .persistence
            denialReason = nil
        }
        return ExternalWriteFailurePublication(
            failure: failure,
            shouldAudit: true,
            failureKind: failureKind,
            denialReason: denialReason
        )
    }

    static func externalWriteFailurePayload(
        _ write: ExternalWriteCommitContext,
        publication: ExternalWriteFailurePublication,
        committedAt: Date
    ) -> OperationRecordPayload {
        return OperationRecordPayload(
            connectionID: write.connection,
            capability: write.descriptor.capability,
            operationKind: write.descriptor.operationKind,
            outcome: publication.failure.isDenial ? .denied : .failed,
            failureKind: publication.failureKind,
            denialReason: publication.denialReason,
            requestSummary: write.descriptor.requestSummary,
            resultSummary: .none,
            requestedAt: write.requestedAt,
            committedAt: committedAt,
            changePosition: nil
        )
    }

    static func externalWriteNoOpPayload(
        _ write: ExternalWriteCommitContext,
        committedAt: Date
    ) -> OperationRecordPayload {
        OperationRecordPayload(
            connectionID: write.connection,
            capability: write.descriptor.capability,
            operationKind: write.descriptor.operationKind,
            outcome: .noOp,
            failureKind: nil,
            denialReason: nil,
            requestSummary: write.descriptor.requestSummary,
            resultSummary: .affectedItemIDs([]),
            requestedAt: write.requestedAt,
            committedAt: committedAt,
            changePosition: nil
        )
    }
}

private extension ExternalOperationDescriptor {
    var manageOperationContext: ExternalHistoryOperationContext? {
        switch operationKind {
        case .managePin: .managePin
        case .manageUnpin: .manageUnpin
        case .manageRemove: .manageRemove
        case .readRecent, .readSearch, .readDetails, .readPastePayload,
             .adminEnroll, .adminGrant, .adminRevoke, .adminRebase,
             .adminCompact, .readEffectiveContent, .reviseContent,
             .describeFormatCapabilities, .adminRevokeCapability,
             .adminReadConnections, .adminReadGrants, .adminReadAudit:
            nil
        }
    }
}

private extension ExternalFailure {
    var isDenial: Bool {
        switch self {
        case .unauthorized, .connectionRevoked, .requestDenied: true
        case .notFound, .history, .temporarilyUnavailable, .persistence,
             .auditCompactedBefore: false
        }
    }

    var auditFacts: (
        kind: ExternalFailureKindRaw,
        denialReason: ExternalDenialReason?
    ) {
        switch self {
        case .unauthorized: (.unauthorized, nil)
        case .connectionRevoked: (.connectionRevoked, nil)
        case .requestDenied(let reason): (.requestDenied, reason)
        case .notFound: (.notFound, nil)
        case .history: (.history, nil)
        case .temporarilyUnavailable: (.temporarilyUnavailable, nil)
        case .persistence: (.persistence, nil)
        case .auditCompactedBefore: (.auditCompactedBefore, nil)
        }
    }
}

private extension RequestSummaryV1 {
    var itemID: UUID? {
        switch self {
        case .pin(let itemID), .unpin(let itemID), .remove(let itemID):
            itemID
        case .recent, .search, .details, .pastePayload, .enroll, .grant,
             .revokeConnection, .rebase, .compact, .readEffectiveContent,
             .revokeCapability, .readConnections, .readGrants, .readAudit:
            nil
        }
    }
}
