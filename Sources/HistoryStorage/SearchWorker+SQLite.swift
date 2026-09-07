/// V2-09 §4: one request owns one SQLite read transaction. Batches and a
/// bounded candidate window replace the former complete search corpus.
import Foundation
import Fuse
import HistoryCore
import HistoryDomain
import SQLite3

internal struct SearchPageResult: Sendable {
    let page: HistoryPage
    let revisionCounts: [HistoryItemID: Int]
}

extension SearchWorker {
    internal static let maximumBatchRows = 32
    internal static let maximumBatchUTF8Bytes = 1_048_576
    internal static let maximumSnapshotLifetime: Duration = .seconds(30)

    internal func page(
        _ request: HistoryBrowseRequest,
        store: HistoryStoreLocation,
        processMarker: UUID,
        expectedPosition: ChangePosition? = nil
    ) async throws -> HistoryPage {
        try await scanSQLite(
            request, store: store, processMarker: processMarker,
            expectedPosition: expectedPosition, includesRevisionCounts: false
        ).page
    }

    internal func searchPage(
        _ request: HistoryBrowseRequest,
        store: HistoryStoreLocation,
        processMarker: UUID,
        expectedPosition: ChangePosition? = nil
    ) async throws -> SearchPageResult {
        try await scanSQLite(
            request, store: store, processMarker: processMarker,
            expectedPosition: expectedPosition, includesRevisionCounts: true
        )
    }

