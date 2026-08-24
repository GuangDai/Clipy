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
                    let externalPage = try Self.externalPage(
                        from: page,
                        revisionCounts: externalRevisionCounts(
                            for: page.rows.map(\.item.id),
                            in: context
                        )
                    )
                    return (
                        .page(externalPage),
                        try Self.pageSummary(externalPage)
                    )
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
                    let details = try externalDetails(for: id, in: context)
                    guard let representationCount = UInt16(
                        exactly: details.details.effective.count
                    ), let revisionCount = UInt16(
                        exactly: details.revisionCount
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
            do {
                let captured = try autoreleasepool {
                    try captureExternalSearchCorpus(
                        browseRequest,
                        descriptor: facts.descriptor,
                        connection: connection,
                        expectedConnectionKind: expectedConnectionKind,
                        requestedAt: requestedAt
                    )
                }
                let page = try await searchWorker.page(
                    browseRequest,
                    in: captured.snapshot,
                    continuationAnchor: captured.continuationAnchor,
                    processMarker: cursorProcessMarker
                )
                let externalPage = try Self.externalPage(
                    from: page,
                    revisionCounts: captured.revisionCounts
                )
                let summary = try Self.pageSummary(externalPage)
                try commitExternalReadAudit(
                    Self.succeededExternalReadPayload(
                        descriptor: facts.descriptor,
                        connection: connection,
                        result: summary,
                        requestedAt: requestedAt
                    )
                )
                return .page(externalPage)
            } catch let failure as HistoryFailure {
                try publishExternalReadFailure(
                    failure,
                    descriptor: facts.descriptor,
                    connection: connection,
                    requestedAt: requestedAt,
                    operation: .readSearch
                )
            } catch is CancellationError {
                try publishExternalSearchCancellation(
                    descriptor: facts.descriptor,
                    connection: connection,
                    requestedAt: requestedAt
                )
            }
        }
    }

    /// F1's authenticated Local Automation browse projection. This keeps the
    /// existing V1 `HistoryPage` result and never loads X.7's App-Intent-only
    /// revision-count entity facts (V2-05 §5.2/§7.1).
    internal func performLocalAutomationBrowsePreview(
        _ request: ExternalRead,
        connection: ExternalConnectionID,
        requestedAt: Date,
        searchWorker: SearchWorker
    ) async throws -> HistoryPage {
        let facts = try externalReadFacts(
            for: request,
            expectedConnectionKind: .localAutomation
        )

        switch request {
        case .recent(let limit):
            return try autoreleasepool {
                try performExternalReadInOneInterval(
                    descriptor: facts.descriptor,
                    connection: connection,
                    expectedConnectionKind: .localAutomation,
                    requestedAt: requestedAt,
                    operation: .readRecent
                ) { context in
                    let page = try recentPageInLocalContext(
                        limit: limit,
                        after: nil,
                        context: context
                    )
                    return (page, try Self.historyPageSummary(page))
                }
            }

        case .search:
            guard let browseRequest = facts.searchRequest else {
                throw ExternalFailure.persistence(.invariantViolation)
            }
            await suspendIfRequested(.readEntry)
            do {
                let captured = try autoreleasepool {
                    try captureLocalAutomationSearchCorpus(
                        browseRequest,
                        descriptor: facts.descriptor,
                        connection: connection,
                        requestedAt: requestedAt
                    )
                }
                let page = try await searchWorker.page(
                    browseRequest,
                    in: captured.snapshot,
                    continuationAnchor: captured.continuationAnchor,
                    processMarker: cursorProcessMarker
                )
                try commitExternalReadAudit(
                    Self.succeededExternalReadPayload(
                        descriptor: facts.descriptor,
                        connection: connection,
                        result: try Self.historyPageSummary(page),
                        requestedAt: requestedAt
                    )
                )
                return page
            } catch let failure as HistoryFailure {
                try publishExternalReadFailure(
                    failure,
                    descriptor: facts.descriptor,
                    connection: connection,
                    requestedAt: requestedAt,
                    operation: .readSearch
                )
            } catch is CancellationError {
                try publishExternalSearchCancellation(
                    descriptor: facts.descriptor,
                    connection: connection,
                    requestedAt: requestedAt
                )
            }

        case .details, .pastePayload:
            throw ExternalFailure.persistence(.invariantViolation)
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
    func performExternalReadInOneInterval<Result: Sendable>(
        descriptor: ExternalOperationDescriptor,
        connection: ExternalConnectionID,
        expectedConnectionKind: ConnectionEnrollKind,
        requestedAt: Date,
        operation: ExternalHistoryOperationContext,
        projection: (ModelContext) throws -> (Result, ResultSummaryV1)
    ) throws -> Result {
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
            try publishExternalReadFailure(
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
            try publishExternalReadFailure(
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
        continuationAnchor: StoredOrderingAnchor?,
        revisionCounts: [HistoryItemID: Int]
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
            let captured = try searchCorpusSnapshotInLocalContext(
                for: request,
                context: context
            )
            return (
                captured.snapshot,
                captured.continuationAnchor,
                try allExternalRevisionCounts(
                    for: captured.snapshot.rows.map(\.id),
                    in: context
                )
            )
        } catch let failure as HistoryFailure {
            try publishExternalSearchCaptureFailure(
                failure,
                descriptor: descriptor,
                connection: connection,
                requestedAt: requestedAt,
                config: config,
                in: context
            )
        }
    }

    func captureLocalAutomationSearchCorpus(
        _ request: HistoryBrowseRequest,
        descriptor: ExternalOperationDescriptor,
        connection: ExternalConnectionID,
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
            expectedConnectionKind: .localAutomation,
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
            try publishExternalSearchCaptureFailure(
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
    ) throws -> Never {
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
    ) throws -> Never {
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
    ) throws -> Never {
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

    func allExternalRevisionCounts(
        for itemIDs: [HistoryItemID],
        in context: ModelContext
    ) throws -> [HistoryItemID: Int] {
        guard Set(itemIDs).count == itemIDs.count else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        var descriptor = FetchDescriptor<RetainedBytesRow>()
        descriptor.propertiesToFetch = [
            \.itemID,
            \.revisionCount,
            \.bytesSchemaVersion
        ]
        descriptor.fetchLimit = limits.hardMaximumRetainedItems + 1
        let rows: [RetainedBytesRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }
        guard rows.count == itemIDs.count else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let counts = try externalRevisionCountMap(rows)
        guard Set(counts.keys) == Set(itemIDs) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return counts
    }

    /// Reads only the revision-count projection rows named by one already
    /// bounded external page. The UUID membership predicate and `fetchLimit`
    /// keep a small recent request independent of total retained-history size;
    /// the narrow validator below checks only X.7's schema/count facts.
    func externalRevisionCounts(
        for itemIDs: [HistoryItemID],
        in context: ModelContext
    ) throws -> [HistoryItemID: Int] {
        guard !itemIDs.isEmpty else { return [:] }
        let rawItemIDs = itemIDs.map(\.rawValue)
        guard Set(rawItemIDs).count == rawItemIDs.count else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        var descriptor = FetchDescriptor<RetainedBytesRow>(
            predicate: #Predicate { row in
                rawItemIDs.contains(row.itemID)
            }
        )
        descriptor.propertiesToFetch = [
            \.itemID,
            \.revisionCount,
            \.bytesSchemaVersion
        ]
        descriptor.fetchLimit = rawItemIDs.count + 1
        let rows: [RetainedBytesRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }
        guard rows.count == rawItemIDs.count else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return try externalRevisionCountMap(rows)
    }

    /// X.7 reads only the two scalar facts its entity projection consumes.
    /// Retention's byte-accounting validation remains owned by retention;
    /// unrelated canonical/revision byte corruption cannot broaden a browse
    /// or search failure. The schema/count bounds still fail closed.
    func externalRevisionCountMap(
        _ rows: [RetainedBytesRow]
    ) throws -> [HistoryItemID: Int] {
        var counts: [HistoryItemID: Int] = [:]
        counts.reserveCapacity(rows.count)
        for row in rows {
            let id = HistoryItemID(rawValue: row.itemID)
            guard counts[id] == nil else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            guard row.bytesSchemaVersion
                    == RetainedBytesStamping.bytesSchemaVersion,
                  row.revisionCount >= 0,
                  row.revisionCount <= limits.maximumRevisionsPerItem
            else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            counts[id] = row.revisionCount
        }
        return counts
    }

    static func externalPage(
        from page: HistoryPage,
        revisionCounts: [HistoryItemID: Int]
    ) throws -> ExternalHistoryPage {
        let rows = try page.rows.map { row in
            guard let revisionCount = revisionCounts[row.item.id] else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            return ExternalHistoryRow(
                row: row,
                revisionCount: revisionCount
            )
        }
        return ExternalHistoryPage(
            position: page.position,
            rows: rows,
            next: page.next
        )
    }

    static func pageSummary(
        _ page: ExternalHistoryPage
    ) throws -> ResultSummaryV1 {
        guard let count = UInt16(exactly: page.rows.count) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return .page(returnedCount: count, hasMore: page.next != nil)
    }

    static func historyPageSummary(
        _ page: HistoryPage
    ) throws -> ResultSummaryV1 {
        guard let count = UInt16(exactly: page.rows.count) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return .page(returnedCount: count, hasMore: page.next != nil)
    }

}
