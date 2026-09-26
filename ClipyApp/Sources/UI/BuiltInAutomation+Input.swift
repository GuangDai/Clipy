import Foundation
import ImageIO
import Vision

enum BuiltInAutomationInput: Sendable, Equatable {
    case text(String)
    case image(Data)

    var byteCount: Int {
        switch self { case let .text(text): text.utf8.count; case let .image(data): data.count }
    }

    var text: String? {
        if case let .text(value) = self { value } else { nil }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.text(a), .text(b)): a.utf8.elementsEqual(b.utf8)
        case let (.image(a), .image(b)): a == b
        default: false
        }
    }
}

struct BuiltInAutomationOutput: Sendable {
    let value: BuiltInAutomationInput
    let requestsNotification: Bool
    var matchedConditions = true
    var matchedItemCount = 1
    var originalInput: BuiltInAutomationInput?
}

extension BuiltInAutomation {
    static let maximumImageBytes = 32 * 1_048_576

    /// Only Vision decodes for OCR. Header checks reject oversized input before
    /// requesting analysis; no file URLs, clipboard objects or UI cross actors.
    static func validateImage(_ data: Data) throws {
        guard data.count <= maximumImageBytes else { throw BuiltInAutomationFailure.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else {
            throw BuiltInAutomationFailure.invalidImage
        }
        guard width.doubleValue * height.doubleValue <= 16_000_000 else {
            throw BuiltInAutomationFailure.imageTooLarge
        }
    }

    static func run(
        _ input: BuiltInAutomationInput, steps: [BuiltInAutomationStep],
        recognizeText: @Sendable (Data) async throws -> String = BuiltInAutomation.recognizeText
    ) async throws -> BuiltInAutomationOutput {
        try validateStepTree(steps)
        switch input {
        case let .text(text): try checkSize(text)
        case let .image(data): try validateImage(data)
        }
        return try await runBranches(input, steps: steps, recognizeText: recognizeText)
    }

    private struct BranchFrame {
        let original: BuiltInAutomationInput
        let steps: [BuiltInAutomationStep]
        var value: BuiltInAutomationInput
        var nextStep = 0
        var requestsNotification = false
        var hasCondition = false
        var matchedPath = false
        var notificationAllowed: Bool

        init(_ input: BuiltInAutomationInput, steps: [BuiltInAutomationStep], insideCondition: Bool) {
            original = input
            value = input
            self.steps = steps
            // Existing flat definitions defer notifications until all guards
            // pass, even when the notification precedes its sibling guard.
            notificationAllowed = insideCondition || steps.contains {
                $0.enabled && [.requireText, .requireImage, .containsText, .matchesRegex].contains($0.operation)
            }
        }
    }

    /// A heap-backed frame per active branch replaces recursive async calls.
    /// A failed legacy guard discards only its current branch's work; selected
    /// branch results and deferred notifications join the parent only on match.
    private static func runBranches(
        _ input: BuiltInAutomationInput, steps: [BuiltInAutomationStep],
        recognizeText: @Sendable (Data) async throws -> String
    ) async throws -> BuiltInAutomationOutput {
        var frames = [BranchFrame(input, steps: steps, insideCondition: false)]
        var stepsSinceYield = 0
        while var frame = frames.popLast() {
            try Task.checkCancellation()
            if frame.nextStep == frame.steps.count {
                let matched = !frame.hasCondition || frame.matchedPath
                guard var parent = frames.popLast() else {
                    return BuiltInAutomationOutput(
                        value: frame.value, requestsNotification: frame.requestsNotification,
                        matchedConditions: matched, originalInput: input
                    )
                }
                if matched {
                    parent.value = frame.value
                    parent.matchedPath = true
                    parent.requestsNotification = parent.requestsNotification || frame.requestsNotification
                }
                frames.append(parent)
                continue
            }

            let step = frame.steps[frame.nextStep]
            frame.nextStep += 1
            stepsSinceYield += 1
            if stepsSinceYield == 64 {
                await Task.yield()
                try Task.checkCancellation()
                stepsSinceYield = 0
            }
            guard step.enabled else { frames.append(frame); continue }
            switch step.operation {
            case .conditional:
                frame.hasCondition = true
                let matches = try conditionMatches(frame.value, step: step)
                let selected = matches ? step.thenSteps : step.otherwiseSteps
                frames.append(frame)
                if matches || selected.contains(where: \.enabled) {
                    frames.append(BranchFrame(frame.value, steps: selected, insideCondition: true))
                }
                continue
            case .requireText, .requireImage, .containsText, .matchesRegex:
                frame.hasCondition = true
                let matches: Bool
                switch step.operation {
                case .requireText: matches = frame.value.text != nil
                case .requireImage: if case .image = frame.value { matches = true } else { matches = false }
                case .containsText: matches = !step.find.isEmpty && frame.value.text?.range(of: step.find, options: .literal) != nil
                case .matchesRegex:
                    if let text = frame.value.text { matches = try matchesRegularExpression(text, pattern: step.find) }
                    else { matches = false }
                default: matches = false
                }
                if !matches {
                    if frames.isEmpty {
                        return .init(value: frame.original, requestsNotification: false,
                                     matchedConditions: false, originalInput: input)
                    }
                    // The suspended parent still owns its pre-branch value.
                    // Dropping this frame also drops every deferred effect.
                    continue
                }
                frame.matchedPath = true
                frame.notificationAllowed = true
            case .recognizeText:
                guard case let .image(data) = frame.value else { throw BuiltInAutomationFailure.requiresImage }
                let recognized = try await recognizeText(data)
                try Task.checkCancellation()
                try checkSize(recognized)
                guard !recognized.isEmpty else { throw BuiltInAutomationFailure.noRecognizedText }
                frame.value = .text(recognized)
                frame.matchedPath = true
            case .notify:
                guard frame.notificationAllowed else { throw BuiltInAutomationFailure.notificationNeedsCondition }
                frame.requestsNotification = true
            default:
                guard case let .text(text) = frame.value else { throw BuiltInAutomationFailure.requiresText }
                frame.value = .text(try applyTextOperation(text, step: step))
                frame.matchedPath = true
            }
            frames.append(frame)
        }
        // The root frame always returns above, including an empty workflow.
        throw BuiltInAutomationFailure.invalidWorkflow
    }

    private static func recognizeText(_ data: Data) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        do {
            let observations = try await request.perform(on: data)
            var text = ""
            var bytes = 0
            for observation in observations {
                try Task.checkCancellation()
                guard let candidate = observation.topCandidates(1).first else { continue }
                let line = candidate.string
                bytes += line.utf8.count + (text.isEmpty ? 0 : 1)
                guard bytes <= maximumBytes else { throw BuiltInAutomationFailure.textTooLarge }
                if !text.isEmpty { text.append("\n") }
                text.append(line)
            }
            return text
        } catch is CancellationError { throw CancellationError() }
        catch let failure as BuiltInAutomationFailure { throw failure }
        catch { throw BuiltInAutomationFailure.recognitionFailed }
    }
}
