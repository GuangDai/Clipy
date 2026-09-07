/// Direct SQLite facts. Candidate iteration retains only its current bytes
/// and the confirmed winner's scalars, never a history-sized content array.
import Foundation
import HistoryCore
import HistoryDomain

internal struct HistoryItemMetadata: Sendable {
    internal let id: HistoryItemID
    internal let contentVersion: ContentVersion
    internal let currentContentID: UUID
    internal let occurrence: CopyOccurrence
    internal let pinOrdinal: PinOrdinal?
    internal let canonicalBytes: Int
    internal let revisionCount: Int
    internal let revisionBytes: Int
    internal var summary: RetainedItemSummary {
        RetainedItemSummary(id: id, lastCopiedAt: occurrence.lastCopiedAt, pinOrdinal: pinOrdinal)
    }
}

internal struct HistoryContentMetadata: Sendable {
    internal let id: UUID
    internal let ordinal: Int
    internal let createdAt: Date
    internal let byteCount: Int
    internal let representationCount: Int
    internal var revisionSummary: RevisionRetentionSummary {
        RevisionRetentionSummary(id: RevisionID(rawValue: id), byteCount: byteCount)
    }
}

internal enum HistoryItemRowHydration {
    internal static func metadata(itemID: HistoryItemID, in database: SQLiteDatabase,
                                  limits: HistoryLimits = .standard) throws -> HistoryItemMetadata? {
        let row = try database.prepare("""
            SELECT contentVersion,currentContentID,firstCopiedAt,lastCopiedAt,copyCount,
                   firstSource,lastSource,pinOrdinal,canonicalBytes,revisionCount,revisionBytes
            FROM history_items WHERE id=?
            """, bindings: [.text(itemID.rawValue.uuidString)])
        defer { row.finalize() }
        guard try row.step() else { return nil }
        let first = try Date(timeIntervalSinceReferenceDate: row.real(at: 2))
        let last = try Date(timeIntervalSinceReferenceDate: row.real(at: 3))
        let count = try sqliteUInt64(row.blob(at: 4))
        let firstSource = try row.optionalText(at: 5)
        let lastSource = try row.optionalText(at: 6)
        let version = try sqliteUInt64(row.blob(at: 0))
        let canonicalBytes = try integer(row, 8)
        let revisionCount = try integer(row, 9)
        let revisionBytes = try integer(row, 10)
        guard first.timeIntervalSinceReferenceDate.isFinite, last.timeIntervalSinceReferenceDate.isFinite,
              first <= last, count > 0, version > 0, canonicalBytes > 0,
              canonicalBytes <= limits.maximumCaptureBytes,
              revisionCount >= 0, revisionCount <= limits.maximumRevisionsPerItem,
              revisionBytes >= 0, revisionBytes <= limits.maximumTotalRevisionBytesPerItem,
              (revisionCount == 0 ? revisionBytes == 0 : revisionBytes >= revisionCount),
              [firstSource, lastSource].allSatisfy({ ($0?.utf8.count ?? 0) <= limits.maximumSourceApplicationObservationUTF8Bytes })
        else { throw corrupt }
        return HistoryItemMetadata(id: itemID, contentVersion: ContentVersion(rawValue: version),
            currentContentID: try uuid(row.text(at: 1)),
            occurrence: CopyOccurrence(firstCopiedAt: first, lastCopiedAt: last, count: count,
                                       firstSource: firstSource, lastSource: lastSource),
            pinOrdinal: try pin(row, 7), canonicalBytes: canonicalBytes,
            revisionCount: revisionCount, revisionBytes: revisionBytes)
    }

