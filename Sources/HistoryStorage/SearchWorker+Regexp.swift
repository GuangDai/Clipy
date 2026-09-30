/// Regexp-mode evaluation and pattern-shape screening (03b §8).
/// Split out of SearchWorker.swift (file-size hygiene); same target, unchanged semantics.
///
/// REVIEW Card 11C adjudication (03b §8): the frozen rejection grammar is
/// unchanged — a top-level ambiguous-quantifier chain stays admissible — and
/// the scan operation is instead Apple's documented interruptible iterator
/// (`enumerateMatches` with `.reportProgress`/`.reportCompletion`) under a
/// fixed per-request engine deadline, so an admitted slow pattern can no
/// longer run uninterruptibly on this actor.
import Foundation
import HistoryCore
import HistoryDomain

extension SearchWorker {
    // MARK: - Regexp mode (03b §8)

    /// `NSRegularExpression` search over the bounded prefixes (03b §8):
    /// admission rejects an invalid or known unsafe pattern BEFORE any
    /// scanning; evaluation scans at most the first 1,000 Characters of
    /// title and, only on title miss, the first 1,000 Characters of body;
    /// the first match wins; the default row order is preserved. The body
    /// excerpt windows only that bounded prefix, while its trailing ellipsis
    /// still records when the stored body continues beyond the scan bound.
    ///
    /// - Throws: `.invalidInput(.invalidRegularExpression)` at admission
    ///   (03b §8); `.temporarilyUnavailable(.searchEngineDeadline)` when the
    ///   request's fixed engine deadline elapses or the engine abandons the
    ///   match internally mid-scan (03b §8 Card 11C — the whole request
    ///   fails, no partial results); `CancellationError` when cooperative
    ///   cancellation is observed inside the engine's progress callback.
    internal func evaluateRegexp(
        term: String,
        in corpus: SearchCorpusSnapshot,
        directive: ScanDirective,
        preparedPattern: NSRegularExpression? = nil,
        sharedEngineDeadline: ContinuousClock.Instant? = nil,
        work: SearchWorkCounter? = nil
    ) async throws -> EvaluationResult {
        // Admission (03b §8), every rejection is
        // `.invalidInput(.invalidRegularExpression)`: a pattern over the
        // Part VI 512-Character limit; a conservative textual guard for
        // the catastrophic-backtracking shapes; an `NSRegularExpression`
        // compilation failure.
        let regex: NSRegularExpression
        if let preparedPattern {
            regex = preparedPattern
        } else {
            guard term.count <= limits.maximumRegexpPatternCharacters,
                  !Self.containsRejectedPatternShape(term) else {
                throw HistoryFailure.invalidInput(.invalidRegularExpression)
            }
            do {
                regex = try NSRegularExpression(pattern: term)
            } catch {
                throw HistoryFailure.invalidInput(.invalidRegularExpression)
            }
        }

        // One engine deadline per evaluateRegexp request (03b §8 Card 11C):
        // both bounded-prefix scans below observe the same monotonic instant.
        let engineDeadline = sharedEngineDeadline ?? ContinuousClock().now.advanced(
            by: regexpEngineDeadline
        )
        // A pattern with no regexp syntax has exactly the literal UTF-16
        // matching semantics of NSString's .literal search. Avoid entering
        // ICU's progress iterator twice per row for this common case; complex
        // expressions keep the existing interruptible engine and deadline.
        let literalPattern = regex.options.isEmpty
            && NSRegularExpression.escapedPattern(for: regex.pattern) == regex.pattern
            ? regex.pattern : nil

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
            work?.rowsEvaluated += 1
#if DEBUG
            debugProcessedRows += 1
            debugTitleUTF8Bytes += row.debugTitleUTF8Bytes
#endif
            let titlePrefix = String(
                row.title.prefix(limits.maximumRegexpTitleBodyPrefixCharacters)
            )
            if let match = try Self.firstInterruptibleMatch(
                of: regex,
                in: titlePrefix,
                literalPattern: literalPattern,
                deadline: engineDeadline
            ) {
                work?.matchesFound += 1
                // Title match: `NSRegularExpression` already reports
                // UTF-16 offsets, and the prefix's offsets index the title
                // identically (03b §8: ranges relative to
                // `HistoryRow.title`, `snippet == nil`).
                scanTracker.appendIfRetained(
                    EvaluatedRow(
                        corpusRow: row,
                        search: .ready(SearchPresentation(
                            snippet: nil,
                            matchedRanges: [UTF16TextRange(
                                location: match.location,
                                length: match.length
                            )]
                        )),
                        anchor: Self.defaultOrderAnchor(for: row)
                    ),
                    to: &evaluated
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
            guard let match = try Self.firstInterruptibleMatch(
                of: regex,
                in: bodyPrefix,
                literalPattern: literalPattern,
                deadline: engineDeadline
            ) else {
#if DEBUG
                recordProgressIfNeeded()
#endif
                continue scan
            }
            work?.matchesFound += 1
            // The 03b §8 excerpt defers to page materialization with the
            // original UTF-16 match intact. A regexp may match only part of
            // a Character; converting through Character offsets here loses
            // that range. Window coordinates are needed only for returned rows.
            scanTracker.appendIfRetained(
                EvaluatedRow(
                    corpusRow: row,
                    search: .bodyExcerpt(
                        characterRanges: [],
                        maximumCharacters: limits
                            .maximumRegexpTitleBodyPrefixCharacters,
                        bodySuffixWasOmitted: bodyScan.suffixWasOmitted,
                        utf16Range: UTF16TextRange(
                            location: match.location,
                            length: match.length
                        )
                    ),
                    anchor: Self.defaultOrderAnchor(for: row)
                ),
                to: &evaluated
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
        return EvaluationResult(
            rows: evaluated,
            debugRowsProcessed: debugProcessedRows,
            debugMatchedRows: debugTitleMatches + debugBodyMatches
        )
#else
        return EvaluationResult(rows: evaluated)
#endif
    }

    /// Why an interruptible scan ended without a first match (03b §8
    /// Card 11C): the request's engine deadline elapsed, cooperative
    /// cancellation was observed inside the engine's periodic progress
    /// callback, or the engine abandoned the match internally.
    private enum RegexpEngineStop {
        case deadline
        case cancellation
        case internalError
    }

    /// The first-match scan operation behind both bounded prefixes
    /// (03b §8 Card 11C adjudication): Apple's documented interruptible
    /// iterator instead of the never-interruptible `firstMatch` (progress
    /// and completion flags have no effect for that method). The first
    /// reported result wins and stops the enumeration, so the returned
    /// result and its UTF-16 offsets are exactly `firstMatch`'s over the
    /// same full-string range. Entry/exit checks also enforce the request
    /// deadline and cancellation for fast calls without progress reports.
    /// Only the engine's periodic `.progress` callback can interrupt a
    /// running native match; `stop` is out-only and is set only inside the
    /// block. A `.reportCompletion`
    /// `.internalError` abandonment (e.g. an expression requiring
    /// exponential memory) is an explicit failure, never a silent
    /// no-match. After the call returns, a deadline or internal-error stop
    /// throws the typed `.temporarilyUnavailable(.searchEngineDeadline)`
    /// — the caller discards every partially collected row — and a
    /// cancellation stop surfaces as `CancellationError`.
    private static func firstInterruptibleMatch(
        of regex: NSRegularExpression,
        in text: String,
        literalPattern: String?,
        deadline: ContinuousClock.Instant
    ) throws -> NSRange? {
        try Task.checkCancellation()
        let clock = ContinuousClock()
        guard clock.now < deadline else {
            throw HistoryFailure.temporarilyUnavailable(.searchEngineDeadline)
        }
        if let literalPattern {
            let range = (text as NSString).range(of: literalPattern, options: .literal)
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw HistoryFailure.temporarilyUnavailable(.searchEngineDeadline)
            }
            return range.location == NSNotFound ? nil : range
        }
        var match: NSRange?
        var stopReason: RegexpEngineStop?
        regex.enumerateMatches(
            in: text,
            options: [.reportProgress, .reportCompletion],
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) { result, flags, stop in
            if let result {
                match = result.range
                stop.pointee = true
                return
            }
            // Engine-internal abandonment is checked BEFORE the progress
            // branch and only while no first match exists: a hypothetical
            // callback carrying both flags must still surface the
            // abandonment, and an internalError reported after a found
            // first match must not rewrite it (Apple documents
            // internalError on completion callbacks only; both orderings
            // are defensive).
            if flags.contains(.internalError), match == nil {
                stopReason = .internalError
                stop.pointee = true
                return
            }
            if flags.contains(.progress) {
                if clock.now >= deadline {
                    stopReason = .deadline
                    stop.pointee = true
                } else if Task.isCancelled {
                    stopReason = .cancellation
                    stop.pointee = true
                }
                return
            }
        }
        if let stopReason {
            switch stopReason {
            case .deadline, .internalError:
                throw HistoryFailure.temporarilyUnavailable(.searchEngineDeadline)
            case .cancellation:
                throw CancellationError()
            }
        }
        // Fast native matches/misses need not emit a progress callback. The
        // same request budget still applies before accepting their result;
        // periodic callbacks remain responsible for interrupting slow scans.
        try Task.checkCancellation()
        guard clock.now < deadline else {
            throw HistoryFailure.temporarilyUnavailable(.searchEngineDeadline)
        }
        return match
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
    /// patterns (03b §8); malformed syntax is rejected by compilation.
    internal static func containsRejectedPatternShape(_ pattern: String) -> Bool {
        // ICU interprets syntax as Unicode scalars, not grapheme clusters.
        // A combining mark after `(`, `+`, `|`, or `}` must not hide that
        // token from the existing 03b §8 nested-quantifier/alternation check.
        // The separate query-size limits still count Characters.
        let characters = removingEmptyQuotedLiterals(Array(pattern.unicodeScalars))
        var index = 0
        // ICU permits a literal ']' immediately after '[' or '[^'. Keep
        // that prefix separately so a class's literal '+' remains inert.
        var characterClassPrefixes: [CharacterClassPrefix] = []
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
                    if !characterClassPrefixes.isEmpty {
                        characterClassPrefixes[characterClassPrefixes.count - 1] = .body
                    }
                    index += 1
                }
                continue
            }
            if !characterClassPrefixes.isEmpty {
                if character == "\\" {
                    if index + 1 < characters.count,
                       characters[index + 1] == "Q" {
                        // ICU supports `\Q…\E` inside sets as well as outside
                        // them. Preserve the enclosing set depth while quoted
                        // brackets pass through as literals; otherwise a
                        // quoted `[` can hide a real `(class+)+` shape.
                        inQuotedLiteral = true
                        index += 2
                    } else {
                        characterClassPrefixes[characterClassPrefixes.count - 1] = .body
                        index = escapedTokenEnd(at: index, in: characters)
                    }
                    continue
                }
                // ICU UnicodeSet syntax admits nested sets and POSIX classes
                // (`[[a-z][A-Z]]`, `[[:alpha:]]`). Track every unescaped
                // bracket so an inner `]` cannot expose a class-literal `+`
                // as a group quantifier (V1-Verified/03c). A literal bracket
                // in a UnicodeSet is escaped, handled by the branch above.
                if character == "[" {
                    characterClassPrefixes[characterClassPrefixes.count - 1] = .body
                    characterClassPrefixes.append(.first)
                } else if character == "]" {
                    if characterClassPrefixes.last == .body { characterClassPrefixes.removeLast() }
                    else { characterClassPrefixes[characterClassPrefixes.count - 1] = .body }
                } else if character == "^", characterClassPrefixes.last == .first {
                    characterClassPrefixes[characterClassPrefixes.count - 1] = .negatedFirst
                } else {
                    characterClassPrefixes[characterClassPrefixes.count - 1] = .body
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
                        index += 2
                    } else if ("1"..."9").contains(escaped) || escaped == "k" {
                        return true
                    } else {
                        index = escapedTokenEnd(at: index, in: characters)
                    }
                } else {
                    index += 1
                }
            case "[":
                characterClassPrefixes.append(.first)
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
                    index = parenthesizedCommentEnd(at: index, in: characters) ?? characters.count
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
        in characters: [Unicode.Scalar]
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
            // ICU also accepts Unix-lines d and the compatibility no-op u.
            // Stopping before either flag would miss a subsequent enabled x.
            guard "idmsuwx".unicodeScalars.contains(flag) else { return false }
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
        in characters: [Unicode.Scalar]
    ) -> Bool {
        var cursor = index
        // ICU's expr-quant state resumes after a (?#...) comment: the
        // comment does not introduce a term between the group and quantifier.
        while let end = parenthesizedCommentEnd(at: cursor, in: characters) { cursor = end }
        guard cursor < characters.count else { return false }
        switch characters[cursor] {
        case "*", "+", "?":
            return true
        case "{":
            return intervalQuantifierEnd(at: cursor, in: characters) != nil
        default:
            return false
        }
    }

    private enum CharacterClassPrefix: Equatable { case first, negatedFirst, body }

    /// ICU nextChar consumes a complete escaped token before exposing syntax:
    /// apple-oss-distributions/ICU icu4c/source/i18n/regexcmp.cpp, nextChar.
    /// In particular \cX owns X even when X is ')'/'[', and \x{61}'s braces
    /// belong to one literal, never an interval quantifier.
    private static func escapedTokenEnd(at start: Int, in characters: [Unicode.Scalar]) -> Int {
        guard start + 1 < characters.count else { return characters.count }
        let escaped = characters[start + 1]
        if escaped == "c" { return min(start + 3, characters.count) }
        if escaped == "u" { return min(start + 6, characters.count) }
        if escaped == "U" { return min(start + 10, characters.count) }
        if "xNpP".unicodeScalars.contains(escaped), start + 2 < characters.count,
           characters[start + 2] == "{" {
            var cursor = start + 3
            while cursor < characters.count, characters[cursor] != "}" { cursor += 1 }
            return min(cursor + 1, characters.count)
        }
        if escaped == "x" { return min(start + 4, characters.count) }
        return start + 2
    }

    /// Empty \Q\E emits no ICU token, including inside inline flag clauses.
    /// Remove only those regions; nonempty quoted content and escape-owned
    /// operands remain unchanged. The array is bounded by regexp admission.
    private static func removingEmptyQuotedLiterals(_ characters: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(characters.count)
        var cursor = 0
        var quoted = false
        while cursor < characters.count {
            if quoted {
                if characters[cursor] == "\\", cursor + 1 < characters.count,
                   characters[cursor + 1] == "E" {
                    result.append(contentsOf: characters[cursor..<(cursor + 2)])
                    quoted = false
                    cursor += 2
                } else {
                    result.append(characters[cursor])
                    cursor += 1
                }
            } else if characters[cursor] == "\\", cursor + 1 < characters.count {
                if characters[cursor + 1] == "Q" {
                    if cursor + 3 < characters.count, characters[cursor + 2] == "\\",
                       characters[cursor + 3] == "E" {
                        cursor += 4
                    } else {
                        result.append(contentsOf: characters[cursor..<(cursor + 2)])
                        quoted = true
                        cursor += 2
                    }
                } else {
                    let end = escapedTokenEnd(at: cursor, in: characters)
                    result.append(contentsOf: characters[cursor..<end])
                    cursor = end
                }
            } else {
                result.append(characters[cursor])
                cursor += 1
            }
        }
        return result
    }

    /// Native inline comments share nextChar's \Q quoting and \cX escape
    /// handling. An ordinary \) still ends the comment in ICU; a quoted or
    /// control-escape-owned ')' does not.
    private static func parenthesizedCommentEnd(at start: Int, in characters: [Unicode.Scalar]) -> Int? {
        guard start + 2 < characters.count, characters[start] == "(",
              characters[start + 1] == "?", characters[start + 2] == "#" else { return nil }
        var cursor = start + 3
        var quoted = false
        while cursor < characters.count {
            if quoted {
                if characters[cursor] == "\\", cursor + 1 < characters.count,
                   characters[cursor + 1] == "E" {
                    quoted = false
                    cursor += 2
                } else { cursor += 1 }
            } else if characters[cursor] == ")" {
                return cursor + 1
            } else if characters[cursor] == "\\", cursor + 1 < characters.count {
                if characters[cursor + 1] == "Q" {
                    quoted = true
                    cursor += 2
                } else if characters[cursor + 1] == ")" {
                    return cursor + 2
                } else {
                    cursor = escapedTokenEnd(at: cursor, in: characters)
                }
            } else { cursor += 1 }
        }
        return nil
    }

    /// Parses a `{n}` / `{n,}` / `{n,m}` interval quantifier starting at
    /// the `{` at `start`; returns the index just past the closing `}`, or
    /// `nil` when the `{` is a literal (digits are ASCII-only, as ICU
    /// requires).
    internal static func intervalQuantifierEnd(
        at start: Int,
        in characters: [Unicode.Scalar]
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
