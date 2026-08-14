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
        let windowCapacity = snippetLimit - 2
        let sortedRanges = characterRanges.sorted {
            $0.lowerBound < $1.lowerBound
        }

        // The window only ever consumes indices at or below the earliest
        // match plus one window capacity, and the whole-body branch needs
        // the exact count only when the body ends inside the window. The
        // original formulation walked the complete body once for `count`
        // and then up to twice more for the window indices — O(body) per
        // excerpt on a 256-KiB exact-mode projection. The fused walk below
        // touches at most `windowCapacity + 1` Characters to decide the
        // whole-body branch, then at most the pre-clamp window upper bound,
        // with a bounded backward step for the rare end-clamp
        // redistribution. Semantics are bit-identical to the frozen 03b §8
        // construction.
        let windowLower: Int
        let windowUpper: Int   // exclusive
        let windowLowerIndex: String.Index
        let windowUpperIndex: String.Index
        let windowReachedBodyEnd: Bool

        // Phase A — whole-body probe: walking at most windowCapacity + 1
        // Characters either proves the body fits the window (exact count
        // known, indices are the string's own ends) or proves it does not.
        var probeIndex = body.startIndex
        var probeCount = 0
        while probeCount <= windowCapacity, probeIndex != body.endIndex {
            probeIndex = body.index(after: probeIndex)
            probeCount += 1
        }
        if probeIndex == body.endIndex, probeCount <= windowCapacity {
            // Step 2. `count == windowCapacity` fits exactly and equally
            // omits nothing, so it shares the whole-body outcome.
            windowLower = 0
            windowUpper = probeCount
            windowLowerIndex = body.startIndex
            windowUpperIndex = probeIndex
            windowReachedBodyEnd = true
        } else {
            // The body is strictly longer than the window: steps 3–4.
            let earliest = sortedRanges.first
            let preClampLower: Int
            let preClampUpper: Int
            if let earliest {
                let matchLength = earliest.upperBound - earliest.lowerBound
                if matchLength >= windowCapacity {
                    // A longer match keeps its first 320 Characters.
                    preClampLower = earliest.lowerBound
                    preClampUpper = earliest.lowerBound + windowCapacity
                } else {
                    // Center the window; extra context Character AFTER;
                    // edge overflow redistributes to the other side.
                    let context = windowCapacity - matchLength
                    let before = context / 2
                    let after = context - before
                    var lower = earliest.lowerBound - before
                    var upper = earliest.upperBound + after
                    if lower < 0 {
                        upper -= lower
                        lower = 0
                    }
                    preClampLower = lower
                    preClampUpper = upper
                }
            } else {
                // Defensive: a body match always carries at least one range.
                preClampLower = 0
                preClampUpper = windowCapacity
            }

            // Phase B — one forward walk to the pre-clamp upper bound,
            // recording the lower-bound index on the way past it. The end
            // index, when reached first, carries the exact remaining count.
            var index = body.startIndex
            var counter = 0
            var lowerIndex = body.startIndex
            if preClampLower > 0 {
                walk: while true {
                    if index == body.endIndex { break walk }
                    if counter == preClampUpper { break walk }
                    index = body.index(after: index)
                    counter += 1
                    if counter == preClampLower {
                        lowerIndex = index
                    }
                }
            } else {
                walk: while index != body.endIndex, counter < preClampUpper {
                    index = body.index(after: index)
                    counter += 1
                }
            }
            if index == body.endIndex {
                // The body ended at or before the pre-clamp window: clamp
                // the upper bound to the count and redistribute the
                // overshoot before the match, stepping backward at most
                // `after` (≤ windowCapacity) Characters from the recorded
                // lower index.
                let count = counter
                windowUpper = count
                windowUpperIndex = index
                windowReachedBodyEnd = true
                let overshoot = preClampUpper - count
                let clampedLower = overshoot > 0
                    ? max(0, preClampLower - overshoot)
                    : preClampLower
                if clampedLower == preClampLower {
                    windowLower = clampedLower
                    windowLowerIndex = lowerIndex
                } else if clampedLower <= 0 {
                    windowLower = 0
                    windowLowerIndex = body.startIndex
                } else {
                    var backIndex = lowerIndex
                    var backCount = preClampLower
                    while backCount > clampedLower {
                        backIndex = body.index(before: backIndex)
                        backCount -= 1
                    }
                    windowLower = clampedLower
                    windowLowerIndex = backIndex
                }
            } else {
                // counter == preClampUpper and the body continues: the
                // count-dependent clamps cannot fire (preClampUpper ≤
                // count), so the pre-clamp window is the final window and
                // the trailing-ellipsis decision is already determined.
                windowLower = preClampLower
                windowUpper = preClampUpper
                windowLowerIndex = preClampLower > 0 ? lowerIndex : body.startIndex
                windowUpperIndex = index
                windowReachedBodyEnd = false
            }
        }

        let hasLeadingEllipsis = windowLower > 0
        let hasTrailingEllipsis = !windowReachedBodyEnd || bodySuffixWasOmitted
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
    /// original string continues. Returns a slicing `Substring` (no copy)
    /// plus the prefix's exact Character count, so callers that need a
    /// `String` (Fuse, `NSRegularExpression`) pay exactly one bounded copy
    /// while the count is available without a second walk. Computing the
    /// end index is bounded by the same scan limit, avoiding an
    /// O(full-body) `count` just to decide the excerpt's trailing ellipsis.
    internal static func boundedCharacterPrefix(
        of text: String,
        maximumCharacters: Int
    ) -> (text: Substring, characterCount: Int, suffixWasOmitted: Bool) {
        var index = text.startIndex
        var count = 0
        while count < maximumCharacters, index != text.endIndex {
            index = text.index(after: index)
            count += 1
        }
        return (text[..<index], count, index != text.endIndex)
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
