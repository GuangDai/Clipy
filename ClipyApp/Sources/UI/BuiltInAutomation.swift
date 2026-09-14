import Foundation

/// App-local text transforms. Only explicit editor Save authors a revision;
/// these values neither retain clipboard content nor call the History writer.
struct BuiltInAutomationStep: Identifiable, Codable, Equatable, Sendable {
    enum Operation: String, CaseIterable, Codable, Sendable {
        case trim, trimLines, removeEmptyLines, uniqueLines, sortLines
        case uppercase, lowercase, prettyJSON, compactJSON, replace

        var title: String {
            switch self {
            case .trim: "Trim surrounding whitespace"
            case .trimLines: "Trim each line"
            case .removeEmptyLines: "Remove empty lines"
            case .uniqueLines: "Remove duplicate lines"
            case .sortLines: "Sort lines"
            case .uppercase: "Uppercase"
            case .lowercase: "Lowercase"
            case .prettyJSON: "Format JSON"
            case .compactJSON: "Compact JSON"
            case .replace: "Find and replace"
            }
        }
    }

    var id = UUID()
    var operation: Operation
    var enabled = true
    var find = ""
    var replacement = ""

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.operation == rhs.operation && lhs.enabled == rhs.enabled
            && lhs.find.utf8.elementsEqual(rhs.find.utf8)
            && lhs.replacement.utf8.elementsEqual(rhs.replacement.utf8)
    }
}

struct BuiltInAutomationWorkflow: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var steps: [BuiltInAutomationStep]

    static var presets: [Self] {
        [
            Self(name: "Clean up text", steps: [.init(operation: .trimLines), .init(operation: .removeEmptyLines)]),
            Self(name: "Unique sorted lines", steps: [.init(operation: .trimLines), .init(operation: .removeEmptyLines), .init(operation: .uniqueLines), .init(operation: .sortLines)]),
            Self(name: "Format JSON", steps: [.init(operation: .prettyJSON)])
        ]
    }
}

enum BuiltInAutomationFailure: Error, Equatable {
    case textTooLarge, tooManySteps, tooManyLines, emptyFind, invalidJSON
    case invalidWorkflow, unreadableWorkflows, workflowLimit, definitionTooLarge

    var message: String {
        switch self {
        case .textTooLarge: "Text exceeds the 1 MiB workflow limit. Shorten the text or reduce replacement expansion."
        case .tooManySteps: "Use no more than 32 steps in one workflow."
        case .tooManyLines: "Line operations support up to 50,000 lines. Shorten the text before running this workflow."
        case .emptyFind: "Enter text to find, or disable the replacement step."
        case .invalidJSON: "This text is not valid JSON. Correct the source text or disable the JSON step, then preview again."
        case .invalidWorkflow: "Give this workflow a name and at least one step."
        case .unreadableWorkflows: "Saved workflows could not be read. Your saved data is unchanged. Reset saved workflows to start again."
        case .workflowLimit: "You can save up to 50 workflows. Remove one before saving another."
        case .definitionTooLarge: "Shorten the workflow name to 200 UTF-8 bytes and each find or replacement field to 16 KiB."
        }
    }
}

enum BuiltInAutomation {
    static let maximumBytes = 1_048_576
    static let maximumSteps = 32

    static func run(_ source: String, steps: [BuiltInAutomationStep]) throws -> String {
        try Task.checkCancellation()
        try checkSize(source)
        guard steps.count <= maximumSteps else { throw BuiltInAutomationFailure.tooManySteps }
        var value = source
        for step in steps where step.enabled {
            try Task.checkCancellation()
            switch step.operation {
            case .trim:
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            case .uppercase:
                value = value.uppercased()
            case .lowercase:
                value = value.lowercased()
            case .replace:
                value = try replacing(value, find: step.find, replacement: step.replacement)
            case .prettyJSON, .compactJSON:
                value = try formatJSON(value, pretty: step.operation == .prettyJSON)
            case .trimLines, .removeEmptyLines, .uniqueLines, .sortLines:
                var lines = value.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
                guard lines.count <= 50_000 else { throw BuiltInAutomationFailure.tooManyLines }
                switch step.operation {
                case .trimLines:
                    lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
                case .removeEmptyLines:
                    lines.removeAll { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                case .uniqueLines:
                    // Exact UTF-8 keeps canonically equivalent but byte-distinct
                    // lines distinct, just as History content does (02 §5.4).
                    var seen = Set<Data>()
                    lines = lines.filter { seen.insert(Data($0.utf8)).inserted }
                case .sortLines:
                    lines.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
                default: break
                }
                value = lines.joined(separator: "\n")
            }
            try checkSize(value)
            try Task.checkCancellation()
        }
        return value
    }

    private static func checkSize(_ text: String) throws {
        guard text.utf8.count <= maximumBytes else { throw BuiltInAutomationFailure.textTooLarge }
    }

    private static func replacing(_ source: String, find: String, replacement: String) throws -> String {
        guard !find.isEmpty else { throw BuiltInAutomationFailure.emptyFind }
        try checkSize(find)
        try checkSize(replacement)
        var result = ""
        var byteCount = 0
        var cursor = source.startIndex
        while let range = source.range(of: find, options: .literal, range: cursor..<source.endIndex) {
            try Task.checkCancellation()
            let prefix = source[cursor..<range.lowerBound]
            byteCount += prefix.utf8.count + replacement.utf8.count
            guard byteCount <= maximumBytes else { throw BuiltInAutomationFailure.textTooLarge }
            result.append(contentsOf: prefix)
            result.append(replacement)
            cursor = range.upperBound
        }
        let tail = source[cursor...]
        guard byteCount + tail.utf8.count <= maximumBytes else { throw BuiltInAutomationFailure.textTooLarge }
        result.append(contentsOf: tail)
        return result
    }

    /// Validate first, then format lexical bytes. JSONSerialization's writer
    /// would round some numbers and collapse repeated keys; formatting must
    /// preserve their original spelling and all string escape sequences.
    private static func formatJSON(_ source: String, pretty: Bool) throws -> String {
        let data = Data(source.utf8)
        do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw BuiltInAutomationFailure.invalidJSON }
        let input = Array(data)
        var output = [UInt8]()
        var inString = false
        var escaped = false
        var depth = 0
        var previous: UInt8?
        func whitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
        func newline() { output.append(10); output.append(contentsOf: repeatElement(32, count: depth * 2)) }
        for (index, byte) in input.enumerated() {
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            if inString {
                output.append(byte)
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 {
                inString = true
                output.append(byte)
            } else if !whitespace(byte) {
                if byte == 123 || byte == 91 {
                    output.append(byte)
                    depth += 1
                    if pretty {
                        let next = input[(index + 1)...].first { !whitespace($0) }
                        if next != 125 && next != 93 { newline() }
                    }
                } else if byte == 125 || byte == 93 {
                    depth -= 1
                    if pretty && previous != 123 && previous != 91 { newline() }
                    output.append(byte)
                } else if byte == 44 {
                    output.append(byte)
                    if pretty { newline() }
                } else if byte == 58 {
                    output.append(byte)
                    if pretty { output.append(32) }
                } else { output.append(byte) }
            }
            if !whitespace(byte) || inString { previous = byte }
            guard output.count <= maximumBytes else { throw BuiltInAutomationFailure.textTooLarge }
        }
        return String(decoding: output, as: UTF8.self)
    }
}
