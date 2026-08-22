/// Scalar read-row helpers, lane ordering (§14.1), and rejection mappings.
/// Split out of HistoryAuthority.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData


// MARK: - Scalar read row helper (docs/05-authority-kernel.md §14.1)

/// The authoritative unpinned lane key: newest copy first, then the smallest
/// business ID. It is shared by the exactness fallback's bounded selector and
/// its continuation-anchor partition.
internal struct UnpinnedOrderKey: Comparable {
    let lastCopiedAt: Date
    let id: HistoryItemID

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.lastCopiedAt != rhs.lastCopiedAt {
            return lhs.lastCopiedAt > rhs.lastCopiedAt
        }
        return lhs.id < rhs.id
    }
}

/// One scalar projection row extracted from a fetched `HistoryItemRow`, with
/// the decoded scalar fields `recentPage` needs to assemble a `HistoryRow` and
/// mint the continuation anchor. No `@Model` instance escapes the read
/// interval (§5).
internal struct ScalarReadRow {
    internal let id: HistoryItemID
    internal let contentVersion: ContentVersion
    internal let title: String
    internal let effectiveTypeIdentifiersBlob: Data
    internal let lastCopiedAt: Date
    internal let copyCount: UInt64
    internal let lastSource: String?
    internal let pinOrdinal: PinOrdinal?

    var unpinnedOrderKey: UnpinnedOrderKey {
        UnpinnedOrderKey(lastCopiedAt: lastCopiedAt, id: id)
    }

    internal init(_ row: HistoryItemRow, limits: HistoryLimits) throws {
        self.id = HistoryItemID(rawValue: row.id)
        let projectionSchemaVersion = row.projectionSchemaVersion
        let title = row.title
        let lastCopiedAt = row.lastCopiedAt
        let copyCount = row.copyCount
        let lastSource = row.lastSource
        try mapCodecFailure {
            try ContentProjector.validateStoredSchemaVersion(
                projectionSchemaVersion
            )
            try ContentProjector.validateStoredTitle(title, limits: limits)
            try RevisionStateBlobCodec.validateFiniteLastCopiedAt(lastCopiedAt)
            try RevisionStateBlobCodec.validateCopyCount(copyCount)
            try RevisionStateBlobCodec.validateSourceObservation(
                lastSource,
                limits: limits
            )
        }
        self.contentVersion = try mapCodecFailure {
            try RevisionStateBlobCodec.decodeContentVersion(row.contentVersionRaw)
        }
        self.title = title
        self.effectiveTypeIdentifiersBlob = row.effectiveTypeIdentifiersBlob
        self.lastCopiedAt = lastCopiedAt
        self.copyCount = copyCount
        self.lastSource = lastSource
        self.pinOrdinal = try mapCodecFailure {
            try RevisionStateBlobCodec.decodePinOrdinal(row.pinOrdinal)
        }
    }

    /// The `.defaultOrder` anchor for this row (04 §6).
    internal var defaultOrderAnchor: StoredOrderingAnchor {
        .defaultOrder(
            pinnedOrdinal: pinOrdinal?.rawValue,
            lastCopiedAt: lastCopiedAt,
            id: id
        )
    }

    /// Whether this row matches the given continuation anchor (04 §6).
    internal func matches(_ anchor: StoredOrderingAnchor) -> Bool {
        switch anchor {
        case .defaultOrder(let pinnedOrdinal, let anchoredLastCopiedAt, let anchoredID):
            return id == anchoredID
                && lastCopiedAt == anchoredLastCopiedAt
                && pinOrdinal?.rawValue == pinnedOrdinal
        case .fuzzyUnpinned:
            // The recent-browse path only produces `.defaultOrder` anchors;
            // a fuzzy anchor never matches here.
            return false
        }
    }

    /// Maps this scalar row to a `HistoryRow`, decoding the small
    /// `effectiveTypeIdentifiersBlob` projection (§14.1: the effective type
    /// identifiers blob decode is a small scalar blob, not a content blob).
    internal func toHistoryRow(limits: HistoryLimits) throws -> HistoryRow {
        let typeIdentifiers = try mapCodecFailure {
            try EffectiveTypeIdentifiersBlobCodec.decode(
                effectiveTypeIdentifiersBlob,
                limits: limits
            )
        }
        return HistoryRow(
            item: HistoryItemReference(id: id, contentVersion: contentVersion),
            title: title,
            typeIdentifiers: typeIdentifiers,
            lastCopiedAt: lastCopiedAt,
            copyCount: copyCount,
            lastSource: lastSource,
            pinnedPosition: pinOrdinal?.rawValue,
            search: nil
        )
    }
}

