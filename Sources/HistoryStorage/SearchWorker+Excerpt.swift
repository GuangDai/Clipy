/// Body excerpt and UTF-16 translation helpers (03b §8; docs/04-coherence.md §7).
/// Split out of SearchWorker.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

extension SearchWorker {
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
    internal static func boundedCharacterPrefix(
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
    internal static func utf16PrefixOffsets(
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
