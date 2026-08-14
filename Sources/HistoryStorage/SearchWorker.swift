/// Search evaluation worker for the two-step value pipeline
/// (docs/05-authority-kernel.md §14.2; docs/04-coherence.md §7).
/// Owning spec: docs/03b-instruction-set.md §8 (frozen search behavior);
/// bounds: docs/06-cross-cutting.md §2; fixtures: docs/06-cross-cutting.md
/// §8 WS17.
///
/// The facade wires the pipeline: `HistoryAuthority` captures a bounded
/// Sendable `SearchCorpusSnapshot` inside one non-suspending interval, then
/// this worker evaluates the request over it off the Authority and returns
/// the bounded `HistoryPage` stamped with the corpus position. The worker
/// never reads SwiftData and never uses dedup Candidate Rank (§14.2); it is
/// pure evaluation over the Sendable corpus, and only immutable `Sendable`
/// values cross its boundary (docs/01-architecture.md §6).
///
/// The actor exists to confine the non-Sendable Fuse 1.4.0 matcher: `Fuse`
/// is a pre-concurrency class with no `Sendable` conformance, so it lives
/// entirely as actor-isolated state and never appears in a public or
/// package signature (docs/01-architecture.md §6; docs/AUDIT.md §4b).
import Foundation
import HistoryCore
import HistoryDomain
import Fuse

/// Named test-only suspension points for the off-Authority search evaluator.
/// The handler is always nil in production and is compiled in so `@testable`
/// observation proofs can place a commit inside the snapshot→evaluation
/// interval without retaining any SwiftData value across the suspension
/// (docs/04-coherence.md §5/§7; docs/06-cross-cutting.md §8 WS12).
internal enum SearchWorkerSuspensionPoint: String, Sendable {
    case evaluationEntry = "SearchWorker.page.evaluationEntry"
}

