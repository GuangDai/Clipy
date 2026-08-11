/// Package-seam validation tests for custom HistoryLimits profiles
/// (docs/06-cross-cutting.md §2). Production uses `.standard`; focused tests
/// exercise every admission relation through the validated package initializer.
import Testing
@testable import HistoryCore

private struct HistoryLimitsFixture {
    var maximumRepresentationsPerCaptureOrRevision = 32
    var maximumTypeIdentifierUTF8Bytes = 512
    var maximumRepresentationBytes = 64 * 1_048_576
    var maximumCaptureBytes = 128 * 1_048_576
    var maximumProposedRevisionBytes = 64 * 1_048_576
    var maximumRevisionsPerItem = 100
    var maximumTotalRevisionBytesPerItem = 256 * 1_048_576
    var hardMaximumRetainedItems = 5_000
    var userMaximumUnpinnedLowerBound = 1
    var userMaximumUnpinnedUpperBound = 5_000
    var defaultMaximumUnpinnedItems = 200
    var maximumSourceApplicationObservationUTF8Bytes = 1_024
    var maximumStoredTitleUTF8Bytes = 1_024
    var maximumStoredSearchBodyUTF8Bytes = 256 * 1_024
    var pageRowLimitLowerBound = 1
    var pageRowLimitUpperBound = 500
    var maximumSearchTermUTF8Bytes = 4_096
    var maximumRegexpPatternCharacters = 512
    var maximumFuzzyQueryCharacters = 64
    var maximumFuzzyTitleBodyPrefixCharacters = 5_000
    var maximumRegexpTitleBodyPrefixCharacters = 1_000
    var maximumBodySearchSnippetCharacters = 322
    var thumbnailDimensionLowerBound = 1
    var thumbnailDimensionUpperBound = 2_048
    var maximumEncodedThumbnailBytes = 16 * 1_048_576

    func make() -> HistoryLimits? {
        HistoryLimits(
            maximumRepresentationsPerCaptureOrRevision: maximumRepresentationsPerCaptureOrRevision,
            maximumTypeIdentifierUTF8Bytes: maximumTypeIdentifierUTF8Bytes,
            maximumRepresentationBytes: maximumRepresentationBytes,
            maximumCaptureBytes: maximumCaptureBytes,
            maximumProposedRevisionBytes: maximumProposedRevisionBytes,
            maximumRevisionsPerItem: maximumRevisionsPerItem,
            maximumTotalRevisionBytesPerItem: maximumTotalRevisionBytesPerItem,
            hardMaximumRetainedItems: hardMaximumRetainedItems,
            userMaximumUnpinnedLowerBound: userMaximumUnpinnedLowerBound,
            userMaximumUnpinnedUpperBound: userMaximumUnpinnedUpperBound,
            defaultMaximumUnpinnedItems: defaultMaximumUnpinnedItems,
            maximumSourceApplicationObservationUTF8Bytes: maximumSourceApplicationObservationUTF8Bytes,
            maximumStoredTitleUTF8Bytes: maximumStoredTitleUTF8Bytes,
            maximumStoredSearchBodyUTF8Bytes: maximumStoredSearchBodyUTF8Bytes,
            pageRowLimitLowerBound: pageRowLimitLowerBound,
            pageRowLimitUpperBound: pageRowLimitUpperBound,
            maximumSearchTermUTF8Bytes: maximumSearchTermUTF8Bytes,
            maximumRegexpPatternCharacters: maximumRegexpPatternCharacters,
            maximumFuzzyQueryCharacters: maximumFuzzyQueryCharacters,
            maximumFuzzyTitleBodyPrefixCharacters: maximumFuzzyTitleBodyPrefixCharacters,
            maximumRegexpTitleBodyPrefixCharacters: maximumRegexpTitleBodyPrefixCharacters,
            maximumBodySearchSnippetCharacters: maximumBodySearchSnippetCharacters,
            thumbnailDimensionLowerBound: thumbnailDimensionLowerBound,
            thumbnailDimensionUpperBound: thumbnailDimensionUpperBound,
            maximumEncodedThumbnailBytes: maximumEncodedThumbnailBytes
        )
    }
}

enum HistoryLimitsRejectionCase: CaseIterable, Sendable {
    case nonPositiveRepresentations
    case nonPositiveTypeIdentifierBytes
    case nonPositiveRepresentationBytes
    case nonPositiveCaptureBytes
    case nonPositiveProposedRevisionBytes
    case nonPositiveRevisionCount
    case nonPositiveTotalRevisionBytes
    case nonPositiveRetainedItemCount
    case nonPositiveDefaultUnpinnedCount
    case nonPositiveSourceApplicationBytes
    case nonPositiveStoredTitleBytes
    case nonPositiveStoredSearchBodyBytes
    case nonPositiveSearchTermBytes
    case nonPositiveRegexpPatternCharacters
    case nonPositiveFuzzyQueryCharacters
    case nonPositiveFuzzyPrefixCharacters
    case nonPositiveRegexpPrefixCharacters
    case nonPositiveSnippetCharacters
    case snippetCannotFitContentAndEllipses
    case nonPositiveThumbnailBytes
    case nonPositiveUnpinnedRangeLowerBound
    case nonPositivePageRangeLowerBound
    case nonPositiveThumbnailRangeLowerBound
    case malformedUnpinnedRange
    case malformedPageRange
    case malformedThumbnailRange
    case unpinnedRangeExceedsHardMaximum
    case defaultUnpinnedOutsideRange
    case representationExceedsCapture
    case representationExceedsProposedRevision
    case proposedRevisionExceedsItemTotal
    case fuzzyQueryExceedsDependencyWordWidth
}

