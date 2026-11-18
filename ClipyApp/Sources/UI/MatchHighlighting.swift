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

enum SearchMatchStyle: String, CaseIterable, Sendable {
    case background
    case underline

    static let defaultsKey = "clipy.appearance.searchMatchStyle"

    var title: String {
        switch self {
        case .background: "Background"
        case .underline: "Underline"
        }
    }
}

extension EnvironmentValues {
    @Entry var searchMatchStyle: SearchMatchStyle = .background
}

private struct SearchMatchStyleModifier: ViewModifier {
    @AppStorage(SearchMatchStyle.defaultsKey) private var style: SearchMatchStyle = .background

    func body(content: Content) -> some View {
        content.environment(\.searchMatchStyle, style)
    }
}

extension View {
    func searchMatchAppearance() -> some View {
        modifier(SearchMatchStyleModifier())
    }
}

/// Builds a highlighted `AttributedString`, preserving exact scalar boundaries
/// within graphemes (docs/search.md).
enum MatchHighlighting {
    static func resultText(for row: HistoryRow, foreground: Color?, style: SearchMatchStyle) -> AttributedString {
        guard let match = row.search else { return AttributedString(flattened(row.title[...])) }
        return highlighted(match.snippet ?? row.title, ranges: match.matchedRanges,
                           foreground: foreground, prioritizesMatch: true, style: style, flattensLineBreaks: true)
    }

    /// - Parameters:
    ///   - text: The base string (title or snippet excerpt).
    ///   - ranges: UTF-16 ranges into `text`; out-of-bounds, zero-length,
    ///     surrogate-splitting, and overlapping (after sorting) ranges are
    ///     ignored.
    ///   - prioritizesMatch: Keep the first valid hit near the start for a
    ///     line-limited view. The highlight remains scalar-exact.
    static func highlighted(
        _ text: String,
        ranges: [UTF16TextRange],
        foreground: Color? = .accentColor,
        prioritizesMatch: Bool = false,
        style: SearchMatchStyle = .background,
        focusedRange: UTF16TextRange? = nil,
        flattensLineBreaks: Bool = false
    ) -> AttributedString {
        func rendered(_ slice: Substring) -> AttributedString {
            AttributedString(flattensLineBreaks ? flattened(slice) : String(slice))
        }
        let bounds: [(start: Int, end: Int)] = ranges.compactMap { range in
            guard range.location >= 0, range.length > 0 else { return nil }
            let (end, overflow) = range.location.addingReportingOverflow(range.length)
            guard !overflow else { return nil }
            return (range.location, end)
        }
        let endpoints = Set(bounds.flatMap { [$0.start, $0.end] })
        guard let finalOffset = endpoints.max() else { return rendered(text[...]) }

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

        guard let firstMatch = matched.first else { return rendered(text[...]) }
        let focused = focusedRange.flatMap { range -> Range<String.Index>? in
            let (end, overflow) = range.location.addingReportingOverflow(range.length)
            guard !overflow, let startIndex = indices[range.location], let endIndex = indices[end],
                  startIndex < endIndex else { return nil }
            return startIndex..<endIndex
        }

        var result = AttributedString()
        var cursor = text.startIndex
        if prioritizesMatch {
            cursor = text.indices.last(where: { $0 <= firstMatch.lowerBound }) ?? text.startIndex
            for _ in 0..<12 {
                guard cursor != text.startIndex else { break }
                let preceding = text.index(before: cursor)
                guard !text[preceding].isNewline else { break }
                cursor = preceding
            }
            if cursor != text.startIndex { result.append(AttributedString("…")) }
        }
        for range in matched {
            // Skip overlaps (the range starts inside an already-emitted
            // segment) and zero-length matches — neither has pixels to mark.
            guard range.lowerBound >= cursor,
                  range.lowerBound < range.upperBound
            else { continue }
            if cursor < range.lowerBound {
                result.append(rendered(text[cursor..<range.lowerBound]))
            }
            var segment = rendered(text[range])
            segment.inlinePresentationIntent = .stronglyEmphasized
            let isFocused = focused == range
            switch style {
            case .background:
                segment.swiftUI.backgroundColor = isFocused
                    ? Color(red: 1, green: 0.65, blue: 0.12)
                    : Color(red: 1, green: 0.85, blue: 0.49)
                segment.swiftUI.foregroundColor = .black
            case .underline:
                segment.swiftUI.underlineStyle = .single
                segment.swiftUI.foregroundColor = foreground
                if isFocused {
                    segment.swiftUI.backgroundColor = Color(red: 1, green: 0.85, blue: 0.49)
                    segment.swiftUI.foregroundColor = .black
                }
            }
            result.append(segment)
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result.append(rendered(text[cursor..<text.endIndex]))
        }
        return result
    }

    private static func flattened(_ text: Substring) -> String {
        String(text.map { $0.isNewline ? " " : $0 })
    }
}
