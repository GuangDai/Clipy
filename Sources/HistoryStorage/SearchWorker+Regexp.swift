/// Regexp-mode evaluation and pattern-shape screening (03b §8).
/// Split out of SearchWorker.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

extension SearchWorker {
    // MARK: - Regexp mode (03b §8)

    /// `NSRegularExpression` search over the bounded prefixes (03b §8):
    /// admission rejects an invalid or known unsafe pattern BEFORE any
    /// scanning; evaluation scans at most the first 1,000 Characters of
    /// title and, only on title miss, the first 1,000 Characters of body;
    /// the first match wins; the default row order is preserved. The body
    /// excerpt windows only that bounded prefix, while its trailing ellipsis
    /// still records when the stored body continues beyond the scan bound.
    internal func evaluateRegexp(
        term: String,
        in corpus: SearchCorpusSnapshot,
        directive: ScanDirective
    ) async throws -> [EvaluatedRow] {
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
        var scanTracker = OrderPreservingScanTracker(directive: directive)
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
            phase: "regexp-scan-begin",
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
                phase: "regexp-scan-progress",
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
                .regexp,
                beforeRowAt: rowOffset
            )
#if DEBUG
            debugProcessedRows += 1
            debugTitleUTF8Bytes += row.debugTitleUTF8Bytes
#endif
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
                        search: .ready(SearchPresentation(
                            snippet: nil,
                            matchedRanges: [UTF16TextRange(
                                location: match.range.location,
                                length: match.range.length
                            )]
                        )),
                        anchor: Self.defaultOrderAnchor(for: row)
                    )
                )
#if DEBUG
                debugTitleMatches += 1
#endif
                if !scanTracker.recordMatch(
                    ofRow: Self.defaultOrderAnchor(for: row)
                ) {
                    break scan
                }
#if DEBUG
                recordProgressIfNeeded()
#endif
                continue scan
            }
            // Only on title miss: the first 1,000 Characters of body
            // (03b §8).
#if DEBUG
            debugBodyUTF8Bytes += row.debugSearchBodyUTF8Bytes
#endif
            let bodyScan = Self.boundedCharacterPrefix(
                of: row.searchBody,
                maximumCharacters: limits.maximumRegexpTitleBodyPrefixCharacters
            )
            let bodyPrefix = String(bodyScan.text)
            guard let match = regex.firstMatch(
                in: bodyPrefix,
                range: NSRange(
                    bodyPrefix.startIndex..<bodyPrefix.endIndex,
                    in: bodyPrefix
                )
            ) else {
#if DEBUG
                recordProgressIfNeeded()
#endif
                continue scan
            }
            // Convert the UTF-16 match to Character offsets for the
            // excerpt algorithm. The conversion cannot fail — the range
            // was produced against this very string — but a failed
            // conversion is treated as a miss rather than a crash.
            guard let found = Range(match.range, in: bodyPrefix) else {
#if DEBUG
                recordProgressIfNeeded()
#endif
                continue scan
            }
            let lower = bodyPrefix.distance(
                from: bodyPrefix.startIndex,
                to: found.lowerBound
            )
            let upper = bodyPrefix.distance(
                from: bodyPrefix.startIndex,
                to: found.upperBound
            )
            // The 03b §8 excerpt defers to page materialization with the
            // scan-bound and omitted-suffix facts recorded during the scan.
            evaluated.append(
                EvaluatedRow(
                    corpusRow: row,
                    search: .bodyExcerpt(
                        characterRanges: [lower..<upper],
                        maximumCharacters: limits
                            .maximumRegexpTitleBodyPrefixCharacters,
                        bodySuffixWasOmitted: bodyScan.suffixWasOmitted
                    ),
                    anchor: Self.defaultOrderAnchor(for: row)
                )
            )
#if DEBUG
            debugBodyMatches += 1
#endif
            if !scanTracker.recordMatch(
                ofRow: Self.defaultOrderAnchor(for: row)
            ) {
                break scan
            }
#if DEBUG
            recordProgressIfNeeded()
#endif
        }
        try Task.checkCancellation()
#if DEBUG
        searchDebugProbe.record(
            traceID: corpus.debugTrace.id,
            component: "worker",
            phase: "regexp-scan-complete",
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
    internal static func inlineFlagClauseEnablesComments(
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
    internal static func isQuantifierToken(
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
    internal static func intervalQuantifierEnd(
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

}
