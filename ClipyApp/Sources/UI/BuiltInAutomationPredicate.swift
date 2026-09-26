import Foundation

/// One If evaluates the current value against this concrete condition tree.
/// All/Any follow Shortcuts' multi-condition model; Not and nested groups keep
/// the same meaning in the visual editor and the indented text syntax (V2-13).
indirect enum BuiltInAutomationPredicate: Codable, Equatable, Sendable {
    case match(BuiltInAutomationStep.Condition, String)
    case all([Self])
    case any([Self])
    case not(Self)

    private enum Evaluation {
        case evaluate(BuiltInAutomationPredicate)
        case invert
        case continueAll([BuiltInAutomationPredicate], Int)
        case continueAny([BuiltInAutomationPredicate], Int)
    }

    /// Evaluation is left-to-right and short-circuits, including expensive
    /// regular expressions. The explicit stack supports nested groups without
    /// turning condition depth into synchronous call-stack recursion.
    func matches(_ input: BuiltInAutomationInput) throws -> Bool {
        var pending: [Evaluation] = [.evaluate(self)]
        var result = false
        while let action = pending.popLast() {
            try Task.checkCancellation()
            switch action {
            case .evaluate(let predicate):
                switch predicate {
                case .match(let condition, let find):
                    switch condition {
                    case .isText: result = input.text != nil
                    case .isImage:
                        if case .image = input { result = true } else { result = false }
                    case .containsText:
                        result = !find.isEmpty && input.text?.range(of: find, options: .literal) != nil
                    case .matchesRegex:
                        if let text = input.text {
                            result = try BuiltInAutomation.matchesRegularExpression(text, pattern: find)
                        } else { result = false }
                    }
                case .all(let children):
                    guard let first = children.first else { throw BuiltInAutomationFailure.emptyConditionGroup }
                    pending.append(.continueAll(children, 1))
                    pending.append(.evaluate(first))
                case .any(let children):
                    guard let first = children.first else { throw BuiltInAutomationFailure.emptyConditionGroup }
                    pending.append(.continueAny(children, 1))
                    pending.append(.evaluate(first))
                case .not(let child):
                    pending.append(.invert)
                    pending.append(.evaluate(child))
                }
            case .invert:
                result.toggle()
            case .continueAll(let children, let next):
                if result, next < children.count {
                    pending.append(.continueAll(children, next + 1))
                    pending.append(.evaluate(children[next]))
                }
            case .continueAny(let children, let next):
                if !result, next < children.count {
                    pending.append(.continueAny(children, next + 1))
                    pending.append(.evaluate(children[next]))
                }
            }
        }
        return result
    }

    /// Saving checks every condition, even one skipped by short-circuiting.
    /// Empty groups are incomplete edits, never an implicit unconditional match.
    func validate() throws {
        var pending = [self]
        while let predicate = pending.popLast() {
            try Task.checkCancellation()
            switch predicate {
            case .match(let condition, let find):
                guard find.utf8.count <= 16_384 else { throw BuiltInAutomationFailure.definitionTooLarge }
                if condition == .matchesRegex {
                    guard !find.isEmpty, (try? NSRegularExpression(pattern: find)) != nil else {
                        throw BuiltInAutomationFailure.invalidRegex
                    }
                }
            case .all(let children), .any(let children):
                guard !children.isEmpty else { throw BuiltInAutomationFailure.emptyConditionGroup }
                pending.append(contentsOf: children)
            case .not(let child): pending.append(child)
            }
        }
    }

    var containsImageTest: Bool {
        var pending = [self]
        while let predicate = pending.popLast() {
            switch predicate {
            case .match(.isImage, _): return true
            case .match: break
            case .all(let children), .any(let children): pending.append(contentsOf: children)
            case .not(let child): pending.append(child)
            }
        }
        return false
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        var pending = [(lhs, rhs)]
        while let (left, right) = pending.popLast() {
            switch (left, right) {
            case let (.match(a, x), .match(b, y)):
                guard a == b, x.utf8.elementsEqual(y.utf8) else { return false }
            case let (.all(a), .all(b)), let (.any(a), .any(b)):
                guard a.count == b.count else { return false }
                pending.append(contentsOf: zip(a, b))
            case let (.not(a), .not(b)): pending.append((a, b))
            default: return false
            }
        }
        return true
    }
}

extension BuiltInAutomationStep {
    /// Definitions written before compound conditions keep their exact prior
    /// condition and find bytes until the user edits that condition.
    var effectivePredicate: BuiltInAutomationPredicate { predicate ?? .match(condition, find) }
}