    internal static func canonical(itemID: HistoryItemID, in database: SQLiteDatabase,
                                   blobStore: ImmutableBlobStore, limits: HistoryLimits = .standard) throws -> CanonicalContent {
        let query = try database.prepare("SELECT id FROM contents WHERE itemID=? AND revisionOrdinal=0",
                                         bindings: [.text(itemID.rawValue.uuidString)])
        defer { query.finalize() }
        guard try query.step() else { throw corrupt }
        let loaded = try content(id: uuid(query.text(at: 0)), itemID: itemID,
                                 in: database, blobStore: blobStore, limits: limits)
        var representations: [CanonicalRepresentation] = []
        for (representation, fingerprint) in zip(loaded.content.representations, loaded.fingerprints) {
            guard let fingerprint else { throw corrupt }
            representations.append(CanonicalRepresentation(content: representation, fingerprint: fingerprint))
        }
        do { return try CanonicalContent(representations: representations) }
        catch { throw corrupt }
    }

    internal static func effective(itemID: HistoryItemID, in database: SQLiteDatabase,
                                   blobStore: ImmutableBlobStore, limits: HistoryLimits = .standard)
        throws -> (item: HistoryItemReference, content: EffectiveContent) {
        guard let metadata = try metadata(itemID: itemID, in: database, limits: limits) else {
            throw HistoryFailure.notFound(itemID)
        }
        let loaded = try content(id: metadata.currentContentID, itemID: itemID,
                                 in: database, blobStore: blobStore, limits: limits)
        // The same current-lineage relationships as purpose-specific reads
        // (SQLiteContentReads.currentContent). A valid FK to Canonical is
        // not a valid active pointer once any immutable revision exists.
        guard metadata.revisionCount == 0 ? loaded.metadata.ordinal == 0 : loaded.metadata.ordinal > 0,
              loaded.metadata.ordinal == 0 ? loaded.metadata.byteCount == metadata.canonicalBytes
                : loaded.metadata.byteCount <= metadata.revisionBytes else { throw corrupt }
        return (HistoryItemReference(id: itemID, contentVersion: metadata.contentVersion), loaded.content)
    }

    internal static func contentMetadata(id: UUID, itemID: HistoryItemID, in database: SQLiteDatabase) throws -> HistoryContentMetadata {
        let row = try database.prepare("""
            SELECT revisionOrdinal,createdAt,contentByteCount,representationCount
            FROM contents WHERE id=? AND itemID=?
            """, bindings: [.text(id.uuidString), .text(itemID.rawValue.uuidString)])
        defer { row.finalize() }
        guard try row.step() else { throw corrupt }
        let ordinal = try integer(row, 0)
        let createdAt = try Date(timeIntervalSinceReferenceDate: row.real(at: 1))
        let bytes = try integer(row, 2)
        let count = try integer(row, 3)
        guard ordinal >= 0, createdAt.timeIntervalSinceReferenceDate.isFinite, bytes > 0, count > 0 else { throw corrupt }
        return HistoryContentMetadata(id: id, ordinal: ordinal, createdAt: createdAt, byteCount: bytes, representationCount: count)
    }

