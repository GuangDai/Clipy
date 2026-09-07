import Foundation
import HistoryCore
import HistoryDomain

/// Scalar facts only. Payload bytes are read separately after the caller has
/// selected a representation in this same Authority interval (V2-09 §§4/5).
internal struct SQLiteContentItem: Sendable {
    let reference: HistoryItemReference
    let currentContentID: UUID
    let title: String
    let occurrence: CopyOccurrenceSummary
    let pinOrdinal: Int?
    let canonicalBytes: Int
    let revisionCount: Int
    let revisionBytes: Int
    let effectiveMatchesCanonical: Bool
}

internal struct SQLiteStoredContent: Sendable {
    let id: UUID
    let ordinal: Int
    let createdAt: Date
    let title: String
    let byteCount: Int
    let representationCount: Int
}

internal struct SQLiteRepresentationSource: Sendable {
    let contentID: UUID
    let ordinal: Int
    let typeIdentifier: String
    let byteCount: Int
}

/// Concrete SQL reads; no model hydration, decoder routing or retained row
/// objects. Statements and file reads stay inside their owning actor call.
internal struct SQLiteContentReads {
    let database: SQLiteDatabase
    let blobStore: ImmutableBlobStore
    let limits: HistoryLimits

    func reference(for id: HistoryItemID) throws -> HistoryItemReference {
        let statement = try database.prepare(
            "SELECT contentVersion FROM history_items WHERE id = ?", bindings: [.text(id.rawValue.uuidString)]
        )
        defer { statement.finalize() }
        guard try statement.step() else { throw HistoryFailure.notFound(id) }
        let version = try mapCodecFailure {
            try RevisionStateBlobCodec.decodeContentVersion(sqliteUInt64(statement.blob(at: 0)))
        }
        return HistoryItemReference(id: id, contentVersion: version)
    }

    func requireCurrent(_ expected: HistoryItemReference) throws {
        let current = try reference(for: expected.id)
        guard current == expected else {
            throw HistoryFailure.staleContent(expected: expected.contentVersion, current: current.contentVersion)
        }
    }

    func item(for id: HistoryItemID) throws -> SQLiteContentItem {
        let statement = try database.prepare("""
            SELECT contentVersion, currentContentID, titleUTF8, firstCopiedAt, lastCopiedAt,
                   copyCount, firstSource, lastSource, pinOrdinal, canonicalBytes, revisionCount, revisionBytes,
                   effectiveMatchesCanonical
            FROM history_items WHERE id = ?
            """, bindings: [.text(id.rawValue.uuidString)])
        defer { statement.finalize() }
        guard try statement.step() else { throw HistoryFailure.notFound(id) }
        let currentContentID = try uuid(statement.text(at: 1))
        let title = try title(statement.blob(at: 2))
        let first = try Date(timeIntervalSinceReferenceDate: statement.real(at: 3))
        let last = try Date(timeIntervalSinceReferenceDate: statement.real(at: 4))
        let count = try sqliteUInt64(statement.blob(at: 5))
        let firstSource = try statement.optionalText(at: 6)
        let lastSource = try statement.optionalText(at: 7)
        let pin = try statement.isNull(at: 8) ? nil : nonnegativeInt(statement.integer(at: 8))
        let canonicalBytes = try nonnegativeInt(statement.integer(at: 9))
        let revisionCount = try nonnegativeInt(statement.integer(at: 10))
        let revisionBytes = try nonnegativeInt(statement.integer(at: 11))
        let matchesCanonical = try statement.integer(at: 12)
        guard canonicalBytes > 0, canonicalBytes <= limits.maximumCaptureBytes,
              revisionCount <= limits.maximumRevisionsPerItem,
              revisionBytes <= limits.maximumTotalRevisionBytesPerItem,
              (revisionCount == 0) == (revisionBytes == 0),
              matchesCanonical == 0 || matchesCanonical == 1,
              revisionCount > 0 || matchesCanonical == 1 else { throw corrupt }
        let version = try mapCodecFailure {
            try RevisionStateBlobCodec.decodeContentVersion(sqliteUInt64(statement.blob(at: 0)))
        }
        let occurrence = try mapCodecFailure {
            try RevisionStateBlobCodec.decodeOccurrence(
                firstCopiedAt: first, lastCopiedAt: last, copyCount: count,
                firstSource: firstSource, lastSource: lastSource, limits: limits
            )
        }
        return SQLiteContentItem(
            reference: HistoryItemReference(id: id, contentVersion: version), currentContentID: currentContentID,
            title: title, occurrence: CopyOccurrenceSummary(
                firstCopiedAt: occurrence.firstCopiedAt, lastCopiedAt: occurrence.lastCopiedAt,
                count: occurrence.count, firstSource: occurrence.firstSource, lastSource: occurrence.lastSource
            ), pinOrdinal: pin, canonicalBytes: canonicalBytes,
            revisionCount: revisionCount, revisionBytes: revisionBytes,
            effectiveMatchesCanonical: matchesCanonical == 1
        )
    }