    private func scanSQLite(
        _ request: HistoryBrowseRequest,
        store: HistoryStoreLocation,
        processMarker: UUID,
        expectedPosition: ChangePosition?,
        includesRevisionCounts: Bool
    ) async throws -> SearchPageResult {
        // Declared before connection/statement defers, so directory ownership
        // is released only after every request-owned SQLite handle closes.
        defer { withExtendedLifetime(store) {} }
        guard limits.pageRowLimitRange.contains(request.limit) else {
            throw HistoryFailure.invalidInput(.invalidPageLimit)
        }
        let admitted = try AdmittedSearchRequest(request, limits: limits)
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let startedAt = clock.now
        let lifetimeDeadline = startedAt.advanced(by: snapshotLifetime)
        // Prepared matchers stay confined to this worker and this request.
        let exact = admitted.mode == .exact ? ExactLiteralMatcher(term: admitted.term) : nil
        let fuzzy = admitted.mode == .fuzzy ? fuse.createPattern(from: admitted.term) : nil
        let regexp: NSRegularExpression?
        if admitted.mode == .regexp, !admitted.term.isEmpty {
            regexp = try NSRegularExpression(pattern: admitted.term)
        } else { regexp = nil }
        do {
            let database = try SQLiteDatabase(url: store.databaseURL, readOnly: true)
            defer { try? database.close() }
            try database.execute("BEGIN DEFERRED")
            defer { try? database.execute("ROLLBACK") }

            let positionStatement = try database.prepare(
                "SELECT changePosition FROM history_state WHERE key = 'retained-history'"
            )
            let position: ChangePosition
            do {
                defer { positionStatement.finalize() }
                guard try positionStatement.step() else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                guard try positionStatement.blobByteCount(at: 0) == 8 else {
                    throw HistoryFailure.persistence(.corruptStoredValue)
                }
                position = ChangePosition(rawValue: try sqliteUInt64(positionStatement.blob(at: 0)))
                guard try !positionStatement.step() else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
            }
            if let expectedPosition, position != expectedPosition {
                throw HistoryFailure.snapshotExpired(current: position)
            }
            let anchor: StoredOrderingAnchor?
            let direction: HistoryPageDirection
            if let cursor = request.cursor {
                do {
                    let decoded = try PageCursorCodec.decode(cursor, processMarker: processMarker)
                    guard decoded.position == position, decoded.queryShape.matches(request) else {
                        throw HistoryFailure.snapshotExpired(current: position)
                    }
                    anchor = decoded.anchor
                    direction = decoded.direction
                } catch is PageCursorRejection {
                    throw HistoryFailure.snapshotExpired(current: position)
                }
            } else {
                anchor = nil
                direction = .forward
            }

            await suspensionHandler?(.evaluationEntry)
            try checkSnapshotDeadline(lifetimeDeadline)
            let reader = SQLiteSearchRows(database: database, limits: limits)
            defer { reader.finish() }
            let directive = ScanDirective(continuationAnchor: anchor, maximumSurvivors: request.limit + 1,
                                          direction: direction)
            var tracker = OrderPreservingScanTracker(directive: directive)
            var ordered: [EvaluatedRow] = []
            var fuzzySelection = FuzzyPageSelection(directive: directive)
            var revisionCounts: [HistoryItemID: Int] = [:]
            var matchingComplete = false
            var regexpDeadline = clock.now.advanced(by: regexpEngineDeadline)
#if DEBUG
            var processed = 0
            let trace = SearchDebugTrace(id: UUID(), startedAt: startedAt)
            var matchedRows = 0
            var evaluatedRows = 0
            searchDebugProbe.record(
                traceID: trace.id, component: "worker", phase: "entry",
                phaseElapsed: .zero, totalElapsed: startedAt.duration(to: clock.now)
            )
#endif
            while true {
                try checkSnapshotDeadline(lifetimeDeadline)
                let fetchStarted = clock.now
                let batch = try reader.nextBatch(includesRevisionCounts: includesRevisionCounts)
                // The existing two-second regexp budget measures matching,
                // not newly introduced SQL batch fetch/yield latency.
                regexpDeadline = regexpDeadline.advanced(by: fetchStarted.duration(to: clock.now))
                guard !batch.rows.isEmpty else { break }
#if DEBUG
                processed += batch.rows.count
                searchDebugProbe.record(
                    traceID: trace.id, component: "worker", phase: "sqlite-batch",
                    phaseElapsed: fetchStarted.duration(to: clock.now),
                    totalElapsed: startedAt.duration(to: clock.now),
                    rowsProcessed: batch.rows.count, rowsTotal: processed,
                    sourceUTF8Bytes: batch.utf8Bytes
                )
                let snapshot = SearchCorpusSnapshot(position: position, rows: batch.rows, debugTrace: trace)
#else
                let snapshot = SearchCorpusSnapshot(position: position, rows: batch.rows)
#endif
                // Exact/regexp stop matching after lookahead, but continue
                // validating later stored rows: corrupt tail projections must
                // not become invisible merely because the page filled early.
                if !matchingComplete {
                    let evaluation: EvaluationResult
                    let isRankedFuzzy = admitted.mode == .fuzzy && !admitted.term.isEmpty
                    let survivorsSoFar = max(0, ordered.count - (anchor == nil ? 0 : 1))
                    let batchDirective = ScanDirective(
                        continuationAnchor: isRankedFuzzy || (direction == .forward && !ordered.isEmpty)
                            ? nil : anchor,
                        maximumSurvivors: isRankedFuzzy || direction == .backward
                            ? batch.rows.count + 1 : request.limit + 1 - survivorsSoFar,
                        direction: isRankedFuzzy ? .forward : direction
                    )
                    if admitted.term.isEmpty {
                        evaluation = evaluateRecentEquivalent(in: snapshot, directive: batchDirective)
                    } else {
                        switch admitted.mode {
                        case .exact:
                            evaluation = try await evaluateExact(
                                term: admitted.term, in: snapshot, directive: batchDirective,
                                preparedMatcher: exact
                            )
                        case .regexp:
                            evaluation = try await evaluateRegexp(
                                term: admitted.term, in: snapshot, directive: batchDirective,
                                preparedPattern: regexp, sharedEngineDeadline: regexpDeadline
                            )
                        case .fuzzy:
                            evaluation = try await evaluateFuzzy(
                                term: admitted.term, in: snapshot, directive: batchDirective,
                                preparedPattern: fuzzy
                            )
                        }
                    }
#if DEBUG
                    matchedRows += evaluation.debugMatchedRows
                    evaluatedRows += evaluation.debugRowsProcessed
#endif
                    for evaluated in evaluation.rows {
                        let compact = EvaluatedRow(
                            corpusRow: evaluated.corpusRow.replacingSearchBody(with: ""),
                            search: evaluated.search, anchor: evaluated.anchor
                        )
                        if admitted.mode == .fuzzy, !admitted.term.isEmpty {
                            guard let presentation = compact.search else {
                                throw HistoryFailure.persistence(.invariantViolation)
                            }
                            let score: Double
                            if case .fuzzyUnpinned(let value, _, _) = compact.anchor { score = value }
                            else { score = 0 }
                            fuzzySelection.insert(FuzzyHit(
                                corpusRow: compact.corpusRow, score: score,
                                search: presentation
                            ))
                        } else {
                            tracker.appendIfRetained(compact, to: &ordered)
                            if !tracker.recordMatch(ofRow: compact.anchor) {
                                matchingComplete = true
                                break
                            }
                        }
                    }
                    if includesRevisionCounts {
                        revisionCounts.merge(batch.revisionCounts) { _, new in new }
                        let retained = admitted.mode == .fuzzy && !admitted.term.isEmpty
                            ? fuzzySelection.retainedIDs : Set(ordered.map { $0.corpusRow.id })
                        revisionCounts = revisionCounts.filter { retained.contains($0.key) }
                    }
                }
                let yieldStarted = clock.now
#if DEBUG
                await suspensionHandler?(.sqliteBatchComplete)
#endif
                await Task.yield()
                regexpDeadline = regexpDeadline.advanced(by: yieldStarted.duration(to: clock.now))
            }
            try checkSnapshotDeadline(lifetimeDeadline)
            let evaluated = admitted.mode == .fuzzy && !admitted.term.isEmpty
                ? fuzzySelection.evaluatedRows() : ordered
#if DEBUG
            searchDebugProbe.record(
                traceID: trace.id, component: "worker", phase: "evaluation-complete",
                phaseElapsed: startedAt.duration(to: clock.now), totalElapsed: startedAt.duration(to: clock.now),
                rowsProcessed: evaluatedRows, rowsTotal: processed, matchedRows: matchedRows
            )
#endif
            let window = try Self.pageWindow(in: evaluated, anchor: anchor, direction: direction,
                                             limit: request.limit, position: position)
#if DEBUG
            searchDebugProbe.record(
                traceID: trace.id, component: "worker", phase: "continuation",
                phaseElapsed: .zero, totalElapsed: startedAt.duration(to: clock.now),
                rowsProcessed: window.rows.count, rowsTotal: evaluated.count, matchedRows: matchedRows
            )
            let materializationStart = clock.now
#endif
            var rows: [HistoryRow] = []
            rows.reserveCapacity(window.rows.count)
            var returnedCounts: [HistoryItemID: Int] = [:]
            for evaluated in window.rows {
                try checkSnapshotDeadline(lifetimeDeadline)
                let row: EvaluatedRow
                if case .bodyExcerpt? = evaluated.search {
                    // Fetch only this returned body's bytes from the same
                    // read transaction; top-K never retains K full bodies.
                    let statement = try database.prepare(
                        "SELECT searchBodyUTF8 FROM history_items WHERE id = ?",
                        bindings: [.text(evaluated.corpusRow.id.rawValue.uuidString)]
                    )
                    defer { statement.finalize() }
                    guard try statement.step() else {
                        throw HistoryFailure.persistence(.invariantViolation)
                    }
                    let bodyBytes = try statement.blob(at: 0)
                    let body = try mapCodecFailure {
                        try ContentProjector.decodeStoredSearchBody(bodyBytes, limits: limits)
                    }
                    row = EvaluatedRow(
                        corpusRow: evaluated.corpusRow.replacingSearchBody(with: body),
                        search: evaluated.search, anchor: evaluated.anchor
                    )
                } else {
                    row = evaluated
                }
                rows.append(materialize(row))
                if includesRevisionCounts {
                    guard let count = revisionCounts[row.corpusRow.id], count >= 0,
                          count <= limits.maximumRevisionsPerItem else {
                        throw HistoryFailure.persistence(.invariantViolation)
                    }
                    returnedCounts[row.corpusRow.id] = count
                }
            }
            let previous: HistoryPageCursor?
            if window.hasPrevious, let first = window.rows.first {
                previous = try Self.mintSearchCursor(at: first.anchor, direction: .backward,
                                                     request: request, position: position, processMarker: processMarker)
            } else { previous = nil }
            let next: HistoryPageCursor?
            if window.hasNext, let last = window.rows.last {
                next = try Self.mintSearchCursor(at: last.anchor, direction: .forward,
                                                 request: request, position: position, processMarker: processMarker)
            } else { next = nil }
            try checkSnapshotDeadline(lifetimeDeadline)
#if DEBUG
            searchDebugProbe.record(
                traceID: trace.id, component: "worker", phase: "page-materialization",
                phaseElapsed: materializationStart.duration(to: clock.now), totalElapsed: startedAt.duration(to: clock.now),
                rowsProcessed: rows.count, rowsTotal: evaluated.count, matchedRows: matchedRows
            )
            searchDebugProbe.record(
                traceID: trace.id, component: "worker", phase: "complete",
                phaseElapsed: startedAt.duration(to: clock.now), totalElapsed: startedAt.duration(to: clock.now),
                rowsProcessed: evaluatedRows, rowsTotal: processed, matchedRows: matchedRows
            )
#endif
            return SearchPageResult(
                page: HistoryPage(position: position, rows: rows, previous: previous, next: next),
                revisionCounts: returnedCounts
            )
        } catch let failure as SQLiteFailure {
            switch failure.primaryCode {
            case SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_FULL: throw failure.historyFailure
            default: throw HistoryFailure.temporarilyUnavailable(.factProof)
            }
        }
    }

