import Foundation

/// App-local text transforms. Only explicit editor Save authors a revision;
/// these values neither retain clipboard content nor call the History writer.
struct BuiltInAutomationStep: Identifiable, Codable, Equatable, Sendable {
    enum Operation: String, CaseIterable, Codable, Sendable {
        case trim, trimLines, removeEmptyLines, uniqueLines, sortLines
        case uppercase, lowercase, prettyJSON, compactJSON, replace
        case requireText, requireImage, containsText, matchesRegex, recognizeText, regexReplace, regexExtract, notify, conditional

        var title: String {
            switch self {
            case .conditional: "If"
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
            case .requireText: "Require text"
            case .requireImage: "Require image"
            case .recognizeText: "Recognize text (Apple OCR)"
            case .regexReplace: "Regular expression replacement"
            case .regexExtract: "Extract regular expression matches"
            case .notify: "Notify when conditions match"
            case .containsText: "Text contains"
            case .matchesRegex: "Text matches regular expression"
            }
        }
    }

    enum Condition: String, CaseIterable, Codable, Sendable {
        case isText, isImage, containsText, matchesRegex

        var title: String {
            switch self {
            case .isText: "Input is text"
            case .isImage: "Input is an image"
            case .containsText: "Text contains"
            case .matchesRegex: "Text matches regular expression"
            }
        }
    }

    var id = UUID()
    var operation: Operation
    var enabled = true
    var find = ""
    var replacement = ""
    var condition: Condition = .containsText
    var thenSteps: [Self] = []
    var otherwiseSteps: [Self] = []

    private enum CodingKeys: String, CodingKey {
        case id, operation, enabled, find, replacement, condition, thenSteps, otherwiseSteps
    }

    init(id: UUID = UUID(), operation: Operation, enabled: Bool = true, find: String = "",
         replacement: String = "", condition: Condition = .containsText,
         thenSteps: [Self] = [], otherwiseSteps: [Self] = []) {
        self.id = id
        self.operation = operation
        self.enabled = enabled
        self.find = find
        self.replacement = replacement
        self.condition = condition
        self.thenSteps = thenSteps
        self.otherwiseSteps = otherwiseSteps
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        operation = try values.decode(Operation.self, forKey: .operation)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        find = try values.decode(String.self, forKey: .find)
        replacement = try values.decode(String.self, forKey: .replacement)
        condition = try values.decodeIfPresent(Condition.self, forKey: .condition) ?? .containsText
        thenSteps = try values.decodeIfPresent([Self].self, forKey: .thenSteps) ?? []
        otherwiseSteps = try values.decodeIfPresent([Self].self, forKey: .otherwiseSteps) ?? []
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.operation == rhs.operation && lhs.enabled == rhs.enabled
            && lhs.find.utf8.elementsEqual(rhs.find.utf8)
            && lhs.replacement.utf8.elementsEqual(rhs.replacement.utf8)
            && lhs.condition == rhs.condition && lhs.thenSteps == rhs.thenSteps
            && lhs.otherwiseSteps == rhs.otherwiseSteps
    }
}

