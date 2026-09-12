/// ReviseEditorDraftTests — review Card 3's pure regression seam.  "Keep
/// Current" must preserve the bytes visible when the editor opened; it must
/// never silently mean "restore Canonical".
import Foundation
@testable import HistoryCore
@testable import ClipyApp
import Testing

struct ReviseEditorDraftTests {
    private let textType = "public.utf8-plain-text"
    private let siblingType = "com.example.sibling"

    @Test func directEditingLoadsOnlyTheSoleEffectivePlainTextWithoutChangingDecisions() throws {
        let original = HistoryRepresentation(typeIdentifier: textType, bytes: Data("original".utf8))
        let current = HistoryRepresentation(typeIdentifier: textType, bytes: Data("current".utf8))
        let hidden = HistoryRepresentation(typeIdentifier: siblingType, bytes: Data([0x10]))
        var draft = ReviseEditorDraft(details: details(canonical: [original, hidden], effective: [current]))

        let request = try #require(draft.directEditingRequest)
        #expect(request.basis == .effective)
        #expect(request.typeIdentifier == textType)
        #expect(request.pasteboardItemIndex == 0)
        #expect(!draft.hasReplacementSource(for: textType))
        let sourceAccepted = draft.installReplacementSource(current, forDirectEditing: true)
        #expect(sourceAccepted)
        #expect(draft.directEditingRequest == nil)
        #expect(draft.directEditingIdentity == RepresentationIdentity(typeIdentifier: textType))
        #expect(draft.replacementText(for: textType) == "current")
        #expect(!draft.isDirty)
        #expect(draft.dismissalDecision == .dismiss)
        #expect(decisions(from: draft.revisionRequest())[textType] == .inheritCurrent)
        #expect(decisions(from: draft.revisionRequest())[siblingType] == .hide)
        #expect(!draft.hasReplacementSource(for: siblingType))
    }

    @Test func directEditingDoesNotChooseBetweenFormatsOrClipboardItems() {
        let text = HistoryRepresentation(typeIdentifier: textType, bytes: Data("text".utf8))
        let sibling = HistoryRepresentation(typeIdentifier: siblingType, bytes: Data([0x10]))
        let secondItem = HistoryRepresentation(typeIdentifier: textType, bytes: Data("second".utf8), pasteboardItemIndex: 1)
        for representations in [[text, sibling], [text, secondItem], [sibling]] {
            var draft = ReviseEditorDraft(details: details(canonical: representations, effective: representations))
            #expect(draft.directEditingRequest == nil)
            let sourceAccepted = draft.installReplacementSource(text, forDirectEditing: true)
            #expect(!sourceAccepted)
            #expect(!draft.hasReplacementSource(for: textType))
            #expect(!draft.isDirty)
        }
    }

    @Test func directEditingRequiresAValidSourceAndOnlyActualByteChangesAuthorReplacement() {
        let original = HistoryRepresentation(typeIdentifier: textType, bytes: Data([0xC3, 0xA9]))
        var draft = ReviseEditorDraft(details: details(canonical: [original], effective: [original]))
        let invalidSourceAccepted = draft.installReplacementSource(
            HistoryRepresentation(typeIdentifier: textType, bytes: Data([0xFF])),
            forDirectEditing: true
        )
        #expect(!invalidSourceAccepted)
        #expect(draft.directEditingIdentity == nil)
        #expect(!draft.isDirty)
        let originalSourceAccepted = draft.installReplacementSource(original, forDirectEditing: true)
        #expect(originalSourceAccepted)
        draft.setReplacementText("e\u{301}", for: textType)
        #expect(draft.dismissalDecision == .confirmDiscard)
        #expect(decisions(from: draft.revisionRequest())[textType] == .replace(bytes: Data([0x65, 0xCC, 0x81])))
        draft.setReplacementText("", for: textType)
        #expect(draft.hasEmptyReplacement)
        #expect(!draft.canSubmit)
        draft.setReplacementText("\u{E9}", for: textType)
        #expect(draft.canSubmit)
        #expect(!draft.isDirty)
        #expect(draft.dismissalDecision == .dismiss)
        #expect(decisions(from: draft.revisionRequest())[textType] == .inheritCurrent)
    }

    @Test func directEditingLeavesExplicitFormatDecisionsUnderUserControl() {
        let original = HistoryRepresentation(typeIdentifier: textType, bytes: Data("original".utf8))
        var draft = ReviseEditorDraft(details: details(canonical: [original], effective: [original]))
        let sourceAccepted = draft.installReplacementSource(original, forDirectEditing: true)
        #expect(sourceAccepted)
        draft.setChoice(.useOriginal, for: textType)
        #expect(draft.directEditingIdentity == nil)
        #expect(decisions(from: draft.revisionRequest())[textType] == .inheritCanonical)
        draft.setChoice(.replace, for: textType)
        draft.setReplacementText("edit", for: textType)
        draft.setReplacementText("original", for: textType)
        #expect(draft.isDirty)
        #expect(decisions(from: draft.revisionRequest())[textType] == .replace(bytes: original.bytes))
    }