    private func checkSnapshotDeadline(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock().now < deadline else {
            throw HistoryFailure.temporarilyUnavailable(.searchEngineDeadline)
        }
    }
}

private extension SearchCorpusRow {
    func replacingSearchBody(with body: String) -> SearchCorpusRow {
#if DEBUG
        SearchCorpusRow(
            id: id, contentVersion: contentVersion, title: title, searchBody: body,
            debugTitleUTF8Bytes: debugTitleUTF8Bytes, debugSearchBodyUTF8Bytes: debugSearchBodyUTF8Bytes,
            typeIdentifiers: typeIdentifiers, lastCopiedAt: lastCopiedAt, copyCount: copyCount,
            lastSource: lastSource, pinOrdinal: pinOrdinal
        )
#else
        SearchCorpusRow(
            id: id, contentVersion: contentVersion, title: title, searchBody: body,
            typeIdentifiers: typeIdentifiers, lastCopiedAt: lastCopiedAt, copyCount: copyCount,
            lastSource: lastSource, pinOrdinal: pinOrdinal
        )
#endif
    }
}

/// Synchronous SQL projection: the statement can keep one not-yet-consumed
/// SQLite row while a byte-full batch is evaluated, but never copies it into
/// that batch. No model graph, payload file or revision content is loaded.
private final class SQLiteSearchRows {
    let database: SQLiteDatabase
    let limits: HistoryLimits
    var statement: SQLiteStatement?
    var lane = 0
    var pendingRow = false

