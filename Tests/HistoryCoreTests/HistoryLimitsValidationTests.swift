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
    var userMaximumUnpinnedRange = 1...5_000
    var defaultMaximumUnpinnedItems = 200
    var maximumSourceApplicationObservationUTF8Bytes = 1_024
    var maximumStoredTitleUTF8Bytes = 1_024
    var maximumStoredSearchBodyUTF8Bytes = 256 * 1_024
    var pageRowLimitRange = 1...500
    var maximumSearchTermUTF8Bytes = 4_096
    var maximumRegexpPatternCharacters = 512
    var maximumFuzzyQueryCharacters = 64
    var maximumFuzzyTitleBodyPrefixCharacters = 5_000
    var maximumRegexpTitleBodyPrefixCharacters = 1_000
    var maximumBodySearchSnippetCharacters = 322
    var thumbnailDimensionRange = 1...2_048
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
            userMaximumUnpinnedRange: userMaximumUnpinnedRange,
            defaultMaximumUnpinnedItems: defaultMaximumUnpinnedItems,
            maximumSourceApplicationObservationUTF8Bytes: maximumSourceApplicationObservationUTF8Bytes,
            maximumStoredTitleUTF8Bytes: maximumStoredTitleUTF8Bytes,
            maximumStoredSearchBodyUTF8Bytes: maximumStoredSearchBodyUTF8Bytes,
            pageRowLimitRange: pageRowLimitRange,
            maximumSearchTermUTF8Bytes: maximumSearchTermUTF8Bytes,
            maximumRegexpPatternCharacters: maximumRegexpPatternCharacters,
            maximumFuzzyQueryCharacters: maximumFuzzyQueryCharacters,
            maximumFuzzyTitleBodyPrefixCharacters: maximumFuzzyTitleBodyPrefixCharacters,
            maximumRegexpTitleBodyPrefixCharacters: maximumRegexpTitleBodyPrefixCharacters,
            maximumBodySearchSnippetCharacters: maximumBodySearchSnippetCharacters,
            thumbnailDimensionRange: thumbnailDimensionRange,
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
        fixture.userMaximumUnpinnedRange = 0...5_000
    case .nonPositivePageRangeLowerBound:
        fixture.pageRowLimitRange = 0...500
    case .nonPositiveThumbnailRangeLowerBound:
        fixture.thumbnailDimensionRange = 0...2_048
    case .malformedUnpinnedRange:
        fixture.userMaximumUnpinnedRange = ClosedRange(
            uncheckedBounds: (lower: 2, upper: 1)
        )
    case .malformedPageRange:
        fixture.pageRowLimitRange = ClosedRange(
            uncheckedBounds: (lower: 2, upper: 1)
        )
    case .malformedThumbnailRange:
        fixture.thumbnailDimensionRange = ClosedRange(
            uncheckedBounds: (lower: 2, upper: 1)
        )
    case .unpinnedRangeExceedsHardMaximum:
        fixture.userMaximumUnpinnedRange = 1...5_001
    case .defaultUnpinnedOutsideRange:
        fixture.userMaximumUnpinnedRange = 1...100
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
    fixture.userMaximumUnpinnedRange = 1...1
    fixture.defaultMaximumUnpinnedItems = 1
    fixture.pageRowLimitRange = 1...1
    fixture.thumbnailDimensionRange = 1...1

    #expect(fixture.make() != nil)
}