    internal static func content(id: UUID, itemID: HistoryItemID, in database: SQLiteDatabase,
                                 blobStore: ImmutableBlobStore, limits: HistoryLimits = .standard)
        throws -> (metadata: HistoryContentMetadata, content: EffectiveContent, fingerprints: [ContentFingerprint?]) {
        let metadata = try contentMetadata(id: id, itemID: itemID, in: database)
        guard metadata.representationCount <= limits.maximumRepresentationsPerCaptureOrRevision,
              metadata.byteCount <= (metadata.ordinal == 0 ? limits.maximumCaptureBytes : limits.maximumProposedRevisionBytes)
        else { throw corrupt }
        let rows = try database.prepare("""
            SELECT ordinal,exactType,typeKey,byteCount,fingerprint,inlineBytes,blobID
            FROM representations WHERE contentID=? ORDER BY ordinal
            """, bindings: [.text(id.uuidString)])
        defer { rows.finalize() }
        var representations: [ContentRepresentation] = []
        var fingerprints: [ContentFingerprint?] = []
        var types = Set<String>()
        var total = 0
        while try rows.step() {
            let type = try rows.text(at: 1)
            let count = try integer(rows, 3)
            guard try integer(rows, 0) == representations.count,
                  !type.isEmpty, type.utf8.count <= limits.maximumTypeIdentifierUTF8Bytes,
                  try rows.text(at: 2) == type.precomposedStringWithCanonicalMapping,
                  types.insert(type).inserted, count > 0, count <= limits.maximumRepresentationBytes,
                  representations.count < metadata.representationCount else { throw corrupt }
            if let previous = representations.last {
                guard previous.typeIdentifier.unicodeScalars.lexicographicallyPrecedes(type.unicodeScalars) else { throw corrupt }
            }
            let inline = try rows.optionalBlob(at: 5)
            let blobID = try rows.optionalText(at: 6)
            let bytes: Data
            switch (inline, blobID) {
            case (.some(let value), .none): bytes = value
            case (.none, .some(let value)): bytes = try blobStore.read(id: uuid(value), expectedByteCount: count)
            default: throw corrupt
            }
            guard bytes.count == count else { throw corrupt }
            let fingerprint = try rows.optionalBlob(at: 4).map { ContentFingerprint(rawValue: try sqliteUInt64($0)) }
            guard (metadata.ordinal == 0) == (fingerprint != nil) else { throw corrupt }
            representations.append(ContentRepresentation(typeIdentifier: type, bytes: bytes))
            fingerprints.append(fingerprint)
            total += count
        }
        guard representations.count == metadata.representationCount, total == metadata.byteCount else { throw corrupt }
        if metadata.ordinal > 0 {
            let canonicalTypes = try database.prepare("""
                SELECT r.typeKey FROM representations r JOIN contents c ON c.id=r.contentID
                WHERE c.itemID=? AND c.revisionOrdinal=0
                """, bindings: [.text(itemID.rawValue.uuidString)])
            defer { canonicalTypes.finalize() }
            var allowed = Set<String>()
            while try canonicalTypes.step() { allowed.insert(try canonicalTypes.text(at: 0)) }
            guard types.isSubset(of: allowed) else { throw corrupt }
        }
        return (metadata, EffectiveContent(representations: representations), fingerprints)
    }

    internal static func retainedSummary(_ row: SQLiteStatement) throws -> RetainedItemSummary {
        let date = try Date(timeIntervalSinceReferenceDate: row.real(at: 1))
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw corrupt }
        return RetainedItemSummary(id: HistoryItemID(rawValue: try uuid(row.text(at: 0))), lastCopiedAt: date, pinOrdinal: try pin(row, 2))
    }
    internal static func uuid(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value), id.uuidString == value else { throw corrupt }
        return id
    }
    internal static func integer(_ row: SQLiteStatement, _ column: Int32) throws -> Int {
        guard let value = Int(exactly: try row.integer(at: column)) else { throw corrupt }
        return value
    }
    private static func pin(_ row: SQLiteStatement, _ column: Int32) throws -> PinOrdinal? {
        guard try !row.isNull(at: column) else { return nil }
        let ordinal = try integer(row, column)
        guard ordinal >= 0 else { throw corrupt }
        return PinOrdinal(rawValue: ordinal)
    }
    private static var corrupt: HistoryFailure { .persistence(.corruptStoredValue) }
}

