/// Explicit advanced search syntax shared by the UI and History admission.
/// Parsing is pure and bounded; it never reads application or History state.
import Foundation

public struct HistorySearchExpressionError: Error, Sendable, Equatable {
    public enum Reason: String, Sendable {
        case queryTooLong, tooManyTerms, tooDeep, expectedTerm, unexpectedToken
        case unclosedQuote, unclosedParenthesis, missingValue
        case invalidDate, invalidDateRange, invalidType, invalidFlag
    }

    public let reason: Reason
    /// Zero-based Character offset in the original expression.
    public let offset: Int

    public var message: String {
        switch reason {
        case .queryTooLong: "The expression is too long."
        case .tooManyTerms: "The expression has too many terms."
        case .tooDeep: "The expression is nested too deeply."
        case .expectedTerm: "Enter a search term or condition."
        case .unexpectedToken: "An operator or closing parenthesis is out of place."
        case .unclosedQuote: "Close the quoted phrase."
        case .unclosedParenthesis: "Close the parenthesized group."
        case .missingValue: "Enter a value after the field name."
        case .invalidDate: "Use a valid date in YYYY-MM-DD format."
        case .invalidDateRange: "The end date must be on or after the start date."
        case .invalidType: "Use type:text, type:images, type:links, or type:all."
        case .invalidFlag: "Use is:pinned."
        }
    }
}

/// AND (including adjacent terms) binds more tightly than OR; NOT binds
/// first. Quoted values escape only backslash and double quote. Calendar
/// dates refer to UTC days, independent of the machine's current timezone.
public struct HistorySearchExpression: Sendable, Hashable {
    package indirect enum Node: Sendable, Hashable {
        case all
        case text(String)
        case application(String)
        case sourceID(String)
        case noMatch
        case copiedDate(from: Date?, until: Date?)
        case type(HistoryContentType)
        case pinned
        case and(Node, Node)
        case or(Node, Node)
        case not(Node)
    }

    package let root: Node

    /// Unresolved source/app values; exact `source-id:` terms need no app
    /// metadata lookup. The order follows their first appearance in the query.
    public var applicationTerms: [String] {
        func terms(_ node: Node) -> [String] {
            switch node {
            case .application(let value): return [value]
            case .and(let lhs, let rhs), .or(let lhs, let rhs): return terms(lhs) + terms(rhs)
            case .not(let child): return terms(child)
            default: return []
            }
        }
        return terms(root)
    }

    public static func parse(_ text: String) throws(HistorySearchExpressionError) -> Self {
        guard text.utf8.count <= HistoryLimits.standard.maximumSearchTermUTF8Bytes else {
            throw HistorySearchExpressionError(reason: .queryTooLong, offset: 0)
        }
        var parser = try ExpressionParser(text)
        return Self(root: try parser.parse())
    }

    /// A literal expression value, suitable for a full term or after `app:`.
    public static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// App composition resolves display names using installed application
    /// metadata. This pure transformation substitutes exact source IDs; nil
    /// leaves a term unresolved, while an empty list matches no History row.
    public func replacingApplicationTerms(
        _ transform: (String) -> [String]?
    ) -> Self {
        func replace(_ node: Node) -> Node {
            switch node {
            case .application(let name):
                guard let identifiers = transform(name) else { return node }
                guard let first = identifiers.first else { return .noMatch }
                return identifiers.dropFirst().reduce(.sourceID(first)) { .or($0, .sourceID($1)) }
            case .and(let lhs, let rhs): return .and(replace(lhs), replace(rhs))
            case .or(let lhs, let rhs): return .or(replace(lhs), replace(rhs))
            case .not(let child): return .not(replace(child))
            default: return node
            }
        }
        return Self(root: replace(root))
    }