/// Retains only the first `capacity` rows under the authoritative unpinned
/// order. The heap root is the worst retained row, allowing a better row to
/// replace it in `O(log L)` time while scratch remains `O(L)`.
internal struct BoundedBestUnpinnedRows {
    internal let capacity: Int
    internal var heap: [ScalarReadRow]

    init(capacity: Int) {
        self.capacity = capacity
        heap = []
        heap.reserveCapacity(capacity)
    }

    mutating func offer(_ row: ScalarReadRow) {
        guard capacity > 0 else { return }
        if heap.count < capacity {
            heap.append(row)
            siftUp(from: heap.count - 1)
        } else if row.unpinnedOrderKey < heap[0].unpinnedOrderKey {
            heap[0] = row
            siftDown(from: 0)
        }
    }

    var ordered: [ScalarReadRow] {
        heap.sorted { $0.unpinnedOrderKey < $1.unpinnedOrderKey }
    }

    internal mutating func siftUp(from startIndex: Int) {
        var childIndex = startIndex
        while childIndex > 0 {
            let parentIndex = (childIndex - 1) / 2
            guard heap[parentIndex].unpinnedOrderKey
                < heap[childIndex].unpinnedOrderKey else {
                return
            }
            heap.swapAt(parentIndex, childIndex)
            childIndex = parentIndex
        }
    }

    internal mutating func siftDown(from startIndex: Int) {
        var parentIndex = startIndex
        while true {
            let leftIndex = parentIndex * 2 + 1
            guard leftIndex < heap.count else { return }

            let rightIndex = leftIndex + 1
            var worseChildIndex = leftIndex
            if rightIndex < heap.count,
               heap[leftIndex].unpinnedOrderKey
                < heap[rightIndex].unpinnedOrderKey {
                worseChildIndex = rightIndex
            }
            guard heap[parentIndex].unpinnedOrderKey
                < heap[worseChildIndex].unpinnedOrderKey else {
                return
            }
            heap.swapAt(parentIndex, worseChildIndex)
            parentIndex = worseChildIndex
        }
    }
}

// MARK: - Lane ordering helpers (docs/05-authority-kernel.md §14.1)

internal extension HistoryAuthority {

    /// Orders the pinned lane by the full key `(pinOrdinal ascending)`.
    ///
    /// The pinned lane sorts by `pinOrdinal`, which is unique and contiguous
    /// (D12, proved at startup §13 step 9), so no tie is possible and the
    /// small slice is ordered directly. A full slice (limit+1 rows) is still
    /// safe: `pinOrdinal` alone is a total order over the pinned set.
    func orderPinnedLane(
        _ rows: [HistoryItemRow]
    ) throws -> [ScalarReadRow] {
        // The FetchDescriptor already sorts by `\.pinOrdinal`. D12 proves
        // every ordinal is unique, so there is no store-level tie to resolve.
        return try rows.map { try ScalarReadRow($0, limits: limits) }
    }

