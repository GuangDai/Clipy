/// Bounded search-corpus snapshot capture (§14.2).
/// Split out of HistoryAuthority.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

extension HistoryAuthority {
    internal func searchCorpusSnapshot(
        for request: HistoryBrowseRequest
    ) async throws -> (snapshot: SearchCorpusSnapshot, continuationAnchor: StoredOrderingAnchor?) {
        // WS12 seam: the one legal suspension point of this path — no
        // context is live yet (§5).
        await suspendIfRequested(.readEntry)
        return try searchCorpusSnapshotInLocalContext(for: request)
    }

    /// Synchronous V1 corpus projection used after the caller has crossed its
    /// owning read-entry suspension. Keeping context creation here lets the
    /// external read path perform its live grant gate plus capture in one
    /// non-suspending Authority interval (`V2-05` §5.2).
    internal func searchCorpusSnapshotInLocalContext(
        for request: HistoryBrowseRequest,
        context callerContext: ModelContext? = nil
    ) throws -> (
        snapshot: SearchCorpusSnapshot,
        continuationAnchor: StoredOrderingAnchor?
    ) {
#if DEBUG
        let debugClock = ContinuousClock()
        let debugTrace = SearchDebugTrace(id: UUID(), startedAt: debugClock.now)
        let debugTraceID = debugTrace.id
        let debugTotalStart = debugTrace.startedAt
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "authority",
            phase: "entry",
            phaseElapsed: debugTotalStart.duration(to: debugClock.now),
            totalElapsed: debugTotalStart.duration(to: debugClock.now)
        )
        let debugAdmissionStart = debugClock.now
#endif

        // Preserve §16's page-limit precedence, then perform REVIEW Card 11A
        // caller-input admission before cursor resolution, ModelContext
        // creation, and corpus fetch. The SearchWorker repeats the same closed
        // checks defensively after the immutable corpus crosses the actor
        // boundary.
        guard limits.pageRowLimitRange.contains(request.limit) else {
            throw HistoryFailure.invalidInput(.invalidPageLimit)
        }
        _ = try AdmittedSearchRequest(request, limits: limits)

        // §6 steps 1–2: decode the cursor and verify shape match. The
        // position check runs inside the interval below.
        let resolvedCursor: ResolvedPageCursor?
        if let cursor = request.after {
            do {
                resolvedCursor = try Self.decodeCursor(
                    cursor,
                    request: request,
                    processMarker: processMarker
                )
            } catch is PageCursorRejection {
                // §16: cursor decode/shape failure → `.snapshotExpired`.
                let pos = try readPositionInLocalContext()
                throw HistoryFailure.snapshotExpired(current: pos)
            }
        } else {
            resolvedCursor = nil
        }

#if DEBUG
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "authority",
            phase: "request-admission",
            phaseElapsed: debugAdmissionStart.duration(to: debugClock.now),
            totalElapsed: debugTotalStart.duration(to: debugClock.now)
        )
        let debugContextStart = debugClock.now
#endif

        let context = callerContext ?? ModelContext(container)
        context.autosaveEnabled = false

#if DEBUG
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "authority",
            phase: "context-create",
            phaseElapsed: debugContextStart.duration(to: debugClock.now),
            totalElapsed: debugTotalStart.duration(to: debugClock.now)
        )
        let debugPositionStart = debugClock.now
#endif

        // ── Non-suspending read interval (§5): no `await` past this
        //    line while the context or fetched rows are live. ──

        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §6 step 3: position recheck.
        if let cursor = resolvedCursor {
            guard cursor.position == currentPosition else {
                throw HistoryFailure.snapshotExpired(current: currentPosition)
            }
        }

#if DEBUG
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "authority",
            phase: "position-read",
            phaseElapsed: debugPositionStart.duration(to: debugClock.now),
            totalElapsed: debugTotalStart.duration(to: debugClock.now)
        )
        let debugFetchStart = debugClock.now
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "authority",
            phase: "corpus-fetch-begin",
            phaseElapsed: .zero,
            totalElapsed: debugTotalStart.duration(to: debugClock.now)
        )
