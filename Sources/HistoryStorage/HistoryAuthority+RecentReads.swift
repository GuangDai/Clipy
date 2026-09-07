/// SQLite metadata-only recent pages and position reads (05 §14.1; 04 §6).
import Foundation
import HistoryCore
import HistoryDomain

extension HistoryAuthority {
    internal func currentPosition() async throws -> ChangePosition {
        await suspendIfRequested(.positionRecheckEntry)
        let row = try Self.fetchExactlyOnePositionRow(in: database)
        return try Self.decodePositionRow(row, limits: limits).position
    }

    /// One explicit snapshot joins ChangePosition, anchor validation and the
    /// bounded page. The synchronous helper also serves Gateway callers that
    /// already own a transaction; it never nests BEGIN inside that interval.
    internal func recentPage(limit: Int, after: HistoryPageCursor?) async throws -> HistoryPage {
        await suspendIfRequested(.readEntry)
        guard limits.pageRowLimitRange.contains(limit) else {
            throw HistoryFailure.invalidInput(.invalidPageLimit)
        }
        let page: HistoryPage
        do {
            page = try autoreleasepool {
                try database.readTransaction {
                    try recentPageInLocalContext(limit: limit, after: after)
                }
            }
        } catch let failure as SQLiteFailure {
            throw failure.historyFailure
        }
#if DEBUG
        storageLifecycleDebugProbe.record(phase: .recentAutoreleasePoolDrained)
#endif
        return page
    }

