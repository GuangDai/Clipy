/// Fuzzy-mode evaluation behind the actor-confined Fuse matcher (03b §8).
/// Split out of SearchWorker.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import Fuse

extension SearchWorker {
    // MARK: - Fuzzy mode (03b §8)

    /// A necessary condition for the pinned Fuse 1.4 Bitap loop. With its
    /// frozen location 0, distance 100 and threshold .7, `finish` cannot
    /// exceed 70 + pattern length. Each pattern position whose Character
    /// is absent from that prefix costs at least one substitution/deletion;
    /// Fuse never reaches an error level whose error/length exceeds .7.
    ///
    /// This only rejects proven misses. Survivors still use Fuse unchanged,
    /// including its exact-match prepass and score/range behavior. ASCII
    /// permits inspecting this short prefix before lowercasing or counting
    /// a 5,000-Character body. Non-ASCII prefixes use the original matcher.
    internal struct FuzzyASCIIRejection {
        private let masks: [Int]
        private let crlfMask: Int
        private let prefixCharacters: Int
        private let requiredPositions: Int

        internal init(pattern: Fuse.Pattern) {
            var masks = [Int](repeating: 0, count: 128)
            for (character, mask) in pattern.alphabet {
                if let ascii = character.asciiValue {
                    masks[Int(ascii)] = mask
                }
            }
            self.masks = masks
            self.crlfMask = pattern.alphabet["\r\n"] ?? 0
            self.prefixCharacters = 70 + pattern.len
            // Use the same division as Fuse's error-level stopping test,
            // avoiding a separate floating-point rounding convention.
            let maximumErrors = (0..<pattern.len).last {
                Double($0) / Double(pattern.len) <= 0.7
            } ?? 0
            self.requiredPositions = pattern.len - maximumErrors
        }

        internal func rejects(_ text: String) -> Bool {
            text.utf8.withContiguousStorageIfAvailable { bytes in
                var offset = 0
                var characters = 0
                var positions = 0
                while offset < bytes.count, characters < prefixCharacters {
                    let byte = bytes[offset]
                    guard byte < 128 else { return false }
                    if byte == 13, offset + 1 < bytes.count, bytes[offset + 1] == 10 {
                        // CRLF is one Character; neither standalone control
                        // character occurs at this position in Fuse's input.
                        positions |= crlfMask
                        offset += 2
                    } else {
                        let lowercase = (65...90).contains(byte) ? byte + 32 : byte
                        positions |= masks[Int(lowercase)]
                        offset += 1
                    }
                    characters += 1
                    if positions.nonzeroBitCount >= requiredPositions { return false }
                }
                // A following non-ASCII scalar may extend the last ASCII
                // byte into an EGC, e.g. e + COMBINING ACUTE. Defer to Fuse
                // instead of treating that partial Character as plain e.
                if offset < bytes.count, bytes[offset] >= 128 { return false }
                return positions.nonzeroBitCount < requiredPositions
            } ?? false
        }
    }

    /// Per-request top-K selection. The root is the worst retained hit, so
    /// a better candidate replaces it in O(log(limit)); prior-page hits
    /// never occupy the heap. Keep the exact anchor separately for `page`'s
    /// existing missing/changed-anchor rejection (04 §6). This bounds only
    /// evaluated results, not the current full corpus snapshot.
    internal struct FuzzyPageSelection {
        private let directive: ScanDirective
        internal private(set) var hits: [EvaluatedRow] = []
        private var anchorRow: EvaluatedRow?

        internal init(directive: ScanDirective) {
            self.directive = directive
        }

        internal mutating func insert(_ hit: FuzzyHit) {
            let row = EvaluatedRow(
                corpusRow: hit.corpusRow,
                search: hit.search,
                anchor: hit.corpusRow.pinOrdinal == nil
                    ? .fuzzyUnpinned(
                        score: hit.score,
                        lastCopiedAt: hit.corpusRow.lastCopiedAt,
                        id: hit.corpusRow.id
                    )
                    : SearchWorker.defaultOrderAnchor(for: hit.corpusRow)
            )
            if let anchor = directive.continuationAnchor {
                if row.anchor == anchor {
                    anchorRow = row
                    return
                }
                guard isPreferred(anchor, row.anchor) else { return }
            }
            if hits.count < directive.maximumSurvivors {
                hits.append(row)
                var child = hits.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard isPreferred(hits[parent].anchor, hits[child].anchor) else {
                        break
                    }
                    hits.swapAt(parent, child)
                    child = parent
                }
            } else if let worst = hits.first,
                      isPreferred(row.anchor, worst.anchor) {
                hits[0] = row
                var parent = 0
                while parent * 2 + 1 < hits.count {
                    var child = parent * 2 + 1
                    let right = child + 1
                    if right < hits.count,
                       isPreferred(hits[child].anchor, hits[right].anchor) {
                        child = right
                    }
                    guard isPreferred(hits[parent].anchor, hits[child].anchor) else {
                        break
                    }
                    hits.swapAt(parent, child)
                    parent = child
                }
            }
        }