    /// Orders the unpinned lane by the full key `(lastCopiedAt DESC, id ASC)`.
    ///
    /// EXACTNESS GUARD (§14.1): a first page re-fetches when its page/lookahead
    /// boundary ties on `lastCopiedAt`. A continuation also re-fetches when
    /// same-date rows that sort before the anchor contaminate the bounded
    /// fetch head, when the anchor is absent from a full slice, or when its
    /// true post-anchor page/lookahead boundary ties. `\.id` is never trusted
    /// to sort at the store level. `anchorDate` carries the continuation's
    /// store-level `lastCopiedAt <= anchor` bound (04 §6) so the guard's
    /// re-fetch keeps the same lane scope as the initial fetch (`nil` on a
    /// first page).
    func orderUnpinnedLane(
        _ rows: [HistoryItemRow],
        pageLimit: Int,
        continuationAnchor: StoredOrderingAnchor?,
        anchorDate: Date?,
        in context: ModelContext
    ) throws -> [ScalarReadRow] {
        try validateFiniteLastCopiedDates(in: rows)
        let orderedSlice = try rows.sorted(by: unpinnedRowPrecedes).map {
            try ScalarReadRow($0, limits: limits)
        }
        // When pinned rows fill the page exactly, one unpinned row is fetched
        // only as existence lookahead. Its UUID tie order cannot affect the
        // returned page or its pinned anchor, so no exactness fallback is
        // needed for this zero-capacity lane.
        if pageLimit == 0 {
            return orderedSlice
        }
        let fetchDepth = pageLimit + (continuationAnchor == nil ? 1 : 2)
        let sliceIsFull = rows.count == fetchDepth

        let needsFullFetch: Bool
        if !sliceIsFull {
            // Fewer rows than the fetch limit proves the complete bounded lane
            // is already present; anchor validation remains the caller's job.
            needsFullFetch = false
        } else if let continuationAnchor {
            if let anchorIndex = orderedSlice.firstIndex(where: {
                $0.matches(continuationAnchor)
            }) {
                let rowsAfterAnchor = orderedSlice.count - anchorIndex - 1
                let pageBoundaryTies = rowsAfterAnchor > pageLimit
                    && orderedSlice[anchorIndex + pageLimit].lastCopiedAt
                        == orderedSlice[anchorIndex + pageLimit + 1].lastCopiedAt

                // `anchorIndex > 0` means already-consumed same-date siblings
                // occupied fetch slots before the anchor. The bounded slice
                // can no longer prove page+lookahead completeness even when
                // its final two store-level dates differ (V1V-03B-001).
                needsFullFetch = anchorIndex > 0 || pageBoundaryTies
            } else {
                // A full date-bounded slice can omit the anchor when a large
                // same-date group is returned in an unspecified store order.
                // Re-fetch before deciding the snapshot is contradictory.
                needsFullFetch = true
            }
        } else {
            needsFullFetch = orderedSlice[pageLimit - 1].lastCopiedAt
                == orderedSlice[pageLimit].lastCopiedAt
        }

        let source: [HistoryItemRow]
        if needsFullFetch {
            var descriptor: FetchDescriptor<HistoryItemRow>
            if let anchorDate {
                descriptor = FetchDescriptor<HistoryItemRow>(
                    predicate: #Predicate { $0.pinOrdinal == nil && $0.lastCopiedAt <= anchorDate }
                )
            } else {
                descriptor = FetchDescriptor<HistoryItemRow>(
                    predicate: #Predicate { $0.pinOrdinal == nil }
                )
            }
            descriptor.propertiesToFetch = Self.scalarProjectionProperties(
                includingSearchBody: false
            )
            descriptor.fetchLimit = limits.hardMaximumRetainedItems
#if DEBUG
            let fallbackFetchClock = ContinuousClock()
            let fallbackFetchStart = fallbackFetchClock.now
            storageLifecycleDebugProbe.record(
                phase: .recentUnpinnedFallbackFetchBegin
            )
#endif
            do {
                source = try context.fetch(descriptor)
            } catch {
                throw HistoryFailure.temporarilyUnavailable(.factProof)
            }
#if DEBUG
            storageLifecycleDebugProbe.record(
                phase: .recentUnpinnedFallbackFetchComplete,
                elapsed: fallbackFetchStart.duration(to: fallbackFetchClock.now),
                rows: source.count
            )
#endif
            try validateFiniteLastCopiedDates(in: source)
        } else {
            source = rows
        }

        if !needsFullFetch {
            return orderedSlice
        }
        return try boundedExactUnpinnedRows(
            source,
            pageLimit: pageLimit,
            continuationAnchor: continuationAnchor
        )
    }