    @Test(arguments: ReviseEditorDraftTests.utf16EncodingFixtures)
    func directUTF16EditingKeepsEncodingAndReturnsCleanOnlyBeforeRebase(fixture: UTF16EncodingFixture) {
        let source = HistoryRepresentation(typeIdentifier: fixture.type, bytes: fixture.initial)
        var draft = ReviseEditorDraft(details: utf16Details(
            type: fixture.type, canonical: fixture.initial, effective: fixture.initial
        ))
        let sourceAccepted = draft.installReplacementSource(source, forDirectEditing: true)
        #expect(sourceAccepted)
        #expect(!draft.isDirty)
        draft.setReplacementText("B🌿", for: fixture.type)
        #expect(decisions(from: draft.revisionRequest())[fixture.type] == .replace(bytes: fixture.edited))
        draft.setReplacementText("A", for: fixture.type)
        #expect(draft.dismissalDecision == .dismiss)
        #expect(decisions(from: draft.revisionRequest())[fixture.type] == .inheritCurrent)

        draft.setReplacementText("B🌿", for: fixture.type)
        draft.markStale()
        #expect(!draft.canSubmit)
        let olderReloadAccepted = draft.reloadLatest(details: utf16Details(
            type: fixture.type, canonical: fixture.initial, effective: fixture.initial, version: 1
        ))
        #expect(!olderReloadAccepted)
        #expect(draft.directEditingIdentity != nil)
        let latestReloadAccepted = draft.reloadLatest(details: utf16Details(
            type: fixture.type, canonical: fixture.initial,
            effective: Data([0xFE, 0xFF, 0x00, 0x43]), version: 3
        ))
        #expect(latestReloadAccepted)
        #expect(draft.directEditingIdentity == nil)
        #expect(draft.directEditingRequest == nil)
        #expect(draft.revisionRequest().expected == ContentVersion(rawValue: 3))
        #expect(decisions(from: draft.revisionRequest())[fixture.type] == .replace(bytes: fixture.edited))
        // Returning to the old source means A, not the competitor's C.
        draft.setReplacementText("A", for: fixture.type)
        #expect(draft.dismissalDecision == .confirmDiscard)
        #expect(decisions(from: draft.revisionRequest())[fixture.type] == .replace(bytes: fixture.initial))
    }

    @Test func untouchedDirectEditorReloadsLatestSourceAndItsEncoding() {
        let type = "public.utf16-plain-text"
        let original = Data([0xFF, 0xFE, 0x41, 0x00])
        let latest = Data([0xFE, 0xFF, 0x00, 0x43])
        var draft = ReviseEditorDraft(details: utf16Details(type: type, canonical: original, effective: original))
        let originalSourceAccepted = draft.installReplacementSource(
            HistoryRepresentation(typeIdentifier: type, bytes: original), forDirectEditing: true
        )
        #expect(originalSourceAccepted)
        draft.markStale()
        #expect(draft.directEditingRequest == nil)
        let latestReloadAccepted = draft.reloadLatest(details: utf16Details(
            type: type, canonical: original, effective: latest, version: 3
        ))
        #expect(latestReloadAccepted)
        #expect(!draft.hasReplacementSource(for: type))
        #expect(draft.directEditingRequest?.item.contentVersion == ContentVersion(rawValue: 3))
        let latestSourceAccepted = draft.installReplacementSource(
            HistoryRepresentation(typeIdentifier: type, bytes: latest), forDirectEditing: true
        )
        #expect(latestSourceAccepted)
        #expect(draft.replacementText(for: type) == "C")
        #expect(draft.dismissalDecision == .dismiss)
        draft.setReplacementText("D", for: type)
        #expect(decisions(from: draft.revisionRequest())[type] == .replace(bytes: Data([0xFE, 0xFF, 0x00, 0x44])))
    }

