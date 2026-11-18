import Foundation
import HistoryCore

/// Finds occurrence locations in text already displayed by the app. The
/// offsets index this exact string, independent of the stored search projection.
public enum SearchTextOccurrences {
    public static let maximumPreviewOccurrences = 512
    internal static let resultRangeLimit = HistoryLimits.standard.maximumStoredTitleUTF8Bytes
    internal static let regexpPresentationBudget: Duration = .milliseconds(40)

    /// Returns nonempty exact or regexp matches in the bounded preview text.
    /// Callers use stored title/excerpt evidence for conditions, fuzzy search,
    /// and matches in another representation. Use a background task for previews.
    public static func ranges(in text: String, term: String, mode: SearchMode) -> [UTF16TextRange] {
        let limits = HistoryLimits.standard
        guard !Task.isCancelled, !term.isEmpty,
              term.utf8.prefix(limits.maximumSearchTermUTF8Bytes + 1).count <= limits.maximumSearchTermUTF8Bytes
        else { return [] }

        switch mode {
        case .exact:
            let input = boundedUTF8Prefix(of: text, limit: limits.maximumStoredSearchBodyUTF8Bytes)
            return literalRanges(in: input, term: term, options: [.literal, .caseInsensitive],
                                 scope: 0..<input.utf16.count, limit: maximumPreviewOccurrences)
        case .regexp:
            guard term.count <= limits.maximumRegexpPatternCharacters,
                  !SearchWorker.containsRejectedPatternShape(term),
                  let pattern = try? NSRegularExpression(pattern: term) else { return [] }
            let prefix = boundedUTF8Prefix(of: text, limit: limits.maximumStoredSearchBodyUTF8Bytes)
            let input = String(prefix.prefix(limits.maximumRegexpTitleBodyPrefixCharacters))
            let literal = NSRegularExpression.escapedPattern(for: term) == term ? term : nil
            return regexpRanges(in: input, pattern: pattern, literalPattern: literal,
                                scope: 0..<input.utf16.count, limit: maximumPreviewOccurrences,
                                deadline: ContinuousClock.now.advanced(by: regexpPresentationBudget))
        case .fuzzy, .expression:
            return []
        }
    }

    internal static func literalRanges(
        in text: String, term: String, options: String.CompareOptions, scope: Range<Int>,
        limit: Int, deadline: ContinuousClock.Instant? = nil
    ) -> [UTF16TextRange] {
        guard !scope.isEmpty, !term.isEmpty else { return [] }
        let text = text as NSString
        guard scope.lowerBound >= 0, scope.upperBound <= text.length else { return [] }
        var results: [UTF16TextRange] = []
        var start = scope.lowerBound
        while start < scope.upperBound, results.count < limit, !Task.isCancelled {
            if let deadline, ContinuousClock.now >= deadline { break }
            let remaining = NSRange(location: start, length: scope.upperBound - start)
            let match = text.range(of: term, options: options, range: remaining)
            guard match.location != NSNotFound, match.length > 0 else { break }
            results.append(.init(location: match.location, length: match.length))
            start = NSMaxRange(match)
        }
        return results
    }

    internal static func regexpRanges(
        in text: String, pattern: NSRegularExpression, literalPattern: String?, scope: Range<Int>,
        limit: Int, deadline: ContinuousClock.Instant
    ) -> [UTF16TextRange] {
        // A displayed title can extend past the prefix admitted for regexp search.
        let lowerBound = max(0, scope.lowerBound)
        let upperBound = min(scope.upperBound, text.utf16.count)
        guard lowerBound < upperBound, !Task.isCancelled, ContinuousClock.now < deadline else { return [] }
        if let literalPattern {
            return literalRanges(in: text, term: literalPattern, options: .literal,
                                 scope: lowerBound..<upperBound, limit: limit, deadline: deadline)
        }
        // Scan the original bounded input so anchors and lookaround keep
        // their real context. Collect only occurrences in the display scope.
        var results: [UTF16TextRange] = []
        pattern.enumerateMatches(in: text, options: [.reportProgress, .reportCompletion],
                                 range: NSRange(text.startIndex..<text.endIndex, in: text)) { match, flags, stop in
            guard !Task.isCancelled, ContinuousClock.now < deadline, !flags.contains(.internalError) else {
                stop.pointee = true
                return
            }
            guard let range = match?.range else { return }
            if range.location >= upperBound {
                stop.pointee = true
                return
            }
            guard range.location >= lowerBound, range.length > 0 else { return }
            results.append(.init(location: range.location, length: range.length))
            if results.count >= limit { stop.pointee = true }
        }
        return results
    }

    private static func boundedUTF8Prefix(of text: String, limit: Int) -> String {
        let bytes = text.utf8
        var end = bytes.prefix(limit).endIndex
        guard end != bytes.endIndex else { return text }
        // Continuation bytes belong to the omitted scalar if the byte bound
        // ends inside it. Keep each returned UTF-16 position in the input.
        while bytes[end] & 0xC0 == 0x80 {
            bytes.formIndex(before: &end)
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}