    /// Exact fallback selection after the date-only store order proved
    /// insufficient. Every fetched model is converted to `ScalarReadRow`
    /// before it can be discarded, preserving fail-closed validation of all
    /// scalar fields. Only the anchor plus page/lookahead rows survive.
    ///
    /// SwiftData still materializes the bounded `N`-row fetch, but Swift-side
    /// work falls from `O(N log N)` sorting plus `O(N)` scalar storage to
    /// `O(N log L)` selection plus `O(L)` scalar storage for page limit `L`.
    func boundedExactUnpinnedRows(
        _ rows: [HistoryItemRow],
        pageLimit: Int,
        continuationAnchor: StoredOrderingAnchor?
    ) throws -> [ScalarReadRow] {
        let anchorKey: UnpinnedOrderKey?
        if let continuationAnchor {
            guard case .defaultOrder(
                let pinnedOrdinal,
                let lastCopiedAt,
                let itemID
            ) = continuationAnchor,
            pinnedOrdinal == nil else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            anchorKey = UnpinnedOrderKey(
                lastCopiedAt: lastCopiedAt,
                id: itemID
            )
        } else {
            anchorKey = nil
        }

        // The caller drops the inclusive continuation anchor. Retain one
        // extra post-anchor row so its existing `merged.count > limit` test
        // can still prove and mint a next cursor.
        var selection = BoundedBestUnpinnedRows(capacity: pageLimit + 1)
        var foundAnchor: ScalarReadRow?
        for model in rows {
            let row = try ScalarReadRow(model, limits: limits)
            guard let anchorKey, let continuationAnchor else {
                selection.offer(row)
                continue
            }

            let rowKey = row.unpinnedOrderKey
            if rowKey == anchorKey {
                guard row.matches(continuationAnchor), case nil = foundAnchor else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                foundAnchor = row
            } else if anchorKey < rowKey {
                // Strictly after the anchor: eligible for page+lookahead.
                selection.offer(row)
            }
            // A row strictly before the anchor was already consumed. It was
            // still fully scalar-validated above before being discarded.
        }

        var ordered = selection.ordered
        if let foundAnchor {
            ordered.insert(foundAnchor, at: 0)
        }
        // If the anchor was absent, leave it absent: the existing caller maps
        // that frozen-snapshot contradiction to `.snapshotExpired`.
        return ordered
    }

    /// Full unpinned order (03b §8): newest copy first, business ID as the
    /// deterministic tie-breaker. Kept as one helper so guard inspection and
    /// the authoritative re-fetch cannot drift.
    func unpinnedRowPrecedes(_ lhs: HistoryItemRow, _ rhs: HistoryItemRow) -> Bool {
        if lhs.lastCopiedAt != rhs.lastCopiedAt {
            return lhs.lastCopiedAt > rhs.lastCopiedAt
        }
        return HistoryItemID(rawValue: lhs.id) < HistoryItemID(rawValue: rhs.id)
    }

    /// Validate ordering scalars before any comparator sees them. NaN would
    /// make the comparator non-strict; infinity is likewise outside the v1
    /// durable Date contract (§4).
    func validateFiniteLastCopiedDates(in rows: [HistoryItemRow]) throws {
        for row in rows {
            let lastCopiedAt = row.lastCopiedAt
            try mapCodecFailure {
                try RevisionStateBlobCodec.validateFiniteLastCopiedAt(
                    lastCopiedAt
                )
            }
        }
    }
}

internal extension DomainRejection {
    /// The exhaustive docs/02-domain.md §6 → Part III mapping the storage
    /// boundary applies to every planner throw.
    var historyFailure: HistoryFailure {
        switch self {
        case .notFound(let itemID):
            return .notFound(itemID)
        case .staleContent(let expected, let current):
            return .staleContent(expected: expected, current: current)
        case .invalidPinnedPlacement(let failure):
            return .invalidPinnedPlacement(failure)
        case .invalidRevisionDraft:
            return .invalidInput(.incoherentRevisionDraft)
        case .corruptLineage:
            return .persistence(.invariantViolation)
        case .capacityExceeded(let kind):
            return .capacityExceeded(kind)
        }
    }
}

internal extension SignatureIndexRejection {
    /// The §13 startup mapping (§2, §16): corrupt durable signature metadata
    /// fails open as `.persistence(.corruptStoredValue)` rather than
    /// enabling writes from an unproved state; an over-bound retained count
    /// is an invariant violation. Delta-prevalidation cases are unreachable
    /// from `build(from:limits:)` and map defensively.
    var startupFailure: HistoryFailure {
        switch self {
        case .retainedCountExceedsBound:
            return .persistence(.invariantViolation)
        case .emptySignatureEntries, .duplicateEntry, .duplicateTypeIdentifier:
            return .persistence(.corruptStoredValue)
        case .additionAlreadyIndexed, .removalNotIndexed, .overlappingAdditionAndRemoval:
            return .persistence(.invariantViolation)
        }
    }
}