    @Test func metadataDoesNotDownloadOrDecodeAnyReplacementUntilExplicitlyLoaded() {
        var draft = ReviseEditorDraft(details: details(
            canonicalText: Data("original".utf8), effectiveText: Data("current".utf8)
        ))
        #expect(!draft.hasReplacementSource(for: textType))
        #expect(draft.replacementText(for: textType).isEmpty)
        #expect(!draft.hasReplacementSource(for: siblingType))
        #expect(draft.replacementRequest(for: siblingType) == nil)
        draft.setChoice(.replace, for: textType)
        draft.setReplacementText("not yet authorized by a loaded source", for: textType)
        #expect(draft.choice(for: textType) == .keepCurrent)
        #expect(draft.replacementText(for: textType).isEmpty)
        #expect(!draft.isDirty)
        #expect(decisions(from: draft.revisionRequest())[textType] == .inheritCurrent)
        installSource(Data("current".utf8), for: textType, in: &draft)
        #expect(!draft.isDirty)
        #expect(!draft.hasReplacementSource(for: siblingType))
        draft.setChoice(.replace, for: textType)
        #expect(draft.isDirty)
    }

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
                == .inheritCurrent
        )
        #expect(decisions[siblingType] == .inheritCurrent)
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

        #expect(decisions[textType] == .inheritCurrent)
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
        #expect(decisions[siblingType] == .inheritCurrent)
    }

    @Test func keepCurrentPreservesHiddenStateUntilUseOriginalIsChosen() {
        let canonical = HistoryRepresentation(
            typeIdentifier: siblingType,
            bytes: Data([0x10, 0x20])
        )
        let visible = HistoryRepresentation(typeIdentifier: textType, bytes: Data("visible".utf8))
        var draft = ReviseEditorDraft(details: details(
            canonical: [canonical, visible], effective: [visible]
        ))
        draft.setChoice(.hide, for: textType)

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

    @Test func openingDraftIsCleanAndCanDismissDirectly() {
        let draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: Data("current revision".utf8)
            )
        )

        #expect(!draft.isDirty)
        #expect(draft.dismissalDecision == .dismiss)
    }

    @Test func changedChoiceRequiresConfirmationUntilRestoredExactly() {
        var draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: Data("current revision".utf8)
            )
        )

        draft.setChoice(.useOriginal, for: textType)

        #expect(draft.isDirty)
        #expect(draft.dismissalDecision == .confirmDiscard)

        draft.setChoice(.keepCurrent, for: textType)

        #expect(!draft.isDirty)
        #expect(draft.dismissalDecision == .dismiss)
    }

    @Test func replacementTextDirtyStateComparesExactUTF8Bytes() {
        var draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: Data([0xC3, 0xA9])
            )
        )

        installSource(Data([0xC3, 0xA9]), for: textType, in: &draft)
        draft.setReplacementText("e\u{301}", for: textType)

        #expect(draft.isDirty)
        #expect(
            Data(draft.replacementText(for: textType).utf8)
                == Data([0x65, 0xCC, 0x81])
        )

        draft.setReplacementText("\u{E9}", for: textType)

        #expect(!draft.isDirty)
        #expect(
            Data(draft.replacementText(for: textType).utf8)
                == Data([0xC3, 0xA9])
        )
    }

    @Test func restoringOneTextDoesNotLoseAnotherFormatsUnsavedChangesAcrossReload() {
        let secondType = "public.utf16-external-plain-text"
        let firstBytes = Data("original".utf8)
        let secondBytes = Data([0xFE, 0xFF, 0x00, 0x41])
        let originals = [
            HistoryRepresentation(typeIdentifier: textType, bytes: firstBytes),
            HistoryRepresentation(typeIdentifier: secondType, bytes: secondBytes),
        ]
        var draft = ReviseEditorDraft(details: details(canonical: originals, effective: originals))
        installSource(firstBytes, for: textType, in: &draft)
        installSource(secondBytes, for: secondType, in: &draft)
        draft.setReplacementText("first edit", for: textType)
        draft.setReplacementText("B", for: secondType)
        draft.setReplacementText("original", for: textType)
        #expect(draft.dismissalDecision == .confirmDiscard)

        draft.markStale()
        let reloaded = draft.reloadLatest(details: details(canonical: originals, effective: originals, version: 3))
        #expect(reloaded)
        #expect(!draft.hasReplacementSource(for: textType))
        #expect(draft.replacementText(for: secondType) == "B")
        #expect(draft.dismissalDecision == .confirmDiscard)

        draft.setReplacementText("A", for: secondType)
        #expect(!draft.isDirty)
        #expect(draft.dismissalDecision == .dismiss)
        draft.setChoice(.hide, for: secondType)
        #expect(draft.isDirty)
        draft.setChoice(.keepCurrent, for: secondType)
        #expect(!draft.isDirty)
    }

    @Test func dirtyDraftKeepsOpeningReferenceAndLiteralReplacementBytes() {
        var draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: Data("current revision".utf8)
            )
        )
        installSource(Data("current revision".utf8), for: textType, in: &draft)
        draft.setChoice(.replace, for: textType)
        draft.setReplacementText("draft-A", for: textType)

        let request = draft.revisionRequest()
        let revisionDecisions = decisions(from: request)
        #expect(request.expected == ContentVersion(rawValue: 2))
        #expect(
            revisionDecisions[textType]
                == .replace(bytes: Data("draft-A".utf8))
        )
        #expect(draft.isDirty)
        #expect(draft.dismissalDecision == .confirmDiscard)
    }

    @Test func staleDraftCannotSubmitAgainAndKeepsLiteralReplacementBytes() {
        var draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: Data("current revision".utf8)
            )
        )
        installSource(Data("current revision".utf8), for: textType, in: &draft)
        draft.setChoice(.replace, for: textType)
        draft.setReplacementText("draft-A", for: textType)

        draft.markStale()

        #expect(draft.isAwaitingLatestContent)
        #expect(!draft.canSubmit)
        #expect(draft.isDirty)
        #expect(draft.replacementText(for: textType) == "draft-A")
        #expect(
            decisions(from: draft.revisionRequest())[textType]
                == .replace(bytes: Data("draft-A".utf8))
        )
    }

    @Test func reloadLatestAdvancesBaseAndPreservesAuthoredEditableBytes() {
        var draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original-v1".utf8),
                effectiveText: Data("effective-v1".utf8)
            )
        )
        installSource(Data("effective-v1".utf8), for: textType, in: &draft)
        draft.setChoice(.replace, for: textType)
        draft.setReplacementText("draft-A", for: textType)
        draft.markStale()

        draft.reloadLatest(
            details: details(
                canonical: [
                    HistoryRepresentation(
                        typeIdentifier: textType,
                        bytes: Data("original-v1".utf8)
                    ),
                    HistoryRepresentation(
                        typeIdentifier: siblingType,
                        bytes: Data([0x10, 0x20])
                    ),
                ],
                effective: [
                    HistoryRepresentation(
                        typeIdentifier: textType,
                        bytes: Data("effective-v3".utf8)
                    ),
                    HistoryRepresentation(
                        typeIdentifier: siblingType,
                        bytes: Data("sibling-effective-v3".utf8)
                    ),
                ],
                version: 3
            )
        )

        let request = draft.revisionRequest()
        let revisionDecisions = decisions(from: request)
        #expect(!draft.isAwaitingLatestContent)
        #expect(draft.canSubmit)
        #expect(draft.isDirty)
        #expect(request.expected == ContentVersion(rawValue: 3))
        #expect(
            revisionDecisions[textType]
                == .replace(bytes: Data("draft-A".utf8))
        )
        #expect(
            revisionDecisions[siblingType]
                == .inheritCurrent
        )
        #expect(
            draft.canonicalRepresentations.first?.byteCount
                == Data("original-v1".utf8).count
        )
    }

    @Test func reloadLatestWithoutEditsAdoptsLatestCleanBaseline() {
        var draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: Data("effective-v1".utf8)
            )
        )
        draft.markStale()

        draft.reloadLatest(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: Data("effective-v3".utf8),
                version: 3
            )
        )

        #expect(!draft.isDirty)
        #expect(draft.dismissalDecision == .dismiss)
        #expect(
            decisions(from: draft.revisionRequest())[textType]
                == .inheritCurrent
        )
    }

    @Test func reloadLatestKeepsCanonicalTypesWhenEffectiveHidesAType() {
        var draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: Data("current revision".utf8)
            )
        )
        installSource(Data("current revision".utf8), for: textType, in: &draft)
        draft.setChoice(.replace, for: textType)
        draft.setReplacementText("draft-A", for: textType)
        draft.setChoice(.hide, for: siblingType)
        draft.markStale()

        draft.reloadLatest(
            details: details(
                canonical: [
                    HistoryRepresentation(
                        typeIdentifier: textType,
                        bytes: Data("original capture".utf8)
                    ),
                    HistoryRepresentation(
                        typeIdentifier: siblingType,
                        bytes: Data([0x10, 0x20])
                    ),
                ],
                effective: [
                    HistoryRepresentation(
                        typeIdentifier: textType,
                        bytes: Data("latest current".utf8)
                    ),
                ],
                version: 4
            )
        )

        let revisionDecisions = decisions(from: draft.revisionRequest())
        #expect(
            draft.canonicalRepresentations.map(\.typeIdentifier)
                == [textType, siblingType]
        )
        #expect(
            revisionDecisions[textType]
                == .replace(bytes: Data("draft-A".utf8))
        )
        #expect(revisionDecisions[siblingType] == .hide)
    }

    @Test func newlyHiddenTextDropsOnlyAnInspectedSourceAndNextReplaceReadsCanonical() {
        let original = HistoryRepresentation(typeIdentifier: textType, bytes: Data("original".utf8))
        let current = HistoryRepresentation(typeIdentifier: textType, bytes: Data("current".utf8))
        let sibling = HistoryRepresentation(typeIdentifier: siblingType, bytes: Data([0x10, 0x20]))
        var draft = ReviseEditorDraft(details: details(
            canonical: [original, sibling], effective: [current, sibling]
        ))
        installSource(current.bytes, for: textType, in: &draft)
        #expect(!draft.isDirty)
        draft.markStale()
        let reloaded = draft.reloadLatest(details: details(
            canonical: [original, sibling], effective: [sibling], version: 3
        ))
        #expect(reloaded)
        #expect(!draft.isAwaitingLatestContent)
        #expect(!draft.isDirty)
        #expect(!draft.hasReplacementSource(for: textType))
        #expect(draft.replacementText(for: textType).isEmpty)
        #expect(decisions(from: draft.revisionRequest())[textType] == .hide)
        #expect(decisions(from: draft.revisionRequest())[siblingType] == .inheritCurrent)
        installSource(original.bytes, for: textType, in: &draft, basis: .canonical)
        draft.setChoice(.replace, for: textType)
        #expect(decisions(from: draft.revisionRequest())[textType] == .replace(bytes: original.bytes))
        #expect(draft.revisionRequest().expected == ContentVersion(rawValue: 3))
    }

    @Test func olderMetadataCannotResetTheStaleBaseOrAuthoredText() {
        var draft = ReviseEditorDraft(details: details(
            canonicalText: Data("original".utf8), effectiveText: Data("current".utf8), version: 4
        ))
        installSource(Data("current".utf8), for: textType, in: &draft)
        draft.setChoice(.replace, for: textType)
        draft.setReplacementText("draft-A", for: textType)
        draft.markStale()
        let reloaded = draft.reloadLatest(details: details(
            canonicalText: Data("original".utf8), effectiveText: Data("older".utf8), version: 3
        ))
        #expect(!reloaded)
        #expect(draft.isAwaitingLatestContent)
        #expect(!draft.canSubmit)
        #expect(draft.revisionRequest().expected == ContentVersion(rawValue: 4))
        #expect(decisions(from: draft.revisionRequest())[textType] == .replace(bytes: Data("draft-A".utf8)))
    }

    @Test func reloadConflictPreservesEntireAuthoredDraftAndOldBase() throws {
        var draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: Data("current revision".utf8)
            )
        )
        installSource(Data("current revision".utf8), for: textType, in: &draft)
        draft.setChoice(.replace, for: textType)
        draft.setReplacementText("draft-A", for: textType)
        draft.markStale()

        let reloaded = draft.reloadLatest(
            details: details(
                canonical: [
                    HistoryRepresentation(
                        typeIdentifier: textType,
                        bytes: Data("original capture".utf8)
                    ),
                ],
                effective: [
                    HistoryRepresentation(
                        typeIdentifier: textType,
                        bytes: Data([0xFF])
                    ),
                ],
                version: 5
            )
        )

        let representation = try #require(
            draft.canonicalRepresentations.first
        )
        #expect(!reloaded)
        #expect(draft.isAwaitingLatestContent)
        #expect(!draft.canSubmit)
        #expect(draft.canReplace(representation))
        #expect(draft.choice(for: textType) == .replace)
        #expect(draft.replacementText(for: textType) == "draft-A")
        #expect(
            decisions(from: draft.revisionRequest())[textType]
                == .replace(bytes: Data("draft-A".utf8))
        )
        #expect(
            draft.revisionRequest().expected == ContentVersion(rawValue: 2)
        )
    }

    @Test func emptyReplacementIsInvalidUntilLiteralBytesExist() {
        var draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: Data("current revision".utf8)
            )
        )
        installSource(Data("current revision".utf8), for: textType, in: &draft)
        draft.setChoice(.replace, for: textType)
        draft.setReplacementText("", for: textType)

        #expect(draft.hasEmptyReplacement)

        draft.setReplacementText("replacement", for: textType)

        #expect(!draft.hasEmptyReplacement)
    }

    @Test func unsupportedTextFormatsRemainOutsideLiteralReplacement() {
        let utf8 = HistoryRepresentation(
            typeIdentifier: textType,
            bytes: Data("literal UTF-8".utf8)
        )
        let utf8Draft = ReviseEditorDraft(
            details: details(canonical: [utf8], effective: [utf8])
        )

        #expect(utf8Draft.canReplace(metadata(utf8)))

        for fixture in nonReplaceableFormatFixtures() {
            let representation = HistoryRepresentation(
                typeIdentifier: fixture.typeIdentifier,
                bytes: fixture.canonicalBytes
            )
            let draft = ReviseEditorDraft(
                details: details(
                    canonical: [representation],
                    effective: [representation]
                )
            )

            #expect(!draft.canReplace(metadata(representation)))
            #expect(draft.replacementRequest(for: fixture.typeIdentifier) == nil)
            #expect(!draft.hasReplacementSource(for: fixture.typeIdentifier))
        }
    }

    @Test func keepCurrentPreservesUnsupportedFormatBytesExactly() {
        for fixture in nonReplaceableFormatFixtures() {
            let draft = ReviseEditorDraft(
                details: details(
                    canonical: [
                        HistoryRepresentation(
                            typeIdentifier: fixture.typeIdentifier,
                            bytes: fixture.canonicalBytes
                        ),
                    ],
                    effective: [
                        HistoryRepresentation(
                            typeIdentifier: fixture.typeIdentifier,
                            bytes: fixture.effectiveBytes
                        ),
                    ]
                )
            )

            #expect(
                decisions(from: draft.revisionRequest())[
                    fixture.typeIdentifier
                ] == .inheritCurrent
            )
        }
    }

    @Test func unsupportedFormatsRejectProgrammaticReplaceIntent() {
        for fixture in nonReplaceableFormatFixtures() {
            var draft = ReviseEditorDraft(
                details: details(
                    canonical: [
                        HistoryRepresentation(
                            typeIdentifier: fixture.typeIdentifier,
                            bytes: fixture.canonicalBytes
                        ),
                    ],
                    effective: [
                        HistoryRepresentation(
                            typeIdentifier: fixture.typeIdentifier,
                            bytes: fixture.effectiveBytes
                        ),
                    ]
                )
            )

            draft.setReplacementText(
                "ordinary text is not \(fixture.typeIdentifier)",
                for: fixture.typeIdentifier
            )
            draft.setChoice(.replace, for: fixture.typeIdentifier)

            #expect(draft.choice(for: fixture.typeIdentifier) == .keepCurrent)
            #expect(draft.replacementText(for: fixture.typeIdentifier).isEmpty)
            #expect(!draft.isDirty)
            #expect(
                decisions(from: draft.revisionRequest())[
                    fixture.typeIdentifier
                ] == .inheritCurrent
            )
        }
    }

    @Test func exactUTF8PlainTextReplaceEmitsLiteralUTF8Bytes() {
        var draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: Data("current revision".utf8)
            )
        )

        installSource(Data("current revision".utf8), for: textType, in: &draft)
        draft.setChoice(.replace, for: textType)
        draft.setReplacementText("replacement 🌿", for: textType)

        #expect(draft.choice(for: textType) == .replace)
        #expect(
            decisions(from: draft.revisionRequest())[textType]
                == .replace(bytes: Data("replacement 🌿".utf8))
        )
    }

    @Test(arguments: ["public.utf16-plain-text", "public.utf16-external-plain-text"])
    func utf16ChoicesPreserveRawCurrentOrCanonicalBytes(type: String) {
        let original = Data([0xFF, 0xFE, 0x41, 0x00])
        let current = Data([0xFE, 0xFF, 0x00, 0x42])
        var draft = ReviseEditorDraft(details: utf16Details(
            type: type, canonical: original, effective: current
        ))
        #expect(decisions(from: draft.revisionRequest())[type] == .inheritCurrent)
        draft.setChoice(.useOriginal, for: type)
        #expect(decisions(from: draft.revisionRequest())[type] == .inheritCanonical)
        draft.setChoice(.hide, for: type)
        #expect(decisions(from: draft.revisionRequest())[type] == .hide)
        #expect(draft.allRepresentationsHidden)
        draft.setChoice(.keepCurrent, for: type)
        #expect(decisions(from: draft.revisionRequest())[type] == .inheritCurrent)
        #expect(!draft.hasReplacementSource(for: type))
        installSource(current, for: type, in: &draft)
        draft.setChoice(.replace, for: type)
        #expect(draft.replacementText(for: type) == "B")
        #expect(decisions(from: draft.revisionRequest())[type] == .replace(bytes: current))
    }

    @Test(arguments: ReviseEditorDraftTests.utf16EncodingFixtures)
    func utf16ReplacementRetainsTheSourceByteOrderAndBOM(fixture: UTF16EncodingFixture) throws {
        var draft = ReviseEditorDraft(details: utf16Details(
            type: fixture.type, canonical: fixture.initial, effective: fixture.initial
        ))
        let representation = try #require(draft.canonicalRepresentations.first)
        #expect(draft.canReplace(representation))
        #expect(draft.replacementText(for: fixture.type).isEmpty)
        installSource(fixture.initial, for: fixture.type, in: &draft)
        #expect(draft.replacementText(for: fixture.type) == "A")
        #expect(!draft.isDirty)

        draft.setChoice(.replace, for: fixture.type)
        #expect(decisions(from: draft.revisionRequest())[fixture.type] == .replace(bytes: fixture.initial))
        draft.setReplacementText("B🌿", for: fixture.type)
        #expect(decisions(from: draft.revisionRequest())[fixture.type] == .replace(bytes: fixture.edited))
    }

    @Test func utf16AuthoredReplacementKeepsItsCodecAcrossRepeatedReloads() {
        let type = "public.utf16-external-plain-text"
        let original = Data([0xFF, 0xFE, 0x41, 0x00])
        var draft = ReviseEditorDraft(details: utf16Details(
            type: type, canonical: original, effective: original
        ))
        installSource(original, for: type, in: &draft)
        draft.setChoice(.replace, for: type)
        draft.setReplacementText("B🌿", for: type)

        for version in [UInt64(3), UInt64(4)] {
            draft.markStale()
            let reloaded = draft.reloadLatest(details: utf16Details(
                type: type,
                canonical: original,
                effective: Data([0xFE, 0xFF, 0x00, 0x43]),
                version: version
            ))
            #expect(reloaded)
            #expect(draft.revisionRequest().expected == ContentVersion(rawValue: version))
            #expect(draft.replacementText(for: type) == "B🌿")
            #expect(decisions(from: draft.revisionRequest())[type] == .replace(
                bytes: Data([0xFF, 0xFE, 0x42, 0x00, 0x3C, 0xD8, 0x3F, 0xDF])
            ))
            #expect(draft.isDirty)
            #expect(draft.canSubmit)
        }
    }

    @Test func untouchedUTF16ReloadAdoptsTheNewEffectiveCodec() {
        let type = "public.utf16-plain-text"
        let original = Data([0xFF, 0xFE, 0x41, 0x00])
        let latest = Data([0xFE, 0xFF, 0x00, 0x41])
        var draft = ReviseEditorDraft(details: utf16Details(
            type: type, canonical: original, effective: original
        ))
        installSource(original, for: type, in: &draft)
        #expect(draft.replacementText(for: type) == "A")
        draft.markStale()
        let reloaded = draft.reloadLatest(details: utf16Details(
            type: type, canonical: original, effective: latest, version: 3
        ))
        #expect(reloaded)
        #expect(!draft.isDirty)
        #expect(!draft.hasReplacementSource(for: type))
        #expect(draft.replacementText(for: type).isEmpty)
        #expect(draft.replacementRequest(for: type)?.item.contentVersion == ContentVersion(rawValue: 3))
        installSource(latest, for: type, in: &draft)
        #expect(draft.replacementText(for: type) == "A")
        draft.setChoice(.replace, for: type)
        draft.setReplacementText("B", for: type)
        #expect(decisions(from: draft.revisionRequest())[type] == .replace(
            bytes: Data([0xFE, 0xFF, 0x00, 0x42])
        ))
    }

    @Test func hiddenUTF16ReplacementStartsFromCanonicalTextAndEncoding() {
        let type = "public.utf16-external-plain-text"
        let canonical = HistoryRepresentation(
            typeIdentifier: type, bytes: Data([0xFE, 0xFF, 0x00, 0x41])
        )
        let visible = HistoryRepresentation(typeIdentifier: siblingType, bytes: Data([0x10]))
        var draft = ReviseEditorDraft(details: details(canonical: [canonical, visible], effective: [visible]))
        draft.setChoice(.hide, for: siblingType)
        #expect(draft.allRepresentationsHidden)
        #expect(draft.canReplace(metadata(canonical)))
        installSource(canonical.bytes, for: type, in: &draft, basis: .canonical)
        #expect(draft.replacementText(for: type) == "A")
        draft.setChoice(.replace, for: type)
        #expect(draft.canSubmit)
        #expect(decisions(from: draft.revisionRequest())[type] == .replace(bytes: canonical.bytes))
    }

    @Test func metadataReloadPreservesAuthoredUTF16WithoutReadingNewMalformedBytes() {
        let type = "public.utf16-plain-text"
        let original = Data([0xFF, 0xFE, 0x41, 0x00])
        var draft = ReviseEditorDraft(details: utf16Details(
            type: type, canonical: original, effective: original
        ))
        installSource(original, for: type, in: &draft)
        draft.setChoice(.replace, for: type)
        draft.setReplacementText("B", for: type)
        draft.markStale()

        let reloaded = draft.reloadLatest(details: utf16Details(
            type: type,
            canonical: original,
            effective: Data([0xFF, 0xFE, 0x00, 0xD8]), // unpaired high surrogate
            version: 3
        ))
        #expect(reloaded)
        #expect(!draft.isAwaitingLatestContent)
        #expect(draft.canSubmit)
        #expect(draft.revisionRequest().expected == ContentVersion(rawValue: 3))
        #expect(draft.choice(for: type) == .replace)
        #expect(draft.replacementText(for: type) == "B")
        #expect(decisions(from: draft.revisionRequest())[type] == .replace(
            bytes: Data([0xFF, 0xFE, 0x42, 0x00])
        ))
    }

    @Test func initialEffectiveTextKeepsItsOwnSpellingAndCodec() {
        let type = "public.utf16-external-plain-text"
        let canonical = Data([0xFE, 0xFF, 0x00, 0xE9]) // BE: precomposed é
        let current = Data([0xFF, 0xFE, 0x65, 0x00, 0x01, 0x03]) // LE: e + accent
        var draft = ReviseEditorDraft(details: utf16Details(
            type: type, canonical: canonical, effective: current
        ))
        installSource(current, for: type, in: &draft)
        #expect(draft.replacementText(for: type).unicodeScalars.map(\.value) == [0x65, 0x301])
        #expect(!draft.isDirty)
        draft.setChoice(.replace, for: type)
        #expect(decisions(from: draft.revisionRequest())[type] == .replace(bytes: current))
        draft.setReplacementText("B", for: type)
        #expect(decisions(from: draft.revisionRequest())[type] == .replace(
            bytes: Data([0xFF, 0xFE, 0x42, 0x00])
        ))
    }

    @Test func replacementValidatesOnlyTheExplicitlySelectedEffectiveSource() throws {
        let type = "public.utf16-external-plain-text"
        let valid = Data([0x00, 0x41])
        let malformed = Data([0xD8, 0x00]) // unpaired high surrogate
        for (canonical, current) in [
            (valid, malformed), (malformed, valid), (malformed, malformed),
        ] {
            var draft = ReviseEditorDraft(details: utf16Details(
                type: type, canonical: canonical, effective: current
            ))
            let representation = try #require(draft.canonicalRepresentations.first)
            #expect(draft.canReplace(representation))
            #expect(draft.replacementRequest(for: type)?.basis == .effective)
            #expect(!draft.hasReplacementSource(for: type))
            let installed = draft.installReplacementSource(HistoryRepresentation(typeIdentifier: type, bytes: current))
            #expect(installed == (current == valid))
            draft.setChoice(.replace, for: type)
            #expect(draft.choice(for: type) == (current == valid ? .replace : .keepCurrent))
        }
    }

    @Test(arguments: [Data([0xFF]), Data([0xC3]), Data([0xED, 0xA0, 0x80])])
    func malformedUTF8SourceDoesNotEnableReplacementOrEraseAuthoredText(malformed: Data) {
        var draft = ReviseEditorDraft(details: details(
            canonicalText: Data("original".utf8), effectiveText: malformed
        ))
        let source = HistoryRepresentation(typeIdentifier: textType, bytes: malformed)
        let installedMalformed = draft.installReplacementSource(source)
        #expect(!installedMalformed)
        #expect(!draft.hasReplacementSource(for: textType))
        draft.setChoice(.replace, for: textType)
        #expect(draft.choice(for: textType) == .keepCurrent)
        #expect(!draft.isDirty)

        // A later failed source result cannot clobber an already-authored
        // draft; the UI also owns its separate request-reference check.
        let reloaded = draft.reloadLatest(details: details(
            canonicalText: Data("original".utf8), effectiveText: Data("current".utf8), version: 3
        ))
        #expect(reloaded)
        installSource(Data("current".utf8), for: textType, in: &draft)
        draft.setChoice(.replace, for: textType)
        draft.setReplacementText("authored 🌿", for: textType)
        let reinstalledMalformed = draft.installReplacementSource(source)
        #expect(!reinstalledMalformed)
        #expect(draft.replacementText(for: textType) == "authored 🌿")
        #expect(decisions(from: draft.revisionRequest())[textType] == .replace(bytes: Data("authored 🌿".utf8)))
    }

    @Test func utf16DirtyComparisonPreservesCanonicallyEquivalentSpellings() {
        let type = "public.utf16-external-plain-text"
        let composed = Data([0xFE, 0xFF, 0x00, 0xE9])
        var draft = ReviseEditorDraft(details: utf16Details(
            type: type, canonical: composed, effective: composed
        ))
        installSource(composed, for: type, in: &draft)
        draft.setReplacementText("e\u{301}", for: type)
        #expect(draft.isDirty)
        draft.setChoice(.replace, for: type)
        #expect(decisions(from: draft.revisionRequest())[type] == .replace(
            bytes: Data([0xFE, 0xFF, 0x00, 0x65, 0x03, 0x01])
        ))
        draft.setReplacementText("é", for: type)
        draft.setChoice(.keepCurrent, for: type)
        #expect(!draft.isDirty)
    }

    @Test func utf16BOMDoesNotMakeAnEmptyReplacementSubmittable() {
        let type = "public.utf16-plain-text"
        let original = Data([0xFF, 0xFE, 0x41, 0x00])
        var draft = ReviseEditorDraft(details: utf16Details(
            type: type, canonical: original, effective: original
        ))
        installSource(original, for: type, in: &draft)
        draft.setChoice(.replace, for: type)
        draft.setReplacementText("", for: type)
        #expect(draft.hasEmptyReplacement)
        #expect(!draft.canSubmit)
        draft.setReplacementText("B", for: type)
        #expect(!draft.hasEmptyReplacement)
        #expect(draft.canSubmit)
    }

    private func utf16Details(
        type: String,
        canonical: Data,
        effective: Data,
        version: UInt64 = 2
    ) -> HistoryDetails {
        details(
            canonical: [HistoryRepresentation(typeIdentifier: type, bytes: canonical)],
            effective: [HistoryRepresentation(typeIdentifier: type, bytes: effective)],
            version: version
        )
    }

    struct UTF16EncodingFixture: Sendable {
        let type: String
        let initial: Data
        let edited: Data
    }

    private static let utf16EncodingFixtures: [UTF16EncodingFixture] = [
        .init(type: "public.utf16-plain-text", initial: Data([0x41, 0x00]),
              edited: Data([0x42, 0x00, 0x3C, 0xD8, 0x3F, 0xDF])),
        .init(type: "public.utf16-plain-text", initial: Data([0xFF, 0xFE, 0x41, 0x00]),
              edited: Data([0xFF, 0xFE, 0x42, 0x00, 0x3C, 0xD8, 0x3F, 0xDF])),
        .init(type: "public.utf16-plain-text", initial: Data([0xFE, 0xFF, 0x00, 0x41]),
              edited: Data([0xFE, 0xFF, 0x00, 0x42, 0xD8, 0x3C, 0xDF, 0x3F])),
        .init(type: "public.utf16-external-plain-text", initial: Data([0x00, 0x41]),
              edited: Data([0x00, 0x42, 0xD8, 0x3C, 0xDF, 0x3F])),
        .init(type: "public.utf16-external-plain-text", initial: Data([0xFF, 0xFE, 0x41, 0x00]),
              edited: Data([0xFF, 0xFE, 0x42, 0x00, 0x3C, 0xD8, 0x3F, 0xDF])),
        .init(type: "public.utf16-external-plain-text", initial: Data([0xFE, 0xFF, 0x00, 0x41]),
              edited: Data([0xFE, 0xFF, 0x00, 0x42, 0xD8, 0x3C, 0xDF, 0x3F])),
    ]

    private func details(
        canonicalText: Data,
        effectiveText: Data,
        version: UInt64 = 2
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
            ],
            version: version
        )
    }

    private func details(
        canonical: [HistoryRepresentation],
        effective: [HistoryRepresentation],
        version: UInt64 = 2
    ) -> HistoryDetails {
        HistoryDetails(
            item: HistoryItemReference(
                id: HistoryItemID(
                    rawValue: UUID(
                        uuidString: "00000000-0000-0000-0000-000000000301"
                    )!
                ),
                contentVersion: ContentVersion(rawValue: version)
            ),
            title: "Metadata fixture",
            canonical: canonical.map(metadata),
            effective: effective.map(metadata),
            effectiveMatchesCanonical: canonical == effective,
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

    private func metadata(_ representation: HistoryRepresentation) -> HistoryRepresentationMetadata {
        HistoryRepresentationMetadata(typeIdentifier: representation.typeIdentifier, byteCount: representation.bytes.count, pasteboardItemIndex: representation.pasteboardItemIndex)
    }

    /// Simulate only the UI's explicit one-representation read result. The
    /// initial Details fixture carries sizes/type facts, never payloads.
    private func installSource(
        _ bytes: Data, for type: String, in draft: inout ReviseEditorDraft,
        basis: HistoryContentBasis = .effective
    ) {
        #expect(draft.replacementRequest(for: type) == HistoryRepresentationRequest(
            item: draft.itemReference, basis: basis, typeIdentifier: type
        ))
        let installed = draft.installReplacementSource(HistoryRepresentation(typeIdentifier: type, bytes: bytes))
        #expect(installed)
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

    private struct NonReplaceableFormatFixture {
        let typeIdentifier: String
        let canonicalBytes: Data
        let effectiveBytes: Data
    }

    /// Valid bytes are intentional: these formats are excluded because the
    /// editor lacks an exact paired encoder, not because the fixtures fail a
    /// UTF-8 probe (review TYPE-2; pasteboard type-system memo §9.2).
    private func nonReplaceableFormatFixtures()
        -> [NonReplaceableFormatFixture]
    {
        [
            NonReplaceableFormatFixture(
                typeIdentifier: "public.rtf",
                canonicalBytes: Data("{\\rtf1\\ansi original}".utf8),
                effectiveBytes: Data("{\\rtf1\\ansi current}".utf8)
            ),
            NonReplaceableFormatFixture(
                typeIdentifier: "public.html",
                canonicalBytes: Data("<p>original</p>".utf8),
                effectiveBytes: Data("<p>current</p>".utf8)
            ),
            NonReplaceableFormatFixture(
                typeIdentifier: "public.text",
                canonicalBytes: Data("abstract original".utf8),
                effectiveBytes: Data("abstract current".utf8)
            ),
            NonReplaceableFormatFixture(
                typeIdentifier: "public.plain-text",
                canonicalBytes: Data("unspecified original".utf8),
                effectiveBytes: Data("unspecified current".utf8)
            ),
            NonReplaceableFormatFixture(
                typeIdentifier: "public.utf8-external-plain-text",
                canonicalBytes: Data("external original".utf8),
                effectiveBytes: Data("external current".utf8)
            ),
        ]
    }
}
