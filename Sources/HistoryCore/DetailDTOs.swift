/// Detail, paste, and thumbnail DTOs — the caller-facing result values of the
/// detail/paste/thumbnail queries. Detail is the only general UI query that
/// returns content lineage bytes; paste returns current Effective Content
/// only; thumbnail returns encoded, `Sendable` bytes rather than
/// `NSImage`/`CGImage`.
/// Owning spec: docs/03b-instruction-set.md §9 (Part III — Caller Interface B).
/// Foundation-only.
import Foundation

/// One typed representation of an item's stored content bytes.
/// docs/03b-instruction-set.md §9
public struct HistoryRepresentation: Sendable, Hashable {
    public let typeIdentifier: String
    public let bytes: Data

    package init(typeIdentifier: String, bytes: Data) {
        self.typeIdentifier = typeIdentifier
        self.bytes = bytes
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

/// Full detail for one item: canonical and effective content lineage bytes,
/// revision summaries, occurrence facts, and pin placement.
/// The only general UI query that returns content lineage bytes.
/// docs/03b-instruction-set.md §9
public struct HistoryDetails: Sendable, Hashable {
    public let item: HistoryItemReference
    public let canonical: [HistoryRepresentation]
    public let effective: [HistoryRepresentation]
    public let revisions: [RevisionSummary]
    public let occurrence: CopyOccurrenceSummary
    public let pinnedPosition: Int?

    package init(
        item: HistoryItemReference,
        canonical: [HistoryRepresentation],
        effective: [HistoryRepresentation],
        revisions: [RevisionSummary],
        occurrence: CopyOccurrenceSummary,
        pinnedPosition: Int?
    ) {
        self.item = item
        self.canonical = canonical
        self.effective = effective
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
