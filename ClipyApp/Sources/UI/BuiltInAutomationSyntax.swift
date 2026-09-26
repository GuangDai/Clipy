import Foundation

/// Clipy's editable notation for the existing workflow tree. This is a small
/// indentation-based rule language; parsing never invokes Python or an action.
struct BuiltInAutomationSyntaxError: Error, Equatable, Sendable {
    enum Reason: String, Sendable {
        case sourceTooLarge, parameterTooLarge, tabsInIndentation, unexpectedIndentation
        case expectedIndentedBlock, unexpectedElse, expectedColon, unknownAction, unknownCondition
        case expectedCall, expectedString, wrongArgumentCount, unterminatedString, invalidEscape
        case unexpectedToken, expectedCondition, unclosedParenthesis, unrepresentableStep
    }

    let reason: Reason
    let line: Int
    let column: Int

    var message: String {
        switch reason {
        case .sourceTooLarge: "Keep rule text within 1 MiB of UTF-8."
        case .parameterTooLarge: "Keep each rule argument within 16 KiB of UTF-8."
        case .tabsInIndentation: "Use spaces rather than tabs for indentation."
        case .unexpectedIndentation: "Align this line with an existing indentation level."
        case .expectedIndentedBlock: "Indent the following actions, or write an indented pass."
        case .unexpectedElse: "Place else or elif immediately after its matching if block."
        case .expectedColon: "End this block heading with a colon."
        case .unknownAction: "Use a supported Clipy action name."
        case .unknownCondition: "Use is_text, is_image, contains, or matches as the condition."
        case .expectedCall: "Write a function call with parentheses."
        case .expectedString: "Put each argument in single or double quotes."
        case .wrongArgumentCount: "Check the number of arguments for this action or condition."
        case .unterminatedString: "Close the quoted argument on the same line."
        case .invalidEscape: "Use a supported string escape, or a raw string for a regular expression."
        case .unexpectedToken: "Remove the unexpected text or add the missing operator."
        case .expectedCondition: "Enter a condition after the keyword or operator."
        case .unclosedParenthesis: "Close the parenthesized condition."
        case .unrepresentableStep: "This definition contains inactive branches that rule text cannot preserve. Use the visual editor."
        }
    }
}

enum BuiltInAutomationSyntax {
    static let maximumSourceBytes = BuiltInAutomation.maximumBytes
    private static let maximumArgumentBytes = 16_384
    private typealias Step = BuiltInAutomationStep
    private typealias Predicate = BuiltInAutomationPredicate
    private typealias Failure = BuiltInAutomationSyntaxError

