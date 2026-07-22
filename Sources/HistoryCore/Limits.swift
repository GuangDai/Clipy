/// HistoryLimits — the fixed v1 admission and resource-safety bounds.
/// Owning spec: docs/06-cross-cutting.md §2 (Part VI). Foundation-only.
import Foundation

/// The fixed v1 safety bounds, encoded as one validated immutable value.
///
/// docs/06-cross-cutting.md §2: these bounds are admission and
/// resource-safety constraints, not caches or user-facing retention features.
/// One field corresponds to one row of the §2 table, in table order; byte
/// counts use binary units (1 KiB = 1,024 bytes, 1 MiB = 1,048,576 bytes).
/// `standard` holds exactly the table values and is the only value production
/// and the walking-skeleton tests use; a test that needs a different hard
/// bound injects it at the Domain planner seam, not via a custom
/// `HistoryLimits`.
public struct HistoryLimits: Sendable, Hashable {

    /// §2 table: "Representations per capture/revision" — 32.
    public let maximumRepresentationsPerCaptureOrRevision: Int

    /// §2 table: "UTF-8 bytes in one type identifier" — 512.
    public let maximumTypeIdentifierUTF8Bytes: Int

    /// §2 table: "Bytes in one representation" — 64 MiB.
    public let maximumRepresentationBytes: Int

    /// §2 table: "Total bytes in one capture" — 128 MiB.
    public let maximumCaptureBytes: Int

    /// §2 table: "Total bytes in one proposed revision" — 64 MiB.
    public let maximumProposedRevisionBytes: Int

    /// §2 table: "Revisions per History Item" — 100.
    public let maximumRevisionsPerItem: Int

    /// §2 table: "Total revision bytes per History Item" — 256 MiB.
    public let maximumTotalRevisionBytesPerItem: Int

    /// §2 table: "Hard retained History Item count" — 5,000. Pinned items are
    /// exempt from the user maximum-unpinned policy but still count toward
    /// this hard bound.
    public let hardMaximumRetainedItems: Int

    /// §2 table: "User maximum-unpinned range" — 1–5,000. The permitted
    /// interval for the user retention policy value.
    public let userMaximumUnpinnedRange: ClosedRange<Int>

    /// §2 table: "Default maximum unpinned items" — 200.
    public let defaultMaximumUnpinnedItems: Int

    /// §2 table: "UTF-8 bytes in one source-application observation" — 1,024.
    public let maximumSourceApplicationObservationUTF8Bytes: Int

    /// §2 table: "Stored title UTF-8 bytes" — 1,024.
    public let maximumStoredTitleUTF8Bytes: Int

    /// §2 table: "Stored search body UTF-8 bytes per item" — 256 KiB.
    public let maximumStoredSearchBodyUTF8Bytes: Int

    /// §2 table: "Page/observation row limit" — 1–500. The permitted
    /// interval for a browse page or observed first-page row limit.
    public let pageRowLimitRange: ClosedRange<Int>

    /// §2 table: "Search term UTF-8 bytes" — 4,096.
    public let maximumSearchTermUTF8Bytes: Int

    /// §2 table: "Regexp pattern Characters" — 512.
    public let maximumRegexpPatternCharacters: Int

    /// §2 table: "Fuzzy query Characters" — 256.
    public let maximumFuzzyQueryCharacters: Int

    /// §2 table: "Fuzzy title/body prefix" — 5,000 Characters each.
    public let maximumFuzzyTitleBodyPrefixCharacters: Int

    /// §2 table: "Regexp title/body prefix" — 1,000 Characters each.
    public let maximumRegexpTitleBodyPrefixCharacters: Int

    /// §2 table: "Body search snippet" — 322 Characters including ellipses.
    public let maximumBodySearchSnippetCharacters: Int

