/// HistoryCore surface tests (roadmap step 1): `HistoryLimits.standard`
/// against the docs/06-cross-cutting.md §2 table row-for-row; `ContentVersion`
/// and `ChangePosition` minting behavior per docs/03a-instruction-set.md §2;
/// and deterministic UUID-byte ordering.
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
    #expect(limits.userMaximumUnpinnedRange == (1...Int.max))
    #expect(limits.defaultMaximumUnpinnedItems == 200)
    #expect(limits.maximumSourceApplicationObservationUTF8Bytes == 1_024)
    #expect(limits.maximumStoredTitleUTF8Bytes == 1_024)
    #expect(limits.maximumStoredSearchBodyUTF8Bytes == 256 * 1_024) // 256 KiB
    #expect(limits.pageRowLimitRange == (1...500))
    #expect(limits.maximumSearchTermUTF8Bytes == 4_096)
    #expect(limits.maximumRegexpPatternCharacters == 512)
    #expect(limits.maximumFuzzyQueryCharacters == 64)
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

@Test func identityOrderingUsesCanonicalUUIDBytesAndIsTrichotomous() {
    let firstByteLow = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let firstByteHigh = UUID(uuidString: "01000000-0000-0000-0000-000000000000")!
    let lastByteHigh = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    let itemLow = HistoryItemID(rawValue: firstByteLow)
    let itemFirstHigh = HistoryItemID(rawValue: firstByteHigh)
    let itemLastHigh = HistoryItemID(rawValue: lastByteHigh)
    #expect(itemLow < itemFirstHigh)
    #expect(itemLow < itemLastHigh)
    #expect(!(itemLow < itemLow))
    #expect(!(itemFirstHigh < itemLow))

    let revisionLow = RevisionID(rawValue: firstByteLow)
    let revisionFirstHigh = RevisionID(rawValue: firstByteHigh)
    let revisionLastHigh = RevisionID(rawValue: lastByteHigh)
    #expect(revisionLow < revisionFirstHigh)
    #expect(revisionLow < revisionLastHigh)
    #expect(!(revisionLow < revisionLow))
    #expect(!(revisionFirstHigh < revisionLow))
}

@Test func historyItemIDDescriptionIsItsCanonicalUUIDString() {
    let raw = UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!
    #expect(HistoryItemID(rawValue: raw).description == raw.uuidString)
}

@Test(arguments: [SearchMode.exact, .fuzzy, .regexp, .expression])
func searchQueryIdentityPreservesTheOriginalScalarSequence(mode: SearchMode) {
    let composed = HistoryBrowseKind.search(text: "\u{e9}", mode: mode)
    let decomposed = HistoryBrowseKind.search(text: "e\u{301}", mode: mode)

    #expect(composed != decomposed)
    #expect(Set([composed, decomposed]).count == 2)
    #expect(composed == .search(text: "\u{e9}", mode: mode))
    #expect(Set([composed, .search(text: "\u{e9}", mode: mode)]).count == 1)
    #expect(HistoryBrowseRequest(kind: composed, limit: 10) != HistoryBrowseRequest(kind: decomposed, limit: 10))
    #expect(HistoryObservationRequest(kind: composed, limit: 10) != HistoryObservationRequest(kind: decomposed, limit: 10))
}