        internal func evaluatedRows() -> [EvaluatedRow] {
            if directive.continuationAnchor != nil, anchorRow == nil {
                return []
            }
            // The survivor window is limit-bounded, so this ordering sort
            // (like the per-row heap upkeep) adds a log factor over the
            // window, not the corpus; the §9 bullet 7 envelope still only
            // rejects quadratic over the measured scales.
            let ordered = hits.sorted { Self.precedes($0.anchor, $1.anchor) }
            if let anchorRow {
                return directive.direction == .forward ? [anchorRow] + ordered : ordered + [anchorRow]
            }
            return ordered
        }

        /// The caller has consumed complete batches in the default
        /// pin/date/ID order. Once the forward page plus lookahead is full,
        /// later rows cannot outrank an all-pinned window, or an unpinned
        /// worst hit already at the query's proven global score minimum.
        /// Equal-score later rows lose the same date/ID tie break. A cursor
        /// must first be confirmed by its actual matching row (04 §6).
        ///
        /// Zero is Fuse's absolute lower bound. A larger value is permitted
        /// only when query facts prove it for every row in this snapshot;
        /// a score merely observed in the current batch is not such a fact.
        /// A floor-score cursor may start at its ordered suffix: skipped
        /// equal-score prefix rows precede that cursor, and skipped worse
        /// scores cannot improve a full floor-score window. If that window
        /// does not fill, SQLite subsequently supplies the skipped prefix.
        /// In reverse, a floor-score cursor has only equal-score unpinned
        /// predecessors plus pinned predecessors. A pinned cursor has only
        /// earlier pins. SQLite can supply those physical prefixes in reverse
        /// order; the heap still excludes higher-score hits. Once full, later
        /// eligible rows are farther from the cursor and cannot improve it.
        internal func cannotBeImprovedByLaterDefaultOrderedRows(
            lowestPossibleScore: Double = 0,
            reversesEligiblePredecessors: Bool = false
        ) -> Bool {
            guard hits.count == directive.maximumSurvivors,
                  directive.continuationAnchor == nil || anchorRow != nil,
                  let worst = hits.first else { return false }
            if directive.direction == .backward {
                return reversesEligiblePredecessors && anchorRow != nil
            }
            switch worst.anchor {
            case .defaultOrder(let pinOrdinal, _, _):
                return pinOrdinal != nil
            case .fuzzyUnpinned(let score, _, _):
                return score == lowestPossibleScore
            }
        }

        /// Forward keeps the earliest successors; backward keeps the latest
        /// predecessors. Final output still uses the ordinary display order.
        private func isPreferred(_ lhs: StoredOrderingAnchor, _ rhs: StoredOrderingAnchor) -> Bool {
            directive.direction == .forward ? Self.precedes(lhs, rhs) : Self.precedes(rhs, lhs)
        }

        /// Only bounded candidate IDs, including a separately retained
        /// continuation anchor. Used to retain matching external count facts.
        internal var retainedIDs: Set<HistoryItemID> {
            var ids = Set(hits.map { $0.corpusRow.id })
            if let anchorRow { ids.insert(anchorRow.corpusRow.id) }
            return ids
        }