/// Search evaluation worker (docs/05-authority-kernel.md §14.2). Roadmap
/// step 7: the three frozen search modes plus the recent-equivalent empty
/// term (docs/03b-instruction-set.md §8; docs/06-cross-cutting.md §8 WS17).
///
/// All mode behavior is frozen by 03b §8 and fixture-locked by WS17; the
/// individual steps cite the paragraph they implement. Determinism follows
/// docs/04-coherence.md §7: every sort ends with `lastCopiedAt` descending
/// and History Item ID bytes ascending, and matched ranges are UTF-16
/// offsets into the returned title/snippet, never `String.Index` values.
internal actor SearchWorker {
    /// The fixed `HistoryLimits.standard` safety profile
    /// (docs/06-cross-cutting.md §2): the common 4,096-UTF-8-byte search-term
    /// bound, the 512-Character regexp-pattern bound, the 64-Character
    /// fuzzy-query bound, the 1,000/5,000-Character regexp/fuzzy scan prefixes,
    /// and the 322-Character snippet bound.
    private let limits: HistoryLimits

    /// The confined fuzzy matcher (docs/01-architecture.md §6). Frozen
    /// parameters (03b §8): `threshold` 0.7, `location` 0, `distance` 100,
    /// `isCaseSensitive` false; `tokenize` keeps its `false` default.
    /// `maxPatternLength` is deliberately not passed: it is a dead
    /// parameter in the pinned 1.4.0 revision (stored, never read — see
    /// `Fuse/Classes/Fuse.swift` at krisk/fuse-swift
    /// 26ba868691b2d8b7bf2b1322951eb591be70ccca; docs/AUDIT.md §4b), so the
    /// 64-Character query bound is enforced by `page` itself before Fuse
    /// is called.
    private let fuse: Fuse

    /// Same scoring parameters, but case-sensitive because `fuzzyMatch`
    /// supplies the single pre-lowercased working copy. This avoids Fuse
    /// allocating a second lowercase string after the alignment proof.
    private let prelowercasedFuse: Fuse

    /// Deterministic observation-test seam. Nil outside `@testable` tests;
    /// only immutable corpus/request values are live when it is awaited.
    private var suspensionHandler: (
        @Sendable (SearchWorkerSuspensionPoint) async -> Void
    )?

#if DEBUG
    /// Opt-in aggregate tracing for the off-Authority half of the search
    /// pipeline. The probe and all event work are absent from Release builds.
    private var searchDebugProbe = SearchDebugProbe.environmentConfigured()
#endif

    /// Creates the worker with the fixed safety profile and the frozen
    /// Fuse parameter set (03b §8).
    internal init() {
        self.limits = .standard
        self.fuse = Fuse(location: 0, distance: 100, threshold: 0.7, isCaseSensitive: false)
        self.prelowercasedFuse = Fuse(
            location: 0,
            distance: 100,
            threshold: 0.7,
            isCaseSensitive: true
        )
        self.suspensionHandler = nil
    }

    /// Installs or clears the deterministic evaluation-entry handler.
    /// Production never installs one, so the seam is a no-op there.
    internal func setSuspensionHandler(
        _ handler: (@Sendable (SearchWorkerSuspensionPoint) async -> Void)?
    ) {
        suspensionHandler = handler
    }

#if DEBUG
    /// Replaces the environment-backed probe for deterministic Debug tests.
    internal func setSearchDebugProbe(_ probe: SearchDebugProbe) {
        searchDebugProbe = probe
    }
#endif

    /// One evaluated row in final page order: the corpus scalar row, its
    /// search presentation (`nil` on the recent-equivalent lane, 03b §8),
    /// and the complete ordering anchor the next cursor binds to
    /// (docs/04-coherence.md §6).
    private struct EvaluatedRow {
        let corpusRow: SearchCorpusRow
        let search: SearchPresentation?
        let anchor: StoredOrderingAnchor
    }

    /// One fuzzy-matched row before ordering: the corpus row, the Fuse
    /// score (internal only — 03b §8: "Search scores and Fuse objects
    /// remain internal"), and the built presentation.
    private struct FuzzyHit {
        let corpusRow: SearchCorpusRow
        let score: Double
        let search: SearchPresentation
    }

    /// Evaluates one browse request over the pre-ordered corpus
    /// (05 §14.2), returning the bounded page stamped with the corpus
    /// position.
    ///
    /// - Parameter request: The caller's browse request. Only `.search`
    ///   kinds reach this worker: the facade routes `.recent` to the
    ///   Authority's own §14.1 interval (`SwiftDataHistory.browse`), so a
    ///   `.recent` kind here is a wiring violation — the §16 defensive
    ///   internal-invariant mapping, never a caller-observable case.
    /// - Parameter corpus: The bounded Sendable snapshot the Authority
    ///   captured, pre-ordered in the default total order (pinned rows by
    ///   `pinOrdinal` ascending, then unpinned by `lastCopiedAt`
    ///   descending and History Item ID bytes ascending; 03b §8).
    /// - Parameter continuationAnchor: The decoded cursor anchor for a
    ///   continuation page, or `nil` for a first page. The anchor drops
    ///   every row up to and including the anchored row in the computed
    ///   order (docs/04-coherence.md §6).
    /// - Parameter processMarker: The Authority-owned process-instance
    ///   marker the minted cursor binds to (04 §6); the facade forwards it
    ///   — this worker never mints markers.
    /// - Throws: `HistoryFailure.invalidInput(.invalidSearchTerm)` for any
    ///   non-empty search term over the Part VI 4,096-UTF-8-byte bound, before
    ///   mode-specific admission; the same failure is used for a fuzzy query
    ///   over the 64-Character bound before Fuse is called (03b §8; 06 §2);
    ///   `.invalidInput(.invalidRegularExpression)` for a rejected regexp
    ///   pattern after the shared byte bound passes (before any scanning,
    ///   03b §8);
    ///   `.snapshotExpired(current:)` when the continuation anchor names
    ///   no row in the computed order (04 §6).
    internal func page(
        _ request: HistoryBrowseRequest,
        in corpus: SearchCorpusSnapshot,
        continuationAnchor: StoredOrderingAnchor?,
        processMarker: UUID
    ) async throws -> HistoryPage {
#if DEBUG
        let debugClock = ContinuousClock()
        let debugTotalStart = corpus.debugTrace.startedAt
        let debugTraceID = corpus.debugTrace.id
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "worker",
            phase: "entry",
            phaseElapsed: debugTotalStart.duration(to: debugClock.now),
            totalElapsed: debugTotalStart.duration(to: debugClock.now),
            rowsTotal: corpus.rows.count
        )
#endif
        guard case .search(let term, let mode) = request.kind else {
            // The facade routes `.recent` to the Authority's §14.1
            // interval; a `.recent` kind here is a wiring violation —
            // the §16 defensive internal-invariant mapping.
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // Part VI §2: the UTF-8 byte bound is common to every search mode and
        // therefore precedes regexp/fuzzy Character-specific admission. This
        // also prevents a small number of extremely wide grapheme clusters
        // from bypassing the scalar input envelope.
        guard term.utf8.count <= limits.maximumSearchTermUTF8Bytes else {
            throw HistoryFailure.invalidInput(.invalidSearchTerm)
        }

        // WS12/search-observation seam: the Authority has already released
        // its operation-local context and handed over this immutable snapshot.
        // A test may now commit while evaluation is parked, proving the page
        // keeps the old position and the facade's phase-1 recheck discards it.
        await suspensionHandler?(.evaluationEntry)
        try Task.checkCancellation()

#if DEBUG
        let debugEvaluationStart = debugClock.now
#endif

        // 03b §8: an EMPTY term (zero Characters) is equivalent to
        // `.recent` and carries no search presentation. A non-empty term
        // is never re-trimmed or altered — normalized term equality is
        // what the cursor binds.
        let evaluated: [EvaluatedRow]
        if term.isEmpty {
            evaluated = evaluateRecentEquivalent(in: corpus)
        } else {
            switch mode {
            case .exact:
                evaluated = evaluateExact(term: term, in: corpus)
            case .regexp:
                evaluated = try evaluateRegexp(term: term, in: corpus)
            case .fuzzy:
                evaluated = try evaluateFuzzy(term: term, in: corpus)
            }
        }

#if DEBUG
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "worker",
            phase: "evaluation-complete",
            phaseElapsed: debugEvaluationStart.duration(to: debugClock.now),
            totalElapsed: debugTotalStart.duration(to: debugClock.now),
            rowsProcessed: corpus.rows.count,
            rowsTotal: corpus.rows.count,
            matchedRows: evaluated.count
        )
        let debugContinuationStart = debugClock.now
#endif

        // Continuation (04 §6): the cursor anchor names the last row of
        // the previous page in this exact computed order; an absent anchor
        // means the cursor no longer matches this snapshot and fails
        // explicitly rather than silently skipping or repeating rows.
        let survivors: ArraySlice<EvaluatedRow>
        if let continuationAnchor {
            guard let anchorIndex = evaluated.firstIndex(
                where: { $0.anchor == continuationAnchor }
            ) else {
                throw HistoryFailure.snapshotExpired(current: corpus.position)
            }
            survivors = evaluated[(anchorIndex + 1)...]
        } else {
            survivors = evaluated[...]
        }

#if DEBUG
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "worker",
            phase: "continuation",
            phaseElapsed: debugContinuationStart.duration(to: debugClock.now),
            totalElapsed: debugTotalStart.duration(to: debugClock.now),
            rowsProcessed: survivors.count,
            rowsTotal: evaluated.count,
            matchedRows: evaluated.count
        )
        let debugMaterializationStart = debugClock.now
