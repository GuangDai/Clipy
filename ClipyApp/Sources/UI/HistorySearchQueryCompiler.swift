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

/// Finds the places where Clipy's condition delimiter can sit outside a
/// regexp token. The editor uses UTF-16 and the compiler uses UTF-8. Only
/// ASCII syntax changes this state, so both can scan their native units.
struct HistorySearchRegexpBoundary {
    private var characterClassDepth = 0
    private var isQuoted = false
    private var previousWasEscaped = false

    var allowsCondition: Bool {
        characterClassDepth == 0 && !isQuoted && !previousWasEscaped
    }

    /// Advance over a regexp unit or an escape and its complete scalar.
    mutating func advance(_ unit: UInt16, followedBy next: UInt16?, nextScalarWidth: Int) -> Int {
        if isQuoted {
            if unit == 92, next == 69 { // \E
                isQuoted = false
                return 2
            }
            return 1
        }
        if unit == 92 { // Backslash
            if next == 81 { isQuoted = true } // \Q
            previousWasEscaped = !isQuoted
            return next == nil ? 1 : 1 + nextScalarWidth
        }
        previousWasEscaped = false
        switch unit {
        case 91: characterClassDepth += 1 // [
        case 93 where characterClassDepth > 0: characterClassDepth -= 1 // ]
        default: break
        }
        return 1
    }
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
        var regexpBoundary = HistorySearchRegexpBoundary()

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            literalSegments.append(String(decoding: literal, as: UTF8.self))
            literal.removeAll(keepingCapacity: true)
        }

        while cursor < bytes.count {
            if mode == .regexp {
                // Dollar anchors, class members and quoted/escaped dollars
                // belong to the regexp. Only an outside separator can open
                // a Clipy condition.
                let unit = bytes[cursor]
                if unit != 36 || !regexpBoundary.allowsCondition
                    || (cursor > 0 && !hasWhitespaceBefore(cursor, in: bytes)) {
                    let next = cursor + 1 < bytes.count ? bytes[cursor + 1] : nil
                    let end = cursor + regexpBoundary.advance(
                        UInt16(unit), followedBy: next.map { UInt16($0) },
                        nextScalarWidth: next.map(utf8ScalarWidth) ?? 0
                    )
                    literal.append(contentsOf: bytes[cursor..<end])
                    cursor = end
                    continue
                }
            } else if bytes[cursor] == 92, cursor + 1 < bytes.count, bytes[cursor + 1] == 36 {
                literal.append(36)
                cursor += 2
                continue
            }
            guard bytes[cursor] == 36 else {
                literal.append(bytes[cursor])
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
                if mode == .regexp { literal.append(contentsOf: bytes[opening..<cursor]) }
                else {
                    literal.append(36)
                    literal.append(contentsOf: condition)
                    literal.append(36)
                }
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

    /// Explicit completion appends a block only if the same compiler can
    /// recover the original regexp byte for byte. A trailing escape, open
    /// class or unfinished wrapper can otherwise absorb the new block.
    static func regexpConditionInsertionPrefix(for text: String) -> String? {
        guard let original = try? compile(text, mode: .regexp) else { return nil }
        let separator = text.unicodeScalars.last.map {
            CharacterSet.whitespacesAndNewlines.contains($0) ? "" : " "
        } ?? ""
        guard let trial = try? compile(text + separator + "$type:all$", mode: .regexp),
              trial.literalText.utf8.elementsEqual(original.literalText.utf8),
              trial.expressionText != original.expressionText
        else { return nil }
        return separator
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
        // The delimiter is ASCII, so the next byte starts a complete UTF-8
        // scalar. Decode only that scalar rather than rescanning the tail.
        let end = min(bytes.count, index + utf8ScalarWidth(leading))
        guard let scalar = String(decoding: bytes[index..<end], as: UTF8.self).unicodeScalars.first else {
            return false
        }
        return CharacterSet.decimalDigits.contains(scalar)
    }

    private static func utf8ScalarWidth(_ leadingByte: UInt8) -> Int {
        if leadingByte < 128 { return 1 }
        if leadingByte < 224 { return 2 }
        return leadingByte < 240 ? 3 : 4
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
