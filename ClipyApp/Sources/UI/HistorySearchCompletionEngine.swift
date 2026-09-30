import Foundation
import HistoryCore

/// The field editor reports UTF-16 ranges. Keep its raw spelling so a composed
/// and a decomposed edit cannot reuse suggestions for the previous input.
struct HistorySearchCompletionInput: Sendable, Equatable {
    let text: String
    let selection: NSRange
    let isComposing: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selection == rhs.selection && lhs.isComposing == rhs.isComposing
            && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }
}

struct HistorySearchCompletionContext: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case term, source, typeValue, flagValue, dateValue
    }

    let kind: Kind
    /// The decoded current value before the caret, never the whole query.
    let prefix: String
    let replacementRange: NSRange
    let field: String?
    let explicit: Bool
    let openingText: String
    let closingText: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.replacementRange == rhs.replacementRange
            && lhs.field == rhs.field && lhs.explicit == rhs.explicit
            && lhs.openingText == rhs.openingText && lhs.closingText == rhs.closingText
            && lhs.prefix.utf8.elementsEqual(rhs.prefix.utf8)
    }
}

struct HistorySearchCompletionCandidate: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let insertion: String
    let replacementRange: NSRange
    /// Optional UTF-16 caret offset relative to the inserted text.
    let selectionOffset: Int?

    init(
        id: String, title: String, subtitle: String? = nil, insertion: String,
        replacementRange: NSRange, selectionOffset: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.insertion = insertion
        self.replacementRange = replacementRange
        self.selectionOffset = selectionOffset
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id.utf8.elementsEqual(rhs.id.utf8) && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle && lhs.replacementRange == rhs.replacementRange
            && lhs.selectionOffset == rhs.selectionOffset
            && lhs.insertion.utf8.elementsEqual(rhs.insertion.utf8)
    }
}

struct HistorySearchCompletionInsertion: Identifiable, Sendable, Equatable {
    let id: Int
    let originalText: String
    let replacementRange: NSRange
    let text: String
    let selectionOffset: Int?

    init(
        id: Int, originalText: String, replacementRange: NSRange,
        text: String, selectionOffset: Int? = nil
    ) {
        self.id = id
        self.originalText = originalText
        self.replacementRange = replacementRange
        self.text = text
        self.selectionOffset = selectionOffset
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.replacementRange == rhs.replacementRange
            && lhs.selectionOffset == rhs.selectionOffset
            && lhs.originalText.utf8.elementsEqual(rhs.originalText.utf8)
            && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }
}

/// A small input aid, not another expression parser. It identifies a term in
/// an established dollar block and replaces that entire term. Uncertain or
/// oversized contexts produce no automatic suggestions.
enum HistorySearchCompletionEngine {
    private static let maximumInputUTF8Bytes = 8_192
    private static let maximumLookBehindUTF16 = 4_096
    private static let maximumLookAheadUTF16 = 512
    private static let maximumTermUTF16 = 256
    private static let maximumMatchPrefixUTF16 = 128
    private static let maximumMatchTargetUTF16 = 1_024