        /// The frozen pinned/score/date/UUID total order, shared by heap
        /// selection and final ordering so equal scores keep cursor ties.
        private static func precedes(
            _ lhs: StoredOrderingAnchor,
            _ rhs: StoredOrderingAnchor
        ) -> Bool {
            let leftDate: Date
            let rightDate: Date
            let leftID: HistoryItemID
            let rightID: HistoryItemID
            switch (lhs, rhs) {
            case let (.defaultOrder(leftPin, ld, li), .defaultOrder(rightPin, rd, ri)):
                if leftPin != rightPin {
                    return (leftPin ?? Int.max) < (rightPin ?? Int.max)
                }
                (leftDate, rightDate, leftID, rightID) = (ld, rd, li, ri)
            case (.defaultOrder, .fuzzyUnpinned):
                return true
            case (.fuzzyUnpinned, .defaultOrder):
                return false
            case let (.fuzzyUnpinned(ls, ld, li), .fuzzyUnpinned(rs, rd, ri)):
                if ls != rs { return ls < rs }
                (leftDate, rightDate, leftID, rightID) = (ld, rd, li, ri)
            }
            if leftDate != rightDate { return leftDate > rightDate }
            return leftID < rightID
        }
    }

    /// Fuse search over the bounded prefixes (03b §8): the 64-Character
    /// query bound is enforced before Fuse is called; evaluation scans at
    /// most the first 5,000 Characters of title and, only on title miss,
    /// the first 5,000 Characters of body. Ordering preserves the default
    /// pinned-first order: pinned rows first by `pinOrdinal` ascending
    /// (the corpus's pre-order), then unpinned rows by ascending Fuse
    /// score, `lastCopiedAt` descending, History Item ID bytes ascending
    /// (03b §8; docs/04-coherence.md §7).
    internal func evaluateFuzzy(
        term: String,
        in corpus: SearchCorpusSnapshot,
        directive: ScanDirective,
        preparedPattern: Fuse.Pattern? = nil,
        work: SearchWorkCounter? = nil
    ) async throws -> EvaluationResult {
        // Fuse 1.4.0 does not enforce its `maxPatternLength` option (the
        // parameter is unread in the pinned revision, so the documented
        // "return nil" never fires). Fuse 1.4.0's bitap stores its pattern
        // mask in one 64-bit Int; longer patterns either cannot represent the
        // completion bit or can overflow inside Fuse. The worker therefore
        // enforces the Part VI 64-Character bound before Fuse is called
        // (03b §8; 06 §2; V1-Verified/03c).
        guard preparedPattern != nil || term.prefix(limits.maximumFuzzyQueryCharacters + 1).count
                <= limits.maximumFuzzyQueryCharacters else {
            throw HistoryFailure.invalidInput(.invalidSearchTerm)
        }
        // `createPattern` lowercases the pattern (isCaseSensitive ==
        // false) and returns `nil` only for an empty pattern; the term is
        // non-empty on this lane (03b §8 routes empty terms to the
        // recent-equivalent lane), so `nil` is purely defensive and means
        // no row can match.
        guard let pattern = preparedPattern ?? fuse.createPattern(from: term) else {
#if DEBUG
            return EvaluationResult(rows: [], debugRowsProcessed: 0, debugMatchedRows: 0)
#else
            return EvaluationResult(rows: [])
#endif
        }

        let rejection = FuzzyASCIIRejection(pattern: pattern)
        var selection = FuzzyPageSelection(directive: directive)
#if DEBUG
        let debugClock = ContinuousClock()
        let debugStart = debugClock.now
        var debugProcessedRows = 0
        var debugTitleMatches = 0
        var debugBodyMatches = 0
        var debugTitleUTF8Bytes = 0
        var debugBodyUTF8Bytes = 0
        searchDebugProbe.record(
            traceID: corpus.debugTrace.id,
            component: "worker",
            phase: "fuzzy-scan-begin",
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
                phase: "fuzzy-scan-progress",
                phaseElapsed: debugStart.duration(to: debugClock.now),
                totalElapsed: corpus.debugTrace.startedAt.duration(to: debugClock.now),
                rowsProcessed: debugProcessedRows,
                rowsTotal: corpus.rows.count,
                matchedRows: debugTitleMatches + debugBodyMatches,
                titleUTF8Bytes: debugTitleUTF8Bytes,
                bodyUTF8Bytes: debugBodyUTF8Bytes,
                titleMatches: debugTitleMatches,
                bodyMatches: debugBodyMatches
            )
        }