    func currentContent(for item: SQLiteContentItem) throws -> SQLiteStoredContent {
        let content = try content(id: item.currentContentID, itemID: item.reference.id)
        guard item.revisionCount == 0 ? content.ordinal == 0 : content.ordinal > 0 else { throw corrupt }
        guard content.ordinal == 0 ? content.byteCount == item.canonicalBytes
            : content.byteCount <= item.revisionBytes else { throw corrupt }
        return content
    }

    func canonicalContent(for item: SQLiteContentItem) throws -> SQLiteStoredContent {
        let statement = try database.prepare("""
            SELECT id, revisionOrdinal, createdAt, titleUTF8, contentByteCount, representationCount
            FROM contents WHERE itemID = ? AND revisionOrdinal = 0
            """, bindings: [.text(item.reference.id.rawValue.uuidString)])
        defer { statement.finalize() }
        guard try statement.step() else { throw corrupt }
        let content = try decodeContent(statement)
        guard content.byteCount == item.canonicalBytes else { throw corrupt }
        return content
    }

    func contents(for item: SQLiteContentItem) throws -> [SQLiteStoredContent] {
        let statement = try database.prepare("""
            SELECT id, revisionOrdinal, createdAt, titleUTF8, contentByteCount, representationCount
            FROM contents WHERE itemID = ? ORDER BY revisionOrdinal LIMIT ?
            """, bindings: [.text(item.reference.id.rawValue.uuidString), .integer(Int64(limits.maximumRevisionsPerItem + 2))])
        defer { statement.finalize() }
        var contents: [SQLiteStoredContent] = []
        var revisionBytes = 0
        while try statement.step() {
            guard contents.count <= limits.maximumRevisionsPerItem else { throw corrupt }
            let content = try decodeContent(statement)
            // Revision ordinals retain creation order through pruning. Gaps
            // are valid and do not require rewriting surviving revisions.
            if let previous = contents.last {
                guard content.ordinal > previous.ordinal else { throw corrupt }
            } else {
                guard content.ordinal == 0 else { throw corrupt }
            }
            if content.ordinal > 0 {
                let (sum, overflow) = revisionBytes.addingReportingOverflow(content.byteCount)
                guard !overflow, sum <= limits.maximumTotalRevisionBytesPerItem else { throw corrupt }
                revisionBytes = sum
            }
            contents.append(content)
        }
        guard contents.count == item.revisionCount + 1,
              contents.first?.byteCount == item.canonicalBytes,
              revisionBytes == item.revisionBytes,
              contents.contains(where: { $0.id == item.currentContentID
                  && (item.revisionCount == 0 ? $0.ordinal == 0 : $0.ordinal > 0) }) else { throw corrupt }
        return contents
    }

    func representations(in content: SQLiteStoredContent) throws -> [SQLiteRepresentationSource] {
        // Deliberately omit inlineBytes: even an inline sibling is not a
        // requested thumbnail payload. Only read(_:) materializes bytes.
        let statement = try database.prepare("""
            SELECT ordinal, exactType, byteCount FROM representations
            WHERE contentID = ? ORDER BY ordinal LIMIT ?
            """, bindings: [.text(content.id.uuidString), .integer(Int64(limits.maximumRepresentationsPerCaptureOrRevision + 1))])
        defer { statement.finalize() }
        var values: [SQLiteRepresentationSource] = []
        var byteCount = 0
        while try statement.step() {
            guard values.count < limits.maximumRepresentationsPerCaptureOrRevision else { throw corrupt }
            let ordinal = try nonnegativeInt(statement.integer(at: 0))
            let identifier = try statement.text(at: 1)
            let count = try nonnegativeInt(statement.integer(at: 2))
            try mapCodecFailure { try CodecValidation.validateTypeIdentifier(identifier, limits: limits) }
            guard ordinal == values.count, count > 0, count <= limits.maximumRepresentationBytes else { throw corrupt }
            let (sum, overflow) = byteCount.addingReportingOverflow(count)
            guard !overflow, sum <= content.byteCount else { throw corrupt }
            byteCount = sum
            values.append(SQLiteRepresentationSource(
                contentID: content.id, ordinal: ordinal, typeIdentifier: identifier, byteCount: count
            ))
        }
        guard values.count == content.representationCount, byteCount == content.byteCount else { throw corrupt }
        try mapCodecFailure { try CodecValidation.requireNormalizedTypeIdentifierOrder(values.map(\.typeIdentifier)) }
        return values
    }

