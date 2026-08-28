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
/// coherence proofs can place a commit inside the snapshot→evaluation gap or
/// cancellation at a bounded scan checkpoint without retaining any SwiftData
/// value across the suspension (docs/04-coherence.md §5/§7; REVIEW Card 11B).
internal enum SearchWorkerSuspensionPoint: String, Sendable {
    case evaluationEntry = "SearchWorker.page.evaluationEntry"
#if DEBUG
    case exactScanChunk = "SearchWorker.page.exactScanChunk"
    case regexpScanChunk = "SearchWorker.page.regexpScanChunk"
    case fuzzyScanChunk = "SearchWorker.page.fuzzyScanChunk"
#endif
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
    /// REVIEW Card 11B: expensive mode scans observe cancellation at a fixed,
    /// small row cadence. One row remains the irreducible unit because the
    /// frozen Foundation/Fuse match calls are synchronous; no matcher object
    /// or mutable state leaves this actor (review playbook §16).
    internal static let cancellationRowInterval = 32

    /// REVIEW Card 11C: the fixed per-request regexp engine deadline — the
    /// same bound as the two-run master watchdog evidence that proved the
    /// former `firstMatch` operation runs uninterruptibly past it on an
    /// admitted pattern. Measured on the monotonic `ContinuousClock` and
    /// enforced only inside the engine's periodic progress callback
    /// (03b §8 adjudication). This bounds the demonstrated non-preemptible
    /// hazard family; it is not a general preemption or total-time guarantee
    /// (total scan cost remains the Part VI §9 envelope), so it deliberately
    /// stays out of the `HistoryLimits` public profile.
    internal static let defaultRegexpEngineDeadline: Duration = .milliseconds(2_000)

    /// The fixed `HistoryLimits.standard` safety profile
    /// (docs/06-cross-cutting.md §2): the common 4,096-UTF-8-byte search-term
    /// bound, the 512-Character regexp-pattern bound, the 64-Character
    /// fuzzy-query bound, the 1,000/5,000-Character regexp/fuzzy scan prefixes,
    /// and the 322-Character snippet bound.
    internal let limits: HistoryLimits

    /// The confined fuzzy matcher (docs/01-architecture.md §6). Frozen
    /// parameters (03b §8): `threshold` 0.7, `location` 0, `distance` 100,
    /// `isCaseSensitive` false; `tokenize` keeps its `false` default.
    /// `maxPatternLength` is deliberately not passed: it is a dead
    /// parameter in the pinned 1.4.0 revision (stored, never read — see
    /// `Fuse/Classes/Fuse.swift` at krisk/fuse-swift
    /// 26ba868691b2d8b7bf2b1322951eb591be70ccca; docs/AUDIT.md §4b), so the
    /// 64-Character query bound is enforced by `page` itself before Fuse
    /// is called.
    internal let fuse: Fuse

    /// Same scoring parameters, but case-sensitive because `fuzzyMatch`
    /// supplies the single pre-lowercased working copy. This avoids Fuse
    /// allocating a second lowercase string after the alignment proof.
    internal let prelowercasedFuse: Fuse

    /// Deterministic coherence/cancellation-test seam. Nil outside `@testable`
    /// tests; only immutable corpus/request values are live when it is awaited.
    internal var suspensionHandler: (
        @Sendable (SearchWorkerSuspensionPoint) async -> Void
    )?

    /// The live per-request regexp engine deadline (03b §8 Card 11C). Kept at
    /// `defaultRegexpEngineDeadline` in production; `@testable` tests inject a
    /// zero or distant value along the `suspensionHandler` seam precedent.
    internal var regexpEngineDeadline: Duration

#if DEBUG
    /// Opt-in aggregate tracing for the off-Authority half of the search
    /// pipeline. The probe and all event work are absent from Release builds.
    internal var searchDebugProbe = SearchDebugProbe.environmentConfigured()
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
        self.regexpEngineDeadline = Self.defaultRegexpEngineDeadline
    }

    /// Installs or clears the deterministic evaluation/checkpoint handler.
    /// Production never installs one, so the seam is a no-op there.
    internal func setSuspensionHandler(
        _ handler: (@Sendable (SearchWorkerSuspensionPoint) async -> Void)?
    ) {
        suspensionHandler = handler
    }

    /// Installs the deterministic regexp engine-deadline seam. Production
    /// never calls it, so the fixed default stays in force there.
    internal func setRegexpEngineDeadline(_ deadline: Duration) {
        regexpEngineDeadline = deadline
    }

    /// Cooperative checkpoint shared by the three scan loops. Production's
    /// handler is nil; tests park the first chunk to prove a cancelled query
    /// releases this actor before a replacement query waits for a full scan.
    internal func scanCheckpoint(
        _ mode: SearchMode,
        beforeRowAt offset: Int
    ) async throws {
        guard offset.isMultiple(of: Self.cancellationRowInterval) else {
            return
        }
#if DEBUG
        let point: SearchWorkerSuspensionPoint
        switch mode {
        case .exact:
            point = .exactScanChunk
        case .regexp:
            point = .regexpScanChunk
        case .fuzzy:
            point = .fuzzyScanChunk
        }
        await suspensionHandler?(point)
#endif
        try Task.checkCancellation()
    }

#if DEBUG
    /// Replaces the environment-backed probe for deterministic Debug tests.
    internal func setSearchDebugProbe(_ probe: SearchDebugProbe) {
        searchDebugProbe = probe
    }