    init(database: SQLiteDatabase, limits: HistoryLimits) {
        self.database = database
        self.limits = limits
    }

    func finish() { statement?.finalize(); statement = nil }

    func nextBatch(includesRevisionCounts: Bool) throws -> (rows: [SearchCorpusRow], revisionCounts: [HistoryItemID: Int], utf8Bytes: Int) {
        var rows: [SearchCorpusRow] = []
        var counts: [HistoryItemID: Int] = [:]
        var byteCount = 0
        while rows.count < SearchWorker.maximumBatchRows {
            try Task.checkCancellation()
            if statement == nil {
                guard lane < 2 else { break }
                let condition = lane == 0 ? "pinOrdinal IS NOT NULL" : "pinOrdinal IS NULL"
                statement = try database.prepare("""
                    SELECT id,contentVersion,titleUTF8,searchBodyUTF8,effectiveTypeIdentifiersBlob,
                           lastCopiedAt,copyCount,lastSource,pinOrdinal,revisionCount
                    FROM history_items WHERE \(condition)
                    ORDER BY pinOrdinal ASC,lastCopiedAt DESC,id ASC
                    """)
            }
            guard let statement else { break }
            if !pendingRow {
                guard try statement.step() else {
                    finish()
                    lane += 1
                    continue
                }
                pendingRow = true
            }
            let titleBytes = try statement.blobByteCount(at: 2)
            let bodyBytes = try statement.blobByteCount(at: 3)
            let typeBytes = try statement.blobByteCount(at: 4)
            let sourceBytes = try statement.isNull(at: 7) ? 0 : statement.textByteCount(at: 7)
            guard titleBytes <= limits.maximumStoredTitleUTF8Bytes,
                  bodyBytes <= limits.maximumStoredSearchBodyUTF8Bytes,
                  typeBytes <= EffectiveTypeIdentifiersBlobCodec.maximumBlobBytes(limits: limits),
                  sourceBytes <= limits.maximumSourceApplicationObservationUTF8Bytes,
                  try statement.textByteCount(at: 0) == 36,
                  try statement.blobByteCount(at: 1) == 8,
                  try statement.blobByteCount(at: 6) == 8 else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            let rowBytes = titleBytes + bodyBytes + typeBytes + sourceBytes
            if !rows.isEmpty, byteCount + rowBytes > SearchWorker.maximumBatchUTF8Bytes { break }
            guard rowBytes <= SearchWorker.maximumBatchUTF8Bytes else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            let rawID = try statement.text(at: 0)
            guard let uuid = UUID(uuidString: rawID), uuid.uuidString == rawID else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            let row = try mapCodecFailure {
                let title = try ContentProjector.decodeStoredTitle(statement.blob(at: 2), limits: limits)
                let body = try ContentProjector.decodeStoredSearchBody(statement.blob(at: 3), limits: limits)
                let version = try RevisionStateBlobCodec.decodeContentVersion(sqliteUInt64(statement.blob(at: 1)))
                let types = try EffectiveTypeIdentifiersBlobCodec.decode(statement.blob(at: 4), limits: limits)
                let copiedAt = Date(timeIntervalSinceReferenceDate: try statement.real(at: 5))
                let copyCount = try sqliteUInt64(statement.blob(at: 6))
                let source = try statement.optionalText(at: 7)
                let ordinal = try statement.isNull(at: 8) ? nil : Int(exactly: statement.integer(at: 8))
                try RevisionStateBlobCodec.validateFiniteLastCopiedAt(copiedAt)
                try RevisionStateBlobCodec.validateCopyCount(copyCount)
                let pin = try RevisionStateBlobCodec.decodePinOrdinal(ordinal)
#if DEBUG
                return SearchCorpusRow(
                    id: HistoryItemID(rawValue: uuid), contentVersion: version, title: title, searchBody: body,
                    debugTitleUTF8Bytes: titleBytes, debugSearchBodyUTF8Bytes: bodyBytes,
                    typeIdentifiers: types, lastCopiedAt: copiedAt, copyCount: copyCount,
                    lastSource: source, pinOrdinal: pin
                )
#else
                return SearchCorpusRow(
                    id: HistoryItemID(rawValue: uuid), contentVersion: version, title: title, searchBody: body,
                    typeIdentifiers: types, lastCopiedAt: copiedAt, copyCount: copyCount,
                    lastSource: source, pinOrdinal: pin
                )
#endif
            }
            if includesRevisionCounts, let count = try? statement.integer(at: 9), let exact = Int(exactly: count) {
                counts[row.id] = exact
            }
            rows.append(row)
            byteCount += rowBytes
            pendingRow = false
        }
        return (rows, counts, byteCount)
    }
}