struct BuiltInAutomationWorkflow: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var steps: [BuiltInAutomationStep]
    var trigger: BuiltInAutomationTrigger = .manual
    var scope = BuiltInAutomationScope()

    private enum CodingKeys: String, CodingKey { case id, name, steps, trigger, scope }

    init(id: UUID = UUID(), name: String, steps: [BuiltInAutomationStep],
         trigger: BuiltInAutomationTrigger = .manual, scope: BuiltInAutomationScope = .init()) {
        self.id = id
        self.name = name
        self.steps = steps
        self.trigger = trigger
        self.scope = scope
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        steps = try values.decode([BuiltInAutomationStep].self, forKey: .steps)
        trigger = try values.decodeIfPresent(BuiltInAutomationTrigger.self, forKey: .trigger) ?? .manual
        scope = try values.decodeIfPresent(BuiltInAutomationScope.self, forKey: .scope) ?? .init()
    }

    static var presets: [Self] {
        [
            Self(name: "Clean up text", steps: [.init(operation: .trimLines), .init(operation: .removeEmptyLines)]),
            Self(name: "Unique sorted lines", steps: [.init(operation: .trimLines), .init(operation: .removeEmptyLines), .init(operation: .uniqueLines), .init(operation: .sortLines)]),
            Self(name: "Format JSON", steps: [.init(operation: .prettyJSON)]),
            Self(name: "Read text from image", steps: [.init(operation: .conditional, condition: .isImage, thenSteps: [.init(operation: .recognizeText), .init(operation: .trim)])], scope: .init(source: .clipboard)),
            Self(name: "Extract email addresses", steps: [.init(operation: .conditional, condition: .isText, thenSteps: [.init(operation: .regexExtract, find: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#), .init(operation: .uniqueLines)])]),
            Self(name: "Notify about TODO", steps: [.init(operation: .conditional, find: "TODO", thenSteps: [.init(operation: .notify)])])
        ]
    }
}

enum BuiltInAutomationFailure: Error, Equatable {
    case textTooLarge, tooManySteps, tooManyLines, emptyFind, invalidJSON
    case invalidWorkflow, unreadableWorkflows, workflowLimit, definitionTooLarge
    case requiresText, requiresImage, invalidImage, imageTooLarge, noRecognizedText, recognitionFailed
    case invalidRegex, regexEngineFailed, regexTimedOut, notificationDenied, notificationFailed, clipboardUnavailable
    case conditionNotMet, notificationNeedsCondition, invalidScope, historyUnavailable, executionQueueFull

    var message: String {
        switch self {
        case .executionQueueFull: "The workflow queue is full. Wait for running workflows to finish, then try again."
        case .conditionNotMet: "Conditions did not match. No notification was sent."
        case .notificationNeedsCondition: "Add an enabled type or text condition before using notifications."
        case .invalidScope: "Choose a valid time range and between 1 and 1,000 history items."
        case .historyUnavailable: "History could not be read. Reopen the workflow and try again."
        case .requiresText: "This step requires text. Add OCR before text steps when the input is an image."
        case .requiresImage: "This step requires an image. Choose an image input or disable this step."
        case .invalidImage: "This image could not be read. Choose a PNG, JPEG, TIFF or HEIC image."
        case .imageTooLarge: "Use an image no larger than 32 MiB and 16 million pixels."
        case .noRecognizedText: "Apple OCR found no text in this image. Try a clearer image."
        case .recognitionFailed: "Apple OCR could not read this image. Try another image."
        case .invalidRegex: "Enter a valid regular expression. Replacement templates support $1, $2 and other capture groups."
        case .regexEngineFailed: "The regular expression engine could not finish. Simplify the pattern or shorten the input."
        case .regexTimedOut: "The regular expression took too long. Simplify the pattern and try again."
        case .notificationDenied: "The workflow finished, but notifications are disabled. Allow Clipy in System Settings > Notifications."
        case .notificationFailed: "The workflow finished, but its notification could not be sent."
        case .clipboardUnavailable: "The clipboard does not contain the selected input type, or it could not be written."
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
        try validateStepTree(steps)
        var value = source
        for step in steps where step.enabled {
            try Task.checkCancellation()
            switch step.operation {
            case .conditional:
                let matches = try conditionMatches(.text(value), step: step)
                value = try run(value, steps: matches ? step.thenSteps : step.otherwiseSteps)
            case .requireText, .notify:
                break
            case .containsText:
                guard !step.find.isEmpty, value.range(of: step.find, options: .literal) != nil else {
                    throw BuiltInAutomationFailure.conditionNotMet
                }
            case .matchesRegex:
                guard try matchesRegularExpression(value, pattern: step.find) else {
                    throw BuiltInAutomationFailure.conditionNotMet
                }
            case .requireImage, .recognizeText:
                throw BuiltInAutomationFailure.requiresImage
            case .regexReplace, .regexExtract:
                value = try regularExpression(value, step: step)
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
                // Bound splitting before allocating owned line strings: a
                // valid 1 MiB input can contain over a million empty lines.
                let parts = value.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .split(separator: "\n", maxSplits: 50_000, omittingEmptySubsequences: false)
                guard parts.count <= 50_000 else { throw BuiltInAutomationFailure.tooManyLines }
                var lines = parts.map(String.init)
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

    /// The existing 32-step product limit includes both branches, disabled
    /// steps and every nesting level, so execution and persistence stay bounded.
    static func validateStepTree(_ steps: [BuiltInAutomationStep]) throws {
        var remaining = maximumSteps
        var ids = Set<UUID>()
        func visit(_ children: [BuiltInAutomationStep]) throws {
            for step in children {
                remaining -= 1
                guard remaining >= 0 else { throw BuiltInAutomationFailure.tooManySteps }
                guard ids.insert(step.id).inserted else { throw BuiltInAutomationFailure.invalidWorkflow }
                try visit(step.thenSteps)
                try visit(step.otherwiseSteps)
            }
        }
        try visit(steps)
    }

    static func conditionMatches(_ input: BuiltInAutomationInput, step: BuiltInAutomationStep) throws -> Bool {
        switch step.condition {
        case .isText: return input.text != nil
        case .isImage: if case .image = input { return true }; return false
        case .containsText: return !step.find.isEmpty && input.text?.range(of: step.find, options: .literal) != nil
        case .matchesRegex:
            guard let text = input.text else { return false }
            return try matchesRegularExpression(text, pattern: step.find)
        }
    }

    static func prefersImage(_ steps: [BuiltInAutomationStep]) -> Bool {
        steps.contains { step in
            step.enabled && ([.requireImage, .recognizeText].contains(step.operation)
                || (step.operation == .conditional && (step.condition == .isImage
                    || prefersImage(step.thenSteps) || prefersImage(step.otherwiseSteps))))
        }
    }

    static func checkSize(_ text: String) throws {
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
