import Foundation
import HistoryCore

/// The matching mode applies only to literalText. Wrapped conditions remain
/// a separate expression so adding a source filter cannot turn fuzzy or
/// regular-expression text into an exact expression phrase.
struct HistorySearchQueryCompilation: Sendable {
    let literalText: String
    let expressionText: String?
    let expression: HistorySearchExpression?
}

enum HistorySearchQueryCompiler {
    static func compile(_ text: String, mode: SearchMode = .fuzzy) throws(HistorySearchExpressionError) -> HistorySearchQueryCompilation {
        let limit = HistoryLimits.standard.maximumSearchTermUTF8Bytes
        // Inspect a bounded admission prefix before considering the legacy
        // oversized-text path, which returns the original literal String.
        let bytes = Array(text.utf8.prefix(limit + 1))
        guard bytes.count <= limit else {
            // The caller performs this oversized-input path away from the
            // main actor. Legacy fuzzy text keeps its bounded-prefix behavior;
            // any dollar requires complete wrapper admission, never truncation.
            guard !text.utf8.contains(36) else { throw tooLong }
            return HistorySearchQueryCompilation(literalText: text, expressionText: nil, expression: nil)
        }

        var literalSegments: [String] = []
        var conditionSegments: [ConditionSegment] = []
        var soleExpression: HistorySearchExpression?
        var literal: [UInt8] = []
        var cursor = 0

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            literalSegments.append(String(decoding: literal, as: UTF8.self))
            literal.removeAll(keepingCapacity: true)
        }

        while cursor < bytes.count {
            if bytes[cursor] == 92, cursor + 1 < bytes.count, bytes[cursor + 1] == 36 {
                // This escape blocks wrapper admission in every mode. A
                // regexp still needs its backslash to match a literal dollar.
                if mode == .regexp { literal.append(92) }
                literal.append(36)
                cursor += 2
                continue
            }
            guard bytes[cursor] == 36 else {
                literal.append(bytes[cursor])
                cursor += 1
                continue
            }
            // Regexp dollar anchors belong to the pattern. Conditions begin
            // at the input start or after whitespace in that matching mode.
            if mode == .regexp, cursor > 0, !hasWhitespaceBefore(cursor, in: bytes) {
                literal.append(36)
                cursor += 1
                continue
            }

            let opening = cursor
            cursor += 1
            let conditionStart = cursor
            var condition: [UInt8] = []
            var isQuoted = false
            while cursor < bytes.count {
                let byte = bytes[cursor]
                if byte == 92, cursor + 1 < bytes.count {
                    let next = bytes[cursor + 1]
                    if next == 36 {
                        condition.append(36)
                        cursor += 2
                        continue
                    }
                    if isQuoted, next == 92 || next == 34 {
                        // Keep the raw DSL's backslash/quote escape spelling;
                        // its parser, rather than this wrapper, decodes it.
                        condition.append(byte)
                        condition.append(next)
                        cursor += 2
                        continue
                    }
                }
                if byte == 34 { isQuoted.toggle() }
                if byte == 36, !isQuoted, !startsWithDecimalDigit(bytes, at: cursor + 1) { break }
                condition.append(byte)
                cursor += 1
            }

            guard cursor < bytes.count else {
                // The final dollar and every tail byte survive while a user
                // is still typing the closing delimiter or quoted value.
                literal.append(36)
                if mode == .regexp { literal.append(contentsOf: bytes[conditionStart...]) }
                else { literal.append(contentsOf: condition) }
                break
            }
            let conditionEnd = cursor
            cursor += 1
            let conditionText = String(decoding: condition, as: UTF8.self)
            let numericText = conditionText.trimmingCharacters(in: .whitespacesAndNewlines)
            if isAmount(numericText) {
                // A paired numeric amount is still ordinary clipboard text.
                literal.append(36)
                literal.append(contentsOf: condition)
                literal.append(36)
                continue
            }
            let parsed: HistorySearchExpression
            do {
                parsed = try HistorySearchExpression.parse(conditionText)
            } catch {
                throw HistorySearchExpressionError(reason: error.reason, offset: originalCharacterOffset(
                    for: error.offset, in: conditionText, rawBytes: bytes,
                    conditionStart: conditionStart, conditionEnd: conditionEnd, query: text
                ))
            }
            flushLiteral()
            let isEmptyCondition = conditionText.allSatisfy(\.isWhitespace)
            soleExpression = conditionSegments.isEmpty && !isEmptyCondition ? parsed : nil
            // The raw parser accepts an empty expression as all rows. Give
            // that value a usable term when joining it with another block.
            conditionSegments.append(ConditionSegment(
                text: isEmptyCondition ? parsed.serialized : conditionText,
                opening: opening
            ))
        }
        flushLiteral()

        guard !conditionSegments.isEmpty else {
            return HistorySearchQueryCompilation(
                literalText: literalSegments.joined(), expressionText: nil, expression: nil
            )
        }

