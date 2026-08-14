/// Exact-mode evaluation (03b §8).
/// Split out of SearchWorker.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

extension SearchWorker {
    // MARK: - Exact mode (03b §8)

    /// Case-insensitive literal substring search (03b §8): title first and,
    /// only on title miss, the full bounded `searchBody`; the first match
    /// wins; the default row order is preserved. `.literal` pins the
    /// "literal" half of the frozen definition — no canonical-equivalence
    /// folding, only case-insensitivity.
    internal func evaluateExact(
        term: String,
        in corpus: SearchCorpusSnapshot
    ) -> [EvaluatedRow] {
        // Preprocess the eligible-ASCII needle once for this public request.
        // The scalar baseline has a linear worst-case bound and delegates
        // every fallback comparison to Foundation's frozen §8 semantics.
        let matcher = ExactLiteralMatcher(term: term)
        var evaluated: [EvaluatedRow] = []
#if DEBUG
        let debugClock = ContinuousClock()
        let debugStart = debugClock.now
        var debugProcessedRows = 0
        var debugTitleRows = 0
        var debugBodyRows = 0
        var debugTitleUTF8Bytes = 0
        var debugBodyUTF8Bytes = 0
        var debugTitleMatches = 0
        var debugBodyMatches = 0
        var debugExactASCIIEvaluations = 0
        var debugExactFoundationEvaluations = 0
        var debugTitleElapsed = Duration.zero
        var debugBodyElapsed = Duration.zero
        searchDebugProbe.record(
            traceID: corpus.debugTrace.id,
            component: "worker",
            phase: "exact-scan-begin",
            phaseElapsed: .zero,
            totalElapsed: corpus.debugTrace.startedAt.duration(to: debugClock.now),
            rowsTotal: corpus.rows.count
        )

        func recordProgressIfNeeded() {
            let isProgressBoundary = debugProcessedRows.isMultiple(
                of: SearchDebugProbe.progressRowInterval
            )
            let isLastRow = debugProcessedRows == corpus.rows.count
            guard isProgressBoundary || isLastRow else {
                return
            }
            searchDebugProbe.record(
                traceID: corpus.debugTrace.id,
                component: "worker",
                phase: "exact-scan-progress",
                phaseElapsed: debugStart.duration(to: debugClock.now),
                totalElapsed: corpus.debugTrace.startedAt.duration(to: debugClock.now),
                rowsProcessed: debugProcessedRows,
                rowsTotal: corpus.rows.count,
                matchedRows: debugTitleMatches + debugBodyMatches,
                titleUTF8Bytes: debugTitleUTF8Bytes,
                bodyUTF8Bytes: debugBodyUTF8Bytes,
                titleMatches: debugTitleMatches,
                bodyMatches: debugBodyMatches,
                exactASCIIEvaluations: debugExactASCIIEvaluations,
                exactFoundationEvaluations: debugExactFoundationEvaluations
            )
        }
#endif
        for row in corpus.rows {
#if DEBUG
            debugTitleRows += 1
            debugTitleUTF8Bytes += row.debugTitleUTF8Bytes
            let debugTitleStart = debugClock.now
#endif
#if DEBUG
            let titleResult = matcher.firstMatchWithDebugRoute(in: row.title)
            if titleResult.usedASCIILinearPath {
                debugExactASCIIEvaluations += 1
            } else {
                debugExactFoundationEvaluations += 1
            }
            let titleMatch = titleResult.match
#else
            let titleMatch = matcher.firstMatch(in: row.title)
#endif
#if DEBUG
            debugTitleElapsed += debugTitleStart.duration(to: debugClock.now)
#endif
            if let found = titleMatch {
                // Title match: `snippet == nil`, UTF-16 ranges relative to
                // `HistoryRow.title` (03b §8).
                evaluated.append(
                    EvaluatedRow(
                        corpusRow: row,
                        search: SearchPresentation(
                            snippet: nil,
                            matchedRanges: [UTF16TextRange(
                                location: found.utf16Offset,
                                length: found.utf16Length
                            )]
                        ),
                        anchor: Self.defaultOrderAnchor(for: row)
                    )
                )
#if DEBUG
                debugTitleMatches += 1
                debugProcessedRows += 1
                recordProgressIfNeeded()
#endif
                continue
            }
            // Only on title miss: the full bounded searchBody (03b §8).
            // Exact mode has no scan prefix; the excerpt therefore windows
            // the complete bounded projection text.
#if DEBUG
            debugBodyRows += 1
            debugBodyUTF8Bytes += row.debugSearchBodyUTF8Bytes
            let debugBodyStart = debugClock.now
#endif
#if DEBUG
            let bodyResult = matcher.firstMatchWithDebugRoute(in: row.searchBody)
            if bodyResult.usedASCIILinearPath {
                debugExactASCIIEvaluations += 1
            } else {
                debugExactFoundationEvaluations += 1
            }
            let bodyMatch = bodyResult.match
#else
            let bodyMatch = matcher.firstMatch(in: row.searchBody)
#endif
#if DEBUG
            debugBodyElapsed += debugBodyStart.duration(to: debugClock.now)
#endif
            guard let found = bodyMatch else {
#if DEBUG
                debugProcessedRows += 1
                recordProgressIfNeeded()
#endif
                continue
            }
            // The matcher already returns Character coordinates. The ASCII
            // fast path obtains them directly from byte offsets; the Unicode
            // fallback performs the Foundation-to-Character translation once.
            // `bodyExcerpt` materializes only its bounded window, never the
            // complete stored search body (03b §8; 06 §2).
            let excerpt = Self.bodyExcerpt(
                body: row.searchBody,
                characterRanges: [
                    found.characterOffset ..<
                        (found.characterOffset + found.characterLength),
                ],
                snippetLimit: limits.maximumBodySearchSnippetCharacters
            )
            evaluated.append(
                EvaluatedRow(
                    corpusRow: row,
                    search: SearchPresentation(
                        snippet: excerpt.snippet,
                        matchedRanges: excerpt.ranges
                    ),
                    anchor: Self.defaultOrderAnchor(for: row)
                )
            )
#if DEBUG
            debugBodyMatches += 1
            debugProcessedRows += 1
            recordProgressIfNeeded()
#endif
        }
#if DEBUG
        let debugTotalElapsed = debugStart.duration(to: debugClock.now)
        searchDebugProbe.record(
            traceID: corpus.debugTrace.id,
            component: "worker",
            phase: "exact-title-scan",
            phaseElapsed: debugTitleElapsed,
            totalElapsed: corpus.debugTrace.startedAt.duration(to: debugClock.now),
            rowsProcessed: debugTitleRows,
            rowsTotal: corpus.rows.count,
            matchedRows: debugTitleMatches + debugBodyMatches,
            titleUTF8Bytes: debugTitleUTF8Bytes,
            titleMatches: debugTitleMatches,
            bodyMatches: debugBodyMatches,
            exactASCIIEvaluations: debugExactASCIIEvaluations,
            exactFoundationEvaluations: debugExactFoundationEvaluations
        )
        searchDebugProbe.record(
            traceID: corpus.debugTrace.id,
            component: "worker",
            phase: "exact-body-scan",
            phaseElapsed: debugBodyElapsed,
            totalElapsed: corpus.debugTrace.startedAt.duration(to: debugClock.now),
            rowsProcessed: debugBodyRows,
            rowsTotal: corpus.rows.count,
            matchedRows: debugTitleMatches + debugBodyMatches,
            bodyUTF8Bytes: debugBodyUTF8Bytes,
            titleMatches: debugTitleMatches,
            bodyMatches: debugBodyMatches,
            exactASCIIEvaluations: debugExactASCIIEvaluations,
            exactFoundationEvaluations: debugExactFoundationEvaluations
        )
        searchDebugProbe.record(
            traceID: corpus.debugTrace.id,
            component: "worker",
            phase: "exact-scan-complete",
            phaseElapsed: debugTotalElapsed,
            totalElapsed: corpus.debugTrace.startedAt.duration(to: debugClock.now),
            rowsProcessed: debugProcessedRows,
            rowsTotal: corpus.rows.count,
            matchedRows: debugTitleMatches + debugBodyMatches,
            titleUTF8Bytes: debugTitleUTF8Bytes,
            bodyUTF8Bytes: debugBodyUTF8Bytes,
            titleMatches: debugTitleMatches,
            bodyMatches: debugBodyMatches,
            exactASCIIEvaluations: debugExactASCIIEvaluations,
            exactFoundationEvaluations: debugExactFoundationEvaluations
        )
#endif
        return evaluated
    }

}