    static func context(
        for input: HistorySearchCompletionInput, explicit: Bool = false, mode: SearchMode = .fuzzy
    ) -> HistorySearchCompletionContext? {
        // Count only a bounded prefix before bridging to NSString. A pasted
        // megabyte value must not become a megabyte allocation or scan here.
        guard !input.isComposing,
              input.text.utf8.prefix(maximumInputUTF8Bytes + 1).count <= maximumInputUTF8Bytes else { return nil }
        let text = input.text as NSString
        guard let selection = safeSelection(input.selection, in: text),
              selection.location <= maximumLookBehindUTF16 else { return nil }

        // Quote state is meaningful only inside a dollar block. Checking the
        // bounded prefix establishes delimiter pairing; guessing the parity
        // from a closing dollar beside the caret would complete ordinary text.
        var blockStart: Int?
        var quoted = false
        var cursor = 0
        while cursor < selection.location {
            let unit = text.character(at: cursor)
            if unit == 92, cursor + 1 < text.length {
                let following = text.character(at: cursor + 1)
                if following == 36 || (blockStart != nil && quoted && (following == 34 || following == 92)) {
                    cursor += 2
                    continue
                }
            }
            if blockStart != nil, unit == 34 { quoted.toggle() }
            if unit == 36, !quoted {
                if blockStart == nil {
                    if mode != .regexp || cursor == 0 || isWhitespace(text.character(at: cursor - 1)) {
                        blockStart = cursor + 1
                    }
                }
                else if !isAmountDigitAfter(cursor, in: text) { blockStart = nil }
            }
            cursor += 1
        }

        guard let blockStart else {
            guard explicit else { return nil }
            let needsSeparator = mode == .regexp && selection.length == 0
                && selection.location == text.length && selection.location > 0
                && !isWhitespace(text.character(at: selection.location - 1))
            return .init(kind: .term, prefix: "", replacementRange: selection,
                         field: nil, explicit: true, openingText: needsSeparator ? " $" : "$", closingText: "$")
        }

        let endLimit = min(text.length, selection.location + maximumLookAheadUTF16)
        var closing: Int?
        // A caret can sit between a backslash and its escaped quote/dollar.
        // The prefix scanner has already consumed that pair in this case.
        while cursor < endLimit {
            let unit = text.character(at: cursor)
            if unit == 92, cursor + 1 < text.length {
                let following = text.character(at: cursor + 1)
                if following == 36 || (quoted && (following == 34 || following == 92)) {
                    cursor += 2
                    continue
                }
            }
            if unit == 34 { quoted.toggle() }
            if unit == 36, !quoted, !isAmountDigitAfter(cursor, in: text) { closing = cursor; break }
            cursor += 1
        }
        guard closing != nil || endLimit == text.length else { return nil }
        let blockEnd = closing ?? text.length
        guard NSMaxRange(selection) <= blockEnd else { return nil }
        if closing != nil, isAmount(in: text, range: NSRange(location: blockStart, length: blockEnd - blockStart)) {
            return nil
        }
        if closing == nil {
            var firstValue = blockStart
            while firstValue < blockEnd, isWhitespace(text.character(at: firstValue)) { firstValue += 1 }
            if isDecimalDigit(at: firstValue, in: text) { return nil }
        }

        cursor = blockStart
        while cursor < blockEnd {
            if isTermBoundary(text.character(at: cursor)) {
                cursor += 1
                continue
            }
            let start = cursor
            var tokenQuoted = false
            while cursor < blockEnd {
                let unit = text.character(at: cursor)
                if !tokenQuoted, isTermBoundary(unit) { break }
                if unit == 92, cursor + 1 < blockEnd {
                    let following = text.character(at: cursor + 1)
                    if following == 36 || (tokenQuoted && (following == 34 || following == 92)) {
                        cursor += 2
                        continue
                    }
                }
                if unit == 34 { tokenQuoted.toggle() }
                cursor += 1
            }
            if selection.location >= start, selection.location <= cursor {
                guard NSMaxRange(selection) <= cursor, cursor - start <= maximumTermUTF16 else { return nil }
                let range = NSRange(location: start, length: cursor - start)
                guard text.rangeOfComposedCharacterSequences(for: range) == range else { return nil }
                let prefixRange = NSRange(location: start, length: selection.location - start)
                let token = text.substring(with: range) as NSString
                let rawPrefix = text.substring(with: prefixRange)
                // A missing delimiter can close this term only when it is
                // the block's final term. Closing in the middle would turn
                // the remaining conditions into ordinary outside text.
                return termContext(token: token, rawPrefix: rawPrefix, range: range,
                                   explicit: explicit, closingText: closing == nil && cursor == blockEnd ? "$" : "")
            }
            if start > selection.location { break }
        }

        guard explicit else { return nil }
        return .init(kind: .term, prefix: "", replacementRange: selection,
                     field: nil, explicit: true, openingText: "", closingText: closing == nil && NSMaxRange(selection) == blockEnd ? "$" : "")
    }