#endif

        // §14.2: capture scalar fields for EVERY retained row, bounded by the
        // hard retained-item maximum. Scalar-only — no content blob decode.
        var descriptor = FetchDescriptor<HistoryItemRow>()
        descriptor.propertiesToFetch = Self.scalarProjectionProperties(
            includingSearchBody: true
        )
        descriptor.fetchLimit = limits.hardMaximumRetainedItems + 1
        let rows: [HistoryItemRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }
        guard rows.count <= limits.hardMaximumRetainedItems else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

#if DEBUG
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "authority",
            phase: "corpus-fetch",
            phaseElapsed: debugFetchStart.duration(to: debugClock.now),
            totalElapsed: debugTotalStart.duration(to: debugClock.now),
            rowsProcessed: rows.count,
            rowsTotal: rows.count
        )
        let debugProjectionStart = debugClock.now
        var debugTitleUTF8Bytes = 0
        var debugBodyUTF8Bytes = 0
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "authority",
            phase: "corpus-projection-begin",
            phaseElapsed: .zero,
            totalElapsed: debugTotalStart.duration(to: debugClock.now),
            rowsTotal: rows.count
        )
#endif

        // Build the corpus rows and sort by the default order (pinned ordinal
        // ascending, then lastCopiedAt DESC + id ASC) so exact/regexp preserve
        // the default order (§14.2; 03b §8).
        var corpusRows: [SearchCorpusRow] = []
        corpusRows.reserveCapacity(rows.count)
        for row in rows {
            // Bind the row's scalar values first: the non-Sendable @Model
            // row must not be captured by the `mapCodecFailure` closures
            // (actor-isolated context — sending the row risks data races).
            let identifiersBlob = row.effectiveTypeIdentifiersBlob
            let contentVersionRaw = row.contentVersionRaw
            let projectionSchemaVersion = row.projectionSchemaVersion
            let title = row.title
            let searchBody = row.searchBody
            let lastCopiedAt = row.lastCopiedAt
            let copyCount = row.copyCount
            let lastSource = row.lastSource
            let rawPinOrdinal = row.pinOrdinal
            let projectionSize = try mapCodecFailure {
                let size = try ContentProjector.validateStoredProjection(
                    schemaVersion: projectionSchemaVersion,
                    title: title,
                    searchBody: searchBody,
                    limits: limits
                )
                try RevisionStateBlobCodec.validateFiniteLastCopiedAt(
                    lastCopiedAt
                )
                try RevisionStateBlobCodec.validateCopyCount(copyCount)
                try RevisionStateBlobCodec.validateSourceObservation(
                    lastSource,
                    limits: limits
                )
                return size
            }
#if DEBUG
            debugTitleUTF8Bytes += projectionSize.titleUTF8Bytes
            debugBodyUTF8Bytes += projectionSize.searchBodyUTF8Bytes
#else
            _ = projectionSize
#endif
            let typeIdentifiers = try mapCodecFailure {
                try EffectiveTypeIdentifiersBlobCodec.decode(
                    identifiersBlob,
                    limits: limits
                )
            }
            let contentVersion = try mapCodecFailure {
                try RevisionStateBlobCodec.decodeContentVersion(contentVersionRaw)
            }
            let pinOrdinal = try mapCodecFailure {
                try RevisionStateBlobCodec.decodePinOrdinal(rawPinOrdinal)
            }
            let corpusRow: SearchCorpusRow
#if DEBUG
            corpusRow = SearchCorpusRow(
                id: HistoryItemID(rawValue: row.id),
                contentVersion: contentVersion,
                title: title,
                searchBody: searchBody,
                debugTitleUTF8Bytes: projectionSize.titleUTF8Bytes,
                debugSearchBodyUTF8Bytes: projectionSize.searchBodyUTF8Bytes,
                typeIdentifiers: typeIdentifiers,
                lastCopiedAt: lastCopiedAt,
                copyCount: copyCount,
                lastSource: lastSource,
                pinOrdinal: pinOrdinal
            )
#else
            corpusRow = SearchCorpusRow(
                id: HistoryItemID(rawValue: row.id),
                contentVersion: contentVersion,
                title: title,
                searchBody: searchBody,
                typeIdentifiers: typeIdentifiers,
                lastCopiedAt: lastCopiedAt,
                copyCount: copyCount,
                lastSource: lastSource,
                pinOrdinal: pinOrdinal
            )
#endif
            corpusRows.append(corpusRow)
#if DEBUG
            let debugProcessedRows = corpusRows.count
            let debugIsProgressBoundary = debugProcessedRows.isMultiple(
                of: SearchDebugProbe.progressRowInterval
            )
            if debugIsProgressBoundary || debugProcessedRows == rows.count {
                searchDebugProbe.record(
                    traceID: debugTraceID,
                    component: "authority",
                    phase: "corpus-projection-progress",
                    phaseElapsed: debugProjectionStart.duration(to: debugClock.now),
                    totalElapsed: debugTotalStart.duration(to: debugClock.now),
                    rowsProcessed: debugProcessedRows,
                    rowsTotal: rows.count,
                    titleUTF8Bytes: debugTitleUTF8Bytes,
                    bodyUTF8Bytes: debugBodyUTF8Bytes
                )
            }
#endif
        }