#endif

        let pageSlice = survivors.prefix(request.limit)
        let rows = pageSlice.map { evaluatedRow -> HistoryRow in
            let corpusRow = evaluatedRow.corpusRow
            return HistoryRow(
                item: HistoryItemReference(
                    id: corpusRow.id,
                    contentVersion: corpusRow.contentVersion
                ),
                title: corpusRow.title,
                typeIdentifiers: corpusRow.typeIdentifiers,
                lastCopiedAt: corpusRow.lastCopiedAt,
                copyCount: corpusRow.copyCount,
                lastSource: corpusRow.lastSource,
                pinnedPosition: corpusRow.pinOrdinal?.rawValue,
                search: evaluatedRow.search
            )
        }

        // The next cursor is minted through `PageCursorCodec` (same
        // target); it binds the complete normalized query shape, the corpus
        // position, and the last RETURNED row's complete ordering anchor
        // (04 §6). `next` exists exactly when survivors remain beyond the
        // returned page.
        let next: HistoryPageCursor?
        if survivors.count > request.limit, let lastReturned = pageSlice.last {
            do {
                next = try PageCursorCodec.encode(
                    ResolvedPageCursor(
                        queryShape: .search(text: term, mode: mode, limit: request.limit),
                        position: corpus.position,
                        anchor: lastReturned.anchor
                    ),
                    processMarker: processMarker
                )
            } catch {
                // A cursor is minted only from already validated scalar/search
                // values. Encoding failure is therefore an internal invariant,
                // never an expired caller cursor (05 §16).
                throw HistoryFailure.persistence(.invariantViolation)
            }
        } else {
            next = nil
        }

#if DEBUG
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "worker",
            phase: "page-materialization",
            phaseElapsed: debugMaterializationStart.duration(to: debugClock.now),
            totalElapsed: debugTotalStart.duration(to: debugClock.now),
            rowsProcessed: rows.count,
            rowsTotal: evaluated.count,
            matchedRows: evaluated.count
        )
        searchDebugProbe.record(
            traceID: debugTraceID,
            component: "worker",
            phase: "complete",
            phaseElapsed: debugTotalStart.duration(to: debugClock.now),
            totalElapsed: debugTotalStart.duration(to: debugClock.now),
            rowsProcessed: rows.count,
            rowsTotal: corpus.rows.count,
            matchedRows: evaluated.count
        )
