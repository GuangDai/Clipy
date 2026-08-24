/// X.6 Authority-owned granted external reads.
/// Owning spec: `V2-05` §3.1/§5.2 and X-BEHAVIOR-1.
///
/// Recent, details, and paste payload keep the live targeted gate, existing V1
/// projection, and mandatory audit append in one non-suspending Authority
/// interval over one fresh context. Search captures its immutable V1 corpus in
/// that same gated interval, awaits only the facade-owned `SearchWorker`, then
/// crosses a closing audit barrier without rechecking the grant. Revocation in
/// that documented window therefore takes effect on the next request.
import Foundation
import HistoryCore
import SwiftData

extension HistoryAuthority {
    internal func performExternalRead(
        _ request: ExternalRead,
        connection: ExternalConnectionID,
        expectedConnectionKind: ConnectionEnrollKind = .appIntents,
        requestedAt: Date,
        searchWorker: SearchWorker
    ) async throws -> ExternalReadResult {
        let facts = try externalReadFacts(
            for: request,
            expectedConnectionKind: expectedConnectionKind
        )

        switch request {
        case .recent(let limit):
            return try autoreleasepool {
                try performExternalReadInOneInterval(
                    descriptor: facts.descriptor,
                    connection: connection,
                    expectedConnectionKind: expectedConnectionKind,
                    requestedAt: requestedAt,
                    operation: .readRecent
                ) { context in
                    let page = try recentPageInLocalContext(
                        limit: limit,
                        after: nil,
                        context: context
                    )
                    return (.page(page), try Self.pageSummary(page))
                }
            }

        case .details(let id):
            return try autoreleasepool {
                try performExternalReadInOneInterval(
                    descriptor: facts.descriptor,
                    connection: connection,
                    expectedConnectionKind: expectedConnectionKind,
                    requestedAt: requestedAt,
                    operation: .readDetails
                ) { context in
                    let details = try details(for: id, in: context)
                    guard let representationCount = UInt16(
                        exactly: details.effective.count
                    ), let revisionCount = UInt16(
                        exactly: details.revisions.count
                    ) else {
                        throw HistoryFailure.persistence(.invariantViolation)
                    }
                    return (
                        .details(details),
                        .details(
                            effectiveRepresentationCount: representationCount,
                            revisionCount: revisionCount
                        )
                    )
                }
            }

        case .pastePayload(let id):
            return try autoreleasepool {
                try performExternalReadInOneInterval(
                    descriptor: facts.descriptor,
                    connection: connection,
                    expectedConnectionKind: expectedConnectionKind,
                    requestedAt: requestedAt,
                    operation: .readPastePayload
                ) { context in
                    let payload = try pastePayload(for: id, in: context)
                    guard let representationCount = UInt16(
                        exactly: payload.representations.count
                    ) else {
                        throw HistoryFailure.persistence(.invariantViolation)
                    }
                    return (
                        .pastePayload(payload),
                        .pastePayload(
                            representationCount: representationCount
                        )
                    )
                }
            }

        case .search:
            guard let browseRequest = facts.searchRequest else {
                throw ExternalFailure.persistence(.invariantViolation)
            }

            // The read-entry seam precedes the authoritative gate. Interval 1
            // then contains no await: live decision + scalar corpus capture.
            await suspendIfRequested(.readEntry)
            let captured = try autoreleasepool {
                try captureExternalSearchCorpus(
                    browseRequest,
                    descriptor: facts.descriptor,
                    connection: connection,
                    expectedConnectionKind: expectedConnectionKind,
                    requestedAt: requestedAt
                )
            }

            do {
                let page = try await searchWorker.page(
                    browseRequest,
                    in: captured.snapshot,
                    continuationAnchor: captured.continuationAnchor,
                    processMarker: cursorProcessMarker
                )
                let summary = try Self.pageSummary(page)
                try commitExternalReadAudit(
                    Self.succeededExternalReadPayload(
                        descriptor: facts.descriptor,
                        connection: connection,
                        result: summary,
                        requestedAt: requestedAt
                    )
                )
                return .page(page)
            } catch let failure as HistoryFailure {
                return try publishExternalReadFailure(
                    failure,
                    descriptor: facts.descriptor,
                    connection: connection,
                    requestedAt: requestedAt,
                    operation: .readSearch
                )
            } catch is CancellationError {
                return try publishExternalSearchCancellation(
                    descriptor: facts.descriptor,
                    connection: connection,
                    requestedAt: requestedAt
                )
            }
        }
    }
}

