/// Metadata-first revision authoring. Keep Current is an instruction to the
/// sole History writer; only an explicitly selected text replacement loads bytes.
import ClipboardFormats
import Foundation
import HistoryCore

package struct ReviseEditorDraft: Sendable {
    package enum Choice: Hashable, Sendable { case keepCurrent, useOriginal, hide, replace }
    package enum DismissalDecision: Hashable, Sendable { case dismiss, confirmDiscard }
    private var item: HistoryItemReference
    private let canonical: [HistoryRepresentationMetadata]
    private var effectiveTypes: Set<String>
    private var choices: [String: Choice] = [:]
    private var replacementTexts: [String: String] = [:]
    private var replacementCodecs: [String: EditorTextCodec] = [:]
    private var openingTexts: [String: String] = [:]
    package private(set) var isAwaitingLatestContent = false

    package init(details: HistoryDetails) {
        item = details.item
        canonical = details.canonical
        effectiveTypes = Set(details.effective.map(\.typeIdentifier))
    }
    package var itemID: HistoryItemID { item.id }
    package var itemReference: HistoryItemReference { item }
    package var canonicalRepresentations: [HistoryRepresentationMetadata] { canonical }
    package var canSubmit: Bool { !isAwaitingLatestContent && !allRepresentationsHidden && !hasEmptyReplacement }
    package var isDirty: Bool {
        choices.values.contains { $0 != .keepCurrent }
            || replacementTexts.contains { entry in
                guard let original = openingTexts[entry.key] else { return true }
                return !entry.value.utf8.elementsEqual(original.utf8)
            }
    }
    package var dismissalDecision: DismissalDecision { isDirty ? .confirmDiscard : .dismiss }
    package var allRepresentationsHidden: Bool {
        !canonical.isEmpty && canonical.allSatisfy {
            switch choice(for: $0.typeIdentifier) {
            case .hide: true
            case .keepCurrent: !effectiveTypes.contains($0.typeIdentifier)
            case .useOriginal, .replace: false
            }
        }
    }
    package var hasEmptyReplacement: Bool {
        canonical.contains { choice(for: $0.typeIdentifier) == .replace && replacementText(for: $0.typeIdentifier).isEmpty }
    }
    package func choice(for typeIdentifier: String) -> Choice { choices[typeIdentifier] ?? .keepCurrent }
    package mutating func setChoice(_ choice: Choice, for typeIdentifier: String) {
        guard canonical.contains(where: { $0.typeIdentifier == typeIdentifier }) else { return }
        guard choice != .replace || replacementCodecs[typeIdentifier] != nil else { return }
        choices[typeIdentifier] = choice
    }
    package func replacementText(for typeIdentifier: String) -> String { replacementTexts[typeIdentifier] ?? "" }
    package mutating func setReplacementText(_ text: String, for typeIdentifier: String) {
        guard replacementCodecs[typeIdentifier] != nil else { return }
        replacementTexts[typeIdentifier] = text
    }

    /// Metadata offers declared encodings; choosing Replace validates its source.
    package func canReplace(_ representation: HistoryRepresentationMetadata) -> Bool {
        let type = ClipboardFormatIdentifier(rawValue: representation.typeIdentifier)
        return type == .utf8PlainText || type == .utf16PlainText || type == .utf16ExternalPlainText
    }
    package func replacementRequest(for typeIdentifier: String) -> HistoryRepresentationRequest? {
        guard let metadata = canonical.first(where: { $0.typeIdentifier == typeIdentifier }), canReplace(metadata) else { return nil }
        return HistoryRepresentationRequest(item: item,
            basis: effectiveTypes.contains(typeIdentifier) ? .effective : .canonical,
            typeIdentifier: typeIdentifier)
    }
    package func hasReplacementSource(for typeIdentifier: String) -> Bool { replacementCodecs[typeIdentifier] != nil }
    @discardableResult
    package mutating func installReplacementSource(_ source: HistoryRepresentation) -> Bool {
        guard replacementRequest(for: source.typeIdentifier) != nil,
              let decoded = EditorTextCodec.decode(source) else { return false }
        replacementTexts[source.typeIdentifier] = decoded.text
        replacementCodecs[source.typeIdentifier] = decoded.codec
        openingTexts[source.typeIdentifier] = decoded.text
        return true
    }
    package mutating func markStale() { isAwaitingLatestContent = true }

    /// Rebase metadata without downloading unchanged formats. Authored text
    /// keeps its codec. An inspected but unedited source is read afresh next time.
    @discardableResult
    package mutating func reloadLatest(details: HistoryDetails) -> Bool {
        guard details.item.id == item.id, details.item.contentVersion >= item.contentVersion,
              details.canonical == canonical else { return false }
        for type in Array(replacementTexts.keys) {
            if choice(for: type) != .replace,
               let current = replacementTexts[type], let opening = openingTexts[type],
               current.utf8.elementsEqual(opening.utf8) {
                replacementTexts.removeValue(forKey: type)
                replacementCodecs.removeValue(forKey: type)
                openingTexts.removeValue(forKey: type)
            }
        }
        item = details.item
        effectiveTypes = Set(details.effective.map(\.typeIdentifier))
        isAwaitingLatestContent = false
        return true
    }
    package func revisionRequest() -> RevisionRequest {
        RevisionRequest(itemID: item.id, expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: canonical.map { representation in
                let type = representation.typeIdentifier
                let action: RevisionDecisionAction
                switch choice(for: type) {
                case .keepCurrent: action = effectiveTypes.contains(type) ? .inheritCurrent : .hide
                case .useOriginal: action = .inheritCanonical
                case .hide: action = .hide
                case .replace: action = .replace(bytes: replacementCodecs[type]!.encode(replacementText(for: type)))
                }
                return RevisionDecision(typeIdentifier: type, action: action)
            })))
    }
}
