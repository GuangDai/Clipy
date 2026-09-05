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

    @Test func dirtyDraftKeepsOpeningReferenceAndLiteralReplacementBytes() {
        var draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: Data("current revision".utf8)
            )
        )
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
                == .replace(bytes: Data("sibling-effective-v3".utf8))
        )
        #expect(
            draft.canonicalRepresentations.first?.bytes
                == Data("original-v1".utf8)
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
                == .replace(bytes: Data("effective-v3".utf8))
        )
    }

    @Test func reloadLatestKeepsCanonicalTypesWhenEffectiveHidesAType() {
        var draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: Data("current revision".utf8)
            )
        )
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

    @Test func reloadConflictPreservesEntireAuthoredDraftAndOldBase() throws {
        var draft = ReviseEditorDraft(
            details: details(
                canonicalText: Data("original capture".utf8),
                effectiveText: Data("current revision".utf8)
            )
        )
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

        #expect(utf8Draft.canReplace(utf8))

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

            #expect(!draft.canReplace(representation))
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
                ] == .replace(bytes: fixture.effectiveBytes)
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
                ] == .replace(bytes: fixture.effectiveBytes)
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
        #expect(decisions(from: draft.revisionRequest())[type] == .replace(bytes: current))
        draft.setChoice(.useOriginal, for: type)
        #expect(decisions(from: draft.revisionRequest())[type] == .inheritCanonical)
        draft.setChoice(.hide, for: type)
        #expect(decisions(from: draft.revisionRequest())[type] == .hide)
        #expect(draft.allRepresentationsHidden)
        draft.setChoice(.keepCurrent, for: type)
        #expect(decisions(from: draft.revisionRequest())[type] == .replace(bytes: current))
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
        draft.markStale()
        let reloaded = draft.reloadLatest(details: utf16Details(
            type: type, canonical: original, effective: latest, version: 3
        ))
        #expect(reloaded)
        #expect(!draft.isDirty)
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
        var draft = ReviseEditorDraft(details: details(canonical: [canonical], effective: []))
        #expect(draft.allRepresentationsHidden)
        #expect(draft.canReplace(canonical))
        #expect(draft.replacementText(for: type) == "A")
        draft.setChoice(.replace, for: type)
        #expect(draft.canSubmit)
        #expect(decisions(from: draft.revisionRequest())[type] == .replace(bytes: canonical.bytes))
    }

    @Test func malformedUTF16ReloadLeavesAuthoredBytesAndOldBaseIntact() {
        let type = "public.utf16-plain-text"
        let original = Data([0xFF, 0xFE, 0x41, 0x00])
        var draft = ReviseEditorDraft(details: utf16Details(
            type: type, canonical: original, effective: original
        ))
        draft.setChoice(.replace, for: type)
        draft.setReplacementText("B", for: type)
        draft.markStale()

        let reloaded = draft.reloadLatest(details: utf16Details(
            type: type,
            canonical: original,
            effective: Data([0xFF, 0xFE, 0x00, 0xD8]), // unpaired high surrogate
            version: 3
        ))
        #expect(!reloaded)
        #expect(draft.isAwaitingLatestContent)
        #expect(!draft.canSubmit)
        #expect(draft.revisionRequest().expected == ContentVersion(rawValue: 2))
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
        #expect(draft.replacementText(for: type).unicodeScalars.map(\.value) == [0x65, 0x301])
        #expect(!draft.isDirty)
        draft.setChoice(.replace, for: type)
        #expect(decisions(from: draft.revisionRequest())[type] == .replace(bytes: current))
        draft.setReplacementText("B", for: type)
        #expect(decisions(from: draft.revisionRequest())[type] == .replace(
            bytes: Data([0xFF, 0xFE, 0x42, 0x00])
        ))
    }

    @Test func initialReplacementStillRequiresValidCanonicalAndEffectiveText() throws {
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
            #expect(!draft.canReplace(representation))
            draft.setChoice(.replace, for: type)
            #expect(draft.choice(for: type) == .keepCurrent)
        }
    }

    @Test func utf16DirtyComparisonPreservesCanonicallyEquivalentSpellings() {
        let type = "public.utf16-external-plain-text"
        let composed = Data([0xFE, 0xFF, 0x00, 0xE9])
        var draft = ReviseEditorDraft(details: utf16Details(
            type: type, canonical: composed, effective: composed
        ))
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