        // Removing a condition should separate its neighboring text words.
        // Interior bytes within each literal segment remain unchanged.
        let literalText = literalSegments.compactMap { segment -> String? in
            let value = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }.joined(separator: " ")

        let isCompound = conditionSegments.count > 1
        var expressionBytes = isCompound ? (conditionSegments.count - 1) * 5 : 0
        for condition in conditionSegments {
            expressionBytes += condition.text.utf8.count + (isCompound ? 2 : 0)
            guard expressionBytes <= limit else { throw tooLong }
        }
        // Budget before constructing the combined source or its AST. A sole
        // block needs no extra group that would consume its nesting allowance.
        let expressionText = isCompound
            ? conditionSegments.map { "(" + $0.text + ")" }.joined(separator: " AND ")
            : conditionSegments[0].text
        let expression: HistorySearchExpression
        if let soleExpression {
            // Its source and parser limits are unchanged after wrapper admission.
            expression = soleExpression
        } else {
            do {
                expression = try HistorySearchExpression.parse(expressionText)
            } catch {
                let opening = relatedOpening(for: error.offset, in: conditionSegments, isCompound: isCompound)
                throw HistorySearchExpressionError(
                    reason: error.reason, offset: characterOffset(at: opening, in: text)
                )
            }
        }
        return HistorySearchQueryCompilation(
            literalText: literalText,
            expressionText: expressionText,
            expression: expression
        )
    }

    private struct ConditionSegment {
        let text: String
        let opening: Int
    }

    /// Translate only on failure. The parser counts Characters after the
    /// wrapper removes \$, while diagnostics address the original field.
    private static func originalCharacterOffset(
        for offset: Int, in condition: String, rawBytes: [UInt8],
        conditionStart: Int, conditionEnd: Int, query: String
    ) -> Int {
        let decodedTarget = condition.prefix(offset).utf8.count
        var cursor = conditionStart
        var decodedBytes = 0
        var isQuoted = false
        while cursor < conditionEnd, decodedBytes < decodedTarget {
            let byte = rawBytes[cursor]
            if byte == 92, cursor + 1 < conditionEnd {
                let next = rawBytes[cursor + 1]
                if next == 36 {
                    cursor += 2
                    decodedBytes += 1
                    continue
                }
                if isQuoted, next == 92 || next == 34 {
                    cursor += 2
                    decodedBytes += 2
                    continue
                }
            }
            if byte == 34 { isQuoted.toggle() }
            cursor += 1
            decodedBytes += 1
        }
        return characterOffset(at: cursor, in: query)
    }

    private static func characterOffset(at byteOffset: Int, in text: String) -> Int {
        var bytes = 0
        var offset = 0
        for character in text {
            bytes += String(character).utf8.count
            if byteOffset < bytes { return offset }
            offset += 1
        }
        return offset
    }

    private static func relatedOpening(
        for offset: Int, in conditions: [ConditionSegment], isCompound: Bool
    ) -> Int {
        var end = 0
        for condition in conditions {
            end += condition.text.count + (isCompound ? 2 : 0)
            if offset < end { return condition.opening }
            if isCompound { end += 5 }
        }
        return conditions.last?.opening ?? 0
    }

    private static var tooLong: HistorySearchExpressionError {
        HistorySearchExpressionError(reason: .queryTooLong, offset: 0)
    }

    private static func isAmount(_ text: String) -> Bool {
        var hasDigit = false
        var hasPoint = false
        var endsWithDigit = false
        for scalar in text.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                hasDigit = true
                endsWithDigit = true
            } else if scalar == ".", hasDigit, !hasPoint {
                hasPoint = true
                endsWithDigit = false
            } else {
                return false
            }
        }
        return hasDigit && endsWithDigit
    }

    private static func startsWithDecimalDigit(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index < bytes.count else { return false }
        let leading = bytes[index]
        if leading < 128 { return (48...57).contains(leading) }
        let width = leading < 224 ? 2 : (leading < 240 ? 3 : 4)
        // The delimiter is ASCII, so the next byte starts a complete UTF-8
        // scalar. Decode only that scalar rather than rescanning the tail.
        let end = min(bytes.count, index + width)
        guard let scalar = String(decoding: bytes[index..<end], as: UTF8.self).unicodeScalars.first else {
            return false
        }
        return CharacterSet.decimalDigits.contains(scalar)
    }

    private static func hasWhitespaceBefore(_ index: Int, in bytes: [UInt8]) -> Bool {
        var start = index - 1
        // Decode only the preceding complete UTF-8 scalar, including Unicode
        // separators; the admitted query is already valid Swift text.
        while start > 0, bytes[start] & 0xC0 == 0x80 { start -= 1 }
        guard let scalar = String(decoding: bytes[start..<index], as: UTF8.self).unicodeScalars.first else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
