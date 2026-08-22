/// MatchHighlighting.swift — search-match highlighting for row titles and
/// snippets (docs/03b-instruction-set.md §8; roadmap 05).
///
/// Matched ranges are UTF-16 offsets relative to the string they annotate:
/// the row title when `search.snippet == nil`, else the snippet excerpt. The
/// conversion is defensive — a range that does not fall entirely inside the
/// string, or whose bounds split a surrogate pair, is dropped, never clamped
/// into wrong pixels.
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
    ///     surrogate-splitting, and overlapping (after sorting) ranges are
    ///     ignored.
    public static func highlighted(
        _ text: String,
        ranges: [UTF16TextRange]
    ) -> AttributedString {
        // UTF-16 offsets → String index ranges. Range.init?(NSRange, in:)
        // returns nil for anything not fully inside `text`, but it CLAMPS a
        // bound that lands between the two units of a surrogate pair into the
        // surrounding Character instead of failing — so surrogate-splitting
        // bounds are rejected explicitly before the conversion (03b §8:
        // dropped, never clamped).
        let matched = ranges
            .compactMap { utf16Range -> Range<String.Index>? in
                let (end, overflowed) = utf16Range.location
                    .addingReportingOverflow(utf16Range.length)
                guard !overflowed,
                      !splitsSurrogatePair(of: text, atOffset: utf16Range.location),
                      !splitsSurrogatePair(of: text, atOffset: end)
                else { return nil }
                return Range(
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

    /// Whether `offset` lands strictly between the two units of a surrogate
    /// pair — i.e. the UTF-16 unit immediately before it is a lead surrogate.
    /// Such an offset is not a scalar boundary; `Range(NSRange, in:)` clamps
    /// it into the surrounding Character instead of returning nil, so callers
    /// must reject it themselves. Out-of-string offsets are left for the
    /// NSRange conversion to reject, as before.
    private static func splitsSurrogatePair(of text: String, atOffset offset: Int) -> Bool {
        guard offset > 0, offset <= text.utf16.count else { return false }
        let before = text.utf16.index(text.utf16.startIndex, offsetBy: offset - 1)
        return UTF16.isLeadSurrogate(text.utf16[before])
    }
}
