/// Explicit sorting for the immutable-corpus matcher oracle. Production reads
/// this ordering directly from SQLite; owner tests supply an existing array.
/// Matching still evaluates bounded batches and retains only the adjacent
/// page and its lookahead or lookbehind (04 §6; V2-09 §4).
import Foundation
import HistoryCore
import Fuse

extension SearchWorker {
    /// The immutable fixture entry shares the production single-row matcher
    /// when resolving a reading position. Its adjacent pages still use the
    /// ordinary bounded matcher oracle and complete cursor query shapes.
    internal func pageStartingAtInCorpus(
        _ id: HistoryItemID, request: HistoryBrowseRequest, admitted: AdmittedSearchRequest,
        corpus: SearchCorpusSnapshot, processMarker: UUID
    ) async throws -> HistoryPage {
        guard let source = corpus.rows.first(where: { $0.id == id }) else { throw HistoryFailure.notFound(id) }
        let targetEvaluation = try await evaluateSeekBatch(
            [source], admitted: admitted, position: corpus.position, exact: nil, fuzzy: nil, regexp: nil,
            expression: admitted.expression.map { PreparedSearchExpression($0.root) },
            deadline: ContinuousClock.now.advanced(by: regexpEngineDeadline), work: SearchWorkCounter()
        )
        guard let target = targetEvaluation.rows.first else { throw HistoryFailure.notFound(id) }
        let anchor = request.sortOrder == .automatic ? target.anchor : HistorySortSQL.anchor(for: source)

        func adjacentRequest(limit: Int, direction: HistoryPageDirection) throws -> HistoryBrowseRequest {
            let query = HistoryBrowseRequest(kind: request.kind, limit: limit, filter: request.filter,
                                             sortOrder: request.sortOrder)
            let cursor = try Self.mintSearchCursor(at: anchor, direction: direction, request: query,
                                                   position: corpus.position, processMarker: processMarker)
            return HistoryBrowseRequest(kind: query.kind, limit: limit, cursor: cursor, filter: query.filter,
                                         sortOrder: query.sortOrder)
        }
        let before = try await page(adjacentRequest(limit: request.limit, direction: .backward), in: corpus,
                                    continuationAnchor: anchor, processMarker: processMarker)
        let after = try await page(adjacentRequest(limit: request.limit, direction: .forward),
                                   in: corpus, continuationAnchor: anchor, processMarker: processMarker)
        let previous = try before.rows.isEmpty ? nil : Self.mintSearchCursor(
            at: anchor, direction: .backward, request: request, position: corpus.position, processMarker: processMarker
        )
        let following = Array(after.rows.prefix(max(0, request.limit - 1)))
        let next: HistoryPageCursor?
        if after.rows.count > following.count || after.next != nil {
            let lastAnchor: StoredOrderingAnchor
            if let lastID = following.last?.item.id,
               let lastSource = corpus.rows.first(where: { $0.id == lastID }) {
                if request.sortOrder != .automatic { lastAnchor = HistorySortSQL.anchor(for: lastSource) }
                else if admitted.mode == .fuzzy && !admitted.term.isEmpty {
                    let match = try await evaluateSeekBatch(
                        [lastSource], admitted: admitted, position: corpus.position,
                        exact: nil, fuzzy: nil, regexp: nil, expression: nil,
                        deadline: ContinuousClock.now.advanced(by: regexpEngineDeadline), work: SearchWorkCounter()
                    )
                    guard let last = match.rows.first else { throw HistoryFailure.persistence(.invariantViolation) }
                    lastAnchor = last.anchor
                } else { lastAnchor = Self.defaultOrderAnchor(for: lastSource) }
            } else { lastAnchor = anchor }
            next = try Self.mintSearchCursor(at: lastAnchor, direction: .forward, request: request,
                                             position: corpus.position, processMarker: processMarker)
        } else { next = nil }
        return HistoryPage(position: corpus.position,
                           rows: [materialize(target)] + following,
                           previous: previous, next: next)
    }