    /// Canonical source text for forwarding a resolved query through the
    /// ordinary search request and its cursor/observation identity.
    public var serialized: String {
        func day(_ value: Date) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let parts = calendar.dateComponents([.year, .month, .day], from: value)
            return String(format: "%04d-%02d-%02d", parts.year ?? 1, parts.month ?? 1, parts.day ?? 1)
        }
        func render(_ node: Node, inside parentPrecedence: Int = 0) -> String {
            let text: String
            let precedence: Int
            switch node {
            case .all: text = "type:all"; precedence = 4
            case .noMatch: text = "NOT type:all"; precedence = 3
            case .text(let value): text = Self.quoted(value); precedence = 4
            case .application(let name): text = "source:" + Self.quoted(name); precedence = 4
            case .sourceID(let id): text = "source-id:" + Self.quoted(id); precedence = 4
            case .type(let type): text = "type:" + type.rawValue; precedence = 4
            case .pinned: text = "is:pinned"; precedence = 4
            case .copiedDate(let from, let until):
                precedence = 4
                if let from, let until {
                    text = "date:" + day(from) + ".." + day(until.addingTimeInterval(-86_400))
                } else if let from { text = "after:" + day(from) }
                else if let until { text = "before:" + day(until) }
                else { text = "type:all" }
            case .and(let lhs, let rhs):
                precedence = 2
                text = render(lhs, inside: 2) + " AND " + render(rhs, inside: 2)
            case .or(let lhs, let rhs):
                precedence = 1
                text = render(lhs, inside: 1) + " OR " + render(rhs, inside: 1)
            case .not(let child):
                precedence = 3
                text = "NOT " + render(child, inside: 3)
            }
            return precedence < parentPrecedence ? "(" + text + ")" : text
        }
        return render(root)
    }
}

private struct ExpressionToken {
    enum Kind: Equatable {
        case atom(String, field: String?)
        case and, or, not, open, close
    }
    let kind: Kind
    let offset: Int
}

private struct ExpressionParser {
    typealias Node = HistorySearchExpression.Node
    typealias Failure = HistorySearchExpressionError
    let tokens: [ExpressionToken]
    let endOffset: Int
    var index = 0

    init(_ text: String) throws(HistorySearchExpressionError) {
        let characters = Array(text)
        endOffset = characters.count
        var scanned: [ExpressionToken] = []
        var cursor = 0
        while cursor < characters.count {
            if characters[cursor].isWhitespace { cursor += 1; continue }
            let start = cursor
            let kind: ExpressionToken.Kind
            if characters[cursor] == "(" {
                kind = .open
                cursor += 1
            } else if characters[cursor] == ")" {
                kind = .close
                cursor += 1
            } else {
                var value = ""
                var field: String?
                var wasQuoted = false
                while cursor < characters.count,
                      !characters[cursor].isWhitespace,
                      characters[cursor] != "(", characters[cursor] != ")" {
                    if characters[cursor] == "\"" {
                        wasQuoted = true
                        let quoteStart = cursor
                        cursor += 1
                        while cursor < characters.count, characters[cursor] != "\"" {
                            if characters[cursor] == "\\", cursor + 1 < characters.count,
                               characters[cursor + 1] == "\\" || characters[cursor + 1] == "\"" {
                                cursor += 1
                            }
                            value.append(characters[cursor])
                            cursor += 1
                        }
                        guard cursor < characters.count else {
                            throw Failure(reason: .unclosedQuote, offset: quoteStart)
                        }
                        cursor += 1
                    } else if characters[cursor] == ":", !wasQuoted, field == nil,
                              ["app", "source", "source-id", "date", "before", "after", "type", "is"].contains(value.lowercased()) {
                        field = value.lowercased()
                        value = ""
                        cursor += 1
                    } else {
                        value.append(characters[cursor])
                        cursor += 1
                    }
                }
                if !wasQuoted, field == nil {
                    switch value.uppercased() {
                    case "AND": kind = .and
                    case "OR": kind = .or
                    case "NOT": kind = .not
                    default: kind = .atom(value, field: nil)
                    }
                } else {
                    kind = .atom(value, field: field)
                }
            }
            guard scanned.count < 128 else {
                throw Failure(reason: .tooManyTerms, offset: start)
            }
            scanned.append(ExpressionToken(kind: kind, offset: start))
        }
        tokens = scanned
    }

