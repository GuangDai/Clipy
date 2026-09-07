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

#if DEBUG
/// Process-crash evidence seam for V2-05 §5.2 / PLAY-PY-D5. The callback
/// runs only after a succeeded read audit transaction has committed and before
/// the immutable result crosses the Authority method boundary. It is package-
/// visible solely so `HistoryRestartProbe` can terminate its short-lived
/// process at that exact boundary; ordinary product calls leave it nil.
package enum ExternalReadPublicationDebugInstrumentation {
    @TaskLocal package static var afterSynchronousSuccessfulAuditCommit:
        (@Sendable () -> Void)?
    @TaskLocal internal static var beforeLocalAutomationSearchPublication:
        (@Sendable () async -> Void)?
}
#endif

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
                        after: nil
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
                    let details = try externalDetails(for: id)
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
                    let payload = try pastePayloadInCurrentTransaction(for: id)
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
                let result = try await evaluateAuthorizedSearch(
                    browseRequest, descriptor: facts.descriptor,
                    connection: connection, expectedConnectionKind: expectedConnectionKind,
                    requestedAt: requestedAt, searchWorker: searchWorker
                )
                let externalPage = try Self.externalPage(
                    from: result.page, revisionCounts: result.revisionCounts
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
        after: HistoryPageCursor? = nil,
        connection: ExternalConnectionID,
        requestedAt: Date,
        searchWorker: SearchWorker
    ) async throws -> HistoryPage {
        let facts = try externalReadFacts(
            for: request,
            expectedConnectionKind: .localAutomation,
            after: after
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
                        after: after
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
                let result = try await evaluateAuthorizedSearch(
                    browseRequest, descriptor: facts.descriptor,
                    connection: connection, expectedConnectionKind: .localAutomation,
                    requestedAt: requestedAt, searchWorker: searchWorker
                )
                let page = result.page
                // Local Automation revocation takes effect before content
                // publication, including while the search worker was away.
#if DEBUG
                await ExternalReadPublicationDebugInstrumentation
                    .beforeLocalAutomationSearchPublication?()
#endif
                try Task.checkCancellation()
                let context = database
                let config = try Self.loadGatewayConfig(in: context)
                try authorizeExternal(
                    facts.descriptor, as: connection,
                    expectedConnectionKind: .localAutomation,
                    requestedAt: requestedAt, config: config, in: context
                )
                try commitGatewayAudit(
                    Self.succeededExternalReadPayload(
                        descriptor: facts.descriptor,
                        connection: connection,
                        result: try Self.historyPageSummary(page),
                        requestedAt: requestedAt
                    ),
                    config: config,
                    in: context
                )
                return page
            } catch let failure as HistoryFailure {
                try publishExternalReadFailure(
                    failure,
                    descriptor: facts.descriptor,
                    connection: connection,
                    requestedAt: requestedAt,
                    operation: .readSearch,
                    expectedConnectionKind: .localAutomation
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

    /// Current Effective representations only. The existing paste projection
    /// supplies bytes, but neither its lineage hint nor any detail/revision
    /// DTO crosses this Local Automation operation (`V2-05` §0.2).
    internal func performLocalAutomationEffectiveRead(
        _ itemID: HistoryItemID,
        descriptor: ExternalOperationDescriptor,
        connection: ExternalConnectionID,
        requestedAt: Date
    ) throws -> (contentVersion: UInt64, representations: [HistoryRepresentation]) {
        try autoreleasepool {
            try performExternalReadInOneInterval(
                descriptor: descriptor, connection: connection,
                expectedConnectionKind: .localAutomation,
                requestedAt: requestedAt, operation: .readPastePayload
            ) { context in
                let payload = try pastePayloadInCurrentTransaction(for: itemID)
                let representations = payload.representations
                let totalBytes = representations.reduce(0) { $0 + $1.bytes.count }
                // 24,000,000 raw bytes fit below the existing 32 MiB JSON
                // reply cap after base64 and bounded representation metadata.
                guard totalBytes <= 24_000_000 else {
                    throw HistoryFailure.capacityExceeded(.storageBytes)
                }
                return ((payload.item.contentVersion.rawValue, representations), .effectiveContent(
                    representationCount: UInt16(representations.count),
                    totalBytes: UInt64(totalBytes)
                ))
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
        expectedConnectionKind: ConnectionEnrollKind,
        after: HistoryPageCursor? = nil
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
                    limit: limit,
                    after: after
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
        projection: (SQLiteDatabase) throws -> (Result, ResultSummaryV1)
    ) throws -> Result {
        let context = database
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
                expectedConnectionKind: expectedConnectionKind,
                config: config,
                in: context
            )
        }
#endif

        do {
            let (result, summary) = try context.readTransaction { try projection(context) }
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
#if DEBUG
            ExternalReadPublicationDebugInstrumentation
                .afterSynchronousSuccessfulAuditCommit?()
#endif
            return result
        } catch let failure as HistoryFailure {
            try publishExternalReadFailure(
                failure,
                descriptor: descriptor,
                connection: connection,
                requestedAt: requestedAt,
                operation: operation,
                expectedConnectionKind: expectedConnectionKind,
                config: config,
                in: context
            )
        }
    }

    /// A fresh request retries only a snapshot invalidated before its reader
    /// could start. Each attempt rechecks the grant; intermediate snapshots do
    /// not publish an operation result or audit. Continuations never rebase.
    func evaluateAuthorizedSearch(
        _ request: HistoryBrowseRequest,
        descriptor: ExternalOperationDescriptor,
        connection: ExternalConnectionID,
        expectedConnectionKind: ConnectionEnrollKind,
        requestedAt: Date,
        searchWorker: SearchWorker
    ) async throws -> SearchPageResult {
        while true {
            try Task.checkCancellation()
            let position = try captureExternalSearchPosition(
                descriptor: descriptor, connection: connection,
                expectedConnectionKind: expectedConnectionKind, requestedAt: requestedAt
            )
            do {
                switch expectedConnectionKind {
                case .appIntents:
                    return try await searchWorker.searchPage(
                        request, store: storeLocation, processMarker: cursorProcessMarker,
                        expectedPosition: position
                    )
                case .localAutomation:
                    let page = try await searchWorker.page(
                        request, store: storeLocation, processMarker: cursorProcessMarker,
                        expectedPosition: position
                    )
                    return SearchPageResult(page: page, revisionCounts: [:])
                }
            } catch HistoryFailure.snapshotExpired(_) where request.after == nil {
                continue
            }
        }
    }

    /// Admission captures only the coherence position. SearchWorker owns the
    /// separate request-local SQLite read transaction and streams bounded rows.
    func captureExternalSearchPosition(
        descriptor: ExternalOperationDescriptor,
        connection: ExternalConnectionID,
        expectedConnectionKind: ConnectionEnrollKind,
        requestedAt: Date
    ) throws -> ChangePosition {
        let context = database
        let config = try Self.loadGatewayConfig(in: context)
        try authorizeExternal(
            descriptor, as: connection,
            expectedConnectionKind: expectedConnectionKind,
            requestedAt: requestedAt, config: config, in: context
        )
        do {
            return try readPositionInLocalContext()
        } catch let failure as HistoryFailure {
            try publishExternalReadFailure(
                failure, descriptor: descriptor, connection: connection,
                requestedAt: requestedAt, operation: .readSearch,
                expectedConnectionKind: expectedConnectionKind,
                config: config, in: context
            )
        }
    }

    func publishExternalSearchCaptureFailure(
        _ source: HistoryFailure,
        descriptor: ExternalOperationDescriptor,
        connection: ExternalConnectionID,
        requestedAt: Date,
        config: GatewayConfigRow,
        in context: SQLiteDatabase
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
        expectedConnectionKind: ConnectionEnrollKind = .appIntents,
        config: GatewayConfigRow? = nil,
        in callerContext: SQLiteDatabase? = nil
    ) throws -> Never {
        let mapping: ExternalHistoryFailureMapping
        switch (expectedConnectionKind, source) {
        case (.localAutomation, .snapshotExpired),
             (.localAutomation, .capacityExceeded(.storageBytes)):
            mapping = ExternalHistoryFailureMapping(
                failure: .history(source), auditFailureKind: .history,
                auditDenialReason: nil
            )
        default:
            mapping = mapExternalHistoryFailure(source, for: operation)
        }
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
        let context = database
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

    /// Same-transaction counts only for the bounded recent page. SearchWorker
    /// provides these values from its own read snapshot for search pages.
    func externalRevisionCounts(
        for itemIDs: [HistoryItemID],
        in context: SQLiteDatabase
    ) throws -> [HistoryItemID: Int] {
        guard !itemIDs.isEmpty else { return [:] }
        guard Set(itemIDs).count == itemIDs.count else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ",")
        let statement = try context.prepare(
            "SELECT id, revisionCount FROM history_items WHERE id IN (\(placeholders))",
            bindings: itemIDs.map { .text($0.rawValue.uuidString) }
        )
        var counts: [HistoryItemID: Int] = [:]
        while try statement.step() {
            guard let uuid = UUID(uuidString: try statement.text(at: 0)),
                  let count = Int(exactly: try statement.integer(at: 1)),
                  count >= 0, count <= limits.maximumRevisionsPerItem else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            counts[HistoryItemID(rawValue: uuid)] = count
        }
        guard counts.count == itemIDs.count else {
            throw HistoryFailure.persistence(.invariantViolation)
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
