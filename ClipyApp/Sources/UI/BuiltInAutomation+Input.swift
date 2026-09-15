import Foundation
import ImageIO
import Vision

enum BuiltInAutomationInput: Sendable, Equatable {
    case text(String)
    case image(Data)

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
        guard steps.count <= maximumSteps else { throw BuiltInAutomationFailure.tooManySteps }
        switch input {
        case let .text(text): try checkSize(text)
        case let .image(data): try validateImage(data)
        }
        let enabled = steps.filter(\.enabled)
        if enabled.contains(where: { $0.operation == .notify }),
           !enabled.contains(where: { [.requireText, .requireImage, .containsText, .matchesRegex].contains($0.operation) }) {
            throw BuiltInAutomationFailure.notificationNeedsCondition
        }
        var value = input
        var requestsNotification = false
        for step in steps where step.enabled {
            try Task.checkCancellation()
            switch step.operation {
            case .requireText:
                guard case .text = value else { return .init(value: input, requestsNotification: false, matchedConditions: false) }
            case .requireImage:
                guard case .image = value else { return .init(value: input, requestsNotification: false, matchedConditions: false) }
            case .containsText, .matchesRegex:
                guard let text = value.text else { return .init(value: input, requestsNotification: false, matchedConditions: false) }
                let matches = step.operation == .containsText
                    ? !step.find.isEmpty && text.range(of: step.find, options: .literal) != nil
                    : try matchesRegularExpression(text, pattern: step.find)
                guard matches else { return .init(value: input, requestsNotification: false, matchedConditions: false) }
            case .recognizeText:
                guard case let .image(data) = value else { throw BuiltInAutomationFailure.requiresImage }
                let recognized = try await recognizeText(data)
                try checkSize(recognized)
                guard !recognized.isEmpty else { throw BuiltInAutomationFailure.noRecognizedText }
                value = .text(recognized)
            case .notify:
                requestsNotification = true
            default:
                guard case let .text(text) = value else { throw BuiltInAutomationFailure.requiresText }
                value = .text(try run(text, steps: [step]))
            }
        }
        try Task.checkCancellation()
        return BuiltInAutomationOutput(value: value, requestsNotification: requestsNotification)
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
