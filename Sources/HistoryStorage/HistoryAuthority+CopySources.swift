import Foundation
import HistoryCore
import HistoryDomain

extension HistoryAuthority {
    /// V2-11: one compact summary per observed application, updated inside
    /// the capture's History/Gateway transaction. No payloads or event log.
    internal func recordCopySource(itemID: HistoryItemID, application: String?, copiedAt: Date) throws {
        let key = application.map { "app:" + $0.precomposedStringWithCanonicalMapping } ?? "unknown"
        let identity: [SQLiteValue] = [.text(itemID.rawValue.uuidString), .text(key)]
        let query = try database.prepare(
            "SELECT firstCopiedAt,lastCopiedAt,copyCount FROM copy_sources WHERE itemID=? AND sourceKey=?",
            bindings: identity
        )
        defer { query.finalize() }
        var first = copiedAt
        var last = copiedAt
        var count: UInt64 = 1
        let exists = try query.step()
        if exists {
            let oldFirst = Date(timeIntervalSinceReferenceDate: try query.real(at: 0))
            let oldLast = Date(timeIntervalSinceReferenceDate: try query.real(at: 1))
            let oldCount = try sqliteUInt64(query.blob(at: 2))
            guard oldFirst.timeIntervalSinceReferenceDate.isFinite,
                  oldLast.timeIntervalSinceReferenceDate.isFinite,
                  oldFirst <= oldLast, oldCount > 0 else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            let increment = oldCount.addingReportingOverflow(1)
            guard !increment.overflow else { throw HistoryFailure.capacityExceeded(.copyCount) }
            first = min(oldFirst, copiedAt)
            last = max(oldLast, copiedAt)
            count = increment.partialValue
        }
        if !exists {
            try database.execute("UPDATE history_items SET sourceCount=sourceCount+1 WHERE id=?",
                                 bindings: [.text(itemID.rawValue.uuidString)])
        }
        try database.execute("""
            INSERT INTO copy_sources(itemID,sourceKey,application,firstCopiedAt,lastCopiedAt,copyCount)
            VALUES(?,?,?,?,?,?) ON CONFLICT(itemID,sourceKey) DO UPDATE SET
                firstCopiedAt=excluded.firstCopiedAt,lastCopiedAt=excluded.lastCopiedAt,
                copyCount=excluded.copyCount
            """, bindings: identity + [application.map(SQLiteValue.text) ?? .null,
                .real(first.timeIntervalSinceReferenceDate), .real(last.timeIntervalSinceReferenceDate),
                .blob(sqliteUInt64(count))])
    }

    /// Each page reads at most 32 records plus one lookahead, never payloads.
    /// The item's copy count is the occurrence snapshot: revisions/pins leave
    /// it unchanged; any capture changes it and may reorder these records.
    internal func copySources(
        for itemID: HistoryItemID, expectedCopyCount: UInt64, offset: Int
    ) throws -> HistoryCopySourcePage {
        guard offset >= 0 else { throw HistoryFailure.invalidInput(.invalidPageLimit) }
        return try database.readTransaction {
            guard let item = try HistoryItemRowHydration.metadata(itemID: itemID, in: database, limits: limits)
            else { throw HistoryFailure.notFound(itemID) }
            guard item.occurrence.count == expectedCopyCount else {
                throw HistoryFailure.snapshotExpired(current: try readPositionInLocalContext())
            }
            let query = try database.prepare("""
                SELECT application,firstCopiedAt,lastCopiedAt,copyCount FROM copy_sources
                WHERE itemID=? ORDER BY lastCopiedAt DESC,sourceKey ASC LIMIT 33 OFFSET ?
                """, bindings: [.text(itemID.rawValue.uuidString), .integer(Int64(offset))])
            defer { query.finalize() }
            var sources: [CopySourceSummary] = []
            var hasMore = false
            while try query.step() {
                if sources.count == 32 { hasMore = true; break }
                guard try query.isNull(at: 0)
                    || query.textByteCount(at: 0) <= limits.maximumSourceApplicationObservationUTF8Bytes else {
                    throw HistoryFailure.persistence(.corruptStoredValue)
                }
                let application = try query.optionalText(at: 0)
                let first = Date(timeIntervalSinceReferenceDate: try query.real(at: 1))
                let last = Date(timeIntervalSinceReferenceDate: try query.real(at: 2))
                let count = try sqliteUInt64(query.blob(at: 3))
                try mapCodecFailure {
                    try RevisionStateBlobCodec.validateSourceObservation(application, limits: limits)
                    try RevisionStateBlobCodec.validateFiniteLastCopiedAt(first)
                    try RevisionStateBlobCodec.validateFiniteLastCopiedAt(last)
                    try RevisionStateBlobCodec.validateCopyCount(count)
                }
                guard first <= last, count <= item.occurrence.count else {
                    throw HistoryFailure.persistence(.corruptStoredValue)
                }
                sources.append(CopySourceSummary(application: application, firstCopiedAt: first,
                                                 lastCopiedAt: last, count: count))
            }
            let occurrence = item.occurrence
            return HistoryCopySourcePage(
                item: HistoryItemReference(id: itemID, contentVersion: item.contentVersion),
                occurrence: CopyOccurrenceSummary(firstCopiedAt: occurrence.firstCopiedAt,
                    lastCopiedAt: occurrence.lastCopiedAt, count: occurrence.count,
                    firstSource: occurrence.firstSource, lastSource: occurrence.lastSource),
                sources: sources, nextOffset: hasMore ? offset + sources.count : nil
            )
        }
    }
}