    static func candidates(
        for context: HistorySearchCompletionContext, today: Date = Date()
    ) -> [HistorySearchCompletionCandidate] {
        struct Choice {
            let term: String
            let match: String
            let title: String
            let offset: Int?
        }
        let choices: [Choice]
        switch context.kind {
        case .source:
            return [] // Real retained source occurrences are supplied by History.
        case .term:
            let fields = ["app", "source", "source-id", "type", "is", "date", "before", "after"]
            choices = fields.map {
                Choice(term: $0 + ":", match: $0, title: $0 + ":", offset: $0.utf16.count + 1)
            } + ["AND", "OR", "NOT"].map {
                Choice(term: $0 + " ", match: $0, title: $0, offset: $0.utf16.count + 1)
            }
        case .typeValue:
            choices = ["text", "images", "links", "all"].map {
                Choice(term: "type:" + $0, match: $0, title: "type:" + $0, offset: nil)
            }
        case .flagValue:
            choices = [Choice(term: "is:pinned", match: "pinned", title: "is:pinned", offset: nil)]
        case .dateValue:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let parts = calendar.dateComponents([.year, .month, .day], from: today)
            let day = String(format: "%04d-%02d-%02d", parts.year ?? 1, parts.month ?? 1, parts.day ?? 1)
            let field = context.field ?? "date"
            choices = [Choice(term: field + ":" + day, match: day, title: field + ":" + day, offset: nil)]
        }
        return choices.enumerated().compactMap { index, choice -> (Int, Int, HistorySearchCompletionCandidate)? in
            let score: Int?
            if context.explicit, context.prefix.isEmpty { score = 0 }
            else if context.kind == .dateValue, "today".hasPrefix(context.prefix.lowercased()) { score = 0 }
            else { score = matchScore(choice.match, prefix: context.prefix) }
            guard let score else { return nil }
            return (score, index, candidate(id: choice.term, title: choice.title, term: choice.term,
                                           context: context, selectionOffset: choice.offset))
        }.sorted {
            $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
        }.map(\.2)
    }

    /// `term` is raw expression syntax; callers quote source IDs with the
    /// existing History expression helper before passing them here.
    static func candidate(
        id: String, title: String, subtitle: String? = nil, term: String,
        context: HistorySearchCompletionContext, selectionOffset: Int? = nil
    ) -> HistorySearchCompletionCandidate {
        let raw = term as NSString
        let rawOffset = selectionOffset.map { requested in
            let offset = min(max(requested, 0), raw.length)
            return offset == raw.length ? offset : raw.rangeOfComposedCharacterSequence(at: offset).location
        }
        var insertedEscapes = 0
        if let rawOffset {
            for index in 0..<rawOffset where raw.character(at: index) == 36 { insertedEscapes += 1 }
        }
        let escaped = term.replacingOccurrences(of: "$", with: "\\$")
        let offset = rawOffset.map { context.openingText.utf16.count + $0 + insertedEscapes }
        return .init(id: id, title: title, subtitle: subtitle,
                     insertion: context.openingText + escaped + context.closingText,
                     replacementRange: context.replacementRange, selectionOffset: offset)
    }

    private static func termContext(
        token: NSString, rawPrefix: String, range: NSRange,
        explicit: Bool, closingText: String
    ) -> HistorySearchCompletionContext? {
        var colon: Int?
        for index in 0..<token.length {
            let unit = token.character(at: index)
            if unit == 34 { break }
            if unit == 58 { colon = index; break }
        }
        let prefix = rawPrefix as NSString
        if let colon, colon < prefix.length {
            let field = token.substring(to: colon).lowercased()
            let kind: HistorySearchCompletionContext.Kind?
            switch field {
            case "app", "source", "source-id": kind = .source
            case "type": kind = .typeValue
            case "is": kind = .flagValue
            case "date", "before", "after": kind = .dateValue
            default: kind = nil
            }
            if let kind {
                let value = decoded(prefix.substring(from: colon + 1))
                guard value.utf16.prefix(maximumMatchPrefixUTF16 + 1).count <= maximumMatchPrefixUTF16 else { return nil }
                return .init(kind: kind, prefix: value,
                             replacementRange: range, field: field, explicit: explicit,
                             openingText: "", closingText: closingText)
            }
        }
        // A plain quoted phrase is text even when it contains "type:" or AND.
        guard token.length == 0 || token.character(at: 0) != 34 || explicit else { return nil }
        let value = token.length > 0 && token.character(at: 0) == 34 ? "" : decoded(rawPrefix)
        guard explicit || !value.isEmpty else { return nil }
        return .init(kind: .term, prefix: value, replacementRange: range,
                     field: nil, explicit: explicit, openingText: "", closingText: closingText)
    }

