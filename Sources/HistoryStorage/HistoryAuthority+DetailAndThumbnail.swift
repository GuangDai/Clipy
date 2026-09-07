/// Purpose-specific reads over SQLite metadata and immutable representation
/// payloads. No read hydrates a Canonical/revision aggregate (V2-09 §§4/5).
import Foundation
import HistoryCore
import HistoryDomain

internal struct ThumbnailSourceSelection: Sendable {
    internal let bytes: Data
}

extension HistoryAuthority {
    private var contentReads: SQLiteContentReads {
        SQLiteContentReads(database: database, blobStore: blobStore, limits: limits)
    }

    internal func details(for id: HistoryItemID) async throws -> HistoryDetails {
        try sqliteContentRead {
            try database.readTransaction { try detailsInCurrentTransaction(for: id) }
        }
    }

    /// Gateway already owns its transaction. These reads contain no await,
    /// so metadata, selected payloads and the result belong to one interval.
    internal func detailsInCurrentTransaction(for id: HistoryItemID) throws -> HistoryDetails {
        try sqliteContentRead { try detailsAndTitle(for: id).details }
    }

    internal func externalDetails(for id: HistoryItemID) throws -> ExternalHistoryDetails {
        try sqliteContentRead {
            let value = try detailsAndTitle(for: id)
            return ExternalHistoryDetails(details: value.details, title: value.title)
        }
    }

    private func detailsAndTitle(for id: HistoryItemID) throws -> (details: HistoryDetails, title: String) {
        let reads = contentReads
        let item = try reads.item(for: id)
        let contents = try reads.contents(for: item)
        guard let canonical = contents.first else { throw HistoryFailure.persistence(.corruptStoredValue) }
        let canonicalSources = try reads.representations(in: canonical)
        let canonicalTypes = Set(canonicalSources.map(\.typeIdentifier))
        let canonicalRepresentations = try canonicalSources.map(reads.read)
        var effective = canonicalRepresentations
        var revisions: [RevisionSummary] = []
        for content in contents.dropFirst() {
            let sources = try reads.representations(in: content)
            guard sources.allSatisfy({ canonicalTypes.contains($0.typeIdentifier) }) else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            let isActive = content.id == item.currentContentID
            if isActive { effective = try sources.map(reads.read) }
            // Inactive revisions need only their durable title, type names,
            // size and time. Their payloads stay unopened even in Details.
            revisions.append(RevisionSummary(
                id: RevisionID(rawValue: content.id), createdAt: content.createdAt,
                isActive: isActive, title: content.title,
                typeIdentifiers: sources.map(\.typeIdentifier), byteCount: content.byteCount
            ))
        }
        return (HistoryDetails(
            item: item.reference, canonical: canonicalRepresentations, effective: effective,
            revisions: revisions, occurrence: item.occurrence, pinnedPosition: item.pinOrdinal
        ), item.title)
    }

    internal func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        try sqliteContentRead {
            try database.readTransaction { try pastePayloadInCurrentTransaction(for: id) }
        }
    }

    internal func pastePayloadInCurrentTransaction(for id: HistoryItemID) throws -> PastePayload {
        try sqliteContentRead {
            let reads = contentReads
            let item = try reads.item(for: id)
            let values = try reads.currentRepresentations(for: item).map(reads.read)
            return PastePayload(item: item.reference, representations: values, lineageHint: id)
        }
    }

    /// An exact representation read. Identity and version are checked before
    /// any payload access; no caller receives a blob identifier or file URL.
    internal func rawRepresentation(
        for item: HistoryItemReference,
        basis: SQLiteContentBasis,
        typeIdentifier: String
    ) throws -> HistoryRepresentation {
        try sqliteContentRead {
            let reads = contentReads
            try reads.requireCurrent(item)
            let current = try reads.item(for: item.id)
            let sources: [SQLiteRepresentationSource]
            switch basis {
            case .canonical:
                sources = try reads.representations(in: reads.canonicalContent(for: current))
            case .effective:
                sources = try reads.currentRepresentations(for: current)
            }
            guard let source = sources.first(where: { $0.typeIdentifier == typeIdentifier }) else {
                throw HistoryFailure.invalidInput(.unsupportedRepresentationType(typeIdentifier))
            }
            return try reads.read(source)
        }
    }

    // Thumbnail eligibility remains in its existing behavior owner, not a
    // storage-wide registry. ContentPreview receives only the selected bytes.
    internal static let thumbnailImageTypeIdentifiers: Set<String> = [
        "public.png", "public.jpeg", "public.tiff", "public.heic", "public.heif",
        "com.compuserve.gif", "com.microsoft.bmp",
    ]

    internal func validateThumbnailFlightJoin(
        for item: HistoryItemReference, pixels: PixelSize
    ) async throws {
        try validateThumbnailDimensions(pixels)
        try sqliteContentRead { try contentReads.requireCurrent(item) }
    }

    internal func thumbnailSource(
        for item: HistoryItemReference, pixels: PixelSize
    ) async throws -> ThumbnailSourceSelection? {
        try validateThumbnailDimensions(pixels)
        return try sqliteContentRead {
            try database.readTransaction {
                let reads = contentReads
                try reads.requireCurrent(item)
                let current = try reads.item(for: item.id)
                let sources = try reads.currentRepresentations(for: current)
                guard let selected = sources.first(where: {
                    Self.thumbnailImageTypeIdentifiers.contains($0.typeIdentifier)
                }) else { return nil }
                return ThumbnailSourceSelection(bytes: try reads.read(selected).bytes)
            }
        }
    }

    internal func validateThumbnailDimensions(_ pixels: PixelSize) throws {
        guard limits.thumbnailDimensionRange.contains(pixels.width),
              limits.thumbnailDimensionRange.contains(pixels.height) else {
            throw HistoryFailure.invalidInput(.invalidPixelSize)
        }
    }

    internal func readPositionInLocalContext() throws -> ChangePosition {
        try sqliteContentRead {
            let row = try Self.fetchExactlyOnePositionRow(in: database)
            return try Self.decodePositionRow(row, limits: limits).position
        }
    }

    internal static func decodeCursor(
        _ cursor: HistoryPageCursor, request: HistoryBrowseRequest, processMarker: UUID
    ) throws -> ResolvedPageCursor {
        let resolved = try PageCursorCodec.decode(cursor, processMarker: processMarker)
        guard resolved.queryShape.matches(request) else { throw PageCursorRejection.malformedCursor }
        return resolved
    }

    internal static func defaultOrderIsOrdered(_ lhs: SearchCorpusRow, _ rhs: SearchCorpusRow) -> Bool {
        switch (lhs.pinOrdinal, rhs.pinOrdinal) {
        case (let left?, let right?): left < right
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil):
            lhs.lastCopiedAt == rhs.lastCopiedAt ? lhs.id < rhs.id : lhs.lastCopiedAt > rhs.lastCopiedAt
        }
    }
}

private func sqliteContentRead<T>(_ body: () throws -> T) throws -> T {
    do { return try body() }
    catch let error as SQLiteFailure { throw error.historyFailure }
}