#if DEBUG
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "authority",
            phase: "corpus-projection-complete",
            phaseElapsed: debugProjectionStart.duration(to: debugClock.now),
            totalElapsed: debugTotalStart.duration(to: debugClock.now),
            rowsProcessed: corpusRows.count,
            rowsTotal: rows.count,
            titleUTF8Bytes: debugTitleUTF8Bytes,
            bodyUTF8Bytes: debugBodyUTF8Bytes
        )
        let debugSortStart = debugClock.now
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "authority",
            phase: "corpus-sort-begin",
            phaseElapsed: .zero,
            totalElapsed: debugTotalStart.duration(to: debugClock.now),
            rowsTotal: corpusRows.count
        )
#endif
        corpusRows.sort { lhs, rhs in
            Self.defaultOrderIsOrdered(lhs, rhs)
        }

#if DEBUG
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "authority",
            phase: "corpus-sort",
            phaseElapsed: debugSortStart.duration(to: debugClock.now),
            totalElapsed: debugTotalStart.duration(to: debugClock.now),
            rowsProcessed: corpusRows.count,
            rowsTotal: rows.count,
            titleUTF8Bytes: debugTitleUTF8Bytes,
            bodyUTF8Bytes: debugBodyUTF8Bytes
        )
#endif

#if DEBUG
        let snapshot = SearchCorpusSnapshot(
            position: currentPosition,
            rows: corpusRows,
            debugTrace: debugTrace
        )
#else
        let snapshot = SearchCorpusSnapshot(
            position: currentPosition,
            rows: corpusRows
        )
#endif
#if DEBUG
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "authority",
            phase: "complete",
            phaseElapsed: debugTotalStart.duration(to: debugClock.now),
            totalElapsed: debugTotalStart.duration(to: debugClock.now),
            rowsProcessed: corpusRows.count,
            rowsTotal: rows.count,
            titleUTF8Bytes: debugTitleUTF8Bytes,
            bodyUTF8Bytes: debugBodyUTF8Bytes
        )
#endif
        return (snapshot, resolvedCursor?.anchor)
    }

    /// Detail (docs/05-authority-kernel.md §14.3; docs/03b-instruction-set.md
    /// §9): fetches exactly one row, decodes/validates its full lineage, and
    /// maps it to the public detail DTO.
    ///
    /// One non-suspending read interval: no WS12 seam — detail is a one-shot
    /// caller query, not an observe-loop step.
    ///
    /// - Throws: `.notFound(id)` when the target is not retained; the codec
    ///   decode mappings (`.persistence(.corruptStoredValue)`, §4/§16);
    ///   `.temporarilyUnavailable(.factProof)` for a framework fetch failure;
    ///   `.persistence(.invariantViolation)` for corrupt lineage
    ///   (`effectiveContent` → `DomainRejection.corruptLineage`).
}