private extension HistoryAuthority {
    struct ExternalReadFacts: Sendable {
        let descriptor: ExternalOperationDescriptor
        let searchRequest: HistoryBrowseRequest?
    }

    func externalReadFacts(
        for request: ExternalRead,
        expectedConnectionKind: ConnectionEnrollKind
    ) throws
        -> ExternalReadFacts
    {
        let descriptor = try ExternalOperationDescriptor.forRead(
            request,
            expectedConnectionKind: expectedConnectionKind,
            limits: limits
        )
        if case .search(let text, let mode, let limit) = request {
            return ExternalReadFacts(
                descriptor: descriptor,
                searchRequest: HistoryBrowseRequest(
                    kind: .search(text: text, mode: mode),
                    limit: limit
                )
            )
        }
        return ExternalReadFacts(descriptor: descriptor, searchRequest: nil)
    }

    /// One fresh context owns the exact live decision, projection, and audit.
    func performExternalReadInOneInterval(
        descriptor: ExternalOperationDescriptor,
        connection: ExternalConnectionID,
        expectedConnectionKind: ConnectionEnrollKind,
        requestedAt: Date,
        operation: ExternalHistoryOperationContext,
        projection: (ModelContext) throws
            -> (ExternalReadResult, ResultSummaryV1)
    ) throws -> ExternalReadResult {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let config = try Self.loadGatewayConfig(in: context)
        try authorizeExternal(
            descriptor,
            as: connection,
            expectedConnectionKind: expectedConnectionKind,
            requestedAt: requestedAt,
            config: config,
            in: context
        )

#if DEBUG
        if let injectedFailure = ExternalFailureDebugInstrumentation
            .injectedFailure {
            return try publishExternalReadFailure(
                injectedFailure,
                descriptor: descriptor,
                connection: connection,
                requestedAt: requestedAt,
                operation: operation,
                config: config,
                in: context
            )
        }
#endif

        do {
            let (result, summary) = try projection(context)
            try commitGatewayAudit(
                Self.succeededExternalReadPayload(
                    descriptor: descriptor,
                    connection: connection,
                    result: summary,
                    requestedAt: requestedAt
                ),
                config: config,
                in: context
            )
            return result
        } catch let failure as HistoryFailure {
            return try publishExternalReadFailure(
                failure,
                descriptor: descriptor,
                connection: connection,
                requestedAt: requestedAt,
                operation: operation,
                config: config,
                in: context
            )
        }
    }

