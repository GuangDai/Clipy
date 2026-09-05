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

    package enum DismissalDecision: Hashable, Sendable {
        case dismiss
        case confirmDiscard
    }

    private var item: HistoryItemReference
    private var canonical: [HistoryRepresentation]
    private var effectiveByType: [String: HistoryRepresentation]
    private var openingChoices: [String: Choice]
    private var openingReplacementTextBytes: [String: Data]
    private var openingReplacementCodecs: [String: EditorTextCodec]
    private var choices: [String: Choice]
    private var replacementTexts: [String: String]
    private var replacementCodecs: [String: EditorTextCodec]
    package private(set) var isAwaitingLatestContent = false

    package init(details: HistoryDetails) {
        let state = Self.initialState(details: details)
        item = details.item
        canonical = details.canonical
        effectiveByType = state.effectiveByType
        openingChoices = state.choices
        openingReplacementTextBytes = state.replacementTexts.mapValues {
            Data($0.utf8)
        }
        openingReplacementCodecs = state.replacementCodecs
        choices = state.choices
        replacementTexts = state.replacementTexts
        replacementCodecs = state.replacementCodecs
    }

    package var itemID: HistoryItemID { item.id }

    /// The rows the editor renders. Canonical Content is immutable for the
    /// lifetime of a History item, so Reload Latest never replaces this set.
    package var canonicalRepresentations: [HistoryRepresentation] { canonical }

    /// A stale save must not be repeated against the same base. Validation
    /// remains part of the same submission gate so the view has one source of
    /// truth for whether Save is meaningful.
    package var canSubmit: Bool {
        !isAwaitingLatestContent
            && !allRepresentationsHidden
            && !hasEmptyReplacement
    }

    /// Dirty state is relative to the exact authoritative base presented at
    /// open or the last explicit reload. Swift String equality is canonically
    /// equivalent, so UTF-8 text bytes distinguish literal Unicode edits.
    /// These comparison bytes are independent of the replacement's actual
    /// output codec, whose byte order and BOM are retained separately.
    package var isDirty: Bool {
        choices != openingChoices
            || replacementTexts.mapValues { Data($0.utf8) }
                != openingReplacementTextBytes
            || replacementCodecs != openingReplacementCodecs
    }

    package var dismissalDecision: DismissalDecision {
        isDirty ? .confirmDiscard : .dismiss
    }

    package var allRepresentationsHidden: Bool {
        !canonical.isEmpty && canonical.allSatisfy { representation in
            // Availability checks need only the choice, not newly encoded
            // replacement buffers on every editor redraw.
            switch choice(for: representation.typeIdentifier) {
            case .hide:
                return true
            case .keepCurrent:
                return effectiveByType[representation.typeIdentifier] == nil
            case .useOriginal, .replace:
                return false
            }
        }
    }

    package var hasEmptyReplacement: Bool {
        canonical.contains { representation in
            let typeIdentifier = representation.typeIdentifier
            return choice(for: typeIdentifier) == .replace
                && replacementText(for: typeIdentifier).isEmpty
        }
    }

    package func choice(for typeIdentifier: String) -> Choice {
        choices[typeIdentifier] ?? .keepCurrent
    }

    package mutating func setChoice(
        _ choice: Choice,
        for typeIdentifier: String
    ) {
        if choice == .replace {
            guard let representation = canonical.first(where: {
                $0.typeIdentifier == typeIdentifier
            }), canReplace(representation) else {
                return
            }
        }
        choices[typeIdentifier] = choice
    }

    package func replacementText(for typeIdentifier: String) -> String {
        replacementTexts[typeIdentifier] ?? ""
    }

    package mutating func setReplacementText(
        _ text: String,
        for typeIdentifier: String
    ) {
        guard let representation = canonical.first(where: {
            $0.typeIdentifier == typeIdentifier
        }), canReplace(representation) else {
            return
        }
        replacementTexts[typeIdentifier] = text
    }

    /// Records the optimistic-concurrency rejection without touching any
    /// user-authored bytes. The UI requires an explicit Reload Latest before
    /// another submission (review Card 3B).
    package mutating func markStale() {
        isAwaitingLatestContent = true
    }

    /// Rebases the editor onto explicitly fetched authoritative Effective
    /// Content while preserving the item's immutable Canonical Content. User
    /// choices and authored replacement bytes survive exactly. If the latest
    /// Effective bytes no longer satisfy the paired editor codec, the whole
    /// reload returns false without changing the old base or draft. This does
    /// not merge or submit content.
    @discardableResult
    package mutating func reloadLatest(details: HistoryDetails) -> Bool {
        let previousOpeningReplacementTextBytes = openingReplacementTextBytes
        let previousOpeningReplacementCodecs = openingReplacementCodecs
        let previousChoices = choices
        let previousReplacementTexts = replacementTexts
        let previousReplacementCodecs = replacementCodecs

        let latest = Self.initialState(
            canonical: canonical,
            effective: details.effective
        )

        // Reload is atomic with respect to authored draft bytes. If a format
        // carrying a user-authored replacement no longer satisfies the
        // paired codec, keep the entire old base and draft intact instead of
        // silently degrading Replace to Keep Current.
        for representation in canonical {
            let typeIdentifier = representation.typeIdentifier
            let previousText = previousReplacementTexts[typeIdentifier]
            let previousBytes = previousText.map { Data($0.utf8) }
            let replacementWasAuthored = previousBytes
                != previousOpeningReplacementTextBytes[typeIdentifier]
                || previousReplacementCodecs[typeIdentifier]
                    != previousOpeningReplacementCodecs[typeIdentifier]
            let hadAuthoredReplace = previousChoices[typeIdentifier] == .replace
                || replacementWasAuthored
            guard !hadAuthoredReplace
                || latest.replacementCodecs[typeIdentifier] != nil else {
                return false
            }
        }

        item = details.item
        effectiveByType = latest.effectiveByType
        openingChoices = latest.choices
        openingReplacementTextBytes = latest.replacementTexts.mapValues {
            Data($0.utf8)
        }
        openingReplacementCodecs = latest.replacementCodecs
        choices = latest.choices
        replacementTexts = latest.replacementTexts
        replacementCodecs = latest.replacementCodecs

        for representation in canonical {
            let typeIdentifier = representation.typeIdentifier
            let previousChoice = previousChoices[typeIdentifier]
                ?? .keepCurrent
            if canReplace(representation) {
                choices[typeIdentifier] = previousChoice

                let previousText = previousReplacementTexts[typeIdentifier]
                let previousBytes = previousText.map { Data($0.utf8) }
                let replacementWasAuthored = previousBytes
                    != previousOpeningReplacementTextBytes[typeIdentifier]
                    || previousReplacementCodecs[typeIdentifier]
                        != previousOpeningReplacementCodecs[typeIdentifier]
                if previousChoice == .replace || replacementWasAuthored,
                   let previousText {
                    replacementTexts[typeIdentifier] = previousText
                    replacementCodecs[typeIdentifier] = previousReplacementCodecs[typeIdentifier]
                }
            } else if previousChoice != .replace {
                choices[typeIdentifier] = previousChoice
            }
        }
        isAwaitingLatestContent = false
        return true
    }

    package func canReplace(_ representation: HistoryRepresentation) -> Bool {
        replacementCodecs[representation.typeIdentifier] != nil
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
            // Replace can only be selected after a validated codec was
            // installed, and reload never removes an authored draft's codec.
            action = .replace(
                bytes: replacementCodecs[typeIdentifier]!
                    .encode(replacementText(for: typeIdentifier))
            )
        }
        return RevisionDecision(typeIdentifier: typeIdentifier, action: action)
    }

    private struct InitialState {
        let effectiveByType: [String: HistoryRepresentation]
        let choices: [String: Choice]
        let replacementTexts: [String: String]
        let replacementCodecs: [String: EditorTextCodec]
    }

    private static func initialState(details: HistoryDetails) -> InitialState {
        initialState(
            canonical: details.canonical,
            effective: details.effective
        )
    }

    private static func initialState(
        canonical: [HistoryRepresentation],
        effective: [HistoryRepresentation]
    ) -> InitialState {
        let currentByType = Dictionary(
            effective.map { ($0.typeIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var initialChoices: [String: Choice] = [:]
        var initialTexts: [String: String] = [:]
        var initialCodecs: [String: EditorTextCodec] = [:]
        for representation in canonical {
            let typeIdentifier = representation.typeIdentifier
            initialChoices[typeIdentifier] = .keepCurrent
            // Both immutable Canonical and any visible Effective value must
            // satisfy their exact text format. Current bytes own the editor's
            // BOM/byte order; a hidden type starts from Canonical instead.
            guard let canonicalText = EditorTextCodec.decode(representation) else {
                continue
            }
            let source: (codec: EditorTextCodec, text: String)
            if let current = currentByType[typeIdentifier],
               current.bytes != representation.bytes {
                guard let currentText = EditorTextCodec.decode(current) else {
                    continue
                }
                source = currentText
            } else {
                // Identical raw bytes have identical text and BOM/byte order.
                // Do not substitute Swift String equality here: canonical-
                // equivalent spellings can carry distinct replacement bytes.
                source = canonicalText
            }
            initialTexts[typeIdentifier] = source.text
            initialCodecs[typeIdentifier] = source.codec
        }
        return InitialState(
            effectiveByType: currentByType,
            choices: initialChoices,
            replacementTexts: initialTexts,
            replacementCodecs: initialCodecs
        )
    }
}