    private static func decoded(_ raw: String) -> String {
        let units = Array(raw.utf16) // Only the admitted short current term.
        var decoded: [UInt16] = []
        decoded.reserveCapacity(units.count)
        var cursor = 0
        var quoted = false
        while cursor < units.count {
            let unit = units[cursor]
            if unit == 92, cursor + 1 < units.count,
               units[cursor + 1] == 36 || (quoted && (units[cursor + 1] == 34 || units[cursor + 1] == 92)) {
                decoded.append(units[cursor + 1])
                cursor += 2
            } else {
                if unit == 34 { quoted.toggle() }
                else { decoded.append(unit) }
                cursor += 1
            }
        }
        return String(decoding: decoded, as: UTF16.self)
    }

    private static func safeSelection(_ range: NSRange, in text: NSString) -> NSRange? {
        guard range.location >= 0, range.location <= text.length,
              range.length >= 0, range.length <= text.length - range.location else { return nil }
        if range.length > 0 { return text.rangeOfComposedCharacterSequences(for: range) }
        guard range.location == text.length
                || text.rangeOfComposedCharacterSequence(at: range.location).location == range.location else { return nil }
        return range
    }

    private static func isTermBoundary(_ unit: UInt16) -> Bool {
        if unit == 40 || unit == 41 { return true }
        return isWhitespace(unit)
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isAmountDigitAfter(_ index: Int, in text: NSString) -> Bool {
        isDecimalDigit(at: index + 1, in: text)
    }

    private static func isDecimalDigit(at index: Int, in text: NSString) -> Bool {
        guard index < text.length else { return false }
        let first = UInt32(text.character(at: index))
        let value: UInt32
        if (0xD800...0xDBFF).contains(first), index + 1 < text.length {
            let second = UInt32(text.character(at: index + 1))
            guard (0xDC00...0xDFFF).contains(second) else { return false }
            value = 0x10000 + ((first - 0xD800) << 10) + second - 0xDC00
        } else { value = first }
        guard let scalar = UnicodeScalar(value) else { return false }
        return CharacterSet.decimalDigits.contains(scalar)
    }

    private static func isAmount(in text: NSString, range: NSRange) -> Bool {
        guard range.length <= maximumTermUTF16 else { return false }
        let value = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        var seenDigit = false
        var seenPeriod = false
        var endsWithDigit = false
        for scalar in value.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                seenDigit = true
                endsWithDigit = true
            } else if scalar == ".", seenDigit, !seenPeriod {
                seenPeriod = true
                endsWithDigit = false
            } else { return false }
        }
        return seenDigit && endsWithDigit
    }

    /// Shared with the bounded source worker. Reject oversized values before
    /// case folding or allocating the matching arrays.
    static func matchScore(_ candidate: String, prefix: String) -> Int? {
        guard prefix.utf16.prefix(maximumMatchPrefixUTF16 + 1).count <= maximumMatchPrefixUTF16,
              candidate.utf16.prefix(maximumMatchTargetUTF16 + 1).count <= maximumMatchTargetUTF16 else { return nil }
        let query = Array(prefix.lowercased().utf16)
        let target = Array(candidate.lowercased().utf16)
        guard !query.isEmpty else { return 0 }
        if target.starts(with: query) { return target.count == query.count ? 0 : 1 }
        if query.count >= 2 {
            var matched = 0
            for unit in target where unit == query[matched] {
                matched += 1
                if matched == query.count { return 2 + target.count - query.count }
            }
        }
        guard query.count >= 3, abs(query.count - target.count) <= 1 else { return nil }
        // Only one edit is allowed. Walk the two short values once rather
        // than building the usual quadratic edit-distance matrix.
        var left = 0
        var right = 0
        var changed = false
        while left < query.count, right < target.count {
            if query[left] == target[right] {
                left += 1
                right += 1
                continue
            }
            guard !changed else { return nil }
            changed = true
            if query.count > target.count { left += 1 }
            else if target.count > query.count { right += 1 }
            else if left + 1 < query.count, right + 1 < target.count,
                    query[left] == target[right + 1], query[left + 1] == target[right] {
                left += 2
                right += 2
            } else {
                left += 1
                right += 1
            }
        }
        let remaining = query.count - left + target.count - right
        return remaining <= (changed ? 0 : 1) ? 4 : nil
    }
}
