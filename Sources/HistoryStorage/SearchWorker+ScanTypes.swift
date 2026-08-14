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
    ///   matched Character ranges, the lane's scan-prefix bound (`nil`
    ///   windows the full stored body in exact mode), and whether the
    ///   stored body continued past that prefix.
    internal enum DeferredSearchPresentation {
        case ready(SearchPresentation)
        case titleRanges([Range<Int>])
        case bodyExcerpt(
            characterRanges: [Range<Int>],
            maximumCharacters: Int?,
            bodySuffixWasOmitted: Bool
        )
    }

    /// The page-driven scan directive for order-preserving lanes (03b §8;
    /// docs/04-coherence.md §6): after the continuation anchor (when
    /// present), at most `limit + 1` matched rows can still influence the
    /// returned page or its `next`-cursor decision, so the scan may stop
    /// once that many post-anchor survivors exist. The fuzzy lane never
    /// uses it — its score ordering needs every corpus row.
    internal struct ScanDirective: Sendable {
        let continuationAnchor: StoredOrderingAnchor?
        let maximumSurvivors: Int
    }

    /// Mutable companion of `ScanDirective`: feed one matched row's anchor
    /// per hit; `recordMatch` returns `false` exactly when the page and
    /// cursor decision are already fully determined and the scan may stop.
    /// The anchor row itself is the survivor boundary, never a survivor.
    internal struct OrderPreservingScanTracker: Sendable {
        private let anchor: StoredOrderingAnchor?
        private let maximumSurvivors: Int
        private var anchorSeen = false
        private var postAnchorSurvivors = 0

        internal init(directive: ScanDirective) {
            self.anchor = directive.continuationAnchor
            self.maximumSurvivors = directive.maximumSurvivors
        }

        internal mutating func recordMatch(
            ofRow rowAnchor: StoredOrderingAnchor
        ) -> Bool {
            if let anchor, !anchorSeen {
                guard rowAnchor == anchor else { return true }
                anchorSeen = true
                return true
            }
            postAnchorSurvivors += 1
            return postAnchorSurvivors < maximumSurvivors
        }
    }
}