#endif

        return HistoryPage(position: corpus.position, rows: rows, next: next)
    }

    // MARK: - Default-order anchor (docs/04-coherence.md §6)

    /// The `.defaultOrder` anchor family: used by the recent-equivalent,
    /// exact, and regexp lanes for every row, and by the fuzzy lane for
    /// pinned rows (whose order is the default pinned order, 03b §8).
    private static func defaultOrderAnchor(
        for row: SearchCorpusRow
    ) -> StoredOrderingAnchor {
        .defaultOrder(
            pinnedOrdinal: row.pinOrdinal?.rawValue,
            lastCopiedAt: row.lastCopiedAt,
            id: row.id
        )
    }

    // MARK: - Recent-equivalent lane (03b §8)

    /// Empty-term evaluation: the corpus keeps its pre-ordered default
    /// order and every row carries `search: nil` (03b §8).
    private func evaluateRecentEquivalent(
        in corpus: SearchCorpusSnapshot
    ) -> [EvaluatedRow] {
        corpus.rows.map { row in
            EvaluatedRow(
                corpusRow: row,
                search: nil,
                anchor: Self.defaultOrderAnchor(for: row)
            )
        }
    }

    // MARK: - Exact mode (03b §8)

    /// Case-insensitive literal substring search (03b §8): title first and,
    /// only on title miss, the full bounded `searchBody`; the first match
    /// wins; the default row order is preserved. `.literal` pins the
    /// "literal" half of the frozen definition — no canonical-equivalence
    /// folding, only case-insensitivity.
    private func evaluateExact(
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
                    found.characterOffset
                        ..<(found.characterOffset + found.characterLength),
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

    // MARK: - Regexp mode (03b §8)

    /// `NSRegularExpression` search over the bounded prefixes (03b §8):
    /// admission rejects an invalid or known unsafe pattern BEFORE any
    /// scanning; evaluation scans at most the first 1,000 Characters of
    /// title and, only on title miss, the first 1,000 Characters of body;
    /// the first match wins; the default row order is preserved. The body
    /// excerpt windows only that bounded prefix, while its trailing ellipsis
    /// still records when the stored body continues beyond the scan bound.
    private func evaluateRegexp(
        term: String,
        in corpus: SearchCorpusSnapshot
    ) throws -> [EvaluatedRow] {
        // Admission (03b §8), every rejection is
        // `.invalidInput(.invalidRegularExpression)`: a pattern over the
        // Part VI 512-Character limit; a conservative textual guard for
        // the catastrophic-backtracking shapes; an `NSRegularExpression`
        // compilation failure.
        guard term.count <= limits.maximumRegexpPatternCharacters else {
            throw HistoryFailure.invalidInput(.invalidRegularExpression)
        }
        guard !Self.containsRejectedPatternShape(term) else {
            throw HistoryFailure.invalidInput(.invalidRegularExpression)
        }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: term)
        } catch {
            throw HistoryFailure.invalidInput(.invalidRegularExpression)
        }

        var evaluated: [EvaluatedRow] = []
        for row in corpus.rows {
            let titlePrefix = String(
                row.title.prefix(limits.maximumRegexpTitleBodyPrefixCharacters)
            )
            if let match = regex.firstMatch(
                in: titlePrefix,
                range: NSRange(
                    titlePrefix.startIndex..<titlePrefix.endIndex,
                    in: titlePrefix
                )
            ) {
                // Title match: `NSRegularExpression` already reports
                // UTF-16 offsets, and the prefix's offsets index the title
                // identically (03b §8: ranges relative to
                // `HistoryRow.title`, `snippet == nil`).
                evaluated.append(
                    EvaluatedRow(
                        corpusRow: row,
                        search: SearchPresentation(
                            snippet: nil,
                            matchedRanges: [UTF16TextRange(
                                location: match.range.location,
                                length: match.range.length
                            )]
                        ),
                        anchor: Self.defaultOrderAnchor(for: row)
                    )
                )
                continue
            }
            // Only on title miss: the first 1,000 Characters of body
            // (03b §8).
            let bodyScan = Self.boundedCharacterPrefix(
                of: row.searchBody,
                maximumCharacters: limits.maximumRegexpTitleBodyPrefixCharacters
            )
            let bodyPrefix = bodyScan.text
            guard let match = regex.firstMatch(
                in: bodyPrefix,
                range: NSRange(
                    bodyPrefix.startIndex..<bodyPrefix.endIndex,
                    in: bodyPrefix
                )
            ) else {
                continue
            }
            // Convert the UTF-16 match to Character offsets for the
            // excerpt algorithm. The conversion cannot fail — the range
            // was produced against this very string — but a failed
            // conversion is treated as a miss rather than a crash.
            guard let found = Range(match.range, in: bodyPrefix) else {
                continue
            }
            let lower = bodyPrefix.distance(
                from: bodyPrefix.startIndex,
                to: found.lowerBound
            )
            let upper = bodyPrefix.distance(
                from: bodyPrefix.startIndex,
                to: found.upperBound
            )
            let excerpt = Self.bodyExcerpt(
                body: bodyPrefix,
                characterRanges: [lower..<upper],
                snippetLimit: limits.maximumBodySearchSnippetCharacters,
                bodySuffixWasOmitted: bodyScan.suffixWasOmitted
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
        }
        return evaluated
    }

    /// Conservative textual guards for the rejected unsafe-regexp shapes
    /// (03b §8), all decided before compilation:
    ///
    /// - any backreference — `\1`…`\9` or named `\k<…>` — outside a
    ///   character class (`\0` is an octal escape, not a backreference);
    /// - a quantified group whose body contains either a quantifier or an
    ///   alternation anywhere inside it. This rejects nested quantifiers such
    ///   as `(a+)+`, quantified alternation whose branches contain quantifiers
    ///   such as `(a+|b)+`, and overlapping alternation without inner
    ///   quantifiers such as `(a|a)+` / `(a|ab)+`. Both body flags propagate
    ///   from child to parent on group close, so nested forms are covered.
    ///
    /// Plain non-capturing groups `(?:…)`, anchors, and character-class
    /// constructs stay admissible unless they participate in a rejected
    /// nested-quantifier form. Quantifier tokens are `*`, `+`, `?` (a `?`
    /// directly opening a `(?…` group form is syntax, not a quantifier)
    /// and `{n}`/`{n,}`/`{n,m}` intervals; an unescaped `{` that does not
    /// form an interval is a literal. ICU `(?#…)` comments are skipped to
    /// their closing `)` so comment text cannot desynchronize the group
    /// scan. Any inline flag clause that enables ICU comments mode (`x`) is
    /// rejected conservatively: whitespace and `#` line comments would make
    /// a second structural grammar necessary to prove the same safety
    /// properties. These guards intentionally reject some valid but risky
    /// patterns (03b §8); anything the scanner misreads structurally is
    /// still caught by the compilation check that follows.
    internal static func containsRejectedPatternShape(_ pattern: String) -> Bool {
        let characters = Array(pattern)
        var index = 0
        var characterClassDepth = 0
        var inQuotedLiteral = false
        var openGroupBodyContainsQuantifier: [Bool] = []
        var openGroupBodyContainsAlternation: [Bool] = []

        func markInnermostGroup() {
            guard !openGroupBodyContainsQuantifier.isEmpty else { return }
            openGroupBodyContainsQuantifier[
                openGroupBodyContainsQuantifier.count - 1
            ] = true
        }

        func markInnermostGroupAlternation() {
            guard !openGroupBodyContainsAlternation.isEmpty else { return }
            openGroupBodyContainsAlternation[
                openGroupBodyContainsAlternation.count - 1
            ] = true
        }

        while index < characters.count {
            let character = characters[index]
            if inQuotedLiteral {
                if character == "\\",
                   index + 1 < characters.count,
                   characters[index + 1] == "E" {
                    inQuotedLiteral = false
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if characterClassDepth > 0 {
                if character == "\\" {
                    if index + 1 < characters.count,
                       characters[index + 1] == "Q" {
                        // ICU supports `\Q…\E` inside sets as well as outside
                        // them. Preserve the enclosing set depth while quoted
                        // brackets pass through as literals; otherwise a
                        // quoted `[` can hide a real `(class+)+` shape.
                        inQuotedLiteral = true
                    }
                    index += 2
                    continue
                }
                // ICU UnicodeSet syntax admits nested sets and POSIX classes
                // (`[[a-z][A-Z]]`, `[[:alpha:]]`). Track every unescaped
                // bracket so an inner `]` cannot expose a class-literal `+`
                // as a group quantifier (V1-Verified/03c). A literal bracket
                // in a UnicodeSet is escaped, handled by the branch above.
                if character == "[" {
                    characterClassDepth += 1
                } else if character == "]" {
                    characterClassDepth -= 1
                }
                index += 1
                continue
            }
            switch character {
            case "\\":
                let next = index + 1
                if next < characters.count {
                    let escaped = characters[next]
                    if escaped == "Q" {
                        // ICU `\Q…\E` quotes every structural token inside;
                        // skipping it prevents both false positives and a
                        // quoted `[` from desynchronizing class depth.
                        inQuotedLiteral = true
                    } else if ("1"..."9").contains(escaped) || escaped == "k" {
                        return true
                    }
                }
                index += 2
            case "[":
                characterClassDepth = 1
                index += 1
            case "(":
                if inlineFlagClauseEnablesComments(
                    at: index,
                    in: characters
                ) {
                    return true
                } else if index + 2 < characters.count,
                   characters[index + 1] == "?",
                   characters[index + 2] == "#" {
                    var cursor = index + 3
                    while cursor < characters.count, characters[cursor] != ")" {
                        cursor += 1
                    }
                    index = cursor + 1
                } else {
                    openGroupBodyContainsQuantifier.append(false)
                    openGroupBodyContainsAlternation.append(false)
                    index += (
                        index + 1 < characters.count
                            && characters[index + 1] == "?"
                    ) ? 2 : 1
                }
            case "|":
                // Any alternation inside a group makes a quantifier on that
                // group conservatively unsafe. Escaped pipes and pipes inside
                // character classes were consumed by the branches above.
                markInnermostGroupAlternation()
                index += 1
            case ")":
                let bodyContainsQuantifier =
                    openGroupBodyContainsQuantifier.popLast() ?? false
                let bodyContainsAlternation =
                    openGroupBodyContainsAlternation.popLast() ?? false
                let isQuantified = isQuantifierToken(at: index + 1, in: characters)
                if isQuantified,
                   bodyContainsQuantifier || bodyContainsAlternation {
                    return true
                }
                // Propagate to the parent: either this group is itself
                // quantified (its parent now contains a quantified entity) or
                // its body contained a quantifier (the parent's body
                // transitively contains one), so nested forms like
                // `((a+))+` are rejected (03b §8).
                if isQuantified || bodyContainsQuantifier {
                    markInnermostGroup()
                }
                // A nested alternation remains an alternation contained by its
                // parent, so an outer quantifier is rejected as well.
                if bodyContainsAlternation {
                    markInnermostGroupAlternation()
                }
                index += 1
            case "*", "+", "?":
                markInnermostGroup()
                index += 1
            case "{":
                if let end = intervalQuantifierEnd(at: index, in: characters) {
                    markInnermostGroup()
                    index = end
                } else {
                    index += 1
                }
            default:
                index += 1
            }
        }
        return false
    }

    /// Detects an ICU inline flag clause that enables comments/free-spacing
    /// mode: `(?x)`, mixed forms such as `(?imx-s)`, and scoped forms such as
    /// `(?x:...)`. A mention after `-` disables the flag and is not itself an
    /// enablement. The compiler remains the authority for malformed clauses;
    /// this helper only decides whether the conservative preflight can safely
    /// interpret the pattern's lexical structure.
    private static func inlineFlagClauseEnablesComments(
        at groupStart: Int,
        in characters: [Character]
    ) -> Bool {
        guard groupStart + 2 < characters.count,
              characters[groupStart + 1] == "?" else {
            return false
        }
        var cursor = groupStart + 2
        var enabling = true
        while cursor < characters.count {
            let flag = characters[cursor]
            if flag == "-" {
                enabling = false
                cursor += 1
                continue
            }
            guard "ismwx".contains(flag) else { return false }
            if flag == "x", enabling {
                return true
            }
            cursor += 1
        }
        return false
    }

    /// Whether a quantifier token (`*`, `+`, `?`, or a `{n,m}` interval)
    /// starts at `index` — used for the lookahead that decides whether a
    /// just-closed group is itself quantified (03b §8).
    private static func isQuantifierToken(
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        guard index < characters.count else { return false }
        switch characters[index] {
        case "*", "+", "?":
            return true
        case "{":
            return intervalQuantifierEnd(at: index, in: characters) != nil
        default:
            return false
        }
    }

    /// Parses a `{n}` / `{n,}` / `{n,m}` interval quantifier starting at
    /// the `{` at `start`; returns the index just past the closing `}`, or
    /// `nil` when the `{` is a literal (digits are ASCII-only, as ICU
    /// requires).
    private static func intervalQuantifierEnd(
        at start: Int,
        in characters: [Character]
    ) -> Int? {
        var cursor = start + 1
        var digitCount = 0
        while cursor < characters.count,
              ("0"..."9").contains(characters[cursor]) {
            cursor += 1
            digitCount += 1
        }
        guard digitCount > 0 else { return nil }
        if cursor < characters.count, characters[cursor] == "," {
            cursor += 1
            while cursor < characters.count,
                  ("0"..."9").contains(characters[cursor]) {
                cursor += 1
            }
        }
        guard cursor < characters.count, characters[cursor] == "}" else {
            return nil
        }
        return cursor + 1
    }

    // MARK: - Fuzzy mode (03b §8)

    /// Fuse search over the bounded prefixes (03b §8): the 64-Character
    /// query bound is enforced before Fuse is called; evaluation scans at
    /// most the first 5,000 Characters of title and, only on title miss,
    /// the first 5,000 Characters of body. Ordering preserves the default
    /// pinned-first order: pinned rows first by `pinOrdinal` ascending
    /// (the corpus's pre-order), then unpinned rows by ascending Fuse
    /// score, `lastCopiedAt` descending, History Item ID bytes ascending
    /// (03b §8; docs/04-coherence.md §7).
    private func evaluateFuzzy(
        term: String,
        in corpus: SearchCorpusSnapshot
    ) throws -> [EvaluatedRow] {
        // Fuse 1.4.0 does not enforce its `maxPatternLength` option (the
        // parameter is unread in the pinned revision, so the documented
        // "return nil" never fires). Fuse 1.4.0's bitap stores its pattern
        // mask in one 64-bit Int; longer patterns either cannot represent the
        // completion bit or can overflow inside Fuse. The worker therefore
        // enforces the Part VI 64-Character bound before Fuse is called
        // (03b §8; 06 §2; V1-Verified/03c).
        guard term.count <= limits.maximumFuzzyQueryCharacters else {
            throw HistoryFailure.invalidInput(.invalidSearchTerm)
        }
        // `createPattern` lowercases the pattern (isCaseSensitive ==
        // false) and returns `nil` only for an empty pattern; the term is
        // non-empty on this lane (03b §8 routes empty terms to the
        // recent-equivalent lane), so `nil` is purely defensive and means
        // no row can match.
        guard let pattern = fuse.createPattern(from: term) else {
            return []
        }

        var pinnedHits: [FuzzyHit] = []
        var unpinnedHits: [FuzzyHit] = []
        for row in corpus.rows {
            let hit: FuzzyHit?
            let titlePrefix = String(
                row.title.prefix(limits.maximumFuzzyTitleBodyPrefixCharacters)
            )
            if let titleMatch = fuzzyMatch(pattern: pattern, in: titlePrefix) {
                // Title match: `snippet == nil`, UTF-16 ranges relative to
                // `HistoryRow.title` (03b §8); prefix offsets index the
                // title identically.
                hit = FuzzyHit(
                    corpusRow: row,
                    score: titleMatch.score,
                    search: SearchPresentation(
                        snippet: nil,
                        matchedRanges: Self.utf16Ranges(
                            from: titleMatch.characterRanges,
                            in: titlePrefix
                        )
                    )
                )
            } else {
                // Only on title miss: the first 5,000 Characters of body
                // (03b §8). The excerpt windows that scanned prefix and
                // records a trailing ellipsis when the stored body continues.
                let bodyScan = Self.boundedCharacterPrefix(
                    of: row.searchBody,
                    maximumCharacters: limits.maximumFuzzyTitleBodyPrefixCharacters
                )
                let bodyPrefix = bodyScan.text
                if let bodyMatch = fuzzyMatch(pattern: pattern, in: bodyPrefix) {
                    let excerpt = Self.bodyExcerpt(
                        body: bodyPrefix,
                        characterRanges: bodyMatch.characterRanges,
                        snippetLimit: limits.maximumBodySearchSnippetCharacters,
                        bodySuffixWasOmitted: bodyScan.suffixWasOmitted
                    )
                    hit = FuzzyHit(
                        corpusRow: row,
                        score: bodyMatch.score,
                        search: SearchPresentation(
                            snippet: excerpt.snippet,
                            matchedRanges: excerpt.ranges
                        )
                    )
                } else {
                    hit = nil
                }
            }
            guard let hit else { continue }
            if row.pinOrdinal == nil {
                unpinnedHits.append(hit)
            } else {
                pinnedHits.append(hit)
            }
        }

        // Pinned rows first: the corpus is pre-ordered in the default
        // order (05 §14.2), so pinned hits are already in `pinOrdinal`
        // ascending (03b §8) and keep the `.defaultOrder` anchor family.
        let pinned = pinnedHits.map { hit in
            EvaluatedRow(
                corpusRow: hit.corpusRow,
                search: hit.search,
                anchor: Self.defaultOrderAnchor(for: hit.corpusRow)
            )
        }
        // Unpinned rows: ascending Fuse score, then `lastCopiedAt`
        // descending, then History Item ID bytes ascending (03b §8; the
        // 04 §7 tie-breaker tail). `HistoryItemID.<` compares raw UUID
        // bytes lexicographically.
        let unpinned = unpinnedHits
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score < rhs.score
                }
                if lhs.corpusRow.lastCopiedAt != rhs.corpusRow.lastCopiedAt {
                    return lhs.corpusRow.lastCopiedAt > rhs.corpusRow.lastCopiedAt
                }
                return lhs.corpusRow.id < rhs.corpusRow.id
            }
            .map { hit in
                EvaluatedRow(
                    corpusRow: hit.corpusRow,
                    search: hit.search,
                    anchor: .fuzzyUnpinned(
                        score: hit.score,
                        lastCopiedAt: hit.corpusRow.lastCopiedAt,
                        id: hit.corpusRow.id
                    )
                )
            }
        return pinned + unpinned
    }

    /// Runs the frozen-parameter Fuse matcher over one scanned string.
    ///
    /// Fuse 1.4.0 normally lowercases its working copy internally. This
    /// worker instead creates that lowercase copy once, proves its Character
    /// alignment, and passes it through an otherwise-identical case-sensitive
    /// matcher so Fuse does not allocate it again. Fuse reports match ranges
    /// as `CountableClosedRange<Int>` Character offsets into that copy.
    /// Swift's `lowercased()` performs Unicode default
    /// lowercasing, whose only multi-scalar expansion (U+0130 →
    /// U+0069 U+0307) stays within one extended grapheme cluster, so
    /// Character indices never shift; the count check below proves the
    /// working copy's Character indices align 1:1 with the original's, and
    /// a hypothetical future Unicode change that broke the alignment makes
    /// the field a miss rather than a guess (03b §8: lower-casing must
    /// not shift offsets).
    ///
    /// - Returns: the Fuse score (internal only) and half-open Character
    ///   ranges aligned with the original string; the title caller performs
    ///   UTF-16 translation, while the body caller passes the ranges directly
    ///   to the bounded excerpt algorithm.
    private func fuzzyMatch(
        pattern: Fuse.Pattern,
        in scanned: String
    ) -> (
        score: Double,
        characterRanges: [Range<Int>]
    )? {
        let scannedCharacterCount = scanned.count
        let lowercased = scanned.lowercased()
        guard lowercased.count == scannedCharacterCount else {
            return nil
        }
        guard let result = prelowercasedFuse.search(pattern, in: lowercased) else {
            return nil
        }
        var characterRanges: [Range<Int>] = []
        characterRanges.reserveCapacity(result.ranges.count)
        for range in result.ranges {
            // Defensive: Fuse's ranges index its working copy, which the
            // count check just aligned with `scanned`.
            guard range.lowerBound >= 0,
                  range.upperBound < scannedCharacterCount else {
                continue
            }
            characterRanges.append(range.lowerBound..<(range.upperBound + 1))
        }
        return (
            result.score,
            characterRanges
        )
    }

    // MARK: - Body excerpt (03b §8)

    /// The frozen body-match excerpt construction (03b §8, verbatim):
    ///
    /// 1. sort match ranges;
    /// 2. a body 320 Characters or shorter keeps the whole body and adds
    ///    no ellipses;
    /// 3. otherwise center a window of at most 320 Characters on the
    ///    earliest match — a longer match keeps its first 320 Characters —
    ///    distributing the remaining context equally before/after with the
    ///    extra Character AFTER, and redistributing context that would
    ///    extend past a body edge to the other side;
    /// 4. add `…` at each edge where text was omitted — a leading ellipsis
    ///    only when the window starts after the body start, a trailing one
    ///    when it ends before this input or the caller reports that the
    ///    stored body continues beyond a regexp/fuzzy scan prefix;
    /// 5. clip later ranges to the retained window;
    /// 6. convert the retained ranges to UTF-16 offsets into the final
    ///    snippet, shifting each right by the leading-ellipsis length only
    ///    when one is present.
    ///
    /// `…` is one Character and one UTF-16 code unit, so the final snippet
    /// is at most 320 + 2 = 322 Characters — the governing bound is
    /// `HistoryLimits.maximumBodySearchSnippetCharacters`
    /// (docs/06-cross-cutting.md §2 "Body search snippet"), passed here as
    /// `snippetLimit`; the 320-Character window capacity is derived from
    /// it, not hardcoded.
    ///
    /// Ranges are half-open Character offsets into `body`. (A zero-length
    /// match — possible under regexp mode — centers a window but clips
    /// away, contributing no snippet range.)
    ///
    /// Internal only so direct `@testable` worked examples can pin this frozen
    /// pure algorithm independently of the SwiftData/Fuse integration proof.
    internal static func bodyExcerpt(
        body: String,
        characterRanges: [Range<Int>],
        snippetLimit: Int,
        bodySuffixWasOmitted: Bool = false
    ) -> (snippet: String, ranges: [UTF16TextRange]) {
        // `String.count` walks the body but does not materialize a
        // `[Character]`. The only owned text below is `windowText`, whose size
        // is bounded by the snippet window. This matters in exact mode where
        // `body` may be the full 256-KiB stored projection (06 §2).
        let count = body.count
        let windowCapacity = snippetLimit - 2
        let sortedRanges = characterRanges.sorted {
            $0.lowerBound < $1.lowerBound
        }

        let windowLower: Int
        let windowUpper: Int   // exclusive
        if count <= windowCapacity {
            // Step 2. `count == windowCapacity` fits exactly and equally
            // omits nothing, so it shares the whole-body outcome.
            windowLower = 0
            windowUpper = count
        } else if let earliest = sortedRanges.first {
            let matchLength = earliest.upperBound - earliest.lowerBound
            if matchLength >= windowCapacity {
                // A longer match keeps its first 320 Characters.
                windowLower = earliest.lowerBound
                windowUpper = earliest.lowerBound + windowCapacity
            } else {
                // Center the window; extra context Character AFTER; edge
                // overflow redistributes to the other side.
                let context = windowCapacity - matchLength
                let before = context / 2
                let after = context - before
                var lower = earliest.lowerBound - before
                var upper = earliest.upperBound + after
                if lower < 0 {
                    upper -= lower
                    lower = 0
                }
                if upper > count {
                    lower = max(0, lower - (upper - count))
                    upper = count
                }
                windowLower = lower
                windowUpper = upper
            }
        } else {
            // Defensive: a body match always carries at least one range.
            windowLower = 0
            windowUpper = min(count, windowCapacity)
        }

        let hasLeadingEllipsis = windowLower > 0
        let hasTrailingEllipsis = windowUpper < count || bodySuffixWasOmitted
        let windowLowerIndex = body.index(
            body.startIndex,
            offsetBy: windowLower
        )
        let windowUpperIndex = body.index(
            windowLowerIndex,
            offsetBy: windowUpper - windowLower
        )
        let windowText = String(body[windowLowerIndex..<windowUpperIndex])
        var snippet = hasLeadingEllipsis ? "…" : ""
        snippet.append(contentsOf: windowText)
        if hasTrailingEllipsis {
            snippet.append("…")
        }

        // Clip to the window, then convert to UTF-16 offsets into the
        // final snippet, shifting right by the leading ellipsis only when
        // present (03b §8 steps 5–6).
        let clippedRanges = sortedRanges.compactMap { range -> Range<Int>? in
            let clippedLower = max(range.lowerBound, windowLower)
            let clippedUpper = min(range.upperBound, windowUpper)
            guard clippedLower < clippedUpper else { return nil }
            return (clippedLower - windowLower)..<(clippedUpper - windowLower)
        }
        let maximumMatchedOffset = clippedRanges.map(\.upperBound).max() ?? 0
        let windowOffsets = utf16PrefixOffsets(
            of: windowText,
            through: maximumMatchedOffset
        )
        let ranges = clippedRanges.map { range in
            UTF16TextRange(
                location: windowOffsets[range.lowerBound]
                    + (hasLeadingEllipsis ? 1 : 0),
                length: windowOffsets[range.upperBound]
                    - windowOffsets[range.lowerBound]
            )
        }
        return (snippet, ranges)
    }

    /// Materializes at most `maximumCharacters` and reports whether the
    /// original string continues. Computing the end index is bounded by the
    /// same scan limit, avoiding an O(full-body) `count` just to decide the
    /// excerpt's trailing ellipsis.
    private static func boundedCharacterPrefix(
        of text: String,
        maximumCharacters: Int
    ) -> (text: String, suffixWasOmitted: Bool) {
        let end = text.index(
            text.startIndex,
            offsetBy: maximumCharacters,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        return (String(text[..<end]), end != text.endIndex)
    }

    // MARK: - UTF-16 translation (03b §8; docs/04-coherence.md §7)

    /// Converts half-open Character-offset ranges into UTF-16 offsets into
    /// `text`. A `String`'s UTF-16 view is the concatenation of its
    /// Characters' UTF-16 views, so per-Character prefix sums give exact
    /// code-unit offsets for any Character boundary.
    internal static func utf16Ranges(
        from characterRanges: [Range<Int>],
        in text: String
    ) -> [UTF16TextRange] {
        let maximumMatchedOffset = characterRanges.map(\.upperBound).max() ?? 0
        let offsets = utf16PrefixOffsets(
            of: text,
            through: maximumMatchedOffset
        )
        return characterRanges.map { range in
            UTF16TextRange(
                location: offsets[range.lowerBound],
                length: offsets[range.upperBound] - offsets[range.lowerBound]
            )
        }
    }

    /// `offsets[i]` is the number of UTF-16 code units preceding Character
    /// `i` in `text`. Only offsets through the furthest matched boundary are
    /// built; no caller needs the suffix after that boundary.
    private static func utf16PrefixOffsets(
        of text: String,
        through maximumCharacterOffset: Int
    ) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(maximumCharacterOffset + 1)
        offsets.append(0)
        var total = 0
        for character in text.prefix(maximumCharacterOffset) {
            total += character.utf16.count
            offsets.append(total)
        }
        return offsets
    }
}
