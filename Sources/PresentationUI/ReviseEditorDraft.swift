/// ReviseEditorDraft — the pure value owner for the revision editor's
/// current-vs-canonical decisions.  The view renders and mutates this value;
/// this module alone translates those choices into HistoryCore vocabulary.
/// Owning spec: docs/03a-instruction-set.md §5; review Card 3.
import Foundation
import HistoryCore

package struct ReviseEditorDraft: Sendable {
    package enum Choice: Hashable, Sendable {
        case keepCurrent
        case useOriginal
        case hide
        case replace
    }

    private let item: HistoryItemReference
    private let canonical: [HistoryRepresentation]
    private let effectiveByType: [String: HistoryRepresentation]
    private var choices: [String: Choice]
    private var replacementTexts: [String: String]

    package init(details: HistoryDetails) {
        item = details.item
        canonical = details.canonical
        let currentByType = Dictionary(
            details.effective.map { ($0.typeIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        effectiveByType = currentByType

        var initialChoices: [String: Choice] = [:]
        var initialTexts: [String: String] = [:]
        for representation in details.canonical {
            let typeIdentifier = representation.typeIdentifier
            initialChoices[typeIdentifier] = .keepCurrent
            if Self.isUTF8TextRepresentation(representation) {
                initialTexts[typeIdentifier] = currentByType[typeIdentifier]
                    .flatMap(Self.decodedText)
                    ?? Self.decodedText(representation)
                    ?? ""
            }
        }
        choices = initialChoices
        replacementTexts = initialTexts
    }

    package var allRepresentationsHidden: Bool {
        !canonical.isEmpty && canonical.allSatisfy {
            if case .hide = decision(for: $0).action {
                return true
            }
            return false
        }
    }

    package func choice(for typeIdentifier: String) -> Choice {
        choices[typeIdentifier] ?? .keepCurrent
    }

    package mutating func setChoice(
        _ choice: Choice,
        for typeIdentifier: String
    ) {
        choices[typeIdentifier] = choice
    }

    package func replacementText(for typeIdentifier: String) -> String {
        replacementTexts[typeIdentifier] ?? ""
    }

    package mutating func setReplacementText(
        _ text: String,
        for typeIdentifier: String
    ) {
        replacementTexts[typeIdentifier] = text
    }

    package func canReplace(_ representation: HistoryRepresentation) -> Bool {
        Self.isUTF8TextRepresentation(representation)
    }

    package func revisionRequest() -> RevisionRequest {
        RevisionRequest(
            itemID: item.id,
            expected: item.contentVersion,
            intent: .replace(
                RevisionDraft(decisions: canonical.map(decision(for:)))
            )
        )
    }

    private func decision(
        for canonicalRepresentation: HistoryRepresentation
    ) -> RevisionDecision {
        let typeIdentifier = canonicalRepresentation.typeIdentifier
        let action: RevisionDecisionAction
        switch choice(for: typeIdentifier) {
        case .keepCurrent:
            if let effective = effectiveByType[typeIdentifier] {
                action = effective.bytes == canonicalRepresentation.bytes
                    ? .inheritCanonical
                    : .replace(bytes: effective.bytes)
            } else {
                action = .hide
            }
        case .useOriginal:
            action = .inheritCanonical
        case .hide:
            action = .hide
        case .replace:
            action = .replace(
                bytes: Data(replacementText(for: typeIdentifier).utf8)
            )
        }
        return RevisionDecision(typeIdentifier: typeIdentifier, action: action)
    }

    /// Mirror of storage's frozen v1 textual UTI set (05 §15).  This slice
    /// deliberately preserves existing editor eligibility; codec/type-policy
    /// correction is owned by the later FORMAT cards.
    private static let textualTypeIdentifiers: Set<String> = [
        "public.plain-text",
        "public.utf8-plain-text",
        "public.utf16-plain-text",
        "public.utf8-external-plain-text",
        "public.text",
        "public.rtf",
        "public.html",
    ]

    private static func isUTF8TextRepresentation(
        _ representation: HistoryRepresentation
    ) -> Bool {
        guard textualTypeIdentifiers.contains(representation.typeIdentifier) else {
            return false
        }
        return String(data: representation.bytes, encoding: .utf8) != nil
    }

    private static func decodedText(
        _ representation: HistoryRepresentation
    ) -> String? {
        guard textualTypeIdentifiers.contains(representation.typeIdentifier) else {
            return nil
        }
        if representation.typeIdentifier == "public.utf16-plain-text" {
            return String(data: representation.bytes, encoding: .utf16)
        }
        return String(data: representation.bytes, encoding: .utf8)
    }
}
