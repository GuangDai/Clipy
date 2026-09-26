import Foundation

/// Labels and parameter feedback for the existing, closed operation set.
/// These values do not change execution or the persisted step definition.
enum BuiltInAutomationActionCategory: String, CaseIterable {
    case text, lines, structuredData, matching, images, notifications

    var title: String {
        switch self {
        case .text: "Text"
        case .lines: "Lines"
        case .structuredData: "Structured data"
        case .matching: "Matching and replacement"
        case .images: "Images"
        case .notifications: "Notifications"
        }
    }

    var symbol: String {
        switch self {
        case .text: "textformat"
        case .lines: "list.bullet"
        case .structuredData: "curlybraces"
        case .matching: "text.magnifyingglass"
        case .images: "photo"
        case .notifications: "bell"
        }
    }

    var operations: [BuiltInAutomationStep.Operation] {
        BuiltInAutomationStep.Operation.allCases.filter { !$0.isCondition && $0.actionCategory == self }
    }
}

extension BuiltInAutomationStep.Operation {
    var isCondition: Bool { [.conditional, .requireText, .requireImage, .containsText, .matchesRegex].contains(self) }

    var actionCategory: BuiltInAutomationActionCategory {
        switch self {
        case .trim, .uppercase, .lowercase: .text
        case .trimLines, .removeEmptyLines, .uniqueLines, .sortLines: .lines
        case .prettyJSON, .compactJSON: .structuredData
        case .replace, .regexReplace, .regexExtract, .conditional, .containsText, .matchesRegex: .matching
        case .recognizeText, .requireImage: .images
        case .notify: .notifications
        case .requireText: .text
        }
    }

    var explanation: String {
        switch self {
        case .trim: "Removes whitespace and line breaks from the beginning and end."
        case .trimLines: "Removes surrounding whitespace from each line; keeps line order."
        case .removeEmptyLines: "Removes whitespace-only lines and keeps the remaining lines in order."
        case .uniqueLines: "Keeps the first occurrence of each exact line, including its letter case and spacing."
        case .sortLines: "Sorts lines by UTF-8 byte order; uppercase and lowercase sort separately."
        case .uppercase: "Converts letters to uppercase."
        case .lowercase: "Converts letters to lowercase."
        case .prettyJSON: "Validates JSON and adds indentation without changing keys or number spelling."
        case .compactJSON: "Validates JSON and removes unnecessary whitespace."
        case .replace: "Replaces every exact, case-sensitive occurrence. Replacement text is literal."
        case .regexReplace: "Replaces matches using an ICU regular expression and capture groups."
        case .regexExtract: "Keeps complete regular expression matches, one per line; no matches produces empty text."
        case .recognizeText: "Reads text from an image locally with Apple OCR, then passes text to the next step."
        case .notify: "Sends a notification only after this branch and the rest of the workflow succeed. Preview sends none."
        case .conditional: "Chooses one branch using the current value, then continues with the following steps."
        case .requireText, .requireImage, .containsText, .matchesRegex:
            "Then continue with the following steps. Otherwise stop this workflow."
        }
    }
}

struct BuiltInAutomationParameterIssue: Equatable {
    enum Field: Equatable { case find, replacement }
    let field: Field
    let message: String
    let isError: Bool
}

extension BuiltInAutomationStep {
    var needsFind: Bool {
        [.replace, .regexReplace, .regexExtract, .containsText, .matchesRegex].contains(operation)
            || (operation == .conditional && [.containsText, .matchesRegex].contains(condition))
    }

    var isLiteralFind: Bool {
        [.replace, .containsText].contains(operation)
            || (operation == .conditional && condition == .containsText)
    }

    var needsReplacement: Bool { [.replace, .regexReplace].contains(operation) }

    /// Empty contains-text conditions deliberately remain nonmatching, including
    /// old flat guards. Feedback must not silently change their saved semantics.
    func parameterIssues(ancestorsEnabled: Bool = true) -> [BuiltInAutomationParameterIssue] {
        guard ancestorsEnabled else { return [] }
        var issues: [BuiltInAutomationParameterIssue] = []
        if find.utf8.count > 16_384 {
            issues.append(.init(field: .find, message: "Keep this field within 16 KiB of UTF-8 text to save the workflow.", isError: true))
        }
        if replacement.utf8.count > 16_384 {
            issues.append(.init(field: .replacement, message: "Keep this field within 16 KiB of UTF-8 text to save the workflow.", isError: true))
        }
        guard enabled, needsFind, find.utf8.count <= 16_384 else { return issues }
        if !isLiteralFind {
            if !find.isEmpty, let regex = try? NSRegularExpression(pattern: find) {
                if operation == .regexReplace, replacement.utf8.count <= 16_384 {
                    do {
                        try BuiltInAutomation.validateReplacementTemplate(replacement, captureGroupCount: regex.numberOfCaptureGroups)
                    } catch {
                        issues.append(.init(field: .replacement, message: "Use only capture groups defined in the regular expression.", isError: true))
                    }
                }
            } else {
                issues.append(.init(field: .find, message: "Enter a valid regular expression.", isError: true))
            }
        } else if find.isEmpty {
            if operation == .replace {
                issues.append(.init(field: .find, message: "Enter the text to replace.", isError: true))
            } else {
                issues.append(.init(field: .find, message: "An empty text condition never matches.", isError: false))
            }
        }
        return issues
    }
}
