/// Position and recent-browse read paths (§14; docs/04-coherence.md).
/// Split out of HistoryAuthority.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

extension HistoryAuthority {
    // MARK: - Read paths (docs/05-authority-kernel.md §14; docs/04-coherence.md)

    // The step-7 read methods: position-only recheck, recent browse
    // (§14.1), search corpus capture (§14.2), detail and paste (§14.3).
    // Each reuses this file's non-suspending read-interval spine: the only
    // `await` is the WS12 test seam at entry, before the context exists (§5).

    /// One owner for the projection scalars fetched by recent/search reads
    /// and search corpus capture. Search adds only `searchBodyUTF8`;
    /// keeping the common list here prevents one read path silently omitting
    /// a field that `ScalarReadRow`/`SearchCorpusRow` consumes (§14.1–§14.2).
    internal static func scalarProjectionProperties(
        includingSearchBody: Bool
    ) -> [PartialKeyPath<HistoryItemRow>] {
        var properties: [PartialKeyPath<HistoryItemRow>] = [
            \.id,
            \.contentVersionRaw,
            \.titleUTF8,
            \.effectiveTypeIdentifiersBlob,
            \.lastCopiedAt,
            \.copyCount,
            \.lastSource,
            \.pinOrdinal,
        ]
        if includingSearchBody {
            properties.append(\.searchBodyUTF8)
        }
        return properties
    }