    internal func evaluateMetadataOrder(
        admitted: AdmittedSearchRequest,
        in corpus: SearchCorpusSnapshot,
        sortOrder: HistorySortOrder,
        directive: ScanDirective
    ) async throws -> EvaluationResult {
        if let anchor = directive.continuationAnchor {
            guard case .metadata = anchor else {
                throw HistoryFailure.snapshotExpired(current: corpus.position)
            }
        }
        let exact = admitted.mode == .exact && !admitted.term.isEmpty
            ? ExactLiteralMatcher(term: admitted.term) : nil
        let regexp: NSRegularExpression?
        if admitted.mode == .regexp && !admitted.term.isEmpty {
            regexp = try NSRegularExpression(pattern: admitted.term)
        } else { regexp = nil }
        let fuzzy = admitted.mode == .fuzzy && !admitted.term.isEmpty
            ? fuse.createPattern(from: admitted.term) : nil
        let expression = admitted.expression.map { PreparedSearchExpression($0.root) }
        // Every batch shares one regexp deadline, as in the SQLite path.
        let regexpDeadline = ContinuousClock.now.advanced(by: regexpEngineDeadline)
        let ordered = corpus.rows.sorted {
            HistorySortSQL.precedes($0, $1, sortOrder: sortOrder)
        }
        var tracker = OrderPreservingScanTracker(directive: directive)
        var retained: [EvaluatedRow] = []
        retained.reserveCapacity(min(ordered.count, directive.maximumSurvivors + 1))
#if DEBUG
        var processed = 0
        var matched = 0
#endif

        scan: for start in stride(from: 0, to: ordered.count, by: Self.cancellationRowInterval) {
            try Task.checkCancellation()
            let end = min(start + Self.cancellationRowInterval, ordered.count)
            let batchRows = Array(ordered[start..<end])
#if DEBUG
            let batch = SearchCorpusSnapshot(position: corpus.position, rows: batchRows,
                                             debugTrace: corpus.debugTrace)
#else
            let batch = SearchCorpusSnapshot(position: corpus.position, rows: batchRows)
#endif
            // The outer tracker owns continuation and page capacity. Retain
            // every match in this bounded batch before applying metadata order;
            // a fuzzy relevance rank cannot discard an otherwise eligible row.
            let batchDirective = ScanDirective(continuationAnchor: nil, maximumSurvivors: batchRows.count + 1)
            let evaluation: EvaluationResult
            if admitted.term.isEmpty {
                evaluation = evaluateRecentEquivalent(in: batch, directive: batchDirective)
            } else {
                switch admitted.mode {
                case .exact:
                    evaluation = try await evaluateExact(
                        term: admitted.term, in: batch, directive: batchDirective, preparedMatcher: exact
                    )
                case .regexp:
                    evaluation = try await evaluateRegexp(
                        term: admitted.term, in: batch, directive: batchDirective,
                        preparedPattern: regexp, sharedEngineDeadline: regexpDeadline
                    )
                case .fuzzy:
                    evaluation = try await evaluateFuzzy(
                        term: admitted.term, in: batch, directive: batchDirective, preparedPattern: fuzzy
                    )
                case .expression:
                    guard let expression else {
                        throw HistoryFailure.persistence(.invariantViolation)
                    }
                    evaluation = try await evaluateExpression(expression, in: batch, directive: batchDirective)
                }
            }
#if DEBUG
            processed += evaluation.debugRowsProcessed
            matched += evaluation.debugMatchedRows
#endif
            let batchMatches = evaluation.rows.sorted {
                HistorySortSQL.precedes($0.corpusRow, $1.corpusRow, sortOrder: sortOrder)
            }
            for match in batchMatches {
                let row = EvaluatedRow(corpusRow: match.corpusRow, search: match.search,
                                       anchor: HistorySortSQL.anchor(for: match.corpusRow))
                tracker.appendIfRetained(row, to: &retained)
                if !tracker.recordMatch(ofRow: row.anchor) { break scan }
            }
        }
        try Task.checkCancellation()
#if DEBUG
        return EvaluationResult(rows: retained, debugRowsProcessed: processed, debugMatchedRows: matched)
#else
        return EvaluationResult(rows: retained)
#endif
    }
}
