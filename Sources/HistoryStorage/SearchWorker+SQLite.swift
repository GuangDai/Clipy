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

    internal func measurePage(
        _ request: HistoryBrowseRequest, store: HistoryStoreLocation, processMarker: UUID
    ) async -> MeasuredSearchPage {
        let work = SearchWorkCounter()
        do {
            let result = try await scanSQLite(
                request, store: store, processMarker: processMarker,
                expectedPosition: nil, includesRevisionCounts: false, work: work
            )
            return MeasuredSearchPage(result: .success(result.page), metrics: work.snapshot())
        } catch {
            if error is CancellationError { work.stopReason = .cancelled }
            else if error as? HistoryFailure == .temporarilyUnavailable(.searchEngineDeadline) {
                work.stopReason = .deadline
            } else { work.stopReason = .failed }
            return MeasuredSearchPage(result: .failure(error), metrics: work.snapshot())
        }
    }

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
        includesRevisionCounts: Bool,
        work: SearchWorkCounter = SearchWorkCounter()
    ) async throws -> SearchPageResult {
        // Declared before connection/statement defers, so directory ownership
        // is released only after every request-owned SQLite handle closes.
        defer { withExtendedLifetime(store) {} }
        guard limits.pageRowLimitRange.contains(request.limit) else {
            throw HistoryFailure.invalidInput(.invalidPageLimit)
        }
        guard request.cursor == nil || request.startAround == nil else {
            throw HistoryFailure.invalidInput(.conflictingPageAnchors)
        }
        let admitted = try AdmittedSearchRequest(request, limits: limits)
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let startedAt = clock.now
        let lifetimeDeadline = startedAt.advanced(by: snapshotLifetime)
        // Prepared matchers stay confined to this worker and this request.
        let exact = admitted.mode == .exact ? ExactLiteralMatcher(term: admitted.term) : nil
        let expression = admitted.expression.map { PreparedSearchExpression($0.root) }
        let expressionPredicate = admitted.expression.map { HistoryFilterSQL.expressionPredicate($0.root) }
        let fuzzy = admitted.mode == .fuzzy ? fuse.createPattern(from: admitted.term) : nil
        let regexp: NSRegularExpression?
        if admitted.mode == .regexp, !admitted.term.isEmpty {
            regexp = try NSRegularExpression(pattern: admitted.term)
        } else { regexp = nil }
        do {
            let database = try SQLiteDatabase(storeLocation: store, readOnly: true)
            defer { try? database.close() }
            try database.execute("BEGIN DEFERRED")
            defer { try? database.execute("ROLLBACK") }
            try database.setReadInterruptionDeadline(lifetimeDeadline)
            defer { try? database.setReadInterruptionDeadline(nil) }

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
            var anchor: StoredOrderingAnchor?
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
            let hasExplicitOrder = request.sortOrder != .automatic
            var regexpDeadline = clock.now.advanced(by: regexpEngineDeadline)
            let seekHasPrevious: Bool
            if let target = request.startAround {
                let seek = try await resolveSearchStart(
                    target, request: request, admitted: admitted, database: database, position: position,
                    exact: exact, fuzzy: fuzzy, regexp: regexp, expression: expression,
                    expressionPredicate: expressionPredicate, lifetimeDeadline: lifetimeDeadline,
                    regexpDeadline: &regexpDeadline, work: work
                )
                anchor = seek.anchor
                seekHasPrevious = seek.hasPrevious
            } else { seekHasPrevious = false }
            if let anchor, hasExplicitOrder {
                guard case .metadata = anchor else { throw HistoryFailure.snapshotExpired(current: position) }
            } else if case .metadata? = anchor {
                throw HistoryFailure.snapshotExpired(current: position)
            }
            let isRankedFuzzy = admitted.mode == .fuzzy && !admitted.term.isEmpty && !hasExplicitOrder
            let lowestPossibleFuzzyScore = isRankedFuzzy
                ? try SQLiteSearchIndex.lowestPossibleFuzzyScore(term: admitted.term, in: database) : 0
            let fuzzyOrderedAnchor: StoredOrderingAnchor?
            let completesFuzzyPrefix: Bool
            let reversesFuzzyPredecessors: Bool
            if isRankedFuzzy, let anchor {
                switch anchor {
                case .fuzzyUnpinned(let score, let date, let id) where score == lowestPossibleFuzzyScore:
                    fuzzyOrderedAnchor = .defaultOrder(pinnedOrdinal: nil, lastCopiedAt: date, id: id)
                    completesFuzzyPrefix = direction == .forward
                    reversesFuzzyPredecessors = direction == .backward
                case .defaultOrder(let ordinal, _, _) where ordinal != nil:
                    fuzzyOrderedAnchor = anchor
                    completesFuzzyPrefix = false
                    reversesFuzzyPredecessors = direction == .backward
                default:
                    fuzzyOrderedAnchor = nil
                    completesFuzzyPrefix = false
                    reversesFuzzyPredecessors = false
                }
            } else {
                fuzzyOrderedAnchor = nil
                completesFuzzyPrefix = false
                reversesFuzzyPredecessors = false
            }
            let reversesOrderedRows = direction == .backward && !isRankedFuzzy
            let scanDirection: HistoryPageDirection = reversesOrderedRows ? .forward : direction
            let reader: SQLiteSearchRows?
            if isRankedFuzzy, lowestPossibleFuzzyScore > 0.7 {
                // Every possible match needs more edits than the frozen
                // Fuse loop ever attempts. Skip candidate selection as well
                // as row reads; the ordinary empty-page path below still
                // rejects an unconfirmed cursor anchor and checks deadline/
                // cancellation before publishing the snapshot's position.
                reader = nil
                work.stopReason = .provenNoMatch
            } else {
                reader = try SQLiteSearchRows(
                    database: database, limits: limits, filter: request.filter, sortOrder: request.sortOrder,
                    expressionPredicate: expressionPredicate,
                    candidateExpression: admitted.expression.map { PreparedSearchExpression.candidateExpression($0.root) }
                        ?? SQLiteSearchIndex.matchExpression(term: admitted.term, mode: admitted.mode),
                    orderedAnchor: isRankedFuzzy ? fuzzyOrderedAnchor : anchor,
                    reversesOrder: reversesOrderedRows || reversesFuzzyPredecessors,
                    completesFuzzyPrefix: completesFuzzyPrefix,
                    work: work
                )
            }
            defer { reader?.finish() }
            let directive = ScanDirective(continuationAnchor: anchor, maximumSurvivors: request.limit + 1,
                                          direction: scanDirection)
            var tracker = OrderPreservingScanTracker(directive: directive)
            var ordered: [EvaluatedRow] = []
            var fuzzySelection = FuzzyPageSelection(directive: directive)
            var revisionCounts: [HistoryItemID: Int] = [:]
            var matchingComplete = false
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
            while let reader {
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
                // Ordered modes need only the page and one adjacent match.
                // Corruption is rejected in the bounded candidate projections
                // this query reads; an unrelated tail is not a page input.
                if !matchingComplete {
                    let evaluation: EvaluationResult
                    let survivorsSoFar = max(0, ordered.count - (anchor == nil ? 0 : 1))
                    let batchDirective = ScanDirective(
                        continuationAnchor: hasExplicitOrder || isRankedFuzzy || (scanDirection == .forward && !ordered.isEmpty)
                            ? nil : anchor,
                        maximumSurvivors: hasExplicitOrder || isRankedFuzzy || scanDirection == .backward
                            ? batch.rows.count + 1 : request.limit + 1 - survivorsSoFar,
                        direction: hasExplicitOrder || isRankedFuzzy ? .forward : scanDirection
                    )
                    if admitted.term.isEmpty {
                        evaluation = evaluateRecentEquivalent(in: snapshot, directive: batchDirective, work: work)
                    } else {
                        switch admitted.mode {
                        case .exact:
                            evaluation = try await evaluateExact(
                                term: admitted.term, in: snapshot, directive: batchDirective,
                                preparedMatcher: exact, work: work
                            )
                        case .regexp:
                            evaluation = try await evaluateRegexp(
                                term: admitted.term, in: snapshot, directive: batchDirective,
                                preparedPattern: regexp,
                                sharedEngineDeadline: min(regexpDeadline, lifetimeDeadline), work: work
                            )
                        case .fuzzy:
                            evaluation = try await evaluateFuzzy(
                                term: admitted.term, in: snapshot, directive: batchDirective,
                                preparedPattern: fuzzy, work: work
                            )
                        case .expression:
                            guard let expression else {
                                throw HistoryFailure.persistence(.invariantViolation)
                            }
                            evaluation = try await evaluateExpression(
                                expression, in: snapshot, directive: batchDirective, work: work
                            )
                        }
                    }
#if DEBUG
                    matchedRows += evaluation.debugMatchedRows
                    evaluatedRows += evaluation.debugRowsProcessed
#endif
                    // Matchers preserve their existing acceptance and range
                    // semantics. Explicit order overrides fuzzy relevance only
                    // within this bounded SQL batch, never over a loaded UI page.
                    let evaluatedBatch = hasExplicitOrder ? evaluation.rows.sorted { left, right in
                        reversesOrderedRows
                            ? HistorySortSQL.precedes(right.corpusRow, left.corpusRow, sortOrder: request.sortOrder)
                            : HistorySortSQL.precedes(left.corpusRow, right.corpusRow, sortOrder: request.sortOrder)
                    } : evaluation.rows
                    for evaluated in evaluatedBatch {
                        let compact = EvaluatedRow(
                            corpusRow: evaluated.corpusRow.replacingSearchBody(with: ""),
                            search: evaluated.search,
                            anchor: hasExplicitOrder ? HistorySortSQL.anchor(for: evaluated.corpusRow) : evaluated.anchor
                        )
                        if isRankedFuzzy {
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
                        let retained = isRankedFuzzy
                            ? fuzzySelection.retainedIDs : Set(ordered.map { $0.corpusRow.id })
                        revisionCounts = revisionCounts.filter { retained.contains($0.key) }
                    }
                }
                if matchingComplete { work.stopReason = .pageBudget; break }
                if isRankedFuzzy,
                   fuzzySelection.cannotBeImprovedByLaterDefaultOrderedRows(
                       lowestPossibleScore: lowestPossibleFuzzyScore,
                       reversesEligiblePredecessors: reversesFuzzyPredecessors
                   ) { work.stopReason = .provenBestScore; break }
                let yieldStarted = clock.now
#if DEBUG
                await suspensionHandler?(.sqliteBatchComplete)
#endif
                await Task.yield()
                regexpDeadline = regexpDeadline.advanced(by: yieldStarted.duration(to: clock.now))
            }
            try checkSnapshotDeadline(lifetimeDeadline)
            let evaluated = isRankedFuzzy
                ? fuzzySelection.evaluatedRows() : (reversesOrderedRows ? Array(ordered.reversed()) : ordered)
#if DEBUG
            searchDebugProbe.record(
                traceID: trace.id, component: "worker", phase: "evaluation-complete",
                phaseElapsed: startedAt.duration(to: clock.now), totalElapsed: startedAt.duration(to: clock.now),
                rowsProcessed: evaluatedRows, rowsTotal: processed, matchedRows: matchedRows
            )
#endif
            let window: (rows: ArraySlice<EvaluatedRow>, hasPrevious: Bool, hasNext: Bool)
            if request.startAround != nil, let anchor {
                guard let index = evaluated.firstIndex(where: { $0.anchor == anchor }) else {
                    throw HistoryFailure.snapshotExpired(current: position)
                }
                let inclusive = evaluated[index...]
                window = (inclusive.prefix(request.limit), seekHasPrevious, inclusive.count > request.limit)
            } else {
                window = try Self.pageWindow(in: evaluated, anchor: anchor, direction: direction,
                                             limit: request.limit, position: position)
            }
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
            case SQLITE_INTERRUPT:
                // The native callback uses these same two stop conditions;
                // preserve cancellation/deadline failures, never a partial page.
                try checkSnapshotDeadline(lifetimeDeadline)
                throw HistoryFailure.temporarilyUnavailable(.factProof)
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

    /// A reading-position request resolves its target in this same snapshot,
    /// confirms the actual matcher, then looks for one matching predecessor.
    /// The latter scan is also bounded by batches; no ID or content corpus is
    /// retained. Relevance ordering may need to examine the whole fuzzy corpus.
    private func resolveSearchStart(
        _ id: HistoryItemID, request: HistoryBrowseRequest, admitted: AdmittedSearchRequest,
        database: SQLiteDatabase, position: ChangePosition,
        exact: ExactLiteralMatcher?, fuzzy: Fuse.Pattern?, regexp: NSRegularExpression?,
        expression: PreparedSearchExpression?, expressionPredicate: (sql: String, bindings: [SQLiteValue])?,
        lifetimeDeadline: ContinuousClock.Instant, regexpDeadline: inout ContinuousClock.Instant,
        work: SearchWorkCounter
    ) async throws -> (anchor: StoredOrderingAnchor, hasPrevious: Bool) {
        let targetReader = try SQLiteSearchRows(
            database: database, limits: limits, filter: request.filter, sortOrder: request.sortOrder,
            expressionPredicate: expressionPredicate, candidateExpression: nil,
            orderedAnchor: nil, reversesOrder: false, completesFuzzyPrefix: false,
            work: work, targetedID: id
        )
        defer { targetReader.finish() }
        let targetBatch = try targetReader.nextBatch(includesRevisionCounts: false)
        guard !targetBatch.rows.isEmpty else { throw HistoryFailure.notFound(id) }
        let targetEvaluation = try await evaluateSeekBatch(
            targetBatch.rows, admitted: admitted, position: position, exact: exact, fuzzy: fuzzy,
            regexp: regexp, expression: expression, deadline: min(regexpDeadline, lifetimeDeadline), work: work
        )
        guard let target = targetEvaluation.rows.first else { throw HistoryFailure.notFound(id) }
        let anchor = request.sortOrder == .automatic ? target.anchor : HistorySortSQL.anchor(for: target.corpusRow)
        targetReader.finish()

        let rankedFuzzy = admitted.mode == .fuzzy && !admitted.term.isEmpty && request.sortOrder == .automatic
        let scoresPredecessors = rankedFuzzy && target.corpusRow.pinOrdinal == nil
        let predecessors = try SQLiteSearchRows(
            database: database, limits: limits, filter: request.filter, sortOrder: request.sortOrder,
            expressionPredicate: expressionPredicate,
            candidateExpression: admitted.expression.map { PreparedSearchExpression.candidateExpression($0.root) }
                ?? SQLiteSearchIndex.matchExpression(term: admitted.term, mode: admitted.mode),
            orderedAnchor: scoresPredecessors ? nil : anchor, reversesOrder: !scoresPredecessors,
            completesFuzzyPrefix: false, work: work
        )
        defer { predecessors.finish() }
        while true {
            try checkSnapshotDeadline(lifetimeDeadline)
            let fetchedAt = ContinuousClock.now
            let batch = try predecessors.nextBatch(includesRevisionCounts: false)
            regexpDeadline = regexpDeadline.advanced(by: fetchedAt.duration(to: ContinuousClock.now))
            guard !batch.rows.isEmpty else { return (anchor, false) }
            let matches = try await evaluateSeekBatch(
                batch.rows, admitted: admitted, position: position, exact: exact, fuzzy: fuzzy,
                regexp: regexp, expression: expression, deadline: min(regexpDeadline, lifetimeDeadline), work: work
            )
            for match in matches.rows {
                if rankedFuzzy {
                    if FuzzyPageSelection.precedes(match.anchor, anchor) { return (anchor, true) }
                } else if match.corpusRow.id != id {
                    return (anchor, true)
                }
            }
            let yieldedAt = ContinuousClock.now
            await Task.yield()
            regexpDeadline = regexpDeadline.advanced(by: yieldedAt.duration(to: ContinuousClock.now))
        }
    }

    internal func evaluateSeekBatch(
        _ rows: [SearchCorpusRow], admitted: AdmittedSearchRequest, position: ChangePosition,
        exact: ExactLiteralMatcher?, fuzzy: Fuse.Pattern?, regexp: NSRegularExpression?,
        expression: PreparedSearchExpression?, deadline: ContinuousClock.Instant, work: SearchWorkCounter
    ) async throws -> EvaluationResult {
#if DEBUG
        let corpus = SearchCorpusSnapshot(position: position, rows: rows,
                                          debugTrace: SearchDebugTrace(id: UUID(), startedAt: ContinuousClock.now))
#else
        let corpus = SearchCorpusSnapshot(position: position, rows: rows)
#endif
        let directive = ScanDirective(continuationAnchor: nil, maximumSurvivors: rows.count + 1)
        if admitted.term.isEmpty { return evaluateRecentEquivalent(in: corpus, directive: directive, work: work) }
        switch admitted.mode {
        case .exact:
            return try await evaluateExact(term: admitted.term, in: corpus, directive: directive,
                                            preparedMatcher: exact, work: work)
        case .fuzzy:
            return try await evaluateFuzzy(term: admitted.term, in: corpus, directive: directive,
                                            preparedPattern: fuzzy, work: work)
        case .regexp:
            return try await evaluateRegexp(term: admitted.term, in: corpus, directive: directive,
                                             preparedPattern: regexp, sharedEngineDeadline: deadline, work: work)
        case .expression:
            guard let expression else { throw HistoryFailure.persistence(.invariantViolation) }
            return try await evaluateExpression(expression, in: corpus, directive: directive, work: work)
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
            lastSource: lastSource, pinOrdinal: pinOrdinal, sourceCount: sourceCount
        )
#else
        SearchCorpusRow(
            id: id, contentVersion: contentVersion, title: title, searchBody: body,
            typeIdentifiers: typeIdentifiers, lastCopiedAt: lastCopiedAt, copyCount: copyCount,
            lastSource: lastSource, pinOrdinal: pinOrdinal, sourceCount: sourceCount
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
    let ranges: [(condition: String, bindings: [SQLiteValue], order: String)]
    var pendingRow = false
    let filter: HistoryFilter
    let expressionPredicate: (sql: String, bindings: [SQLiteValue])?
    let candidateExpression: String?
    let prefersSparseCandidates: Bool
    let defersBody: Bool
    let work: SearchWorkCounter
    let fuzzyPrefixLane: Int?

    init(
        database: SQLiteDatabase, limits: HistoryLimits, filter: HistoryFilter, sortOrder: HistorySortOrder,
        expressionPredicate: (sql: String, bindings: [SQLiteValue])?,
        candidateExpression: String?, orderedAnchor: StoredOrderingAnchor?, reversesOrder: Bool,
        completesFuzzyPrefix: Bool,
        work: SearchWorkCounter, targetedID: HistoryItemID? = nil
    ) throws {
        self.database = database
        self.limits = limits
        self.filter = filter
        self.expressionPredicate = expressionPredicate
        self.candidateExpression = candidateExpression
        self.work = work
        self.fuzzyPrefixLane = completesFuzzyPrefix ? 2 : nil
        if let candidateExpression {
            prefersSparseCandidates = try SQLiteSearchIndex.prefersSparseCandidates(
                expression: candidateExpression, in: database
            )
        } else { prefersSparseCandidates = false }
        defersBody = prefersSparseCandidates || sortOrder != .automatic
        // Each range starts directly at the adjacent anchor in the existing
        // pin/date/UUID indexes. Reverse reads restore display order only
        // after their bounded page and lookbehind have been selected.
        if let targetedID {
            ranges = [("id = ?", [.text(targetedID.rawValue.uuidString)], "id")]
        } else if sortOrder != .automatic {
            let anchor: HistorySortSQL.Anchor?
            if case let .metadata(date, count, id)? = orderedAnchor { anchor = (date, count, id) }
            else { anchor = nil }
            ranges = HistorySortSQL.ranges(sortOrder: sortOrder, anchor: anchor, reversed: reversesOrder)
        } else if let orderedAnchor, case let .defaultOrder(ordinal, date, id) = orderedAnchor {
            if let ordinal {
                if reversesOrder {
                    ranges = [("pinOrdinal IS NOT NULL AND pinOrdinal <= ?", [.integer(Int64(ordinal))], "pinOrdinal DESC")]
                } else {
                    ranges = [
                        ("pinOrdinal IS NOT NULL AND pinOrdinal >= ?", [.integer(Int64(ordinal))], "pinOrdinal ASC"),
                        ("pinOrdinal IS NULL", [], "lastCopiedAt DESC,id ASC"),
                    ]
                }
            } else {
                let timestamp = SQLiteValue.real(date.timeIntervalSinceReferenceDate)
                let identifier = SQLiteValue.text(id.rawValue.uuidString)
                if reversesOrder {
                    ranges = [
                        ("pinOrdinal IS NULL AND lastCopiedAt = ? AND id <= ?", [timestamp, identifier], "id DESC"),
                        ("pinOrdinal IS NULL AND lastCopiedAt > ?", [timestamp], "lastCopiedAt ASC,id DESC"),
                        ("pinOrdinal IS NOT NULL", [], "pinOrdinal DESC"),
                    ]
                } else {
                    var forwardRanges: [(condition: String, bindings: [SQLiteValue], order: String)] = [
                        ("pinOrdinal IS NULL AND lastCopiedAt = ? AND id >= ?", [timestamp, identifier], "id ASC"),
                        ("pinOrdinal IS NULL AND lastCopiedAt < ?", [timestamp], "lastCopiedAt DESC,id ASC"),
                    ]
                    if completesFuzzyPrefix {
                        // For a floor-score anchor, equal-score prefix rows
                        // precede the cursor, but worse-score prefix rows may
                        // be needed if the tail cannot fill page+lookahead.
                        // These disjoint ranges are reached only if the tail
                        // did not prove its retained page globally unbeatable.
                        forwardRanges += [
                            ("pinOrdinal IS NULL AND lastCopiedAt > ?", [timestamp], "lastCopiedAt DESC,id ASC"),
                            ("pinOrdinal IS NULL AND lastCopiedAt = ? AND id < ?", [timestamp, identifier], "id ASC"),
                        ]
                    }
                    ranges = forwardRanges
                }
            }
        } else {
            ranges = [
                ("pinOrdinal IS NOT NULL", [], "pinOrdinal ASC"),
                ("pinOrdinal IS NULL", [], "lastCopiedAt DESC,id ASC"),
            ]
        }
    }

    func finish() { statement?.finalize(); statement = nil }

    func nextBatch(includesRevisionCounts: Bool) throws -> (rows: [SearchCorpusRow], revisionCounts: [HistoryItemID: Int], utf8Bytes: Int) {
        var rows: [SearchCorpusRow] = []
        var counts: [HistoryItemID: Int] = [:]
        var byteCount = 0
        while rows.count < SearchWorker.maximumBatchRows {
            try Task.checkCancellation()
            if statement == nil {
                guard lane < ranges.count else { break }
                let range = ranges[lane]
                let predicate = HistoryFilterSQL.predicate(filter)
                let expressionSQL = expressionPredicate?.sql ?? "1"
                let expressionBindings = expressionPredicate?.bindings ?? []
                let candidateSQL: String
                if candidateExpression == nil {
                    candidateSQL = "1"
                } else if prefersSparseCandidates {
                    candidateSQL = "history_items.rowid IN (SELECT rowid FROM history_search WHERE history_search MATCH ?)"
                } else {
                    // Dense hits walk the ordering index and probe each row's
                    // posting membership, stopping after page/lookahead. A
                    // full candidate IN set would sort the whole dense corpus.
                    candidateSQL = "EXISTS (SELECT 1 FROM history_search WHERE rowid = history_items.rowid AND history_search MATCH ?)"
                }
                let candidateBindings = candidateExpression.map { [SQLiteValue.text($0)] } ?? []
                // V2-09 §4: sparse candidates need a temporary ordering
                // sort. Keep full bodies out of its records: otherwise up
                // to 4,096 bodies are copied before the first bounded batch
                // can be admitted. Resolve each yielded rowid below, inside
                // this same read transaction. Dense indexed walks keep their
                // single projection because they do not sort the candidates.
                let bodyProjection = defersBody ? "rowid" : "searchBodyUTF8"
                statement = try database.prepare("""
                    SELECT id,contentVersion,titleUTF8,\(bodyProjection),effectiveTypeIdentifiersBlob,
                           lastCopiedAt,copyCount,lastSource,pinOrdinal,revisionCount,
                           sourceCount
                    FROM history_items WHERE (\(range.condition)) AND (\(predicate.sql))
                      AND (\(expressionSQL)) AND (\(candidateSQL))
                    ORDER BY \(range.order)
                    """, bindings: range.bindings + predicate.bindings + expressionBindings + candidateBindings)
            }
            guard let statement else { break }
            if !pendingRow {
                guard try statement.step() else {
                    finish()
                    lane += 1
                    // Evaluate the completed tail before deciding whether
                    // any skipped fuzzy prefix needs to be decoded at all.
                    if lane == fuzzyPrefixLane, !rows.isEmpty { break }
                    continue
                }
                pendingRow = true
            }
            let deferredBody: SQLiteStatement?
            if defersBody {
                deferredBody = try database.prepare(
                    "SELECT searchBodyUTF8 FROM history_items WHERE rowid = ?",
                    bindings: [.integer(try statement.integer(at: 3))]
                )
            } else { deferredBody = nil }
            defer { deferredBody?.finalize() }
            if let deferredBody, try !deferredBody.step() {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            let bodyStatement = deferredBody ?? statement
            let bodyColumn: Int32 = deferredBody == nil ? 3 : 0
            let titleBytes = try statement.blobByteCount(at: 2)
            let bodyBytes = try bodyStatement.blobByteCount(at: bodyColumn)
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
                let body = try ContentProjector.decodeStoredSearchBody(bodyStatement.blob(at: bodyColumn), limits: limits)
                let version = try RevisionStateBlobCodec.decodeContentVersion(sqliteUInt64(statement.blob(at: 1)))
                let types = try EffectiveTypeIdentifiersBlobCodec.decode(statement.blob(at: 4), limits: limits)
                let copiedAt = Date(timeIntervalSinceReferenceDate: try statement.real(at: 5))
                let copyCount = try sqliteUInt64(statement.blob(at: 6))
                let source = try statement.optionalText(at: 7)
                let sourceCount = try HistoryItemRowHydration.integer(statement, 10)
                guard sourceCount >= 0, UInt64(sourceCount) <= copyCount else {
                    throw HistoryFailure.persistence(.corruptStoredValue)
                }
                let ordinal = try statement.isNull(at: 8) ? nil : Int(exactly: statement.integer(at: 8))
                try RevisionStateBlobCodec.validateFiniteLastCopiedAt(copiedAt)
                try RevisionStateBlobCodec.validateCopyCount(copyCount)
                let pin = try RevisionStateBlobCodec.decodePinOrdinal(ordinal)
#if DEBUG
                return SearchCorpusRow(
                    id: HistoryItemID(rawValue: uuid), contentVersion: version, title: title, searchBody: body,
                    debugTitleUTF8Bytes: titleBytes, debugSearchBodyUTF8Bytes: bodyBytes,
                    typeIdentifiers: types, lastCopiedAt: copiedAt, copyCount: copyCount,
                    lastSource: source, pinOrdinal: pin,
                    sourceCount: sourceCount
                )
#else
                return SearchCorpusRow(
                    id: HistoryItemID(rawValue: uuid), contentVersion: version, title: title, searchBody: body,
                    typeIdentifiers: types, lastCopiedAt: copiedAt, copyCount: copyCount,
                    lastSource: source, pinOrdinal: pin,
                    sourceCount: sourceCount
                )
#endif
            }
            if includesRevisionCounts {
                // V2-09 §4: validate the purpose-specific facts actually
                // consumed by this batch. A malformed stored count is data
                // corruption, not a missing internal result at publication.
                let count = try HistoryItemRowHydration.integer(statement, 9)
                guard count >= 0, count <= limits.maximumRevisionsPerItem else {
                    throw HistoryFailure.persistence(.corruptStoredValue)
                }
                counts[row.id] = count
            }
            if rows.isEmpty { work.batchCount += 1 }
            work.rowsDecoded += 1
            rows.append(row)
            byteCount += rowBytes
            pendingRow = false
        }
        return (rows, counts, byteCount)
    }
}
