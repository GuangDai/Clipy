import Foundation

extension BuiltInAutomation {
    /// Definition feedback uses the execution parser without starting a match.
    /// In particular, $12 may mean capture 1 followed by a literal 2.
    static func validateReplacementTemplate(_ template: String, captureGroupCount: Int) throws {
        guard template.utf8.count <= 16_384 else { throw BuiltInAutomationFailure.invalidRegex }
        _ = try replacementParts(template, groups: captureGroupCount)
    }

    static func matchesRegularExpression(_ text: String, pattern: String) throws -> Bool {
        // An empty match is still a match; use the same interruptible loop,
        // replacing the first match with a fixed marker independent of capture.
        try !regularExpression(text, step: .init(operation: .matchesRegex, find: pattern)).isEmpty
    }

    /// Native ICU matching with progress cancellation and bounded output.
    /// Preview never retains a partially matched/transformed result.
    static func regularExpression(_ source: String, step: BuiltInAutomationStep) throws -> String {
        guard !step.find.isEmpty, step.find.utf8.count <= 16_384,
              step.replacement.utf8.count <= 16_384 else {
            throw BuiltInAutomationFailure.invalidRegex
        }
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: step.find) }
        catch { throw BuiltInAutomationFailure.invalidRegex }
        let template = step.operation == .regexReplace
            ? try replacementParts(step.replacement, groups: regex.numberOfCaptureGroups) : []
        let text = source as NSString
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var output = ""
        var byteCount = 0
        var cursor = 0
        var matches = 0
        var failure: (any Error)?
        func append(_ value: String) throws {
            let count = value.utf8.count
            guard byteCount + count <= maximumBytes else { throw BuiltInAutomationFailure.textTooLarge }
            output.append(value)
            byteCount += count
        }
        regex.enumerateMatches(in: source, options: [.reportProgress, .reportCompletion],
                               range: NSRange(location: 0, length: text.length)) { match, flags, stop in
            do {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw BuiltInAutomationFailure.regexTimedOut }
                guard !flags.contains(.internalError) else { throw BuiltInAutomationFailure.regexEngineFailed }
                guard let match else { return }
                if step.operation == .matchesRegex {
                    output = "matched"
                    stop.pointee = true
                    return
                } else if step.operation == .regexExtract {
                    if matches > 0 { try append("\n") }
                    try append(text.substring(with: match.range))
                } else {
                    try append(text.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                    for part in template {
                        switch part {
                        case let .literal(value): try append(value)
                        case let .capture(index):
                            let range = match.range(at: index)
                            if range.location != NSNotFound { try append(text.substring(with: range)) }
                        }
                    }
                    cursor = NSMaxRange(match.range)
                }
                matches += 1
            } catch {
                failure = error
                stop.pointee = true
            }
        }
        if let failure { throw failure }
        try Task.checkCancellation()
        if step.operation == .regexReplace {
            try append(text.substring(from: cursor))
        }
        return output
    }

    private enum ReplacementPart {
        case literal(String), capture(Int)
    }

    /// Parse capture references once so a repeated large capture is bounded
    /// while appending, before allocating an expanded replacement string.
    /// Backslash quotes the next character; $0 is the complete match.
    private static func replacementParts(_ template: String, groups: Int) throws -> [ReplacementPart] {
        let characters = Array(template)
        var result: [ReplacementPart] = []
        var literal = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "\\", index < characters.count {
                literal.append(characters[index])
                index += 1
            } else if character == "$", index < characters.count,
                      let first = characters[index].asciiValue, (48...57).contains(first) {
                var group = Int(first - 48)
                index += 1
                guard group <= groups else { throw BuiltInAutomationFailure.invalidRegex }
                while index < characters.count,
                      let digit = characters[index].asciiValue, (48...57).contains(digit),
                      group <= (groups - Int(digit - 48)) / 10,
                      group * 10 + Int(digit - 48) <= groups {
                    group = group * 10 + Int(digit - 48)
                    index += 1
                }
                if !literal.isEmpty { result.append(.literal(literal)); literal = "" }
                result.append(.capture(group))
            } else { literal.append(character) }
        }
        if !literal.isEmpty { result.append(.literal(literal)) }
        return result
    }
}
