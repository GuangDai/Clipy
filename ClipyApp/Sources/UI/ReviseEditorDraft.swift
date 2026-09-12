/// Metadata-first revision authoring. Keep Current is an instruction to the
/// sole History writer; opening Edit for one unambiguous plain-text format or
/// explicitly selecting Replace loads only that representation's bytes.
import ClipboardFormats
import Foundation
import HistoryCore

struct ReviseEditorDraft: Sendable {
    enum Choice: Hashable, Sendable { case keepCurrent, useOriginal, hide, replace }
    enum DismissalDecision: Hashable, Sendable { case dismiss, confirmDiscard }
    private var item: HistoryItemReference
    private let canonical: [HistoryRepresentationMetadata]
    private var effectiveTypes: Set<RepresentationIdentity>
    private var choices: [RepresentationIdentity: Choice] = [:]
    private var replacementTexts: [RepresentationIdentity: String] = [:]
    private var replacementCodecs: [RepresentationIdentity: EditorTextCodec] = [:]
    private var openingTexts: [RepresentationIdentity: String] = [:]
    /// Exact comparison is performed when text changes, not every time the
    /// footer, dismissal protection, or accessibility hints render a large draft.
    private var editedTextIdentities: Set<RepresentationIdentity> = []
    /// Opening the simple editor prepares text without authoring a decision.
    /// This identity may restore Keep Current only until its base is reloaded.
    private(set) var directEditingIdentity: RepresentationIdentity?
    private(set) var isAwaitingLatestContent = false

    init(details: HistoryDetails) {
        item = details.item
        canonical = details.canonical
        effectiveTypes = Set(details.effective.map(\.representationIdentity))
    }
    var itemID: HistoryItemID { item.id }
    var itemReference: HistoryItemReference { item }
    var canonicalRepresentations: [HistoryRepresentationMetadata] { canonical }
    /// Edit itself is the explicit read intent (V2-09 §5). Never choose among
    /// multiple Effective formats or clipboard items, or restore a hidden type.
    var directEditingRequest: HistoryRepresentationRequest? {
        guard !isAwaitingLatestContent,
              effectiveTypes.count == 1,
              canonical.allSatisfy({ $0.pasteboardItemIndex == 0 }),
              let identity = effectiveTypes.first,
              choice(for: identity.typeIdentifier, pasteboardItemIndex: identity.pasteboardItemIndex) == .keepCurrent,
              !hasReplacementSource(for: identity.typeIdentifier, pasteboardItemIndex: identity.pasteboardItemIndex)
        else { return nil }
        return replacementRequest(for: identity.typeIdentifier, pasteboardItemIndex: identity.pasteboardItemIndex)
    }
    var canSubmit: Bool { !isAwaitingLatestContent && !hasEmptyPasteboardItem && !hasEmptyReplacement }
    var isDirty: Bool {
        choices.values.contains { $0 != .keepCurrent }
            || !editedTextIdentities.isEmpty
    }
    var dismissalDecision: DismissalDecision { isDirty ? .confirmDiscard : .dismiss }
    var allRepresentationsHidden: Bool {
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
    var hasEmptyPasteboardItem: Bool {
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
    var hasEmptyReplacement: Bool {
        canonical.contains { choice(for: $0.typeIdentifier, pasteboardItemIndex: $0.pasteboardItemIndex) == .replace && replacementText(for: $0.typeIdentifier, pasteboardItemIndex: $0.pasteboardItemIndex).isEmpty }
    }
    func choice(for typeIdentifier: String, pasteboardItemIndex: Int = 0) -> Choice { choices[RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)] ?? .keepCurrent }
    mutating func setChoice(_ choice: Choice, for typeIdentifier: String, pasteboardItemIndex: Int = 0) {
        guard canonical.contains(where: { $0.typeIdentifier == typeIdentifier && $0.pasteboardItemIndex == pasteboardItemIndex }) else { return }
        guard choice != .replace || replacementCodecs[RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)] != nil else { return }
        if directEditingIdentity == RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex) {
            directEditingIdentity = nil
        }
        choices[RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)] = choice
    }
    func replacementText(for typeIdentifier: String, pasteboardItemIndex: Int = 0) -> String { replacementTexts[RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)] ?? "" }
    mutating func setReplacementText(_ text: String, for typeIdentifier: String, pasteboardItemIndex: Int = 0) {
        let identity = RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)
        guard replacementCodecs[identity] != nil else { return }
        replacementTexts[identity] = text
        if let opening = openingTexts[identity], text.utf8.elementsEqual(opening.utf8) {
            editedTextIdentities.remove(identity)
        } else {
            editedTextIdentities.insert(identity)
        }
        if directEditingIdentity == identity {
            choices[identity] = editedTextIdentities.contains(identity) ? .replace : .keepCurrent
        }
    }

    /// Metadata offers declared encodings; choosing Replace validates its source.
    func canReplace(_ representation: HistoryRepresentationMetadata) -> Bool {
        let type = ClipboardFormatIdentifier(rawValue: representation.typeIdentifier)
        return type == .utf8PlainText || type == .utf16PlainText || type == .utf16ExternalPlainText
    }
    func replacementRequest(for typeIdentifier: String, pasteboardItemIndex: Int = 0) -> HistoryRepresentationRequest? {
        guard let metadata = canonical.first(where: { $0.typeIdentifier == typeIdentifier && $0.pasteboardItemIndex == pasteboardItemIndex }), canReplace(metadata) else { return nil }
        return HistoryRepresentationRequest(item: item,
            basis: effectiveTypes.contains(RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)) ? .effective : .canonical,
            typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)
    }
    func hasReplacementSource(for typeIdentifier: String, pasteboardItemIndex: Int = 0) -> Bool { replacementCodecs[RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)] != nil }
    @discardableResult
    mutating func installReplacementSource(_ source: HistoryRepresentation, forDirectEditing: Bool = false) -> Bool {
        if forDirectEditing {
            guard let request = directEditingRequest,
                  request.typeIdentifier == source.typeIdentifier,
                  request.pasteboardItemIndex == source.pasteboardItemIndex else { return false }
        }
        guard replacementRequest(for: source.typeIdentifier, pasteboardItemIndex: source.pasteboardItemIndex) != nil,
              let decoded = EditorTextCodec.decode(source) else { return false }
        let key = RepresentationIdentity(typeIdentifier: source.typeIdentifier, pasteboardItemIndex: source.pasteboardItemIndex)
        replacementTexts[key] = decoded.text
        replacementCodecs[key] = decoded.codec
        openingTexts[key] = decoded.text
        editedTextIdentities.remove(key)
        if forDirectEditing { directEditingIdentity = key }
        return true
    }
    mutating func markStale() { isAwaitingLatestContent = true }

    /// Rebase metadata without downloading unchanged formats. Authored text
    /// keeps its codec. An inspected but unedited source is read afresh next time.
    @discardableResult
    mutating func reloadLatest(details: HistoryDetails) -> Bool {
        guard details.item.id == item.id, details.item.contentVersion >= item.contentVersion,
              details.canonical == canonical else { return false }
        // Authored text keeps its explicit replacement across rebase. Returning
        // to the old opening text must not silently inherit a competitor's bytes.
        directEditingIdentity = nil
        for type in Array(replacementTexts.keys) {
            if choice(for: type.typeIdentifier, pasteboardItemIndex: type.pasteboardItemIndex) != .replace,
               !editedTextIdentities.contains(type) {
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
    func revisionRequest() -> RevisionRequest {
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
