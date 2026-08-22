/// ReviseEditorDraftTests — review Card 3's pure regression seam.  "Keep
/// Current" must preserve the bytes visible when the editor opened; it must
/// never silently mean "restore Canonical".
import Foundation
import HistoryCore
import PresentationUI
import Testing

struct ReviseEditorDraftTests {
    private let textType = "public.utf8-plain-text"
    private let siblingType = "com.example.sibling"

    @Test func keepCurrentPreservesPreviouslyRevisedBytes() {
        let currentText = Data("current revision".utf8)
        let draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: currentText
            )
        )

        let decisions = decisions(from: draft.revisionRequest())

        #expect(
            decisions[textType]
                == .replace(bytes: currentText)
        )
        #expect(decisions[siblingType] == .inheritCanonical)
    }

    @Test func hidingSiblingDoesNotRestorePreviouslyRevisedBytes() {
        let currentText = Data("current revision".utf8)
        var draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: currentText
            )
        )
        draft.setChoice(.hide, for: siblingType)

        let decisions = decisions(from: draft.revisionRequest())

        #expect(decisions[textType] == .replace(bytes: currentText))
        #expect(decisions[siblingType] == .hide)
    }

    @Test func useOriginalIsTheOnlyChoiceThatRestoresCanonicalBytes() {
        var draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: Data("current revision".utf8)
            )
        )
        draft.setChoice(.useOriginal, for: textType)

        let decisions = decisions(from: draft.revisionRequest())

        #expect(decisions[textType] == .inheritCanonical)
        #expect(decisions[siblingType] == .inheritCanonical)
    }

    @Test func keepCurrentPreservesHiddenStateUntilUseOriginalIsChosen() {
        let canonical = HistoryRepresentation(
            typeIdentifier: siblingType,
            bytes: Data([0x10, 0x20])
        )
        var draft = ReviseEditorDraft(
            details: details(canonical: [canonical], effective: [])
        )

        #expect(draft.allRepresentationsHidden)
        #expect(
            decisions(from: draft.revisionRequest())[siblingType] == .hide
        )

        draft.setChoice(.useOriginal, for: siblingType)

        #expect(!draft.allRepresentationsHidden)
        #expect(
            decisions(from: draft.revisionRequest())[siblingType]
                == .inheritCanonical
        )
    }

    private func details(
        canonicalText: Data,
        effectiveText: Data
    ) -> HistoryDetails {
        let sibling = Data([0x10, 0x20])
        return details(
            canonical: [
                HistoryRepresentation(
                    typeIdentifier: textType,
                    bytes: canonicalText
                ),
                HistoryRepresentation(
                    typeIdentifier: siblingType,
                    bytes: sibling
                ),
            ],
            effective: [
                HistoryRepresentation(
                    typeIdentifier: textType,
                    bytes: effectiveText
                ),
                HistoryRepresentation(
                    typeIdentifier: siblingType,
                    bytes: sibling
                ),
            ]
        )
    }

    private func details(
        canonical: [HistoryRepresentation],
        effective: [HistoryRepresentation]
    ) -> HistoryDetails {
        HistoryDetails(
            item: HistoryItemReference(
                id: HistoryItemID(
                    rawValue: UUID(
                        uuidString: "00000000-0000-0000-0000-000000000301"
                    )!
                ),
                contentVersion: ContentVersion(rawValue: 2)
            ),
            canonical: canonical,
            effective: effective,
            revisions: [],
            occurrence: CopyOccurrenceSummary(
                firstCopiedAt: Date(timeIntervalSinceReferenceDate: 1),
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: 2),
                count: 1,
                firstSource: nil,
                lastSource: nil
            ),
            pinnedPosition: nil
        )
    }

    private func decisions(
        from request: RevisionRequest
    ) -> [String: RevisionDecisionAction] {
        guard case .replace(let draft) = request.intent else {
            Issue.record("Expected a replace revision request")
            return [:]
        }
        return Dictionary(
            draft.decisions.map { ($0.typeIdentifier, $0.action) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
