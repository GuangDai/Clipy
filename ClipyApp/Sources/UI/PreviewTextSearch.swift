import Foundation
import HistoryCore
import HistoryStorage
import SwiftUI

struct PreviewSearchQuery: Sendable, Equatable {
    let term: String
    let mode: SearchMode

    init?(term: String, mode: SearchMode) {
        guard mode == .exact || mode == .regexp else { return nil }
        self.term = term
        self.mode = mode
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mode == rhs.mode && lhs.term.utf8.elementsEqual(rhs.term.utf8)
    }
}

struct PreviewTextSearchInput: Sendable, Equatable {
    let text: String
    let query: PreviewSearchQuery

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.query == rhs.query else { return false }
        let left = lhs.text.utf8
        let right = rhs.text.utf8
        return left.withContiguousStorageIfAvailable { lhsBuffer in
            right.withContiguousStorageIfAvailable { rhsBuffer in
                lhsBuffer.count == rhsBuffer.count && (lhsBuffer.baseAddress == rhsBuffer.baseAddress
                    || lhsBuffer.elementsEqual(rhsBuffer))
            } ?? lhsBuffer.elementsEqual(right)
        } ?? left.elementsEqual(right)
    }
}

/// The excerpt is the exact search result evidence, even when its source or
/// position lies outside the formatter's visible representation preview.
struct PreviewSearchEvidence: View {
    let row: HistoryRow
    let accessibilityID: String
    @Environment(\.locale) private var locale
    @Environment(\.searchMatchStyle) private var style

    var body: some View {
        if let match = row.search, match.snippet != nil || !match.matchedRanges.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(PreviewCopy.text("Search match", bundle: PanelActionsCopy.bundle(for: locale)))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(MatchHighlighting.highlighted(match.snippet ?? row.title, ranges: match.matchedRanges,
                    prioritizesMatch: true, style: style))
                    .font(.callout)
                    .lineLimit(3)
                    .accessibilityIdentifier(accessibilityID)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Highlights are local to each renderer segment; one occurrence may cross
/// several segments without rebuilding the selectable preview text.
struct PreviewTextMatches: Sendable, Equatable {
    struct Highlight: Sendable, Equatable {
        let occurrence: Int
        let range: UTF16TextRange
    }

    let input: PreviewTextSearchInput
    var highlights: [Int: [Highlight]] = [:]
    var targets: [Int] = []

    static func prepare(
        input: PreviewTextSearchInput, segments: [Substring], groups: [Range<Int>]
    ) async -> Self {
        let task = Task.detached(priority: .userInitiated) {
            let ranges = SearchTextOccurrences.ranges(in: input.text, term: input.query.term, mode: input.query.mode)
            return Self.project(ranges, input: input, segments: segments, groups: groups)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func project(
        _ ranges: [UTF16TextRange], input: PreviewTextSearchInput,
        segments: [Substring], groups: [Range<Int>]
    ) -> Self {
        var result = Self(input: input)
        var offset = 0
        var matchIndex = 0
        var groupIndex = 0
        for (index, segment) in segments.enumerated() {
            guard matchIndex < ranges.count, !Task.isCancelled else { break }
            let end = offset + segment.utf16.count
            while groupIndex < groups.count, groups[groupIndex].upperBound <= index { groupIndex += 1 }
            guard groupIndex < groups.count else { break }
            while matchIndex < ranges.count, ranges[matchIndex].location < end {
                let match = ranges[matchIndex]
                let matchEnd = match.location + match.length
                let lower = max(match.location, offset)
                let upper = min(matchEnd, end)
                if lower < upper {
                    if match.location >= offset { result.targets.append(groups[groupIndex].lowerBound) }
                    result.highlights[index, default: []].append(Highlight(
                        occurrence: matchIndex, range: .init(location: lower - offset, length: upper - lower)
                    ))
                }
                guard matchEnd <= end else { break }
                matchIndex += 1
            }
            offset = end
        }
        return result
    }

    static func displayText(_ text: Substring, highlights matches: [Highlight]?,
                            activeMatch: Int, style: SearchMatchStyle) -> Text {
        guard let matches else { return Text(verbatim: String(text)) }
        return Text(MatchHighlighting.highlighted(String(text), ranges: matches.map(\.range), style: style,
            focusedRange: matches.first { $0.occurrence == activeMatch }?.range))
    }
}

struct PreviewSearchMatchNavigator: View {
    static let height: CGFloat = 24

    let count: Int
    let selection: Int
    let accessibilityID: String
    let onSelect: (Int) -> Void
    @Environment(\.locale) private var locale

    private var bundle: Bundle { PanelActionsCopy.bundle(for: locale) }

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(String(format: PreviewCopy.text("%@ of %@ matches shown", bundle: bundle),
                (selection + 1).formatted(.number.locale(locale)), count.formatted(.number.locale(locale))))
                .monospacedDigit()
                .accessibilityIdentifier(accessibilityID + ".position")
            stepButton("Previous match", symbol: "chevron.backward", delta: -1, suffix: ".previous")
            stepButton("Next match", symbol: "chevron.forward", delta: 1, suffix: ".next")
        }
        .font(.caption)
        .controlSize(.small)
        .frame(height: Self.height)
    }

    private func stepButton(_ title: String, symbol: String, delta: Int, suffix: String) -> some View {
        let label = PreviewCopy.text(title, bundle: bundle)
        let next = selection + delta
        return Button { onSelect(next) } label: {
            Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!(0..<count).contains(next))
        .help(label)
        .accessibilityIdentifier(accessibilityID + suffix)
    }
}