    /// The position-only scalar read backing the observe loop's phase-1
    /// race-closing recheck (docs/04-coherence.md §5) and WS12
    /// (docs/06-cross-cutting.md §8).
    ///
    /// Flow: WS12 seam at entry → operation-local context → singleton fetch/
    /// decode → return position. The single read interval contains no `await`
    /// past context creation (§5).
    ///
    /// - Throws: `.temporarilyUnavailable(.factProof)` for a framework fetch
    ///   failure; `.persistence(.invariantViolation)` for a duplicate/absent
    ///   singleton; `.persistence(.corruptStoredValue)` for an out-of-range
    ///   stored retention value (§16).
    internal func currentPosition() async throws -> ChangePosition {
        // WS12 seam: the one legal suspension point of this path — no
        // context is live yet (§5).
        await suspendIfRequested(.positionRecheckEntry)

        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending read interval (§5): no `await` past this
        //    line while the context is live. ──

        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )
        return currentPosition
    }

    /// Recent browse (docs/05-authority-kernel.md §14.1): one non-suspending
    /// interval reading the position and at most `limit + 1` scalar projection
    /// rows per lane, with cursor validation and expiry.
    /// docs/05-authority-kernel.md §14.1; docs/04-coherence.md §6
    ///
    /// Flow: WS12 seam at entry → limit validation → cursor decode+validation
    /// when present → operation-local context → position read → scalar-only
    /// two-lane fetch (pinned by `pinOrdinal` ascending; unpinned by
    /// `lastCopiedAt DESC, id ASC`) → continuation
    /// anchor application → page assembly → cursor mint.
    ///
    /// No Canonical/revision blob is decoded (§14.1, §7.5); only scalar
    /// projection fields plus the small `effectiveTypeIdentifiersBlob`.
    ///
    /// - Throws: `.invalidInput(.invalidPageLimit)` for an out-of-range limit
    ///   (§16); `.snapshotExpired(current:)` for a cursor that is undecodable,
    ///   generation-mismatched, shape-mismatched, position-mismatched, or whose
    ///   anchor names no retained row (§16); `.temporarilyUnavailable(.factProof)`
    ///   for a framework fetch failure; `.persistence(...)` for decode or
    ///   invariant failures (§16).
    internal func recentPage(
        limit: Int,
        after: HistoryPageCursor?
    ) async throws -> HistoryPage {
        // WS12 seam: the one legal suspension point of this path — no
        // context is live yet (§5).
        await suspendIfRequested(.readEntry)

        let page = try autoreleasepool {
            try recentPageInLocalContext(limit: limit, after: after)
        }
#if DEBUG
        storageLifecycleDebugProbe.record(phase: .recentAutoreleasePoolDrained)
#endif
        return page
    }

    /// The synchronous half of `recentPage`, keeping every fetched model and
    /// its CoreData backing reference inside the caller's autorelease pool.
    internal func recentPageInLocalContext(
        limit: Int,
        after: HistoryPageCursor?,
        context callerContext: ModelContext? = nil
    ) throws -> HistoryPage {
        // §16: validate the page-row limit before any context.
        guard limits.pageRowLimitRange.contains(limit) else {
            throw HistoryFailure.invalidInput(.invalidPageLimit)
        }

        // §6 step 1–2: decode the cursor (format version + process marker)
        // and verify the query shape matches. The position check (§6 step 3)
        // runs below inside the same non-suspending interval. A cursor decode
        // or shape failure reads the current position for the
        // `.snapshotExpired(current:)` mapping (§16).
        let recentRequest = HistoryBrowseRequest(kind: .recent, limit: limit)
        let resolvedCursor: ResolvedPageCursor?
        if let cursor = after {
            do {
                resolvedCursor = try Self.decodeCursor(
                    cursor,
                    request: recentRequest,
                    processMarker: processMarker
                )
            } catch is PageCursorRejection {
                // §16: undecodable, marker-mismatched, or shape-mismatched
                // cursor → `.snapshotExpired(current:)`.
                let pos = try readPositionInLocalContext()
                throw HistoryFailure.snapshotExpired(current: pos)
            }
        } else {
            resolvedCursor = nil
        }

        let context = callerContext ?? ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending read interval (§5): no `await` past this
        //    line while the context or fetched rows are live. ──

        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §6 step 3: current durable ChangePosition must equal the cursor
        // position; any intervening commit expires the cursor (§16).
        if let cursor = resolvedCursor {
            guard cursor.position == currentPosition else {
                throw HistoryFailure.snapshotExpired(current: currentPosition)
            }
        }

        // §14.1: scalar-only two-lane fetch. `propertiesToFetch` requests only
        // projection fields, and this path never accesses or decodes Canonical
        // or revision blobs. Whether SwiftData also suppresses external-storage
        // faulting is the separate supported-platform §7.5 performance proof.
        let scalarProperties = Self.scalarProjectionProperties(
            includingSearchBody: false
        )
#if DEBUG
        let recentFetchClock = ContinuousClock()
        let recentFetchStart = recentFetchClock.now
        storageLifecycleDebugProbe.record(phase: .recentFetchBegin)
#endif

        // Continuation anchors are lane-scoped (04 §6): a pinned anchor
        // offsets the pinned lane; an unpinned anchor empties the pinned lane
        // (every pinned row precedes it in the merge) and bounds the unpinned
        // lane at the store level. Pinned continuations use FetchDescriptor's
        // sorted-result offset; unpinned continuations use the persisted
        // UUID text sort key and carry one extra inclusive anchor slot. Both
        // lanes verify the complete anchor before dropping it (WS18).
        let laneAnchor: (ordinal: Int?, lastCopiedAt: Date, id: HistoryItemID)?
        if let anchor = resolvedCursor?.anchor {
            guard case .defaultOrder(let ordinal, let date, let id) = anchor else {
                // A fuzzy anchor cannot name a recent-browse row — the query
                // shape check above already rejected a search cursor, so this
                // is a defensive invariant, not data.
                throw HistoryFailure.persistence(.invariantViolation)
            }
            laneAnchor = (ordinal, date, id)
        } else {
            laneAnchor = nil
        }
        let unpinnedAnchorActive = laneAnchor.map { $0.ordinal == nil } ?? false

        // Pinned lane: pinOrdinal != nil, sorted by pinOrdinal ascending.
        // Skipped for an unpinned anchor (every pinned row precedes it in the
        // merge order).
        var pinnedOrdered: [ScalarReadRow] = []
        if !unpinnedAnchorActive {
            var pinnedDescriptor = FetchDescriptor<HistoryItemRow>(
                predicate: #Predicate { $0.pinOrdinal != nil }
            )
            pinnedDescriptor.propertiesToFetch = scalarProperties
            pinnedDescriptor.sortBy = [SortDescriptor(\.pinOrdinal)]
            // Ordinals are unique and contiguous (D12). A continuation starts
            // its sorted subrange AT ordinal k so the complete `(ordinal,
            // lastCopiedAt,id)` anchor can be verified before it is dropped;
            // accepting the offset without that check would turn a malformed
            // package cursor into a silent skip. `fetchOffset` still avoids
            // the former O(k+limit) prefix fetch.
            let pinnedContinuationActive = laneAnchor?.ordinal != nil
            if let ordinal = laneAnchor?.ordinal {
                guard ordinal >= 0, ordinal < limits.hardMaximumRetainedItems else {
                    throw HistoryFailure.snapshotExpired(current: currentPosition)
                }
                pinnedDescriptor.fetchOffset = ordinal
            }
            pinnedDescriptor.fetchLimit = limit + (pinnedContinuationActive ? 2 : 1)
            let pinnedRows: [HistoryItemRow]
#if DEBUG
            let pinnedFetchStart = recentFetchClock.now
            storageLifecycleDebugProbe.record(phase: .recentPinnedFetchBegin)
#endif
            do {
                pinnedRows = try context.fetch(pinnedDescriptor)
            } catch {
                throw HistoryFailure.temporarilyUnavailable(.factProof)
            }
#if DEBUG
            storageLifecycleDebugProbe.record(
                phase: .recentPinnedFetchComplete,
                elapsed: pinnedFetchStart.duration(to: recentFetchClock.now),
                rows: pinnedRows.count
            )
#endif
            let lane = try pinnedRows.map { try ScalarReadRow($0, limits: limits) }
            if let laneAnchor {
                let anchorValue = StoredOrderingAnchor.defaultOrder(
                    pinnedOrdinal: laneAnchor.ordinal,
                    lastCopiedAt: laneAnchor.lastCopiedAt,
                    id: laneAnchor.id
                )
                guard lane.first?.matches(anchorValue) == true else {
                    throw HistoryFailure.snapshotExpired(current: currentPosition)
                }
                pinnedOrdered = Array(lane.dropFirst())
            } else {
                pinnedOrdered = lane
            }
        }

        // Unpinned lane: (lastCopiedAt DESC, UUID bytes ASC). The current
        // `idOrder` field gives SwiftData a lexical UUID key, so a date tie
        // never requires expanding a page into the entire date group. The
        // inclusive keyset predicate returns the anchor first, followed by
        // at most page + lookahead rows (05 §14.1).
        // Fetch only the unpinned capacity left after the pinned lane. When
        // pinned already supplies page+lookahead, no unpinned row is touched;
        // otherwise the two lane slices total at most pageLimit+1. An unpinned
        // continuation has no pinned slice and fetches pageLimit+2 because its
        // inclusive keyset predicate also returns the anchor.
        let unpinnedPageLimit = unpinnedAnchorActive
            ? limit
            : max(0, limit - pinnedOrdered.count)
        var unpinnedOrdered: [ScalarReadRow] = []
        let shouldFetchUnpinned = unpinnedAnchorActive || pinnedOrdered.count <= limit
        if shouldFetchUnpinned {
            var unpinnedDescriptor: FetchDescriptor<HistoryItemRow>
            if unpinnedAnchorActive, let laneAnchor {
                let anchorDate = laneAnchor.lastCopiedAt
                let anchorIDOrder = laneAnchor.id.rawValue.uuidString
                unpinnedDescriptor = FetchDescriptor<HistoryItemRow>(
                    predicate: #Predicate {
                        $0.pinOrdinal == nil
                            && ($0.lastCopiedAt < anchorDate
                                || ($0.lastCopiedAt == anchorDate && $0.idOrder >= anchorIDOrder))
                    }
                )
            } else {
                unpinnedDescriptor = FetchDescriptor<HistoryItemRow>(
                    predicate: #Predicate { $0.pinOrdinal == nil }
                )
            }
            unpinnedDescriptor.propertiesToFetch = scalarProperties
            unpinnedDescriptor.sortBy = [
                SortDescriptor(\.lastCopiedAt, order: .reverse),
                SortDescriptor(\.idOrder, comparator: .lexical),
            ]
            unpinnedDescriptor.fetchLimit = unpinnedAnchorActive
                ? unpinnedPageLimit + 2
                : unpinnedPageLimit + 1
            let unpinnedRows: [HistoryItemRow]
#if DEBUG
            let unpinnedFetchStart = recentFetchClock.now
            storageLifecycleDebugProbe.record(phase: .recentUnpinnedFetchBegin)
#endif
            do {
                unpinnedRows = try context.fetch(unpinnedDescriptor)
            } catch {
                throw HistoryFailure.temporarilyUnavailable(.factProof)
            }
#if DEBUG
            storageLifecycleDebugProbe.record(
                phase: .recentUnpinnedFetchComplete,
                elapsed: unpinnedFetchStart.duration(to: recentFetchClock.now),
                rows: unpinnedRows.count
            )
            let unpinnedOrderStart = recentFetchClock.now
            storageLifecycleDebugProbe.record(phase: .recentUnpinnedOrderBegin)
#endif
            unpinnedOrdered = try unpinnedRows.map { try ScalarReadRow($0, limits: limits) }
#if DEBUG
            storageLifecycleDebugProbe.record(
                phase: .recentUnpinnedOrderComplete,
                elapsed: unpinnedOrderStart.duration(to: recentFetchClock.now),
                rows: unpinnedOrdered.count
            )
#endif
        }
