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
    var predicate: BuiltInAutomationPredicate?
    var thenSteps: [Self] = []
    var otherwiseSteps: [Self] = []

    private enum CodingKeys: String, CodingKey {
        case id, operation, enabled, find, replacement, condition, predicate, thenSteps, otherwiseSteps
    }

    init(id: UUID = UUID(), operation: Operation, enabled: Bool = true, find: String = "",
         replacement: String = "", condition: Condition = .containsText,
         predicate: BuiltInAutomationPredicate? = nil,
         thenSteps: [Self] = [], otherwiseSteps: [Self] = []) {
        self.id = id
        self.operation = operation
        self.enabled = enabled
        self.find = find
        self.replacement = replacement
        self.condition = condition
        self.predicate = predicate
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
        predicate = try values.decodeIfPresent(BuiltInAutomationPredicate.self, forKey: .predicate)
        thenSteps = try values.decodeIfPresent([Self].self, forKey: .thenSteps) ?? []
        otherwiseSteps = try values.decodeIfPresent([Self].self, forKey: .otherwiseSteps) ?? []
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        var pending = [(lhs, rhs)]
        while let (left, right) = pending.popLast() {
            guard left.id == right.id, left.operation == right.operation, left.enabled == right.enabled,
                  left.find.utf8.elementsEqual(right.find.utf8),
                  left.replacement.utf8.elementsEqual(right.replacement.utf8),
                  left.condition == right.condition, left.predicate == right.predicate,
                  left.thenSteps.count == right.thenSteps.count,
                  left.otherwiseSteps.count == right.otherwiseSteps.count else { return false }
            pending.append(contentsOf: zip(left.thenSteps, right.thenSteps))
            pending.append(contentsOf: zip(left.otherwiseSteps, right.otherwiseSteps))
        }
        return true
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
    case textTooLarge, tooManyLines, emptyFind, invalidJSON
    case invalidWorkflow, unreadableWorkflows, workflowLimit, definitionTooLarge
    case unsupportedDefinitionNesting, emptyConditionGroup
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
        case .tooManyLines: "Line operations support up to 50,000 lines. Shorten the text before running this workflow."
        case .emptyFind: "Enter text to find, or disable the replacement step."
        case .invalidJSON: "This text is not valid JSON. Correct the source text or disable the JSON step, then preview again."
        case .invalidWorkflow: "Give this workflow a name and at least one step."
        case .emptyConditionGroup: "Add a condition to each group, or remove the empty group."
        case .unreadableWorkflows: "Saved workflows could not be read. Your saved data is unchanged. Reset saved workflows to start again."
        case .workflowLimit: "You can save up to 50 workflows. Remove one before saving another."
        case .definitionTooLarge: "Shorten the workflow name to 200 UTF-8 bytes and each find or replacement field to 16 KiB."
        case .unsupportedDefinitionNesting: "This workflow is nested more deeply than the workflow file format supports. Reduce branch or condition nesting; the number of steps is not limited."
        }
    }
}

enum BuiltInAutomation {
    static let maximumBytes = 1_048_576

    static func run(_ source: String, steps: [BuiltInAutomationStep]) throws -> String {
        try Task.checkCancellation()
        try checkSize(source)
        try validateStepTree(steps)
        var value = source
        var pending = Array(steps.reversed())
        while let step = pending.popLast() {
            try Task.checkCancellation()
            guard step.enabled else { continue }
            if step.operation == .conditional {
                let matches = try conditionMatches(.text(value), step: step)
                pending.append(contentsOf: (matches ? step.thenSteps : step.otherwiseSteps).reversed())
            } else {
                value = try applyTextOperation(value, step: step)
            }
            try checkSize(value)
            try Task.checkCancellation()
        }
        return value
    }

    /// The asynchronous runner has already admitted the whole tree. Applying
    /// one operation must not recursively revalidate each step's descendants.
    static func applyTextOperation(_ source: String, step: BuiltInAutomationStep) throws -> String {
        try Task.checkCancellation()
        var value = source
        switch step.operation {
        case .conditional:
            throw BuiltInAutomationFailure.invalidWorkflow
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
        return value
    }

    /// Every node, including disabled and inactive branches, needs a distinct
    /// identity. An explicit stack admits long/deep workflows without imposing
    /// an artificial step count or consuming the native call stack.
    static func validateStepTree(_ steps: [BuiltInAutomationStep]) throws {
        var ids = Set<UUID>()
        var pending = Array(steps.reversed())
        while let step = pending.popLast() {
            try Task.checkCancellation()
            guard ids.insert(step.id).inserted else { throw BuiltInAutomationFailure.invalidWorkflow }
            pending.append(contentsOf: step.otherwiseSteps.reversed())
            pending.append(contentsOf: step.thenSteps.reversed())
        }
    }

    static func conditionMatches(_ input: BuiltInAutomationInput, step: BuiltInAutomationStep) throws -> Bool {
        try step.effectivePredicate.matches(input)
    }

    static func prefersImage(_ steps: [BuiltInAutomationStep]) -> Bool {
        var pending = Array(steps.reversed())
        while let step = pending.popLast() {
            guard step.enabled else { continue }
            if step.operation == .requireImage || step.operation == .recognizeText { return true }
            if step.operation == .conditional {
                if step.effectivePredicate.containsImageTest { return true }
                pending.append(contentsOf: step.otherwiseSteps.reversed())
                pending.append(contentsOf: step.thenSteps.reversed())
            }
        }
        return false
    }

    static func checkSize(_ text: String) throws {
        guard text.utf8.count <= maximumBytes else { throw BuiltInAutomationFailure.textTooLarge }
    }

    /// JSONEncoder reports its container-depth failure at the root after
    /// producing the workflow's value tree. Field-level failures (for example
    /// a non-finite date) must retain their own error. A decoder also rejects
    /// ordinary malformed JSON at the root, so only its nesting diagnostic is
    /// translated. No application-owned depth or step-count cap is imposed.
    static func definitionNestingFailure(for error: any Error) -> BuiltInAutomationFailure? {
        if case let EncodingError.invalidValue(_, context) = error,
           context.codingPath.isEmpty {
            return .unsupportedDefinitionNesting
        }
        guard case let DecodingError.dataCorrupted(context) = error,
              context.codingPath.isEmpty else { return nil }
        let underlying = context.underlyingError.map { $0 as NSError }
        let diagnostics = [
            context.debugDescription,
            underlying?.userInfo[NSDebugDescriptionErrorKey] as? String ?? "",
            context.underlyingError.map { String(describing: $0) } ?? "",
        ]
        return diagnostics.contains {
            $0.range(of: "too many nested", options: .caseInsensitive) != nil
                || $0.contains("tooManyNestedArraysOrDictionaries")
        } ? .unsupportedDefinitionNesting : nil
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
