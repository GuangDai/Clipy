/// Fuzzy-mode evaluation behind the actor-confined Fuse matcher (03b §8).
/// Split out of SearchWorker.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

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
    internal func fuzzyMatch(
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

}
