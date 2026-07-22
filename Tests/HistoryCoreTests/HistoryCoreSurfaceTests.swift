/// HistoryCore surface tests (roadmap step 1): `HistoryLimits.standard`
/// against the docs/06-cross-cutting.md §2 table row-for-row; `ContentVersion`
/// and `ChangePosition` minting behavior per docs/03a-instruction-set.md §2;
/// and one caller-construction smoke test per public DTO struct that has a
/// public initializer (docs/03a §2–§7, docs/03b §8–§9).
///
/// Package-only members (`.initial`, `.zero`, `successor()`, the package
/// initializers of the identity/coherence types) are reachable from this
/// same-package test target via `@testable import`.
import Foundation
import Testing
@testable import HistoryCore

// MARK: - HistoryLimits.standard (docs/06-cross-cutting.md §2 table)

@Test func historyLimitsStandardMatchesPartVITableRowForRow() {
    let limits = HistoryLimits.standard

    #expect(limits.maximumRepresentationsPerCaptureOrRevision == 32)
    #expect(limits.maximumTypeIdentifierUTF8Bytes == 512)
    #expect(limits.maximumRepresentationBytes == 64 * 1_048_576) // 64 MiB
    #expect(limits.maximumCaptureBytes == 128 * 1_048_576) // 128 MiB
    #expect(limits.maximumProposedRevisionBytes == 64 * 1_048_576) // 64 MiB
    #expect(limits.maximumRevisionsPerItem == 100)
    #expect(limits.maximumTotalRevisionBytesPerItem == 256 * 1_048_576) // 256 MiB
    #expect(limits.hardMaximumRetainedItems == 5_000)
    #expect(limits.userMaximumUnpinnedRange == (1...5_000))
    #expect(limits.defaultMaximumUnpinnedItems == 200)
    #expect(limits.maximumSourceApplicationObservationUTF8Bytes == 1_024)
    #expect(limits.maximumStoredTitleUTF8Bytes == 1_024)
    #expect(limits.maximumStoredSearchBodyUTF8Bytes == 256 * 1_024) // 256 KiB
    #expect(limits.pageRowLimitRange == (1...500))
    #expect(limits.maximumSearchTermUTF8Bytes == 4_096)
    #expect(limits.maximumRegexpPatternCharacters == 512)
    #expect(limits.maximumFuzzyQueryCharacters == 256)
    #expect(limits.maximumFuzzyTitleBodyPrefixCharacters == 5_000)
    #expect(limits.maximumRegexpTitleBodyPrefixCharacters == 1_000)
    #expect(limits.maximumBodySearchSnippetCharacters == 322)
    #expect(limits.thumbnailDimensionRange == (1...2_048))
    #expect(limits.maximumEncodedThumbnailBytes == 16 * 1_048_576) // 16 MiB
}

// MARK: - Identity coherence values (docs/03a-instruction-set.md §2)

@Test func contentVersionInitialAndSuccessor() {
    #expect(ContentVersion.initial.rawValue == 1)
    #expect(ContentVersion.initial.successor() == ContentVersion(rawValue: 2))
    #expect(ContentVersion(rawValue: UInt64.max).successor() == nil)
}

@Test func changePositionZeroAndSuccessor() {
    #expect(ChangePosition.zero.rawValue == 0)
    #expect(ChangePosition.zero.successor() == ChangePosition(rawValue: 1))
    #expect(ChangePosition(rawValue: UInt64.max).successor() == nil)
}

// MARK: - Caller-construction smoke tests (public initializers)

@Test func historyItemReferenceConstruction() {
    let id = HistoryItemID(rawValue: UUID())
    let reference = HistoryItemReference(id: id, contentVersion: .initial)

    #expect(reference.id == id)
    #expect(reference.contentVersion == .initial)
}

@Test func capturedRepresentationConstruction() {
    let representation = CapturedRepresentation(
        typeIdentifier: "public.utf8-plain-text",
        bytes: Data([0x68, 0x69])
    )

    #expect(representation.bytes == Data([0x68, 0x69]))
}

@Test func copyOriginObservationConstruction() {
    let origin = CopyOriginObservation(
        sourceApplication: "com.example.app",
        lineageHint: nil
    )

    #expect(origin.sourceApplication == "com.example.app")
}

@Test func clipboardCaptureConstruction() {
    let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let capture = ClipboardCapture(
        representations: [
            CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data([0x68, 0x69])
            )
        ],
        origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
        observedAt: observedAt
    )

    #expect(capture.observedAt == observedAt)
}

@Test func revisionRequestConstruction() {
    let id = HistoryItemID(rawValue: UUID())
    let request = RevisionRequest(
        itemID: id,
        expected: .initial,
        intent: .replace(RevisionDraft(decisions: []))
    )

    #expect(request.itemID == id)
    #expect(request.expected == .initial)
}

@Test func revisionDraftConstruction() {
    let draft = RevisionDraft(decisions: [
        RevisionDecision(typeIdentifier: "public.png", action: .inheritCanonical)
    ])

    #expect(draft.decisions.count == 1)
}

@Test func revisionDecisionConstruction() {
    let decision = RevisionDecision(
        typeIdentifier: "public.utf8-plain-text",
        action: .replace(bytes: Data([0x41]))
    )

    #expect(decision.typeIdentifier == "public.utf8-plain-text")
    #expect(decision.action == .replace(bytes: Data([0x41])))
}

@Test func historyCommitConstruction() {
    let commit = HistoryCommit(position: .zero, outcome: .removed(count: 1))

    #expect(commit.position == .zero)
}

@Test func historyBrowseRequestConstruction() {
    let request = HistoryBrowseRequest(
        kind: .search(text: "clipy", mode: .fuzzy),
        limit: 50
    )

    #expect(request.kind == .search(text: "clipy", mode: .fuzzy))
    #expect(request.limit == 50)
    #expect(request.after == nil)
}

@Test func historyObservationRequestConstruction() {
    let request = HistoryObservationRequest(kind: .recent, limit: 200)

    #expect(request.kind == .recent)
    #expect(request.limit == 200)
}

@Test func utf16TextRangeConstruction() {
    let range = UTF16TextRange(location: 4, length: 7)

    #expect(range.location == 4)
    #expect(range.length == 7)
}

@Test func searchPresentationConstruction() {
    let presentation = SearchPresentation(
        snippet: "…body excerpt…",
        matchedRanges: [UTF16TextRange(location: 1, length: 4)]
    )

    #expect(presentation.snippet == "…body excerpt…")
}

@Test func pixelSizeConstruction() {
    let size = PixelSize(width: 128, height: 96)

    #expect(size.width == 128)
    #expect(size.height == 96)
}
