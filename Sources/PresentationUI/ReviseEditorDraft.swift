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
    private var effectiveTypes: Set<RepresentationIdentity>
    private var choices: [RepresentationIdentity: Choice] = [:]
    private var replacementTexts: [RepresentationIdentity: String] = [:]
    private var replacementCodecs: [RepresentationIdentity: EditorTextCodec] = [:]
    private var openingTexts: [RepresentationIdentity: String] = [:]
    package private(set) var isAwaitingLatestContent = false

    package init(details: HistoryDetails) {
        item = details.item
        canonical = details.canonical
        effectiveTypes = Set(details.effective.map(\.representationIdentity))
    }
    package var itemID: HistoryItemID { item.id }
    package var itemReference: HistoryItemReference { item }
    package var canonicalRepresentations: [HistoryRepresentationMetadata] { canonical }
    package var canSubmit: Bool { !isAwaitingLatestContent && !hasEmptyPasteboardItem && !hasEmptyReplacement }
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
            switch choice(for: $0.typeIdentifier, pasteboardItemIndex: $0.pasteboardItemIndex) {
            case .hide: true
            case .keepCurrent: !effectiveTypes.contains($0.representationIdentity)
            case .useOriginal, .replace: false
            }
        }
    }
    /// A revision keeps every constituent item present. Dropping its final
    /// format would change the captured gesture's item boundaries.
    package var hasEmptyPasteboardItem: Bool {
        Dictionary(grouping: canonical, by: \.pasteboardItemIndex).values.contains { representations in
            representations.allSatisfy {
                switch choice(for: $0.typeIdentifier, pasteboardItemIndex: $0.pasteboardItemIndex) {
                case .hide: true
                case .keepCurrent: !effectiveTypes.contains($0.representationIdentity)
                case .useOriginal, .replace: false
                }
            }
        }
    }
    package var hasEmptyReplacement: Bool {
        canonical.contains { choice(for: $0.typeIdentifier, pasteboardItemIndex: $0.pasteboardItemIndex) == .replace && replacementText(for: $0.typeIdentifier, pasteboardItemIndex: $0.pasteboardItemIndex).isEmpty }
    }
    package func choice(for typeIdentifier: String, pasteboardItemIndex: Int = 0) -> Choice { choices[RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)] ?? .keepCurrent }
    package mutating func setChoice(_ choice: Choice, for typeIdentifier: String, pasteboardItemIndex: Int = 0) {
        guard canonical.contains(where: { $0.typeIdentifier == typeIdentifier && $0.pasteboardItemIndex == pasteboardItemIndex }) else { return }
        guard choice != .replace || replacementCodecs[RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)] != nil else { return }
        choices[RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)] = choice
    }
    package func replacementText(for typeIdentifier: String, pasteboardItemIndex: Int = 0) -> String { replacementTexts[RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)] ?? "" }
    package mutating func setReplacementText(_ text: String, for typeIdentifier: String, pasteboardItemIndex: Int = 0) {
        guard replacementCodecs[RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)] != nil else { return }
        replacementTexts[RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)] = text
    }

    /// Metadata offers declared encodings; choosing Replace validates its source.
    package func canReplace(_ representation: HistoryRepresentationMetadata) -> Bool {
        let type = ClipboardFormatIdentifier(rawValue: representation.typeIdentifier)
        return type == .utf8PlainText || type == .utf16PlainText || type == .utf16ExternalPlainText
    }
    package func replacementRequest(for typeIdentifier: String, pasteboardItemIndex: Int = 0) -> HistoryRepresentationRequest? {
        guard let metadata = canonical.first(where: { $0.typeIdentifier == typeIdentifier && $0.pasteboardItemIndex == pasteboardItemIndex }), canReplace(metadata) else { return nil }
        return HistoryRepresentationRequest(item: item,
            basis: effectiveTypes.contains(RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)) ? .effective : .canonical,
            typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)
    }
    package func hasReplacementSource(for typeIdentifier: String, pasteboardItemIndex: Int = 0) -> Bool { replacementCodecs[RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)] != nil }
    @discardableResult
    package mutating func installReplacementSource(_ source: HistoryRepresentation) -> Bool {
        guard replacementRequest(for: source.typeIdentifier, pasteboardItemIndex: source.pasteboardItemIndex) != nil,
              let decoded = EditorTextCodec.decode(source) else { return false }
        let key = RepresentationIdentity(typeIdentifier: source.typeIdentifier, pasteboardItemIndex: source.pasteboardItemIndex)
        replacementTexts[key] = decoded.text
        replacementCodecs[key] = decoded.codec
        openingTexts[key] = decoded.text
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
            if choice(for: type.typeIdentifier, pasteboardItemIndex: type.pasteboardItemIndex) != .replace,
               let current = replacementTexts[type], let opening = openingTexts[type],
               current.utf8.elementsEqual(opening.utf8) {
                replacementTexts.removeValue(forKey: type)
                replacementCodecs.removeValue(forKey: type)
                openingTexts.removeValue(forKey: type)
            }
        }
        item = details.item
        effectiveTypes = Set(details.effective.map(\.representationIdentity))
        isAwaitingLatestContent = false
        return true
    }
    package func revisionRequest() -> RevisionRequest {
        RevisionRequest(itemID: item.id, expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: canonical.map { representation in
                let type = representation.representationIdentity
                let action: RevisionDecisionAction
                switch choice(for: type.typeIdentifier, pasteboardItemIndex: type.pasteboardItemIndex) {
                case .keepCurrent: action = effectiveTypes.contains(type) ? .inheritCurrent : .hide
                case .useOriginal: action = .inheritCanonical
                case .hide: action = .hide
                case .replace: action = .replace(bytes: replacementCodecs[type]!.encode(replacementText(for: type.typeIdentifier, pasteboardItemIndex: type.pasteboardItemIndex)))
                }
                return RevisionDecision(typeIdentifier: type.typeIdentifier, action: action, pasteboardItemIndex: type.pasteboardItemIndex)
            })))
    }
}