    /// §2 table: "Thumbnail dimension" — 1–2,048 pixels per axis. The
    /// permitted interval for either axis of a requested thumbnail.
    public let thumbnailDimensionRange: ClosedRange<Int>

    /// §2 table: "Encoded thumbnail output" — 16 MiB.
    public let maximumEncodedThumbnailBytes: Int

    /// Creates a set of bounds, rejecting out-of-range or inconsistent
    /// combinations by returning `nil` (docs/06-cross-cutting.md §2).
    ///
    /// Rejected: any non-positive scalar bound; a range whose lower bound is
    /// below 1; `userMaximumUnpinnedRange` not contained in
    /// `1...hardMaximumRetainedItems`; `defaultMaximumUnpinnedItems` outside
    /// `userMaximumUnpinnedRange`; `maximumRepresentationBytes` exceeding
    /// `maximumCaptureBytes`; or `maximumProposedRevisionBytes` exceeding
    /// `maximumTotalRevisionBytesPerItem`.
    ///
    /// Validation compares values only — it performs no counter or byte-count
    /// arithmetic, so no calculation can wrap (§2 rules).
    public init?(
        maximumRepresentationsPerCaptureOrRevision: Int,
        maximumTypeIdentifierUTF8Bytes: Int,
        maximumRepresentationBytes: Int,
        maximumCaptureBytes: Int,
        maximumProposedRevisionBytes: Int,
        maximumRevisionsPerItem: Int,
        maximumTotalRevisionBytesPerItem: Int,
        hardMaximumRetainedItems: Int,
        userMaximumUnpinnedRange: ClosedRange<Int>,
        defaultMaximumUnpinnedItems: Int,
        maximumSourceApplicationObservationUTF8Bytes: Int,
        maximumStoredTitleUTF8Bytes: Int,
        maximumStoredSearchBodyUTF8Bytes: Int,
        pageRowLimitRange: ClosedRange<Int>,
        maximumSearchTermUTF8Bytes: Int,
        maximumRegexpPatternCharacters: Int,
        maximumFuzzyQueryCharacters: Int,
        maximumFuzzyTitleBodyPrefixCharacters: Int,
        maximumRegexpTitleBodyPrefixCharacters: Int,
        maximumBodySearchSnippetCharacters: Int,
        thumbnailDimensionRange: ClosedRange<Int>,
        maximumEncodedThumbnailBytes: Int
    ) {
        guard maximumRepresentationsPerCaptureOrRevision >= 1,
              maximumTypeIdentifierUTF8Bytes >= 1,
              maximumRepresentationBytes >= 1,
              maximumCaptureBytes >= 1,
              maximumProposedRevisionBytes >= 1,
              maximumRevisionsPerItem >= 1,
              maximumTotalRevisionBytesPerItem >= 1,
              hardMaximumRetainedItems >= 1,
              defaultMaximumUnpinnedItems >= 1,
              maximumSourceApplicationObservationUTF8Bytes >= 1,
              maximumStoredTitleUTF8Bytes >= 1,
              maximumStoredSearchBodyUTF8Bytes >= 1,
              maximumSearchTermUTF8Bytes >= 1,
              maximumRegexpPatternCharacters >= 1,
              maximumFuzzyQueryCharacters >= 1,
              maximumFuzzyTitleBodyPrefixCharacters >= 1,
              maximumRegexpTitleBodyPrefixCharacters >= 1,
              maximumBodySearchSnippetCharacters >= 1,
              maximumEncodedThumbnailBytes >= 1
        else { return nil }

        guard userMaximumUnpinnedRange.lowerBound >= 1,
              pageRowLimitRange.lowerBound >= 1,
              thumbnailDimensionRange.lowerBound >= 1
        else { return nil }

        guard userMaximumUnpinnedRange.upperBound <= hardMaximumRetainedItems,
              userMaximumUnpinnedRange.contains(defaultMaximumUnpinnedItems),
              maximumRepresentationBytes <= maximumCaptureBytes,
              maximumProposedRevisionBytes <= maximumTotalRevisionBytesPerItem
        else { return nil }

        self.maximumRepresentationsPerCaptureOrRevision = maximumRepresentationsPerCaptureOrRevision
        self.maximumTypeIdentifierUTF8Bytes = maximumTypeIdentifierUTF8Bytes
        self.maximumRepresentationBytes = maximumRepresentationBytes
        self.maximumCaptureBytes = maximumCaptureBytes
        self.maximumProposedRevisionBytes = maximumProposedRevisionBytes
        self.maximumRevisionsPerItem = maximumRevisionsPerItem
        self.maximumTotalRevisionBytesPerItem = maximumTotalRevisionBytesPerItem
        self.hardMaximumRetainedItems = hardMaximumRetainedItems
        self.userMaximumUnpinnedRange = userMaximumUnpinnedRange
        self.defaultMaximumUnpinnedItems = defaultMaximumUnpinnedItems
        self.maximumSourceApplicationObservationUTF8Bytes = maximumSourceApplicationObservationUTF8Bytes
        self.maximumStoredTitleUTF8Bytes = maximumStoredTitleUTF8Bytes
        self.maximumStoredSearchBodyUTF8Bytes = maximumStoredSearchBodyUTF8Bytes
        self.pageRowLimitRange = pageRowLimitRange
        self.maximumSearchTermUTF8Bytes = maximumSearchTermUTF8Bytes
        self.maximumRegexpPatternCharacters = maximumRegexpPatternCharacters
        self.maximumFuzzyQueryCharacters = maximumFuzzyQueryCharacters
        self.maximumFuzzyTitleBodyPrefixCharacters = maximumFuzzyTitleBodyPrefixCharacters
        self.maximumRegexpTitleBodyPrefixCharacters = maximumRegexpTitleBodyPrefixCharacters
        self.maximumBodySearchSnippetCharacters = maximumBodySearchSnippetCharacters
        self.thumbnailDimensionRange = thumbnailDimensionRange
        self.maximumEncodedThumbnailBytes = maximumEncodedThumbnailBytes
    }

