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
    internal func recentPage(limit: Int, cursor: HistoryPageCursor?, filter: HistoryFilter = .all) async throws -> HistoryPage {
        await suspendIfRequested(.readEntry)
        guard limits.pageRowLimitRange.contains(limit) else {
            throw HistoryFailure.invalidInput(.invalidPageLimit)
        }
        let page: HistoryPage
        do {
            page = try autoreleasepool {
                try database.readTransaction {
                    try recentPageInLocalContext(limit: limit, cursor: cursor, filter: filter)
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
        limit: Int, cursor continuation: HistoryPageCursor?, filter: HistoryFilter = .all
    ) throws -> HistoryPage {
        guard limits.pageRowLimitRange.contains(limit) else {
            throw HistoryFailure.invalidInput(.invalidPageLimit)
        }
        let row = try Self.fetchExactlyOnePositionRow(in: database)
        let currentPosition = try Self.decodePositionRow(row, limits: limits).position
        let cursor: ResolvedPageCursor?
        do {
            cursor = try continuation.map {
                try Self.decodeCursor($0, request: .init(kind: .recent, limit: limit, filter: filter), processMarker: processMarker)
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
        if let cursor, cursor.direction == .backward, let anchor {
            return try recentPrecedingPage(
                limit: limit, cursor: cursor, anchor: anchor, position: currentPosition, filter: filter
            )
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
                guard ordinal >= 0 else {
                    throw HistoryFailure.snapshotExpired(current: currentPosition)
                }
                fetched = try fetchRecentScalars(
                    filter: filter,
                    whereSQL: "pinOrdinal IS NOT NULL AND pinOrdinal >= ?",
                    orderSQL: "pinOrdinal ASC", bindings: [.integer(Int64(ordinal))], limit: limit + 2
                )
            } else {
                fetched = try fetchRecentScalars(
                    filter: filter,
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
        if !filter.pinnedOnly && pinned.count <= limit {
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
                    filter: filter,
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
                        filter: filter,
                        whereSQL: "pinOrdinal IS NULL AND lastCopiedAt < ?",
                        orderSQL: "lastCopiedAt DESC, id ASC", bindings: [.real(date)],
                        limit: capacity - unpinned.count
                    )
                }
                fetchedCount = unpinned.count + 1
            } else {
                unpinned = try fetchRecentScalars(
                    filter: filter,
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
        return try recentResult(
            Array(slice), limit: limit, position: currentPosition,
            hasPrevious: cursor != nil, hasNext: merged.count > limit, filter: filter
        )
    }

    /// Reverse the existing partial indexes, selecting the nearest preceding
    /// rows, then restore the canonical display order. Equal dates use the
    /// reverse UUID tie-break; the unpinned head joins the pinned tail.
    private func recentPrecedingPage(
        limit: Int, cursor: ResolvedPageCursor,
        anchor: (ordinal: Int?, date: Date, id: HistoryItemID), position: ChangePosition, filter: HistoryFilter
    ) throws -> HistoryPage {
#if DEBUG
        let clock = ContinuousClock()
        let started = clock.now
        storageLifecycleDebugProbe.record(phase: .recentFetchBegin)
#endif
        let storedAnchor = try fetchRecentScalars(
            filter: filter,
            whereSQL: "id = ?", orderSQL: "id", bindings: [.text(anchor.id.rawValue.uuidString)], limit: 1
        )
        guard storedAnchor.first?.matches(cursor.anchor) == true else {
            throw HistoryFailure.snapshotExpired(current: position)
        }
        var preceding: [ScalarReadRow] = []
        if anchor.ordinal == nil {
#if DEBUG
            let laneStarted = clock.now
            storageLifecycleDebugProbe.record(phase: .recentUnpinnedFetchBegin)
#endif
            let date = anchor.date.timeIntervalSinceReferenceDate
            preceding = try fetchRecentScalars(
                filter: filter,
                whereSQL: "pinOrdinal IS NULL AND lastCopiedAt = ? AND id < ?",
                orderSQL: "id DESC", bindings: [.real(date), .text(anchor.id.rawValue.uuidString)], limit: limit + 1
            )
            if preceding.count <= limit {
                preceding += try fetchRecentScalars(
                    filter: filter,
                    whereSQL: "pinOrdinal IS NULL AND lastCopiedAt > ?",
                    orderSQL: "lastCopiedAt ASC, id DESC", bindings: [.real(date)], limit: limit + 1 - preceding.count
                )
            }
#if DEBUG
            storageLifecycleDebugProbe.record(
                phase: .recentUnpinnedFetchComplete, elapsed: laneStarted.duration(to: clock.now), rows: preceding.count + 1
            )
#endif
        }
        if preceding.count <= limit {
#if DEBUG
            let laneStarted = clock.now
            storageLifecycleDebugProbe.record(phase: .recentPinnedFetchBegin)
#endif
            let pinned: [ScalarReadRow]
            if let ordinal = anchor.ordinal {
                pinned = try fetchRecentScalars(
                    filter: filter,
                    whereSQL: "pinOrdinal IS NOT NULL AND pinOrdinal < ?",
                    orderSQL: "pinOrdinal DESC", bindings: [.integer(Int64(ordinal))], limit: limit + 1
                )
            } else {
                pinned = try fetchRecentScalars(
                    filter: filter,
                    whereSQL: "pinOrdinal IS NOT NULL", orderSQL: "pinOrdinal DESC", limit: limit + 1 - preceding.count
                )
            }
            preceding += pinned
#if DEBUG
            storageLifecycleDebugProbe.record(
                phase: .recentPinnedFetchComplete, elapsed: laneStarted.duration(to: clock.now),
                rows: pinned.count + (anchor.ordinal == nil ? 0 : 1)
            )
#endif
        }
#if DEBUG
        storageLifecycleDebugProbe.record(
            phase: .recentFetchComplete, elapsed: started.duration(to: clock.now), rows: preceding.count
        )
#endif
        return try recentResult(
            Array(preceding.prefix(limit).reversed()), limit: limit, position: position,
            hasPrevious: preceding.count > limit, hasNext: true, filter: filter
        )
    }

    private func recentResult(
        _ slice: [ScalarReadRow], limit: Int, position: ChangePosition,
        hasPrevious: Bool, hasNext: Bool, filter: HistoryFilter
    ) throws -> HistoryPage {
        let rows = try slice.map { try $0.toHistoryRow(limits: limits) }
        let previous: HistoryPageCursor?
        let next: HistoryPageCursor?
        do {
            previous = try hasPrevious ? slice.first.map {
                try PageCursorCodec.encode(ResolvedPageCursor(
                    queryShape: .recent(limit: limit, filter: filter), position: position,
                    anchor: $0.defaultOrderAnchor, direction: .backward
                ), processMarker: processMarker)
            } : nil
            next = try hasNext ? slice.last.map {
                try PageCursorCodec.encode(ResolvedPageCursor(
                    queryShape: .recent(limit: limit, filter: filter), position: position,
                    anchor: $0.defaultOrderAnchor, direction: .forward
                ), processMarker: processMarker)
            } : nil
        } catch {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return HistoryPage(position: position, rows: rows, previous: previous, next: next)
    }

    /// Every query uses a concrete partial index range and a bound LIMIT.
    /// Only its scalar columns are materialized; no model, payload or OFFSET.
    private func fetchRecentScalars(
        filter: HistoryFilter,
        whereSQL: String, orderSQL: String, bindings: [SQLiteValue] = [], limit: Int
    ) throws -> [ScalarReadRow] {
        do {
            let predicate = HistoryFilterSQL.predicate(filter)
            let statement = try database.prepare(
                "SELECT \(ScalarReadRow.columns) FROM history_items WHERE (\(whereSQL)) AND (\(predicate.sql)) ORDER BY \(orderSQL) LIMIT ?",
                bindings: bindings + predicate.bindings + [.integer(Int64(limit))]
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
