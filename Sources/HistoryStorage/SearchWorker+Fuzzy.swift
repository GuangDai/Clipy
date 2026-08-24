/// Fuzzy-mode evaluation behind the actor-confined Fuse matcher (03b §8).
/// Split out of SearchWorker.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import Fuse

extension SearchWorker {
    // MARK: - Fuzzy mode (03b §8)

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
        in corpus: SearchCorpusSnapshot
    ) async throws -> [EvaluatedRow] {
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
#if DEBUG
            debugProcessedRows += 1
            debugTitleUTF8Bytes += row.debugTitleUTF8Bytes
#endif
            // Titles are bounded by `maximumStoredTitleUTF8Bytes` (1,024
            // UTF-8 bytes ⇒ at most 1,024 Characters), strictly below the
            // 5,000-Character scan prefix, so the whole title is always
            // the scanned prefix (03b §8; 06 §2) — no per-row prefix copy.
            let hit: FuzzyHit?
            let lowercasedTitle = row.title.lowercased()
            if let titleMatch = fuzzyMatch(
                pattern: pattern,
                lowercased: lowercasedTitle,
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
            if row.pinOrdinal == nil {
                unpinnedHits.append(hit)
            } else {
                pinnedHits.append(hit)
            }
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
        // bytes lexicographically. Every hit carries only deferred
        // presentation data (Character ranges, no excerpt text), so the
        // sort moves small values regardless of how many rows matched.
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
        try Task.checkCancellation()
        return pinned + unpinned
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
