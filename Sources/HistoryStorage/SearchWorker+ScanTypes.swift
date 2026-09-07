/// Scan-budget and deferred-presentation value types shared by the search
/// lanes and the page materializer (docs/03b-instruction-set.md §8;
/// docs/04-coherence.md §6).
/// Split out of SearchWorker.swift (file-size hygiene); same target,
/// unchanged semantics.
import Foundation
import HistoryCore

extension SearchWorker {
    /// A matched row's presentation, materialized only when the row is
    /// actually returned (03b §8 excerpts are O(matched-window) String
    /// work; a query matching thousands of rows must not pay it for the
    /// rows a bounded page drops, and every continuation page would
    /// otherwise rebuild them from scratch):
    /// - `ready` carries the final frozen presentation (title matches and
    ///   any lane whose construction is already O(1));
    /// - `titleRanges` defers the fuzzy title UTF-16 translation to page
    ///   materialization;
    /// - `bodyExcerpt` defers the 03b §8 body excerpt window, recording the
    ///   matched Character ranges (Fuse) or the original UTF-16 range
    ///   (exact/regexp), the lane's scan-prefix bound (`nil`
    ///   windows the full stored body in exact mode), and whether the
    ///   stored body continued past that prefix.
    internal enum DeferredSearchPresentation {
        case ready(SearchPresentation)
        case titleRanges([Range<Int>])
        case bodyExcerpt(
            characterRanges: [Range<Int>],
            maximumCharacters: Int?,
            bodySuffixWasOmitted: Bool,
            utf16Range: UTF16TextRange? = nil
        )
    }

    /// The page-driven scan directive for order-preserving lanes (03b §8;
    /// docs/04-coherence.md §6): after the continuation anchor (when
    /// present), at most `limit + 1` matched rows can still influence the
    /// returned page or its `next`-cursor decision, so the scan may stop
    /// once that many post-anchor survivors exist. Fuzzy still scans every
    /// row, but retains only that many best post-anchor hits.
    internal struct ScanDirective: Sendable {
        let continuationAnchor: StoredOrderingAnchor?
        let maximumSurvivors: Int
        let direction: HistoryPageDirection

        internal init(
            continuationAnchor: StoredOrderingAnchor?,
            maximumSurvivors: Int,
            direction: HistoryPageDirection = .forward
        ) {
            self.continuationAnchor = continuationAnchor
            self.maximumSurvivors = maximumSurvivors
            self.direction = direction
        }
    }

    /// Mutable companion of `ScanDirective`: feed one matched row's anchor
    /// per hit; `recordMatch` returns `false` exactly when the page and
    /// cursor decision are already fully determined and the scan may stop.
    /// The anchor row itself is the survivor boundary, never a survivor.
    internal struct OrderPreservingScanTracker: Sendable {
        private let anchor: StoredOrderingAnchor?
        private let maximumSurvivors: Int
        private let direction: HistoryPageDirection
        private var anchorSeen = false
        private var postAnchorSurvivors = 0
        /// Backward scans retain the nearest predecessors in a fixed ring.
        /// Advancing through many matches never shifts K metadata rows.
        private var oldestPredecessor = 0

        internal init(directive: ScanDirective) {
            self.anchor = directive.continuationAnchor
            self.maximumSurvivors = directive.maximumSurvivors
            self.direction = directive.direction
        }

        /// Keep the anchor for `page`'s exact validation and its successors;
        /// earlier matches cannot contribute to this page's presentation.
        internal mutating func appendIfRetained(
            _ row: EvaluatedRow,
            to rows: inout [EvaluatedRow]
        ) {
            if direction == .backward {
                guard !anchorSeen else { return }
                if row.anchor == anchor {
                    // Restore normal display order once, then retain the
                    // actual matched anchor as the exclusive page boundary.
                    if oldestPredecessor != 0 {
                        rows = Array(rows[oldestPredecessor...]) + rows[..<oldestPredecessor]
                        oldestPredecessor = 0
                    }
                    rows.append(row)
                } else if rows.count < maximumSurvivors {
                    rows.append(row)
                } else {
                    rows[oldestPredecessor] = row
                    oldestPredecessor = (oldestPredecessor + 1) % maximumSurvivors
                }
                return
            }
            if anchor == nil || anchorSeen || row.anchor == anchor {
                rows.append(row)
            }
        }

        internal mutating func recordMatch(
            ofRow rowAnchor: StoredOrderingAnchor
        ) -> Bool {
            if direction == .backward {
                if rowAnchor == anchor { anchorSeen = true }
                return !anchorSeen
            }
            if let anchor, !anchorSeen {
                guard rowAnchor == anchor else { return true }
                anchorSeen = true
                return true
            }
            postAnchorSurvivors += 1
            return postAnchorSurvivors < maximumSurvivors
        }
    }

    /// Cursor links describe adjacent nonempty regions of this same ordered
    /// result set. The input anchor proves a row exists on the opposite side;
    /// the retained lookahead/lookbehind proves the requested side continues.
    internal static func pageWindow(
        in evaluated: [EvaluatedRow], anchor: StoredOrderingAnchor?,
        direction: HistoryPageDirection, limit: Int, position: ChangePosition
    ) throws -> (rows: ArraySlice<EvaluatedRow>, hasPrevious: Bool, hasNext: Bool) {
        let survivors: ArraySlice<EvaluatedRow>
        if let anchor {
            guard let index = evaluated.firstIndex(where: { $0.anchor == anchor }) else {
                throw HistoryFailure.snapshotExpired(current: position)
            }
            survivors = direction == .forward ? evaluated[(index + 1)...] : evaluated[..<index]
        } else {
            survivors = evaluated[...]
        }
        let rows = direction == .forward ? survivors.prefix(limit) : survivors.suffix(limit)
        guard !rows.isEmpty else { return (rows, false, false) }
        return (
            rows,
            direction == .forward ? anchor != nil : survivors.count > limit,
            direction == .backward ? anchor != nil : survivors.count > limit
        )
    }

    internal static func mintSearchCursor(
        at anchor: StoredOrderingAnchor, direction: HistoryPageDirection,
        request: HistoryBrowseRequest, position: ChangePosition, processMarker: UUID
    ) throws -> HistoryPageCursor {
        do {
            return try PageCursorCodec.encode(
                ResolvedPageCursor(queryShape: StoredQueryShape(request: request), position: position,
                                   anchor: anchor, direction: direction),
                processMarker: processMarker
            )
        } catch {
            throw HistoryFailure.persistence(.invariantViolation)
        }
    }
}