internal enum IngestFactLoader {
    internal static func loadFacts(in database: SQLiteDatabase, blobStore: ImmutableBlobStore,
                                   prepared: PreparedCapture, retention: RetentionPolicy,
                                   limits: HistoryLimits = .standard) throws -> IngestFacts {
        var match: CaptureMatch?
        if let hintedID = prepared.origin.lineageHint,
           let metadata = try HistoryItemRowHydration.metadata(itemID: hintedID, in: database, limits: limits) {
            let effective = try HistoryItemRowHydration.effective(itemID: hintedID, in: database, blobStore: blobStore, limits: limits)
            match = confirmLineageCapture(incoming: prepared.canonical, effective: effective.content,
                                          id: hintedID, occurrence: metadata.occurrence, pinOrdinal: metadata.pinOrdinal)
        }
        if match == nil {
            var sql = """
                SELECT c.itemID FROM representations r JOIN contents c ON c.id=r.contentID
                WHERE c.revisionOrdinal=0 AND r.typeKey=? AND r.byteCount=? AND r.fingerprint=?
                """
            var bindings: [SQLiteValue] = []
            for (index, representation) in prepared.canonical.representations.enumerated() {
                if index > 0 {
                    sql += " AND EXISTS(SELECT 1 FROM representations s WHERE s.contentID=c.id AND s.typeKey=? AND s.byteCount=? AND s.fingerprint=?)"
                }
                bindings += [.text(representation.content.typeIdentifier.precomposedStringWithCanonicalMapping),
                             .integer(Int64(representation.content.bytes.count)), .blob(sqliteUInt64(representation.fingerprint.rawValue))]
            }
            let candidates = try database.prepare(sql, bindings: bindings)
            defer { candidates.finalize() }
            var winner: CanonicalCaptureMatch?
            while try candidates.step() {
                let itemID = HistoryItemID(rawValue: try HistoryItemRowHydration.uuid(candidates.text(at: 0)))
                let confirmed = try autoreleasepool {
                    guard let metadata = try HistoryItemRowHydration.metadata(itemID: itemID, in: database, limits: limits) else {
                        throw HistoryFailure.persistence(.invariantViolation)
                    }
                    let canonical = try HistoryItemRowHydration.canonical(itemID: itemID, in: database, blobStore: blobStore, limits: limits)
                    return confirmCanonicalCapture(incoming: prepared.canonical, existing: canonical,
                        id: itemID, occurrence: metadata.occurrence, pinOrdinal: metadata.pinOrdinal)
                }
                if let confirmed {
                    winner = winner.map { preferredCanonicalCaptureMatch($0, confirmed) } ?? confirmed
                }
            }
            match = winner?.value
        }
        let state = try database.prepare("SELECT retainedItemCount,pinnedItemCount FROM history_state WHERE key='retained-history'")
        defer { state.finalize() }
        guard try state.step() else { throw HistoryFailure.persistence(.invariantViolation) }
        let retained = try HistoryItemRowHydration.integer(state, 0)
        let pinned = try HistoryItemRowHydration.integer(state, 1)
        guard retained >= 0, retained <= limits.hardMaximumRetainedItems, pinned >= 0, pinned <= retained else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let unpinned = retained - pinned
        let occupancy = try database.prepare(
            "SELECT 1 FROM history_items WHERE id=?", bindings: [.text(prepared.candidateID.rawValue.uuidString)]
        )
        let candidateIDExists = try occupancy.step()
        occupancy.finalize()
        if match == nil, candidateIDExists {
            // Let the pure planner report the recoverable ID collision
            // before choosing a prefix that would exclude that occupied ID.
            return IngestFacts(confirmedMatch: nil, candidateIDExists: true,
                retention: CaptureRetentionFacts(retainedCount: retained, unpinnedCount: unpinned, retirementPrefix: nil))
        }
        let victimCount: Int
        do {
            victimCount = try captureRetirementCount(
                confirmedMatch: match, retainedCount: retained, unpinnedCount: unpinned,
                retention: retention, hardMaximumRetainedItems: limits.hardMaximumRetainedItems
            )
        } catch let rejection as DomainRejection {
            throw rejection.historyFailure
        }
        let incomingBytes = match == nil
            ? prepared.canonical.representations.reduce(0) { $0 + $1.content.bytes.count } : 0
        let total = try RetentionConfigLoading.checkedAdd(
            RetentionConfigLoading.totalRetainedBytes(in: database), incomingBytes
        )
        let prefix = try RetentionConfigLoading.retirementPrefix(
            in: database,
            policies: HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil),
            now: prepared.observedAt,
            protectedItemID: match?.id ?? prepared.candidateID,
            projectedTotalBytes: total, minimumRetiredItems: victimCount
        )
        return IngestFacts(confirmedMatch: match, candidateIDExists: candidateIDExists,
            retention: CaptureRetentionFacts(retainedCount: retained, unpinnedCount: unpinned, retirementPrefix: prefix))
    }
}