    /// Exactly the docs/06-cross-cutting.md §2 table values — the only value
    /// production and the `SwiftDataHistory` walking-skeleton tests use.
    ///
    /// The force unwrap cannot fail: the table values satisfy every check in
    /// `init?`. A table edit that breaks a check is a specification violation
    /// and must fail loudly at first access, not silently.
    public static let standard: HistoryLimits = HistoryLimits(
        maximumRepresentationsPerCaptureOrRevision: 32,
        maximumTypeIdentifierUTF8Bytes: 512,
        maximumRepresentationBytes: 64 * 1_048_576,
        maximumCaptureBytes: 128 * 1_048_576,
        maximumProposedRevisionBytes: 64 * 1_048_576,
        maximumRevisionsPerItem: 100,
        maximumTotalRevisionBytesPerItem: 256 * 1_048_576,
        hardMaximumRetainedItems: 5_000,
        userMaximumUnpinnedRange: 1...5_000,
        defaultMaximumUnpinnedItems: 200,
        maximumSourceApplicationObservationUTF8Bytes: 1_024,
        maximumStoredTitleUTF8Bytes: 1_024,
        maximumStoredSearchBodyUTF8Bytes: 256 * 1_024,
        pageRowLimitRange: 1...500,
        maximumSearchTermUTF8Bytes: 4_096,
        maximumRegexpPatternCharacters: 512,
        maximumFuzzyQueryCharacters: 256,
        maximumFuzzyTitleBodyPrefixCharacters: 5_000,
        maximumRegexpTitleBodyPrefixCharacters: 1_000,
        maximumBodySearchSnippetCharacters: 322,
        thumbnailDimensionRange: 1...2_048,
        maximumEncodedThumbnailBytes: 16 * 1_048_576
    )!
}