#if DEBUG
        storageLifecycleDebugProbe.record(
            phase: .recentFetchComplete,
            elapsed: recentFetchStart.duration(to: recentFetchClock.now),
            rows: pinnedOrdered.count + unpinnedOrdered.count
        )
#endif

        // §6: the inclusive keyset query must start at the complete anchor.
        // A missing/mismatched anchor expires the cursor instead of silently
        // skipping ahead within the frozen snapshot.
        if unpinnedAnchorActive, let laneAnchor {
            let anchorValue = StoredOrderingAnchor.defaultOrder(
                pinnedOrdinal: nil,
                lastCopiedAt: laneAnchor.lastCopiedAt,
                id: laneAnchor.id
            )
            guard unpinnedOrdered.first?.matches(anchorValue) == true else {
                throw HistoryFailure.snapshotExpired(current: currentPosition)
            }
            unpinnedOrdered = Array(unpinnedOrdered.dropFirst())
        }

        // Merge lanes: pinned first, then unpinned (03b §8). The continuation
        // drops were applied per lane above (04 §6).
        let merged = pinnedOrdered + unpinnedOrdered

        let pageSlice = merged.prefix(limit)
        let rows: [HistoryRow] = try pageSlice.map { scalarRow in
            try scalarRow.toHistoryRow(limits: limits)
        }

        // Mint the next cursor when more rows remain, binding the LAST
        // RETURNED row's `.defaultOrder` anchor (§6).
        let next: HistoryPageCursor?
        if merged.count > limit, let lastReturned = pageSlice.last {
            do {
                next = try PageCursorCodec.encode(
                    ResolvedPageCursor(
                        queryShape: .recent(limit: limit),
                        position: currentPosition,
                        anchor: lastReturned.defaultOrderAnchor
                    ),
                    processMarker: processMarker
                )
            } catch {
                // Minting uses already validated row scalars. Encoder failure
                // is therefore an internal invariant, never caller cursor
                // expiry (05 §16).
                throw HistoryFailure.persistence(.invariantViolation)
            }
        } else {
            next = nil
        }

        return HistoryPage(position: currentPosition, rows: rows, next: next)
    }

    /// Search corpus capture (docs/05-authority-kernel.md §14.2): captures
    /// the bounded `SearchCorpusSnapshot` (position plus scalar projection
    /// rows) the `SearchWorker` evaluates off-actor, plus the decoded
    /// continuation anchor for a continuation page (`nil` for a first page).
    /// docs/05-authority-kernel.md §14.2; docs/04-coherence.md §6–§7
    ///
    /// Flow: WS12 seam at entry → limit validation → cursor decode+validation
    /// when present → operation-local context → position read → scalar-only
    /// full-corpus fetch bounded by the hard retained-item maximum → default-
    /// order sort → `SearchCorpusSnapshot` + decoded anchor.
    ///
    /// No Canonical/revision blob is decoded (§14.2); only scalar projection
    /// fields plus the small `effectiveTypeIdentifiersBlob`.
    ///
    /// - Throws: `.invalidInput(.invalidPageLimit)` for an out-of-range limit
    ///   (§16); `.snapshotExpired(current:)` for a cursor that is undecodable,
    ///   generation-mismatched, shape-mismatched, or position-mismatched (§16);
    ///   `.temporarilyUnavailable(.factProof)` for a framework fetch failure;
    ///   `.persistence(...)` for decode or invariant failures (§16).
}
