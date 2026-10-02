/// MatchHighlighting.swift — search-match highlighting for row titles and
/// snippets (docs/architecture.md; roadmap 05).
///
/// Matched ranges are UTF-16 offsets relative to the string they annotate:
/// the row title when `search.snippet == nil`, else the snippet excerpt. The
/// conversion is defensive — a range that does not fall entirely inside the
/// string, or whose bounds split a surrogate pair, is dropped, never clamped
/// into wrong pixels.
import Foundation
import HistoryCore
import SwiftUI

/// Builds a highlighted `AttributedString`, preserving exact scalar boundaries
/// within graphemes (docs/search.md).
enum MatchHighlighting {

    /// - Parameters:
    ///   - text: The base string (title or snippet excerpt).
    ///   - ranges: UTF-16 ranges into `text`; out-of-bounds, zero-length,
    ///     surrogate-splitting, and overlapping (after sorting) ranges are
    ///     ignored.
    static func highlighted(
        _ text: String,
        ranges: [UTF16TextRange],
        foreground: Color = .accentColor
    ) -> AttributedString {
        let bounds: [(start: Int, end: Int)] = ranges.compactMap { range in
            guard range.location >= 0, range.length > 0 else { return nil }
            let (end, overflow) = range.location.addingReportingOverflow(range.length)
            guard !overflow else { return nil }
            return (range.location, end)
        }
        let endpoints = Set(bounds.flatMap { [$0.start, $0.end] })
        guard let finalOffset = endpoints.max() else { return AttributedString(text) }

        // Resolve all requested UTF-16 boundaries in one scalar walk. Seeking
        // separately from the string's start for every range repeats O(n)
        // work; this costs O(n + r log r) and retains only O(r) requested
        // indices. Surrogate interiors and out-of-string offsets never enter
        // the map, so those ranges are dropped without clamping.
        let scalars = text.unicodeScalars
        var scalarIndex = scalars.startIndex
        var offset = 0
        var indices: [Int: String.Index] = [:]
        indices.reserveCapacity(endpoints.count)
        if endpoints.contains(0) { indices[0] = scalarIndex }
        while scalarIndex < scalars.endIndex, offset < finalOffset {
            offset += scalars[scalarIndex].value > 0xFFFF ? 2 : 1
            scalarIndex = scalars.index(after: scalarIndex)
            if endpoints.contains(offset) { indices[offset] = scalarIndex }
        }
        let matched = bounds
            .compactMap { bound -> Range<String.Index>? in
                guard let start = indices[bound.start], let end = indices[bound.end] else { return nil }
                return start..<end
            }
            .sorted { $0.lowerBound < $1.lowerBound }

        guard !matched.isEmpty else { return AttributedString(text) }

        var result = AttributedString()
        var cursor = text.startIndex
        for range in matched {
            // Skip overlaps (the range starts inside an already-emitted
            // segment) and zero-length matches — neither has pixels to mark.
            guard range.lowerBound >= cursor,
                  range.lowerBound < range.upperBound
            else { continue }
            if cursor < range.lowerBound {
                result.append(AttributedString(String(text[cursor..<range.lowerBound])))
            }
            var segment = AttributedString(String(text[range]))
            segment.inlinePresentationIntent = .stronglyEmphasized
            segment.foregroundColor = foreground
            result.append(segment)
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result.append(AttributedString(String(text[cursor..<text.endIndex])))
        }
        return result
    }

}
