/// Purpose-specific detail and content DTOs. Details carry metadata only;
/// explicit representation reads return one requested payload, paste returns
/// current Effective Content, and thumbnail returns encoded bytes rather than
/// `NSImage`/`CGImage`.
/// Owning spec: docs/03b-instruction-set.md §9 (Part III — Caller Interface B).
/// Foundation-only.
import Foundation

/// One typed representation of an item's stored content bytes.
/// docs/03b-instruction-set.md §9
public struct HistoryRepresentation: Sendable, Hashable {
    /// Zero-based position of the original system pasteboard item.
    public let pasteboardItemIndex: Int
    public let typeIdentifier: String
    public let bytes: Data

    public init(typeIdentifier: String, bytes: Data, pasteboardItemIndex: Int = 0) {
        self.pasteboardItemIndex = pasteboardItemIndex
        self.typeIdentifier = typeIdentifier
        self.bytes = bytes
    }
}

/// Metadata for one stored representation. No payload is read to produce it.
/// The identifier preserves its exact persisted spelling (V2-09 §5).
public struct HistoryRepresentationMetadata: Sendable, Hashable {
    /// Zero-based position of the original system pasteboard item.
    public let pasteboardItemIndex: Int
    public let typeIdentifier: String
    public let byteCount: Int

    public init(typeIdentifier: String, byteCount: Int, pasteboardItemIndex: Int = 0) {
        self.pasteboardItemIndex = pasteboardItemIndex
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
    }
}

/// Which content state an explicit representation request addresses.
public enum HistoryContentBasis: Sendable, Hashable {
    case canonical
    case effective
}

/// One purpose-selected payload at an exact current item version. Even a
/// Canonical request rejects a stale version rather than mixing UI snapshots.
public struct HistoryRepresentationRequest: Sendable, Hashable {
    public let item: HistoryItemReference
    public let basis: HistoryContentBasis
    /// Zero-based position of the original system pasteboard item.
    public let pasteboardItemIndex: Int
    public let typeIdentifier: String

    public init(item: HistoryItemReference, basis: HistoryContentBasis, typeIdentifier: String, pasteboardItemIndex: Int = 0) {
        self.item = item
        self.basis = basis
        self.pasteboardItemIndex = pasteboardItemIndex
        self.typeIdentifier = typeIdentifier
    }
}

/// Summary of a single revision of an item, in revision order.
/// docs/03b-instruction-set.md §9
public struct RevisionSummary: Sendable, Hashable {
    public let id: RevisionID
    public let createdAt: Date
    public let isActive: Bool
    public let title: String
    public let typeIdentifiers: [String]
    public let byteCount: Int

    package init(
        id: RevisionID,
        createdAt: Date,
        isActive: Bool,
        title: String,
        typeIdentifiers: [String],
        byteCount: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.isActive = isActive
        self.title = title
        self.typeIdentifiers = typeIdentifiers
        self.byteCount = byteCount
    }
}

/// Aggregate copy-occurrence facts for an item.
/// docs/03b-instruction-set.md §9
public struct CopyOccurrenceSummary: Sendable, Hashable {
    public let firstCopiedAt: Date
    public let lastCopiedAt: Date
    public let count: UInt64
    public let firstSource: String?
    public let lastSource: String?

    package init(
        firstCopiedAt: Date,
        lastCopiedAt: Date,
        count: UInt64,
        firstSource: String?,
        lastSource: String?
    ) {
        self.firstCopiedAt = firstCopiedAt
        self.lastCopiedAt = lastCopiedAt
        self.count = count
        self.firstSource = firstSource
        self.lastSource = lastSource
    }
}

/// Metadata for one item, including immutable revision summaries. No content
/// payload is materialized by this read, including Canonical/current payloads.
/// Explicit reads use `HistoryRepresentationRequest` (V2-09 §5).
public struct HistoryDetails: Sendable, Hashable {
    public let item: HistoryItemReference
    public let title: String
    public let canonical: [HistoryRepresentationMetadata]
    public let effective: [HistoryRepresentationMetadata]
    /// Byte-exact equality computed when content is prepared and committed;
    /// metadata equality alone cannot establish this fact.
    public let effectiveMatchesCanonical: Bool
    public let revisions: [RevisionSummary]
    public let occurrence: CopyOccurrenceSummary
    public let pinnedPosition: Int?

    package init(
        item: HistoryItemReference,
        title: String,
        canonical: [HistoryRepresentationMetadata],
        effective: [HistoryRepresentationMetadata],
        effectiveMatchesCanonical: Bool,
        revisions: [RevisionSummary],
        occurrence: CopyOccurrenceSummary,
        pinnedPosition: Int?
    ) {
        self.item = item
        self.title = title
        self.canonical = canonical
        self.effective = effective
        self.effectiveMatchesCanonical = effectiveMatchesCanonical
        self.revisions = revisions
        self.occurrence = occurrence
        self.pinnedPosition = pinnedPosition
    }
}

/// Payload handed to the pasteboard adapter on paste; carries the item's
/// current Effective Content only, plus a lineage hint for the next capture.
/// docs/03b-instruction-set.md §9
public struct PastePayload: Sendable, Hashable {
    public let item: HistoryItemReference
    public let representations: [HistoryRepresentation]
    public let lineageHint: HistoryItemID

    package init(
        item: HistoryItemReference,
        representations: [HistoryRepresentation],
        lineageHint: HistoryItemID
    ) {
        self.item = item
        self.representations = representations
        self.lineageHint = lineageHint
    }
}

/// Requested or produced thumbnail extent, in pixels.
/// docs/03b-instruction-set.md §9
public struct PixelSize: Sendable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Encoded thumbnail image format.
/// docs/03b-instruction-set.md §9
public enum ThumbnailFormat: Sendable, Hashable {
    case png
}

/// Encoded thumbnail bytes for one item — `Sendable` data rather than
/// `NSImage`/`CGImage`, so HistoryCore stays Foundation-only.
/// docs/03b-instruction-set.md §9
public struct ThumbnailPayload: Sendable, Hashable {
    public let item: HistoryItemReference
    public let pixels: PixelSize
    public let format: ThumbnailFormat
    public let encodedBytes: Data

    package init(
        item: HistoryItemReference,
        pixels: PixelSize,
        format: ThumbnailFormat,
        encodedBytes: Data
    ) {
        self.item = item
        self.pixels = pixels
        self.format = format
        self.encodedBytes = encodedBytes
    }
}