    internal func recentPageInLocalContext(
        limit: Int, after: HistoryPageCursor?
    ) throws -> HistoryPage {
        guard limits.pageRowLimitRange.contains(limit) else {
            throw HistoryFailure.invalidInput(.invalidPageLimit)
        }
        let row = try Self.fetchExactlyOnePositionRow(in: database)
        let currentPosition = try Self.decodePositionRow(row, limits: limits).position
        let cursor: ResolvedPageCursor?
        do {
            cursor = try after.map {
                try Self.decodeCursor($0, request: .init(kind: .recent, limit: limit), processMarker: processMarker)
            }
        } catch is PageCursorRejection {
            throw HistoryFailure.snapshotExpired(current: currentPosition)
        }
        if let cursor, cursor.position != currentPosition {
            throw HistoryFailure.snapshotExpired(current: currentPosition)
        }
        let anchor: (ordinal: Int?, date: Date, id: HistoryItemID)?
        if let cursor {
            guard case let .defaultOrder(ordinal, date, id) = cursor.anchor else {
                throw HistoryFailure.snapshotExpired(current: currentPosition)
            }
            anchor = (ordinal, date, id)
        } else {
            anchor = nil
        }
#if DEBUG
        let clock = ContinuousClock()
        let started = clock.now
        storageLifecycleDebugProbe.record(phase: .recentFetchBegin)
#endif
        var pinned: [ScalarReadRow] = []
        let continuesUnpinned = anchor.map { $0.ordinal == nil } ?? false
        if !continuesUnpinned {
#if DEBUG
            let laneStarted = clock.now
            storageLifecycleDebugProbe.record(phase: .recentPinnedFetchBegin)
#endif
            let fetched: [ScalarReadRow]
            if let ordinal = anchor?.ordinal {
                guard ordinal >= 0, ordinal < limits.hardMaximumRetainedItems else {
                    throw HistoryFailure.snapshotExpired(current: currentPosition)
                }
                fetched = try fetchRecentScalars(
                    whereSQL: "pinOrdinal IS NOT NULL AND pinOrdinal >= ?",
                    orderSQL: "pinOrdinal ASC", bindings: [.integer(Int64(ordinal))], limit: limit + 2
                )
            } else {
                fetched = try fetchRecentScalars(
                    whereSQL: "pinOrdinal IS NOT NULL", orderSQL: "pinOrdinal ASC", limit: limit + 1
                )
            }
#if DEBUG
            storageLifecycleDebugProbe.record(
                phase: .recentPinnedFetchComplete, elapsed: laneStarted.duration(to: clock.now), rows: fetched.count
            )
#endif
            if let cursor {
                guard fetched.first?.matches(cursor.anchor) == true else {
                    throw HistoryFailure.snapshotExpired(current: currentPosition)
                }
                pinned = Array(fetched.dropFirst())
            } else {
                pinned = fetched
            }
        }

        var unpinned: [ScalarReadRow] = []
        if pinned.count <= limit {
#if DEBUG
            let laneStarted = clock.now
            storageLifecycleDebugProbe.record(phase: .recentUnpinnedFetchBegin)
#endif
            let capacity = limit + 1 - pinned.count
            let fetchedCount: Int
            if continuesUnpinned, let anchor, let cursor {
                let date = anchor.date.timeIntervalSinceReferenceDate
                // Split the inclusive keyset into two index ranges. A single
                // OR predicate can scan/sort the entire remaining corpus;
                // these equality/date ranges each stop at the remaining LIMIT.
                let tied = try fetchRecentScalars(
                    whereSQL: "pinOrdinal IS NULL AND lastCopiedAt = ? AND id >= ?",
                    orderSQL: "id ASC",
                    bindings: [.real(date), .text(anchor.id.rawValue.uuidString)], limit: capacity + 1
                )
                guard tied.first?.matches(cursor.anchor) == true else {
                    throw HistoryFailure.snapshotExpired(current: currentPosition)
                }
                unpinned = Array(tied.dropFirst())
                if unpinned.count < capacity {
                    unpinned += try fetchRecentScalars(
                        whereSQL: "pinOrdinal IS NULL AND lastCopiedAt < ?",
                        orderSQL: "lastCopiedAt DESC, id ASC", bindings: [.real(date)],
                        limit: capacity - unpinned.count
                    )
                }
                fetchedCount = unpinned.count + 1
            } else {
                unpinned = try fetchRecentScalars(
                    whereSQL: "pinOrdinal IS NULL", orderSQL: "lastCopiedAt DESC, id ASC", limit: capacity
                )
                fetchedCount = unpinned.count
            }
#if DEBUG
            storageLifecycleDebugProbe.record(
                phase: .recentUnpinnedFetchComplete, elapsed: laneStarted.duration(to: clock.now), rows: fetchedCount
            )
#else
            _ = fetchedCount
#endif
        }
        let merged = pinned + unpinned
#if DEBUG
        storageLifecycleDebugProbe.record(
            phase: .recentFetchComplete, elapsed: started.duration(to: clock.now), rows: merged.count
        )
#endif
        let slice = merged.prefix(limit)
        let rows = try slice.map { try $0.toHistoryRow(limits: limits) }
        let next: HistoryPageCursor?
        if merged.count > limit, let last = slice.last {
            do {
                next = try PageCursorCodec.encode(ResolvedPageCursor(
                    queryShape: .recent(limit: limit), position: currentPosition, anchor: last.defaultOrderAnchor
                ), processMarker: processMarker)
            } catch {
                throw HistoryFailure.persistence(.invariantViolation)
            }
        } else {
            next = nil
        }
        return HistoryPage(position: currentPosition, rows: rows, next: next)
    }

    /// Every query uses a concrete partial index range and a bound LIMIT.
    /// Only its scalar columns are materialized; no model, payload or OFFSET.
    private func fetchRecentScalars(
        whereSQL: String, orderSQL: String, bindings: [SQLiteValue] = [], limit: Int
    ) throws -> [ScalarReadRow] {
        do {
            let statement = try database.prepare(
                "SELECT \(ScalarReadRow.columns) FROM history_items WHERE \(whereSQL) ORDER BY \(orderSQL) LIMIT ?",
                bindings: bindings + [.integer(Int64(limit))]
            )
            defer { statement.finalize() }
            var rows: [ScalarReadRow] = []
            rows.reserveCapacity(limit)
            while try statement.step() { rows.append(try ScalarReadRow(statement, limits: limits)) }
            return rows
        } catch let failure as SQLiteFailure {
            throw failure.historyFailure
        }
    }
}