#endif
        scan: for (rowOffset, row) in corpus.rows.enumerated() {
            try await scanCheckpoint(
                .fuzzy,
                beforeRowAt: rowOffset
            )
            work?.rowsEvaluated += 1
#if DEBUG
            debugProcessedRows += 1
            debugTitleUTF8Bytes += row.debugTitleUTF8Bytes
#endif
            // Titles are bounded by `maximumStoredTitleUTF8Bytes` (1,024
            // UTF-8 bytes ⇒ at most 1,024 Characters), strictly below the
            // 5,000-Character scan prefix, so the whole title is always
            // the scanned prefix (03b §8; 06 §2) — no per-row prefix copy.
            let hit: FuzzyHit?
            if !rejection.rejects(row.title), let titleMatch = fuzzyMatch(
                pattern: pattern,
                lowercased: row.title.lowercased(),
                characterCount: row.title.count
            ) {
                // Title match: `snippet == nil`, UTF-16 ranges relative to
                // `HistoryRow.title` (03b §8); prefix offsets index the
                // title identically. The UTF-16 translation itself is
                // deferred to page materialization.
                hit = FuzzyHit(
                    corpusRow: row,
                    score: titleMatch.score,
                    search: .titleRanges(titleMatch.characterRanges)
                )
            } else {
                // Only on title miss: the first 5,000 Characters of body
                // (03b §8). The scan slices without copying, the excerpt
                // window and its trailing-ellipsis decision defer to page
                // materialization.
#if DEBUG
                debugBodyUTF8Bytes += row.debugSearchBodyUTF8Bytes
#endif
                if rejection.rejects(row.searchBody) {
                    hit = nil
                } else {
                    let bodyScan = Self.boundedCharacterPrefix(
                        of: row.searchBody,
                        maximumCharacters: limits.maximumFuzzyTitleBodyPrefixCharacters
                    )
                    let lowercasedBody = bodyScan.text.lowercased()
                    if let bodyMatch = fuzzyMatch(
                        pattern: pattern,
                        lowercased: lowercasedBody,
                        characterCount: bodyScan.characterCount
                    ) {
                        hit = FuzzyHit(
                            corpusRow: row,
                            score: bodyMatch.score,
                            search: .bodyExcerpt(
                                characterRanges: bodyMatch.characterRanges,
                                maximumCharacters: limits
                                    .maximumFuzzyTitleBodyPrefixCharacters,
                                bodySuffixWasOmitted: bodyScan.suffixWasOmitted
                            )
                        )
                    } else {
                        hit = nil
                    }
                }
            }
#if DEBUG
            if let hit {
                if case .titleRanges = hit.search {
                    debugTitleMatches += 1
                } else {
                    debugBodyMatches += 1
                }
            }
            recordProgressIfNeeded()
#endif
            guard let hit else { continue scan }
            work?.matchesFound += 1
            selection.insert(hit)
        }
        try Task.checkCancellation()
#if DEBUG
        searchDebugProbe.record(
            traceID: corpus.debugTrace.id,
            component: "worker",
            phase: "fuzzy-scan-complete",
            phaseElapsed: debugStart.duration(to: debugClock.now),
            totalElapsed: corpus.debugTrace.startedAt.duration(to: debugClock.now),
            rowsProcessed: debugProcessedRows,
            rowsTotal: corpus.rows.count,
            matchedRows: debugTitleMatches + debugBodyMatches,
            titleUTF8Bytes: debugTitleUTF8Bytes,
            bodyUTF8Bytes: debugBodyUTF8Bytes,
            titleMatches: debugTitleMatches,
            bodyMatches: debugBodyMatches
        )
#endif

        // Every row was scored, but only the bounded page candidates need
        // sorting or retained presentation (03b §8 / 04 §6).
        let evaluated = selection.evaluatedRows()
        try Task.checkCancellation()
#if DEBUG
        return EvaluationResult(
            rows: evaluated,
            debugRowsProcessed: debugProcessedRows,
            debugMatchedRows: debugTitleMatches + debugBodyMatches
        )
#else
        return EvaluationResult(rows: evaluated)
#endif
    }

    /// Runs the frozen-parameter Fuse matcher over one pre-lowercased
    /// working copy.
    ///
    /// The caller supplies the single lowercase copy (built once from the
    /// scanned title or the bounded body-prefix slice) and the original's
    /// exact Character count — derived from the same pass that produced
    /// the slice, so the alignment proof costs no extra walk. Swift's
    /// `lowercased()` performs Unicode default lowercasing, whose only
    /// multi-scalar expansion (U+0130 → U+0069 U+0307) stays within one
    /// extended grapheme cluster, so Character indices never shift; the
    /// count check below proves the working copy's Character indices
    /// align 1:1 with the original's, and a hypothetical future Unicode
    /// change that broke the alignment makes the field a miss rather than
    /// a guess (03b §8: lower-casing must not shift offsets).
    ///
    /// - Returns: the Fuse score (internal only) and half-open Character
    ///   ranges aligned with the original string; callers either translate
    ///   them to UTF-16 (title lane) or hand them to the deferred bounded
    ///   excerpt (body lane).
    internal func fuzzyMatch(
        pattern: Fuse.Pattern,
        lowercased: String,
        characterCount: Int
    ) -> (
        score: Double,
        characterRanges: [Range<Int>]
    )? {
        guard lowercased.count == characterCount else {
            return nil
        }
        guard let result = prelowercasedFuse.search(pattern, in: lowercased) else {
            return nil
        }
        var characterRanges: [Range<Int>] = []
        characterRanges.reserveCapacity(result.ranges.count)
        for range in result.ranges {
            // Defensive: Fuse's ranges index its working copy, which the
            // count check just aligned with the original scanned text.
            guard range.lowerBound >= 0,
                  range.upperBound < characterCount else {
                continue
            }
            characterRanges.append(range.lowerBound..<(range.upperBound + 1))
        }
        return (
            result.score,
            characterRanges
        )
    }

}
