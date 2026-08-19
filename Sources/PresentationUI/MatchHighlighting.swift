/// MatchHighlighting.swift — search-match highlighting for row titles and
/// snippets (docs/03b-instruction-set.md §8; roadmap 05).
///
/// Matched ranges are UTF-16 offsets relative to the string they annotate:
/// the row title when `search.snippet == nil`, else the snippet excerpt. The
/// conversion is defensive — a range that does not fall entirely inside the
/// string is dropped, never clamped into wrong pixels.
import Foundation
import HistoryCore
import SwiftUI

/// Builds a highlighted `AttributedString` — bold plus the accent foreground
/// color over each matched range, plain elsewhere (docs/
/// 03b-instruction-set.md §8).
public enum MatchHighlighting {

    /// - Parameters:
    ///   - text: The base string (title or snippet excerpt).
    ///   - ranges: UTF-16 ranges into `text`; out-of-bounds, zero-length,
    ///     and overlapping (after sorting) ranges are ignored.
    public static func highlighted(
        _ text: String,
        ranges: [UTF16TextRange]
    ) -> AttributedString {
        // UTF-16 offsets → String index ranges; Range.init?(NSRange, in:)
        // returns nil for anything not fully inside `text`.
        let matched = ranges
            .compactMap { utf16Range -> Range<String.Index>? in
                Range(
                    NSRange(
                        location: utf16Range.location,
                        length: utf16Range.length
                    ),
                    in: text
                )
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
            segment.foregroundColor = .accentColor
            result.append(segment)
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result.append(AttributedString(String(text[cursor..<text.endIndex])))
        }
        return result
    }
}