    /// Successful parsing creates one complete replacement tree. Callers keep
    /// the prior draft on error; generated step IDs are independent of content.
    static func parse(_ source: String) throws -> [BuiltInAutomationStep] {
        try Task.checkCancellation()
        guard source.utf8.count <= maximumSourceBytes else {
            throw Failure(reason: .sourceTooLarge, line: 1, column: 1)
        }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var parser = RuleParser()
        for (offset, line) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            try Task.checkCancellation()
            try parser.accept(String(line), number: offset + 1)
        }
        return try parser.finish()
    }

    /// Iterative tree traversal keeps nested definitions off the call stack.
    /// Formatting is canonical; comments and UUIDs are not executable rules.
    static func render(_ steps: [BuiltInAutomationStep]) throws -> String {
        enum Work {
            case block([Step], Int)
            case step(Step, Int, Bool)
            case line(String, Int)
        }
        var work: [Work] = [.block(steps, 0)]
        var output = ""
        var line = 1
        while let next = work.popLast() {
            try Task.checkCancellation()
            switch next {
            case .block(let children, let depth):
                if children.isEmpty { work.append(.line("pass", depth)) }
                else { for child in children.reversed() { work.append(.step(child, depth, false)) } }
            case .line(let text, let depth):
                guard depth <= maximumSourceBytes / 4,
                      output.utf8.count + depth * 4 + text.utf8.count + 1 <= maximumSourceBytes else {
                    throw Failure(reason: .sourceTooLarge, line: line, column: 1)
                }
                output += String(repeating: " ", count: depth * 4) + text + "\n"
                line += 1
            case .step(let step, let depth, let insideDisabled):
                if !step.enabled && !insideDisabled {
                    work.append(.step(step, depth + 1, true))
                    work.append(.line("disabled:", depth))
                    continue
                }
                if step.operation == .conditional {
                    if !step.otherwiseSteps.isEmpty {
                        work.append(.block(step.otherwiseSteps, depth + 1))
                        work.append(.line("else:", depth))
                    }
                    work.append(.block(step.thenSteps, depth + 1))
                    work.append(.line("if " + (try renderPredicate(step.effectivePredicate)) + ":", depth))
                } else {
                    guard step.thenSteps.isEmpty, step.otherwiseSteps.isEmpty else {
                        throw Failure(reason: .unrepresentableStep, line: line, column: depth * 4 + 1)
                    }
                    let name = actionName(step.operation)
                    let arguments: [String]
                    switch step.operation {
                    case .replace, .regexReplace: arguments = [step.find, step.replacement]
                    case .containsText, .matchesRegex, .regexExtract: arguments = [step.find]
                    default: arguments = []
                    }
                    for argument in arguments where argument.utf8.count > maximumArgumentBytes {
                        throw Failure(reason: .parameterTooLarge, line: line, column: depth * 4 + 1)
                    }
                    work.append(.line(name + "(" + arguments.map(quoted).joined(separator: ", ") + ")", depth))
                }
            }
        }
        return output
    }

    private static func actionName(_ operation: Step.Operation) -> String {
        switch operation {
        case .trim: "trim"
        case .trimLines: "trim_lines"
        case .removeEmptyLines: "remove_empty_lines"
        case .uniqueLines: "unique_lines"
        case .sortLines: "sort_lines"
        case .uppercase: "uppercase"
        case .lowercase: "lowercase"
        case .prettyJSON: "pretty_json"
        case .compactJSON: "compact_json"
        case .replace: "replace"
        case .requireText: "require_text"
        case .requireImage: "require_image"
        case .containsText: "require_contains"
        case .matchesRegex: "require_matches"
        case .recognizeText: "recognize_text"
        case .regexReplace: "regex_replace"
        case .regexExtract: "regex_extract"
        case .notify: "notify"
        case .conditional: "if"
        }
    }

    private static func quoted(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: output += "\\\""
            case 92: output += "\\\\"
            case 10: output += "\\n"
            case 13: output += "\\r"
            case 9: output += "\\t"
            case 0..<32, 127: output += String(format: "\\u%04X", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }

    private static func renderPredicate(_ predicate: Predicate) throws -> String {
        enum Work { case value(Predicate), text(String) }
        var pending: [Work] = [.value(predicate)]
        var result = ""
        while let next = pending.popLast() {
            try Task.checkCancellation()
            switch next {
            case .text(let text): result += text
            case .value(let value):
                switch value {
                case .match(let condition, let argument):
                    guard argument.utf8.count <= maximumArgumentBytes else {
                        throw Failure(reason: .parameterTooLarge, line: 1, column: 1)
                    }
                    switch condition {
                    case .isText: result += "is_text()"
                    case .isImage: result += "is_image()"
                    case .containsText: result += "contains(" + quoted(argument) + ")"
                    case .matchesRegex: result += "matches(" + quoted(argument) + ")"
                    }
                case .not(let child):
                    result += "not ("
                    pending.append(.text(")"))
                    pending.append(.value(child))
                case .all(let children), .any(let children):
                    guard !children.isEmpty else {
                        throw Failure(reason: .unrepresentableStep, line: 1, column: 1)
                    }
                    let separator: String
                    if case .all = value { separator = " and " } else { separator = " or " }
                    result += "("
                    pending.append(.text(")"))
                    for index in children.indices.reversed() {
                        pending.append(.value(children[index]))
                        if index > 0 { pending.append(.text(separator)) }
                    }
                }
            }
            guard result.utf8.count <= maximumSourceBytes else {
                throw Failure(reason: .sourceTooLarge, line: 1, column: 1)
            }
        }
        return result
    }

    private struct Token {
        enum Kind: Equatable { case name(String), string(String), open, close, comma, colon }
        let kind: Kind
        let column: Int
        let endColumn: Int
    }

    private struct Lexer {
        let characters: [UnicodeScalar]
        let columns: [Int]
        let endColumn: Int
        let line: Int
        var index = 0

        init(source: String, line: Int, baseColumn: Int) throws {
            self.line = line
            characters = Array(source.unicodeScalars)
            // Syntax punctuation is scalar-based: a combining mark directly
            // after an opening quote may share that quote's Character. Keep
            // a separate mapping for the editor's grapheme-based diagnostics.
            var mapped: [Int] = []
            mapped.reserveCapacity(characters.count)
            var column = baseColumn
            for character in source {
                if column.isMultiple(of: 256) { try Task.checkCancellation() }
                mapped.append(contentsOf: repeatElement(column, count: character.unicodeScalars.count))
                column += 1
            }
            columns = mapped
            endColumn = column
        }

        mutating func tokens() throws -> [Token] {
            var result: [Token] = []
            while index < characters.count {
                try Task.checkCancellation()
                let character = characters[index]
                if CharacterSet.whitespaces.contains(character) { index += 1; continue }
                if character == "#" { break }
                let column = self.column(at: index)
                let kind: Token.Kind
                if character == "\"" || character == "'" {
                    kind = .string(try string(raw: false))
                } else if (character == "r" || character == "R"), index + 1 < characters.count,
                          characters[index + 1] == "\"" || characters[index + 1] == "'" {
                    index += 1
                    kind = .string(try string(raw: true))
                } else if isNameStart(character) || (48...57).contains(character.value) {
                    var name = ""
                    repeat { name.unicodeScalars.append(characters[index]); index += 1 }
                    while index < characters.count && (isNameStart(characters[index]) || (48...57).contains(characters[index].value))
                    kind = .name(name)
                } else {
                    switch character {
                    case "(": kind = .open
                    case ")": kind = .close
                    case ",": kind = .comma
                    case ":": kind = .colon
                    default: throw failure(.unexpectedToken, at: index)
                    }
                    index += 1
                }
                result.append(Token(kind: kind, column: column, endColumn: self.column(at: index)))
            }
            return result
        }

        private func isNameStart(_ character: UnicodeScalar) -> Bool {
            character == "_" || (65...90).contains(character.value) || (97...122).contains(character.value)
        }

        private mutating func string(raw: Bool) throws -> String {
            let start = index
            let quote = characters[index]
            index += 1
            var value = ""
            while index < characters.count {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let character = characters[index]
                if character == quote { index += 1; return value }
                if character == "\\" {
                    let escapeStart = index
                    index += 1
                    guard index < characters.count else { throw failure(.unterminatedString, at: start) }
                    if raw {
                        value.append("\\")
                        value.unicodeScalars.append(characters[index])
                        index += 1
                    } else {
                        let escaped = characters[index]
                        index += 1
                        switch escaped {
                        case "\\", "\"", "'": value.unicodeScalars.append(escaped)
                        case "n": value.append("\n")
                        case "r": value.append("\r")
                        case "t": value.append("\t")
                        case "a": value.append("\u{7}")
                        case "b": value.append("\u{8}")
                        case "f": value.append("\u{c}")
                        case "v": value.append("\u{b}")
                        case "x", "u", "U":
                            let width = escaped == "x" ? 2 : (escaped == "u" ? 4 : 8)
                            guard index + width <= characters.count else { throw failure(.invalidEscape, at: escapeStart) }
                            var digits = ""
                            for digit in characters[index..<(index + width)] { digits.unicodeScalars.append(digit) }
                            guard digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                                  let number = UInt32(digits, radix: 16), let scalar = UnicodeScalar(number) else {
                                throw failure(.invalidEscape, at: escapeStart)
                            }
                            value.unicodeScalars.append(scalar)
                            index += width
                        default: throw failure(.invalidEscape, at: escapeStart)
                        }
                    }
                } else { value.unicodeScalars.append(character); index += 1 }
                guard value.utf8.count <= maximumArgumentBytes else { throw failure(.parameterTooLarge, at: start) }
            }
            throw failure(.unterminatedString, at: start)
        }

        private func failure(_ reason: Failure.Reason, at index: Int) -> Failure {
            Failure(reason: reason, line: line, column: column(at: index))
        }

        private func column(at index: Int) -> Int {
            index < columns.count ? columns[index] : endColumn
        }
    }

    private struct RuleParser {
        enum Destination { case root, then(Int), otherwise(Int) }
        struct Node {
            var step: Step
            var thenIDs: [Int] = []
            var otherwiseIDs: [Int] = []
        }
        struct Frame {
            let indentation: Int
            let destination: Destination
            let enabled: Bool
            var availableElse: Int? = nil
        }
        struct Pending {
            let destination: Destination
            let enabled: Bool
            let line: Int
        }

        var nodes: [Node] = []
        var roots: [Int] = []
        var frames = [Frame(indentation: 0, destination: .root, enabled: true)]
        var pending: Pending?

        mutating func accept(_ source: String, number: Int) throws {
            let significant = source.drop(while: { $0 == " " || $0 == "\t" })
            if significant.isEmpty || significant.first == "#" { return }
            let characters = Array(source)
            var indentation = 0
            while indentation < characters.count, characters[indentation] == " " { indentation += 1 }
            if indentation < characters.count, characters[indentation] == "\t" {
                throw Failure(reason: .tabsInIndentation, line: number, column: indentation + 1)
            }
            var lexer = try Lexer(source: String(characters.dropFirst(indentation)), line: number,
                              baseColumn: indentation + 1)
            let tokens = try lexer.tokens()
            guard !tokens.isEmpty else { return }
            if let waiting = pending {
                guard indentation > frames[frames.count - 1].indentation else {
                    throw Failure(reason: .expectedIndentedBlock, line: number, column: indentation + 1)
                }
                frames.append(Frame(indentation: indentation, destination: waiting.destination, enabled: waiting.enabled))
                pending = nil
            } else {
                while frames.count > 1, indentation < frames[frames.count - 1].indentation { frames.removeLast() }
                guard indentation == frames[frames.count - 1].indentation else {
                    throw Failure(reason: .unexpectedIndentation, line: number, column: indentation + 1)
                }
            }
            guard case .name(let name) = tokens[0].kind else {
                throw Failure(reason: .expectedCall, line: number, column: tokens[0].column)
            }
            let frameIndex = frames.count - 1
            switch name {
            case "if":
                try requireColon(tokens, line: number, endColumn: tokens.last?.endColumn ?? characters.count + 1)
                let predicate = try parsePredicate(Array(tokens.dropFirst().dropLast()), line: number,
                                                   endColumn: tokens.last?.column ?? characters.count + 1)
                let step = Step(operation: .conditional, enabled: frames[frameIndex].enabled, predicate: predicate)
                let id = append(step, to: frames[frameIndex].destination)
                frames[frameIndex].availableElse = id
                pending = Pending(destination: .then(id), enabled: true, line: number)
            case "else":
                try requireColon(tokens, line: number, endColumn: tokens.last?.endColumn ?? characters.count + 1)
                guard tokens.count == 2, let id = frames[frameIndex].availableElse else {
                    throw Failure(reason: .unexpectedElse, line: number, column: tokens[0].column)
                }
                frames[frameIndex].availableElse = nil
                pending = Pending(destination: .otherwise(id), enabled: true, line: number)
            case "elif":
                try requireColon(tokens, line: number, endColumn: tokens.last?.endColumn ?? characters.count + 1)
                guard let previous = frames[frameIndex].availableElse else {
                    throw Failure(reason: .unexpectedElse, line: number, column: tokens[0].column)
                }
                let predicate = try parsePredicate(Array(tokens.dropFirst().dropLast()), line: number,
                                                   endColumn: tokens.last?.column ?? characters.count + 1)
                let id = append(Step(operation: .conditional, predicate: predicate), to: .otherwise(previous))
                frames[frameIndex].availableElse = id
                pending = Pending(destination: .then(id), enabled: true, line: number)
            case "disabled":
                try requireColon(tokens, line: number, endColumn: tokens.last?.endColumn ?? characters.count + 1)
                guard tokens.count == 2 else {
                    throw Failure(reason: .unexpectedToken, line: number, column: tokens[1].column)
                }
                frames[frameIndex].availableElse = nil
                pending = Pending(destination: frames[frameIndex].destination, enabled: false, line: number)
            case "pass":
                guard tokens.count == 1 else {
                    throw Failure(reason: .unexpectedToken, line: number, column: tokens[1].column)
                }
                frames[frameIndex].availableElse = nil
            default:
                var index = 0
                let call = try parseCall(tokens, index: &index, line: number)
                guard index == tokens.count else {
                    throw Failure(reason: .unexpectedToken, line: number, column: tokens[index].column)
                }
                guard let operation = Step.Operation.allCases.first(where: { $0 != .conditional && actionName($0) == call.name }) else {
                    throw Failure(reason: .unknownAction, line: number, column: tokens[0].column)
                }
                let expected: Int
                switch operation {
                case .replace, .regexReplace: expected = 2
                case .containsText, .matchesRegex, .regexExtract: expected = 1
                default: expected = 0
                }
                guard call.arguments.count == expected else {
                    throw Failure(reason: .wrongArgumentCount, line: number, column: tokens[0].column)
                }
                _ = append(Step(operation: operation, enabled: frames[frameIndex].enabled,
                                find: call.arguments.first ?? "", replacement: call.arguments.dropFirst().first ?? ""),
                           to: frames[frameIndex].destination)
                frames[frameIndex].availableElse = nil
            }
        }

        mutating func finish() throws -> [Step] {
            if let pending { throw Failure(reason: .expectedIndentedBlock, line: pending.line + 1, column: 1) }
            // Children always follow parents in this flat parse representation.
            // Assemble from the end without recursive parsing or tree mutation.
            var built: [Int: Step] = [:]
            for index in nodes.indices.reversed() {
                try Task.checkCancellation()
                var step = nodes[index].step
                step.thenSteps = nodes[index].thenIDs.compactMap { built.removeValue(forKey: $0) }
                step.otherwiseSteps = nodes[index].otherwiseIDs.compactMap { built.removeValue(forKey: $0) }
                built[index] = step
            }
            return roots.compactMap { built.removeValue(forKey: $0) }
        }

        private mutating func append(_ step: Step, to destination: Destination) -> Int {
            let index = nodes.count
            nodes.append(Node(step: step))
            switch destination {
            case .root: roots.append(index)
            case .then(let parent): nodes[parent].thenIDs.append(index)
            case .otherwise(let parent): nodes[parent].otherwiseIDs.append(index)
            }
            return index
        }

        private func requireColon(_ tokens: [Token], line: Int, endColumn: Int) throws {
            guard tokens.last?.kind == .colon else {
                throw Failure(reason: .expectedColon, line: line, column: endColumn)
            }
        }
    }

    private static func parseCall(
        _ tokens: [Token], index: inout Int, line: Int
    ) throws -> (name: String, arguments: [String]) {
        let start = index
        guard index < tokens.count, case .name(let name) = tokens[index].kind else {
            throw Failure(reason: .expectedCall, line: line, column: tokens.last?.column ?? 1)
        }
        index += 1
        guard index < tokens.count, tokens[index].kind == .open else {
            throw Failure(reason: .expectedCall, line: line, column: tokens[start].column)
        }
        index += 1
        var arguments: [String] = []
        if index < tokens.count, tokens[index].kind == .close { index += 1; return (name, arguments) }
        while index < tokens.count {
            guard case .string(let value) = tokens[index].kind else {
                throw Failure(reason: .expectedString, line: line, column: tokens[index].column)
            }
            arguments.append(value)
            index += 1
            guard index < tokens.count else { break }
            if tokens[index].kind == .close { index += 1; return (name, arguments) }
            guard tokens[index].kind == .comma else {
                throw Failure(reason: .unexpectedToken, line: line, column: tokens[index].column)
            }
            index += 1
            if index < tokens.count, tokens[index].kind == .close { index += 1; return (name, arguments) }
        }
        throw Failure(reason: .unclosedParenthesis, line: line, column: tokens[start].column)
    }

    /// A shunting-yard stack implements Python's not > and > or precedence
    /// without recursive descent, including arbitrarily nested parentheses.
    private static func parsePredicate(_ tokens: [Token], line: Int, endColumn: Int) throws -> Predicate {
        struct Operator {
            enum Kind: Equatable { case not, and, or, open }
            let kind: Kind
            let column: Int
            var precedence: Int {
                switch kind { case .not: 3; case .and: 2; case .or: 1; case .open: 0 }
            }
        }
        var operators: [Operator] = []
        var values: [Predicate] = []
        var index = 0
        var expectsValue = true

        func failure(_ reason: Failure.Reason, column: Int) -> Failure {
            Failure(reason: reason, line: line, column: column)
        }
        func reduce(_ operation: Operator, values: inout [Predicate]) throws {
            guard let right = values.popLast() else { throw failure(.expectedCondition, column: operation.column) }
            if operation.kind == .not { values.append(.not(right)); return }
            guard let left = values.popLast() else { throw failure(.expectedCondition, column: operation.column) }
            switch operation.kind {
            case .and: values.append(.all([left, right]))
            case .or: values.append(.any([left, right]))
            case .not, .open: throw failure(.unclosedParenthesis, column: operation.column)
            }
        }

        while index < tokens.count {
            try Task.checkCancellation()
            let token = tokens[index]
            if expectsValue {
                if token.kind == .name("not") {
                    operators.append(Operator(kind: .not, column: token.column))
                    index += 1
                } else if token.kind == .open {
                    operators.append(Operator(kind: .open, column: token.column))
                    index += 1
                } else {
                    guard case .name(let name) = token.kind,
                          ["is_text", "is_image", "contains", "matches"].contains(name) else {
                        throw failure(.unknownCondition, column: token.column)
                    }
                    let call = try parseCall(tokens, index: &index, line: line)
                    let condition: Step.Condition
                    switch name {
                    case "is_text": condition = .isText
                    case "is_image": condition = .isImage
                    case "contains": condition = .containsText
                    default: condition = .matchesRegex
                    }
                    let expected = (condition == .isText || condition == .isImage) ? 0 : 1
                    guard call.arguments.count == expected else { throw failure(.wrongArgumentCount, column: token.column) }
                    values.append(.match(condition, call.arguments.first ?? ""))
                    expectsValue = false
                }
            } else if token.kind == .close {
                while let last = operators.last, last.kind != .open {
                    try reduce(operators.removeLast(), values: &values)
                }
                guard operators.last?.kind == .open else { throw failure(.unexpectedToken, column: token.column) }
                operators.removeLast()
                index += 1
            } else if token.kind == .name("and") || token.kind == .name("or") {
                let operation = Operator(kind: token.kind == .name("and") ? .and : .or, column: token.column)
                while let last = operators.last, last.kind != .open, last.precedence >= operation.precedence {
                    try reduce(operators.removeLast(), values: &values)
                }
                operators.append(operation)
                expectsValue = true
                index += 1
            } else { throw failure(.unexpectedToken, column: token.column) }
        }
        guard !expectsValue else { throw failure(.expectedCondition, column: endColumn) }
        while let operation = operators.popLast() {
            guard operation.kind != .open else { throw failure(.unclosedParenthesis, column: operation.column) }
            try reduce(operation, values: &values)
        }
        guard values.count == 1, let result = values.first else { throw failure(.expectedCondition, column: endColumn) }
        return result
    }
}