    func captureExternalSearchCorpus(
        _ request: HistoryBrowseRequest,
        descriptor: ExternalOperationDescriptor,
        connection: ExternalConnectionID,
        expectedConnectionKind: ConnectionEnrollKind,
        requestedAt: Date
    ) throws -> (
        snapshot: SearchCorpusSnapshot,
        continuationAnchor: StoredOrderingAnchor?
    ) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let config = try Self.loadGatewayConfig(in: context)
        try authorizeExternal(
            descriptor,
            as: connection,
            expectedConnectionKind: expectedConnectionKind,
            requestedAt: requestedAt,
            config: config,
            in: context
        )
        do {
            return try searchCorpusSnapshotInLocalContext(
                for: request,
                context: context
            )
        } catch let failure as HistoryFailure {
            return try publishExternalSearchCaptureFailure(
                failure,
                descriptor: descriptor,
                connection: connection,
                requestedAt: requestedAt,
                config: config,
                in: context
            )
        }
    }

    func publishExternalSearchCaptureFailure(
        _ source: HistoryFailure,
        descriptor: ExternalOperationDescriptor,
        connection: ExternalConnectionID,
        requestedAt: Date,
        config: GatewayConfigRow,
        in context: ModelContext
    ) throws -> (
        snapshot: SearchCorpusSnapshot,
        continuationAnchor: StoredOrderingAnchor?
    ) {
        let mapping = mapExternalHistoryFailure(source, for: .readSearch)
        try commitGatewayAudit(
            Self.failedExternalReadPayload(
                descriptor: descriptor,
                connection: connection,
                mapping: mapping,
                requestedAt: requestedAt
            ),
            config: config,
            in: context
        )
        throw mapping.failure
    }

    func publishExternalReadFailure(
        _ source: HistoryFailure,
        descriptor: ExternalOperationDescriptor,
        connection: ExternalConnectionID,
        requestedAt: Date,
        operation: ExternalHistoryOperationContext,
        config: GatewayConfigRow? = nil,
        in callerContext: ModelContext? = nil
    ) throws -> ExternalReadResult {
        let mapping = mapExternalHistoryFailure(source, for: operation)
        if let config, let callerContext {
            try commitGatewayAudit(
                Self.failedExternalReadPayload(
                    descriptor: descriptor,
                    connection: connection,
                    mapping: mapping,
                    requestedAt: requestedAt
                ),
                config: config,
                in: callerContext
            )
        } else {
            try commitExternalReadAudit(
                Self.failedExternalReadPayload(
                    descriptor: descriptor,
                    connection: connection,
                    mapping: mapping,
                    requestedAt: requestedAt
                )
            )
        }
        throw mapping.failure
    }

    func publishExternalSearchCancellation(
        descriptor: ExternalOperationDescriptor,
        connection: ExternalConnectionID,
        requestedAt: Date
    ) throws -> ExternalReadResult {
        let mapping = ExternalHistoryFailureMapping(
            failure: .temporarilyUnavailable(.cancelled),
            auditFailureKind: .temporarilyUnavailable,
            auditDenialReason: nil
        )
        try commitExternalReadAudit(
            Self.failedExternalReadPayload(
                descriptor: descriptor,
                connection: connection,
                mapping: mapping,
                requestedAt: requestedAt
            )
        )
        throw mapping.failure
    }

    func commitExternalReadAudit(_ payload: OperationRecordPayload) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let config = try Self.loadGatewayConfig(in: context)
        try commitGatewayAudit(payload, config: config, in: context)
    }

    static func succeededExternalReadPayload(
        descriptor: ExternalOperationDescriptor,
        connection: ExternalConnectionID,
        result: ResultSummaryV1,
        requestedAt: Date
    ) -> OperationRecordPayload {
        // Placeholder only: `commitGatewayAudit` samples the shared Storage
        // clock at the durability barrier and replaces this via
        // `OperationRecordPayload.committing(at:)` before append.
        OperationRecordPayload(
            connectionID: connection,
            capability: descriptor.capability,
            operationKind: descriptor.operationKind,
            outcome: .succeeded,
            failureKind: nil,
            denialReason: nil,
            requestSummary: descriptor.requestSummary,
            resultSummary: result,
            requestedAt: requestedAt,
            committedAt: requestedAt,
            changePosition: nil
        )
    }

    static func failedExternalReadPayload(
        descriptor: ExternalOperationDescriptor,
        connection: ExternalConnectionID,
        mapping: ExternalHistoryFailureMapping,
        requestedAt: Date
    ) -> OperationRecordPayload {
        // Placeholder only; the central audit commit owner overwrites it with
        // the later durability sample before encoding/insertion.
        OperationRecordPayload(
            connectionID: connection,
            capability: descriptor.capability,
            operationKind: descriptor.operationKind,
            outcome: mapping.auditDenialReason == nil ? .failed : .denied,
            failureKind: mapping.auditFailureKind,
            denialReason: mapping.auditDenialReason,
            requestSummary: descriptor.requestSummary,
            resultSummary: .none,
            requestedAt: requestedAt,
            committedAt: requestedAt,
            changePosition: nil
        )
    }

    static func pageSummary(_ page: HistoryPage) throws -> ResultSummaryV1 {
        guard let count = UInt16(exactly: page.rows.count) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return .page(returnedCount: count, hasMore: page.next != nil)
    }

}
