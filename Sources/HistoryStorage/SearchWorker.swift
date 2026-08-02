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
    /// (docs/06-cross-cutting.md §2): the 512-Character regexp-pattern
    /// bound, the 256-Character fuzzy-query bound, the 1,000/5,000-Character
    /// regexp/fuzzy scan prefixes, and the 322-Character snippet bound.
    private let limits: HistoryLimits

    /// The confined fuzzy matcher (docs/01-architecture.md §6). Frozen
    /// parameters (03b §8): `threshold` 0.7, `location` 0, `distance` 100,
    /// `isCaseSensitive` false; `tokenize` keeps its `false` default.
    /// `maxPatternLength` is deliberately not passed: it is a dead
    /// parameter in the pinned 1.4.0 revision (stored, never read — see
    /// `Fuse/Classes/Fuse.swift` at krisk/fuse-swift
    /// 26ba868691b2d8b7bf2b1322951eb591be70ccca; docs/AUDIT.md §4b), so the
    /// 256-Character query bound is enforced by `page` itself before Fuse
    /// is called.
    private let fuse: Fuse

    /// Creates the worker with the fixed safety profile and the frozen
    /// Fuse parameter set (03b §8).
    internal init() {
        self.limits = .standard
        self.fuse = Fuse(location: 0, distance: 100, threshold: 0.7, isCaseSensitive: false)
    }

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
    /// - Throws: `HistoryFailure.invalidInput(.invalidRegularExpression)`
    ///   for a rejected regexp pattern (before any scanning, 03b §8);
    ///   `.invalidInput(.invalidSearchTerm)` for a fuzzy query over the
    ///   256-Character bound (before Fuse is called, 03b §8);
    ///   `.snapshotExpired(current:)` when the continuation anchor names
    ///   no row in the computed order (04 §6).
    internal func page(
        _ request: HistoryBrowseRequest,
        in corpus: SearchCorpusSnapshot,
        continuationAnchor: StoredOrderingAnchor?,
        processMarker: UUID
    ) throws -> HistoryPage {
        guard case .search(let term, let mode) = request.kind else {
            // The facade routes `.recent` to the Authority's §14.1
            // interval; a `.recent` kind here is a wiring violation —
            // the §16 defensive internal-invariant mapping.
            throw HistoryFailure.persistence(.invariantViolation)
        }

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
            next = PageCursorCodec.encode(
                ResolvedPageCursor(
                    queryShape: .search(text: term, mode: mode, limit: request.limit),
                    position: corpus.position,
                    anchor: lastReturned.anchor
                ),
                processMarker: processMarker
            )
        } else {
            next = nil
        }

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
        var evaluated: [EvaluatedRow] = []
        for row in corpus.rows {
            if let found = row.title.range(
                of: term,
                options: [.caseInsensitive, .literal]
            ) {
                // Title match: `snippet == nil`, UTF-16 ranges relative to
                // `HistoryRow.title` (03b §8).
                let nsRange = NSRange(found, in: row.title)
                evaluated.append(
                    EvaluatedRow(
                        corpusRow: row,
                        search: SearchPresentation(
                            snippet: nil,
                            matchedRanges: [UTF16TextRange(
                                location: nsRange.location,
                                length: nsRange.length
                            )]
                        ),
                        anchor: Self.defaultOrderAnchor(for: row)
                    )
                )
                continue
            }
            // Only on title miss: the full bounded searchBody (03b §8).
            // Exact mode has no scan prefix; the excerpt therefore windows
            // the complete bounded projection text.
            guard let found = row.searchBody.range(
                of: term,
                options: [.caseInsensitive, .literal]
            ) else {
                continue
            }
            let lower = row.searchBody.distance(
                from: row.searchBody.startIndex,
                to: found.lowerBound
            )
            let upper = row.searchBody.distance(
                from: row.searchBody.startIndex,
                to: found.upperBound
            )
            let excerpt = Self.bodyExcerpt(
                body: row.searchBody,
                characterRanges: [lower..<upper],
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
        }
        return evaluated
    }

    // MARK: - Regexp mode (03b §8)

    /// `NSRegularExpression` search over the bounded prefixes (03b §8):
    /// admission rejects an invalid or known unsafe pattern BEFORE any
    /// scanning; evaluation scans at most the first 1,000 Characters of
    /// title and, only on title miss, the first 1,000 Characters of body;
    /// the first match wins; the default row order is preserved. Because
    /// the scanned text is the prefix, the body excerpt windows the prefix
    /// — the only text this mode admits.
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
            let bodyPrefix = String(
                row.searchBody.prefix(limits.maximumRegexpTitleBodyPrefixCharacters)
            )
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
        }
        return evaluated
    }

    /// Conservative textual guards for the rejected unsafe-regexp shapes
    /// (03b §8), all decided before compilation:
    ///
    /// - any backreference — `\1`…`\9` or named `\k<…>` — outside a
    ///   character class (`\0` is an octal escape, not a backreference);
    /// - a quantified group whose body contains a quantifier anywhere
    ///   inside it (e.g. `(a+)+`), which also covers a quantified
    ///   alternation group whose branches contain quantifiers (e.g.
    ///   `(a+|b)+`) and nested forms like `((a+))+` (the body-flag
    ///   propagates from child to parent on group close).
    ///
    /// Plain non-capturing groups `(?:…)`, anchors, and character-class
    /// constructs stay admissible unless they participate in a rejected
    /// nested-quantifier form. Quantifier tokens are `*`, `+`, `?` (a `?`
    /// directly opening a `(?…` group form is syntax, not a quantifier)
    /// and `{n}`/`{n,}`/`{n,m}` intervals; an unescaped `{` that does not
    /// form an interval is a literal. ICU `(?#…)` comments are skipped to
    /// their closing `)` so comment text cannot desynchronize the group
    /// scan. These guards intentionally reject some valid but risky
    /// patterns (03b §8); anything the scanner misreads structurally is
    /// still caught by the compilation check that follows.
    private static func containsRejectedPatternShape(_ pattern: String) -> Bool {
        let characters = Array(pattern)
        var index = 0
        var inCharacterClass = false
        var openGroupBodyContainsQuantifier: [Bool] = []

        func markInnermostGroup() {
            guard !openGroupBodyContainsQuantifier.isEmpty else { return }
            openGroupBodyContainsQuantifier[
                openGroupBodyContainsQuantifier.count - 1
            ] = true
        }

        while index < characters.count {
            let character = characters[index]
            if inCharacterClass {
                if character == "\\" {
                    index += 2
                    continue
                }
                if character == "]" {
                    inCharacterClass = false
                }
                index += 1
                continue
            }
            switch character {
            case "\\":
                let next = index + 1
                if next < characters.count {
                    let escaped = characters[next]
                    if ("1"..."9").contains(escaped) || escaped == "k" {
                        return true
                    }
                }
                index += 2
            case "[":
                inCharacterClass = true
                index += 1
            case "(":
                if index + 2 < characters.count,
                   characters[index + 1] == "?",
                   characters[index + 2] == "#" {
                    var cursor = index + 3
                    while cursor < characters.count, characters[cursor] != ")" {
                        cursor += 1
                    }
                    index = cursor + 1
                } else {
                    openGroupBodyContainsQuantifier.append(false)
                    index += (
                        index + 1 < characters.count
                            && characters[index + 1] == "?"
                    ) ? 2 : 1
                }
            case ")":
                let bodyContainsQuantifier =
                    openGroupBodyContainsQuantifier.popLast() ?? false
                let isQuantified = isQuantifierToken(at: index + 1, in: characters)
                if isQuantified && bodyContainsQuantifier {
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

    /// Fuse search over the bounded prefixes (03b §8): the 256-Character
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
        // "return nil" never fires); the worker enforces the Part VI
        // 256-Character fuzzy-query bound itself, before Fuse is called
        // (03b §8; docs/AUDIT.md §4b).
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
                        matchedRanges: titleMatch.utf16Ranges
                    )
                )
            } else {
                // Only on title miss: the first 5,000 Characters of body
                // (03b §8). The excerpt windows that scanned prefix — the
                // only text this mode admits.
                let bodyPrefix = String(
                    row.searchBody.prefix(
                        limits.maximumFuzzyTitleBodyPrefixCharacters
                    )
                )
                if let bodyMatch = fuzzyMatch(pattern: pattern, in: bodyPrefix) {
                    let excerpt = Self.bodyExcerpt(
                        body: bodyPrefix,
                        characterRanges: bodyMatch.characterRanges,
                        snippetLimit: limits.maximumBodySearchSnippetCharacters
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
    /// Fuse 1.4.0's `_search` lowercases its working copy internally when
    /// `isCaseSensitive == false` (`text = text.lowercased()`,
    /// `Fuse/Classes/Fuse.swift` at the pinned revision) and reports match
    /// ranges as `CountableClosedRange<Int>` Character offsets into that
    /// lowercased copy. Swift's `lowercased()` performs Unicode default
    /// lowercasing, whose only multi-scalar expansion (U+0130 →
    /// U+0069 U+0307) stays within one extended grapheme cluster, so
    /// Character indices never shift; the count check below proves the
    /// working copy's Character indices align 1:1 with the original's, and
    /// a hypothetical future Unicode change that broke the alignment makes
    /// the field a miss rather than a guess (03b §8: lower-casing must
    /// not shift offsets). Passing the ORIGINAL string (not a
    /// pre-lowercased one) is what guarantees this worker's working copy
    /// is byte-identical to Fuse's internal one.
    ///
    /// - Returns: the Fuse score (internal only), the ranges translated
    ///   to UTF-16 offsets into the ORIGINAL `scanned` string, and the
    ///   same ranges as half-open Character offsets for the excerpt
    ///   algorithm; `nil` when Fuse reports no match.
    private func fuzzyMatch(
        pattern: Fuse.Pattern,
        in scanned: String
    ) -> (
        score: Double,
        utf16Ranges: [UTF16TextRange],
        characterRanges: [Range<Int>]
    )? {
        guard scanned.lowercased().count == scanned.count else {
            return nil
        }
        guard let result = fuse.search(pattern, in: scanned) else {
            return nil
        }
        var characterRanges: [Range<Int>] = []
        characterRanges.reserveCapacity(result.ranges.count)
        for range in result.ranges {
            // Defensive: Fuse's ranges index its working copy, which the
            // count check just aligned with `scanned`.
            guard range.lowerBound >= 0, range.upperBound < scanned.count else {
                continue
            }
            characterRanges.append(range.lowerBound..<(range.upperBound + 1))
        }
        return (
            result.score,
            Self.utf16Ranges(from: characterRanges, in: scanned),
            characterRanges
        )
    }

    // MARK: - Body excerpt (03b §8)

    /// The frozen body-match excerpt construction (03b §8, verbatim):
    ///
    /// 1. sort match ranges;
    /// 2. a body shorter than 320 Characters keeps the whole body and adds
    ///    no ellipses;
    /// 3. otherwise center a window of at most 320 Characters on the
    ///    earliest match — a longer match keeps its first 320 Characters —
    ///    distributing the remaining context equally before/after with the
    ///    extra Character AFTER, and redistributing context that would
    ///    extend past a body edge to the other side;
    /// 4. add `…` at each edge where text was omitted — a leading ellipsis
    ///    only when the window starts after the body start, a trailing one
    ///    only when it ends before the body end;
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
    private static func bodyExcerpt(
        body: String,
        characterRanges: [Range<Int>],
        snippetLimit: Int
    ) -> (snippet: String, ranges: [UTF16TextRange]) {
        let characters = Array(body)
        let count = characters.count
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
        let hasTrailingEllipsis = windowUpper < count
        var snippet = hasLeadingEllipsis ? "…" : ""
        snippet.append(contentsOf: characters[windowLower..<windowUpper])
        if hasTrailingEllipsis {
            snippet.append("…")
        }

        // Clip to the window, then convert to UTF-16 offsets into the
        // final snippet, shifting right by the leading ellipsis only when
        // present (03b §8 steps 5–6).
        let windowOffsets = utf16PrefixOffsets(
            of: String(characters[windowLower..<windowUpper])
        )
        var ranges: [UTF16TextRange] = []
        ranges.reserveCapacity(sortedRanges.count)
        for range in sortedRanges {
            let clippedLower = max(range.lowerBound, windowLower)
            let clippedUpper = min(range.upperBound, windowUpper)
            guard clippedLower < clippedUpper else { continue }
            let inWindowLower = clippedLower - windowLower
            let inWindowUpper = clippedUpper - windowLower
            ranges.append(
                UTF16TextRange(
                    location: windowOffsets[inWindowLower]
                        + (hasLeadingEllipsis ? 1 : 0),
                    length: windowOffsets[inWindowUpper]
                        - windowOffsets[inWindowLower]
                )
            )
        }
        return (snippet, ranges)
    }

    // MARK: - UTF-16 translation (03b §8; docs/04-coherence.md §7)

    /// Converts half-open Character-offset ranges into UTF-16 offsets into
    /// `text`. A `String`'s UTF-16 view is the concatenation of its
    /// Characters' UTF-16 views, so per-Character prefix sums give exact
    /// code-unit offsets for any Character boundary.
    private static func utf16Ranges(
        from characterRanges: [Range<Int>],
        in text: String
    ) -> [UTF16TextRange] {
        let offsets = utf16PrefixOffsets(of: text)
        return characterRanges.map { range in
            UTF16TextRange(
                location: offsets[range.lowerBound],
                length: offsets[range.upperBound] - offsets[range.lowerBound]
            )
        }
    }

    /// `offsets[i]` is the number of UTF-16 code units preceding Character
    /// `i` in `text`; `offsets[text.count]` is the whole string's UTF-16
    /// length.
    private static func utf16PrefixOffsets(of text: String) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(text.count + 1)
        offsets.append(0)
        var total = 0
        for character in text {
            total += String(character).utf16.count
            offsets.append(total)
        }
        return offsets
    }
}
