#if DEBUG
/// EditorRunningUITestJourneyTests — pure fixture proof paired with the real
/// running-app Card 3B journey. It establishes that the revision committed by
/// the narrow DEBUG ordering seam is not the user's authored draft; the XCUI
/// test separately proves that this real commit advances the store and makes
/// the user's subsequent real Save fail stale.
import ClipboardFormats
import Foundation
import HistoryCore
import PresentationUI
import Testing

@Test("editor stale journey builds a distinct coherent competing revision")
func editorStaleJourneyBuildsDistinctCompetingRevision() throws {
    let itemID = HistoryItemID(rawValue: UUID())
    let expected = ContentVersion(rawValue: 7)
    let textType = ClipboardFormatIdentifier.utf8PlainText.rawValue
    let siblingType = "com.example.editor-runtime-sibling"
    let authoredBytes = Data("clipy-editor-stale-draft".utf8)
    let request = RevisionRequest(
        itemID: itemID,
        expected: expected,
        intent: .replace(
            RevisionDraft(decisions: [
                RevisionDecision(
                    typeIdentifier: textType,
                    action: .replace(bytes: authoredBytes)
                ),
                RevisionDecision(
                    typeIdentifier: siblingType,
                    action: .inheritCanonical
                ),
            ])
        )
    )

    let competing = try #require(
        HistoryViewState.competingEditorRevisionForRunningUITest(
            for: request
        )
    )
    #expect(competing.itemID == itemID)
    #expect(competing.expected == expected)

    guard case .replace(let draft) = competing.intent else {
        Issue.record("The competing request was not a replace draft")
        return
    }
    let byType = Dictionary(
        uniqueKeysWithValues: draft.decisions.map {
            ($0.typeIdentifier, $0.action)
        }
    )
    #expect(
        byType[textType]
            == .replace(bytes: Data("clipy-editor-competing-revision".utf8))
    )
    #expect(byType[textType] != .replace(bytes: authoredBytes))
    #expect(byType[siblingType] == .inheritCanonical)
}
#endif