    func currentRepresentations(for item: SQLiteContentItem) throws -> [SQLiteRepresentationSource] {
        let current = try currentContent(for: item)
        let values = try representations(in: current)
        if current.ordinal > 0 {
            let canonical = try representations(in: canonicalContent(for: item))
            let types = Set(canonical.map(\.typeIdentifier))
            guard values.allSatisfy({ types.contains($0.typeIdentifier) }) else { throw corrupt }
        }
        return values
    }

    func read(_ source: SQLiteRepresentationSource) throws -> HistoryRepresentation {
        try Task.checkCancellation()
        let statement = try database.prepare("""
            SELECT inlineBytes, blobID FROM representations WHERE contentID = ? AND ordinal = ?
            """, bindings: [.text(source.contentID.uuidString), .integer(Int64(source.ordinal))])
        defer { statement.finalize() }
        guard try statement.step() else { throw corrupt }
        let inline = try statement.optionalBlob(at: 0)
        let blob = try statement.optionalText(at: 1)
        let bytes: Data
        switch (inline, blob) {
        case (.some(let value), .none):
            guard value.count == source.byteCount else { throw corrupt }
            bytes = value
        case (.none, .some(let id)):
            bytes = try blobStore.read(id: uuid(id), expectedByteCount: source.byteCount)
        default: throw corrupt
        }
        return HistoryRepresentation(typeIdentifier: source.typeIdentifier, bytes: bytes)
    }

    private func content(id: UUID, itemID: HistoryItemID) throws -> SQLiteStoredContent {
        let statement = try database.prepare("""
            SELECT id, revisionOrdinal, createdAt, titleUTF8, contentByteCount, representationCount
            FROM contents WHERE id = ? AND itemID = ?
            """, bindings: [.text(id.uuidString), .text(itemID.rawValue.uuidString)])
        defer { statement.finalize() }
        guard try statement.step() else { throw corrupt }
        return try decodeContent(statement)
    }

    private func decodeContent(_ row: SQLiteStatement) throws -> SQLiteStoredContent {
        let id = try uuid(row.text(at: 0))
        let ordinal = try nonnegativeInt(row.integer(at: 1))
        let createdAt = try row.real(at: 2)
        let title = try title(row.blob(at: 3))
        let byteCount = try nonnegativeInt(row.integer(at: 4))
        let count = try nonnegativeInt(row.integer(at: 5))
        guard createdAt.isFinite,
              count > 0, count <= limits.maximumRepresentationsPerCaptureOrRevision,
              byteCount > 0, byteCount <= (ordinal == 0 ? limits.maximumCaptureBytes : limits.maximumProposedRevisionBytes)
        else { throw corrupt }
        return SQLiteStoredContent(id: id, ordinal: ordinal, createdAt: Date(timeIntervalSinceReferenceDate: createdAt),
                                   title: title, byteCount: byteCount, representationCount: count)
    }

    private func title(_ bytes: Data) throws -> String {
        guard bytes.count <= limits.maximumStoredTitleUTF8Bytes,
              let value = String(validating: bytes, as: UTF8.self) else { throw corrupt }
        return value
    }

    private func uuid(_ text: String) throws -> UUID {
        guard let value = UUID(uuidString: text), value.uuidString == text else { throw corrupt }
        return value
    }

    private func nonnegativeInt(_ value: Int64) throws -> Int {
        guard let result = Int(exactly: value), result >= 0 else { throw corrupt }
        return result
    }

    private var corrupt: HistoryFailure { .persistence(.corruptStoredValue) }
}
