/// ReviseEditorDraft — the pure value owner for the revision editor's
/// current-vs-canonical decisions.  The view renders and mutates this value;
/// this module alone translates those choices into HistoryCore vocabulary.
/// Owning spec: docs/03a-instruction-set.md §5; review Card 3.
import ClipboardFormats
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
    private var openingReplacementBytes: [String: Data]
    private var choices: [String: Choice]
    private var replacementTexts: [String: String]
    package private(set) var isAwaitingLatestContent = false

    package init(details: HistoryDetails) {
        let state = Self.initialState(details: details)
        item = details.item
        canonical = details.canonical
        effectiveByType = state.effectiveByType
        openingChoices = state.choices
        openingReplacementBytes = state.replacementTexts.mapValues {
            Data($0.utf8)
        }
        choices = state.choices
        replacementTexts = state.replacementTexts
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
    /// equivalent, so replacement UTF-8 bytes preserve byte-exact edit intent.
    package var isDirty: Bool {
        choices != openingChoices
            || replacementTexts.mapValues { Data($0.utf8) }
                != openingReplacementBytes
    }

    package var dismissalDecision: DismissalDecision {
        isDirty ? .confirmDiscard : .dismiss
    }

    package var allRepresentationsHidden: Bool {
        !canonical.isEmpty && canonical.allSatisfy {
            if case .hide = decision(for: $0).action {
                return true
            }
            return false
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
        let previousOpeningReplacementBytes = openingReplacementBytes
        let previousChoices = choices
        let previousReplacementTexts = replacementTexts

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
                != previousOpeningReplacementBytes[typeIdentifier]
            let hadAuthoredReplace = previousChoices[typeIdentifier] == .replace
                || replacementWasAuthored
            guard !hadAuthoredReplace || Self.canReplace(
                canonical: representation,
                effective: latest.effectiveByType[typeIdentifier]
            ) else {
                return false
            }
        }

        item = details.item
        effectiveByType = latest.effectiveByType
        openingChoices = latest.choices
        openingReplacementBytes = latest.replacementTexts.mapValues {
            Data($0.utf8)
        }
        choices = latest.choices
        replacementTexts = latest.replacementTexts

        for representation in canonical {
            let typeIdentifier = representation.typeIdentifier
            let previousChoice = previousChoices[typeIdentifier]
                ?? .keepCurrent
            if canReplace(representation) {
                choices[typeIdentifier] = previousChoice

                let previousText = previousReplacementTexts[typeIdentifier]
                let previousBytes = previousText.map { Data($0.utf8) }
                let replacementWasAuthored = previousBytes
                    != previousOpeningReplacementBytes[typeIdentifier]
                if previousChoice == .replace || replacementWasAuthored,
                   let previousText {
                    replacementTexts[typeIdentifier] = previousText
                }
            } else if previousChoice != .replace {
                choices[typeIdentifier] = previousChoice
            }
        }
        isAwaitingLatestContent = false
        return true
    }

    package func canReplace(_ representation: HistoryRepresentation) -> Bool {
        Self.canReplace(
            canonical: representation,
            effective: effectiveByType[representation.typeIdentifier]
        )
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

    private struct InitialState {
        let effectiveByType: [String: HistoryRepresentation]
        let choices: [String: Choice]
        let replacementTexts: [String: String]
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
        for representation in canonical {
            let typeIdentifier = representation.typeIdentifier
            initialChoices[typeIdentifier] = .keepCurrent
            if canReplace(
                canonical: representation,
                effective: currentByType[typeIdentifier]
            ) {
                initialTexts[typeIdentifier] = currentByType[typeIdentifier]
                    .flatMap(decodedText)
                    ?? decodedText(representation)
                    ?? ""
            }
        }
        return InitialState(
            effectiveByType: currentByType,
            choices: initialChoices,
            replacementTexts: initialTexts
        )
    }

    /// Replace is an encode operation, not a text-likeness heuristic. Clipy
    /// currently owns exactly one paired editor codec: literal Swift String
    /// <-> `public.utf8-plain-text` bytes. Structured, abstract, and
    /// unspecified-encoding UTIs remain byte-exact through Keep Current / Use
    /// Original / Hide until their own encoders land (review TYPE-2; pasteboard
    /// type-system memo §9.2).
    private static let replaceableTypeIdentifier: ClipboardFormatIdentifier =
        .utf8PlainText

    /// A visible current value must decode with the same exact codec used to
    /// encode its replacement. When the type is currently hidden, a valid
    /// Canonical UTF-8 value remains an explicit, safe starting point for
    /// replacing (and therefore restoring) that representation.
    private static func canReplace(
        canonical: HistoryRepresentation,
        effective: HistoryRepresentation?
    ) -> Bool {
        guard supportsLiteralReplacement(canonical) else {
            return false
        }
        guard let effective else {
            return true
        }
        return supportsLiteralReplacement(effective)
    }

    private static func supportsLiteralReplacement(
        _ representation: HistoryRepresentation
    ) -> Bool {
        guard ClipboardFormatIdentifier(
            rawValue: representation.typeIdentifier
        ) == replaceableTypeIdentifier else {
            return false
        }
        return String(data: representation.bytes, encoding: .utf8) != nil
    }

    private static func decodedText(
        _ representation: HistoryRepresentation
    ) -> String? {
        guard ClipboardFormatIdentifier(
            rawValue: representation.typeIdentifier
        ) == replaceableTypeIdentifier else {
            return nil
        }
        return String(data: representation.bytes, encoding: .utf8)
    }
}