private func rejectedLimits(for rejection: HistoryLimitsRejectionCase) -> HistoryLimits? {
    var fixture = HistoryLimitsFixture()
    switch rejection {
    case .nonPositiveRepresentations:
        fixture.maximumRepresentationsPerCaptureOrRevision = 0
    case .nonPositiveTypeIdentifierBytes:
        fixture.maximumTypeIdentifierUTF8Bytes = 0
    case .nonPositiveRepresentationBytes:
        fixture.maximumRepresentationBytes = 0
    case .nonPositiveCaptureBytes:
        fixture.maximumCaptureBytes = 0
    case .nonPositiveProposedRevisionBytes:
        fixture.maximumProposedRevisionBytes = 0
    case .nonPositiveRevisionCount:
        fixture.maximumRevisionsPerItem = 0
    case .nonPositiveTotalRevisionBytes:
        fixture.maximumTotalRevisionBytesPerItem = 0
    case .nonPositiveRetainedItemCount:
        fixture.hardMaximumRetainedItems = 0
    case .nonPositiveDefaultUnpinnedCount:
        fixture.defaultMaximumUnpinnedItems = 0
    case .nonPositiveSourceApplicationBytes:
        fixture.maximumSourceApplicationObservationUTF8Bytes = 0
    case .nonPositiveStoredTitleBytes:
        fixture.maximumStoredTitleUTF8Bytes = 0
    case .nonPositiveStoredSearchBodyBytes:
        fixture.maximumStoredSearchBodyUTF8Bytes = 0
    case .nonPositiveSearchTermBytes:
        fixture.maximumSearchTermUTF8Bytes = 0
    case .nonPositiveRegexpPatternCharacters:
        fixture.maximumRegexpPatternCharacters = 0
    case .nonPositiveFuzzyQueryCharacters:
        fixture.maximumFuzzyQueryCharacters = 0
    case .nonPositiveFuzzyPrefixCharacters:
        fixture.maximumFuzzyTitleBodyPrefixCharacters = 0
    case .nonPositiveRegexpPrefixCharacters:
        fixture.maximumRegexpTitleBodyPrefixCharacters = 0
    case .nonPositiveSnippetCharacters:
        fixture.maximumBodySearchSnippetCharacters = 0
    case .snippetCannotFitContentAndEllipses:
        fixture.maximumBodySearchSnippetCharacters = 2
    case .nonPositiveThumbnailBytes:
        fixture.maximumEncodedThumbnailBytes = 0
    case .nonPositiveUnpinnedRangeLowerBound:
        fixture.userMaximumUnpinnedLowerBound = 0
    case .nonPositivePageRangeLowerBound:
        fixture.pageRowLimitLowerBound = 0
    case .nonPositiveThumbnailRangeLowerBound:
        fixture.thumbnailDimensionLowerBound = 0
    case .malformedUnpinnedRange:
        fixture.userMaximumUnpinnedLowerBound = 2
        fixture.userMaximumUnpinnedUpperBound = 1
    case .malformedPageRange:
        fixture.pageRowLimitLowerBound = 2
        fixture.pageRowLimitUpperBound = 1
    case .malformedThumbnailRange:
        fixture.thumbnailDimensionLowerBound = 2
        fixture.thumbnailDimensionUpperBound = 1
    case .unpinnedRangeExceedsHardMaximum:
        fixture.userMaximumUnpinnedUpperBound = 5_001
    case .defaultUnpinnedOutsideRange:
        fixture.userMaximumUnpinnedUpperBound = 100
        fixture.defaultMaximumUnpinnedItems = 101
    case .representationExceedsCapture:
        fixture.maximumRepresentationBytes = 65
        fixture.maximumProposedRevisionBytes = 65
        fixture.maximumCaptureBytes = 64
    case .representationExceedsProposedRevision:
        fixture.maximumRepresentationBytes = 65
        fixture.maximumCaptureBytes = 65
        fixture.maximumProposedRevisionBytes = 64
    case .proposedRevisionExceedsItemTotal:
        fixture.maximumProposedRevisionBytes = 257
        fixture.maximumTotalRevisionBytesPerItem = 256
    case .fuzzyQueryExceedsDependencyWordWidth:
        fixture.maximumFuzzyQueryCharacters = 65
    }
    return fixture.make()
}

@Test(arguments: HistoryLimitsRejectionCase.allCases)
func historyLimitsRejectsEveryInvalidProfile(
    rejection: HistoryLimitsRejectionCase
) {
    #expect(rejectedLimits(for: rejection) == nil)
}

@Test func historyLimitsAcceptsEqualNestedByteBoundsAndRangeEndpoints() {
    var fixture = HistoryLimitsFixture()
    fixture.maximumRepresentationBytes = 64
    fixture.maximumProposedRevisionBytes = 64
    fixture.maximumCaptureBytes = 64
    fixture.maximumTotalRevisionBytesPerItem = 64
    fixture.userMaximumUnpinnedLowerBound = 1
    fixture.userMaximumUnpinnedUpperBound = 1
    fixture.defaultMaximumUnpinnedItems = 1
    fixture.pageRowLimitLowerBound = 1
    fixture.pageRowLimitUpperBound = 1
    fixture.thumbnailDimensionLowerBound = 1
    fixture.thumbnailDimensionUpperBound = 1

    #expect(fixture.make() != nil)
}