#endif

    /// One evaluated row in final page order: the corpus scalar row, its
    /// deferred presentation (`nil` on the recent-equivalent lane, 03b §8),
    /// and the complete ordering anchor the next cursor binds to
    /// (docs/04-coherence.md §6).
    internal struct EvaluatedRow {
        let corpusRow: SearchCorpusRow
        let search: DeferredSearchPresentation?
        let anchor: StoredOrderingAnchor
    }

    /// One fuzzy-matched row before ordering: the corpus row, the Fuse
    /// score (internal only — 03b §8: "Search scores and Fuse objects
    /// remain internal"), and the deferred presentation.
    internal struct FuzzyHit {
        let corpusRow: SearchCorpusRow
        let score: Double
        let search: DeferredSearchPresentation
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
    ///   `.temporarilyUnavailable(.searchEngineDeadline)` when an admitted
    ///   regexp scan is stopped at its fixed engine deadline or the engine
    ///   abandons the match internally (03b §8 Card 11C — the whole search
    ///   fails, no partial page);
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
        // Repeat the Authority's pre-I/O caller-input admission at the worker
        // boundary. The worker never trusts the already-materialized corpus
        // to imply that its independently supplied request was admitted.
        let admitted = try AdmittedSearchRequest(request, limits: limits)
        let term = admitted.term
        let mode = admitted.mode

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
        let directive = ScanDirective(
            continuationAnchor: continuationAnchor,
            maximumSurvivors: request.limit + 1
        )
        let evaluated: [EvaluatedRow]
        if term.isEmpty {
            evaluated = evaluateRecentEquivalent(in: corpus, directive: directive)
        } else {
            switch mode {
            case .exact:
                evaluated = try await evaluateExact(
                    term: term,
                    in: corpus,
                    directive: directive
                )
            case .regexp:
                evaluated = try await evaluateRegexp(
                    term: term,
                    in: corpus,
                    directive: directive
                )
            case .fuzzy:
                evaluated = try await evaluateFuzzy(term: term, in: corpus)
            }
        }
        try Task.checkCancellation()

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
            // Deferred presentations materialize here and only here —
            // bounded O(returned page) excerpt/translation work instead of
            // O(every matched row) per scan (03b §8; the corpus row already
            // carries the stored body, so nothing extra crosses a boundary).
            let search: SearchPresentation?
            switch evaluatedRow.search {
            case nil:
                search = nil
            case .ready(let presentation):
                search = presentation
            case .titleRanges(let characterRanges):
                search = SearchPresentation(
                    snippet: nil,
                    matchedRanges: Self.utf16Ranges(
                        from: characterRanges,
                        in: corpusRow.title
                    )
                )
            case .bodyExcerpt(
                let characterRanges,
                let maximumCharacters,
                let bodySuffixWasOmitted
            ):
                let excerpt: (snippet: String, ranges: [UTF16TextRange])
                if let maximumCharacters {
                    // Fuzzy/regexp windows: the lane's bounded scan prefix
                    // (03b §8), re-derived from the stored body.
                    let scan = Self.boundedCharacterPrefix(
                        of: corpusRow.searchBody,
                        maximumCharacters: maximumCharacters
                    )
                    excerpt = Self.bodyExcerpt(
                        body: String(scan.text),
                        characterRanges: characterRanges,
                        snippetLimit: limits.maximumBodySearchSnippetCharacters,
                        bodySuffixWasOmitted: bodySuffixWasOmitted
                    )
                } else {
                    // Exact mode windows the complete bounded projection.
                    excerpt = Self.bodyExcerpt(
                        body: corpusRow.searchBody,
                        characterRanges: characterRanges,
                        snippetLimit: limits.maximumBodySearchSnippetCharacters,
                        bodySuffixWasOmitted: bodySuffixWasOmitted
                    )
                }
                search = SearchPresentation(
                    snippet: excerpt.snippet,
                    matchedRanges: excerpt.ranges
                )
            }
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
                search: search
            )
        }
        try Task.checkCancellation()

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

        try Task.checkCancellation()
        return HistoryPage(position: corpus.position, rows: rows, next: next)
    }

    // MARK: - Default-order anchor (docs/04-coherence.md §6)

    /// The `.defaultOrder` anchor family: used by the recent-equivalent,
    /// exact, and regexp lanes for every row, and by the fuzzy lane for
    /// pinned rows (whose order is the default pinned order, 03b §8).
    internal static func defaultOrderAnchor(
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
    /// order and every row carries `search: nil` (03b §8). The directive
    /// bounds the returned array to the rows the page decision can still
    /// consume — the continuation anchor itself (page drops up to and
    /// including it) plus at most `limit + 1` successors — so a 5,000-row
    /// corpus no longer materializes 5,000 evaluated rows per page. A
    /// missing anchor yields an empty array, which `page` maps to
    /// `snapshotExpired` exactly as the full scan did.
    internal func evaluateRecentEquivalent(
        in corpus: SearchCorpusSnapshot,
        directive: ScanDirective
    ) -> [EvaluatedRow] {
        var startIndex = corpus.rows.startIndex
        var window = directive.maximumSurvivors
        if let anchor = directive.continuationAnchor {
            guard let anchorIndex = corpus.rows.firstIndex(where: {
                Self.defaultOrderAnchor(for: $0) == anchor
            }) else {
                return []
            }
            // Include the anchor row itself: `page` locates it in the
            // evaluated array before dropping it, so an anchor-exclusive
            // window would read as an expired cursor.
            startIndex = anchorIndex
            window += 1
        }
        return corpus.rows[startIndex...]
            .prefix(window)
            .map { row in
                EvaluatedRow(
                    corpusRow: row,
                    search: nil,
                    anchor: Self.defaultOrderAnchor(for: row)
                )
            }
    }

}