    mutating func parse() throws(HistorySearchExpressionError) -> Node {
        guard !tokens.isEmpty else { return .all }
        let result = try parseOr(depth: 0)
        guard index == tokens.count else { throw failure(.unexpectedToken) }
        return result
    }

    private mutating func parseOr(depth: Int) throws(HistorySearchExpressionError) -> Node {
        var result = try parseAnd(depth: depth)
        while consume(.or) { result = .or(result, try parseAnd(depth: depth)) }
        return result
    }

    private mutating func parseAnd(depth: Int) throws(HistorySearchExpressionError) -> Node {
        var result = try parseUnary(depth: depth)
        while index < tokens.count {
            if consume(.and) {
                result = .and(result, try parseUnary(depth: depth))
            } else {
                switch tokens[index].kind {
                case .atom, .open, .not:
                    result = .and(result, try parseUnary(depth: depth))
                default: return result
                }
            }
        }
        return result
    }

    private mutating func parseUnary(depth: Int) throws(HistorySearchExpressionError) -> Node {
        guard depth <= 16 else { throw failure(.tooDeep) }
        guard index < tokens.count else { throw failure(.expectedTerm) }
        if consume(.not) { return .not(try parseUnary(depth: depth + 1)) }
        if consume(.open) {
            let result = try parseOr(depth: depth + 1)
            guard consume(.close) else { throw failure(.unclosedParenthesis) }
            return result
        }
        let token = tokens[index]
        guard case .atom(let value, let field) = token.kind else {
            throw failure(.expectedTerm)
        }
        index += 1
        guard !value.isEmpty else { throw Failure(reason: .missingValue, offset: token.offset) }
        switch field {
        case nil: return .text(value)
        case "app", "source": return .application(value)
        case "source-id": return .sourceID(value)
        case "is":
            guard value.lowercased() == "pinned" else {
                throw Failure(reason: .invalidFlag, offset: token.offset)
            }
            return .pinned
        case "type":
            let typeValue = ["image": "images", "link": "links" ][value.lowercased()] ?? value.lowercased()
            guard let type = HistoryContentType(rawValue: typeValue) else {
                throw Failure(reason: .invalidType, offset: token.offset)
            }
            return .type(type)
        case "before": return .copiedDate(from: nil, until: try date(value, offset: token.offset))
        case "after": return .copiedDate(from: try date(value, offset: token.offset), until: nil)
        case "date":
            let bounds = value.components(separatedBy: "..")
            guard bounds.count == 1 || bounds.count == 2 else {
                throw Failure(reason: .invalidDate, offset: token.offset)
            }
            let start = try date(bounds[0], offset: token.offset)
            let end = try date(bounds.last ?? bounds[0], offset: token.offset)
            guard end >= start else { throw Failure(reason: .invalidDateRange, offset: token.offset) }
            return .copiedDate(from: start, until: end.addingTimeInterval(86_400))
        default: return .text(value)
        }
    }

    private func date(_ value: String, offset: Int) throws(HistorySearchExpressionError) -> Date {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }),
              let year = Int(value.prefix(4)), year >= 1,
              let month = Int(value.dropFirst(5).prefix(2)),
              let day = Int(value.suffix(2)) else { throw Failure(reason: .invalidDate, offset: offset) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let result = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: result) == components else {
            throw Failure(reason: .invalidDate, offset: offset)
        }
        return result
    }

    private mutating func consume(_ kind: ExpressionToken.Kind) -> Bool {
        guard index < tokens.count, tokens[index].kind == kind else { return false }
        index += 1
        return true
    }

    private func failure(_ reason: Failure.Reason) -> Failure {
        Failure(reason: reason, offset: index < tokens.count ? tokens[index].offset : endOffset)
    }
}
