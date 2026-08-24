/// HistoryDetailsPurgeTests — receipt-confirmed invalidation of the details
/// surface's non-cooperative async read (deep review Card 9B).
import Foundation
import HistoryCore
import PresentationUI
import Testing

struct HistoryDetailsPurgeTests {
    private func reference(
        _ rawID: String,
        version: UInt64
    ) -> HistoryItemReference {
        HistoryItemReference(
            id: HistoryItemID(rawValue: UUID(uuidString: rawID)!),
            contentVersion: ContentVersion(rawValue: version)
        )
    }

    /// A parked read carries the token returned by `begin`. Purge advances
    /// ownership before that read returns, so its late full-details payload
    /// cannot be accepted; this retired exact-reference screen starts no new
    /// reads after the purge.
    @Test func purgeGenerationRejectsLateDetailsCompletion() {
        let item = reference(
            "00000000-0000-0000-0000-000000009B01",
            version: 1
        )
        var fence = HistoryDetailsLoadFence()
        let oldRead = fence.begin()
        #expect(oldRead != nil)

        let didPurge = fence.purge(.all, item: item)
        #expect(didPurge)
        if let oldRead {
            #expect(!fence.owns(oldRead))
        }

        let newRead = fence.begin()
        #expect(newRead == nil)
    }

    /// Load begin consults the current owner value directly. This proof does
    /// not require `.onChange` to run: an already-published matching purge
    /// retires the exact details reference before a request token is minted.
    @Test func currentPurgeAtLoadBeginPreventsStartingARead() {
        let item = reference(
            "00000000-0000-0000-0000-000000009B05",
            version: 1
        )
        let current = HistorySurfacePurge(
            generation: 7,
            scope: .item(item.id)
        )
        var fence = HistoryDetailsLoadFence(baselinePurgeGeneration: 6)

        #expect(fence.reconcile(current, item: item) == .item(item.id))
        #expect(fence.begin() == nil)
    }

    /// A retained Clear from before this details surface existed establishes
    /// its construction baseline. A later item can load normally; the old
    /// `.all` value is not replayed as a fresh destructive event.
    @Test func priorClearIsIgnoredByANewDetailsSurfaceBaseline() {
        let laterItem = reference(
            "00000000-0000-0000-0000-000000009B09",
            version: 1
        )
        let priorClear = HistorySurfacePurge(generation: 7, scope: .all)
        var fence = HistoryDetailsLoadFence(baselinePurgeGeneration: 7)

        #expect(fence.reconcile(priorClear, item: laterItem) == nil)
        let token = fence.begin()
        #expect(token != nil)
        if let token {
            #expect(
                fence.accepts(
                    token,
                    returned: laterItem,
                    expected: laterItem,
                    isCancelled: false
                )
            )
        }
    }

    /// No retained purge at construction means a generation-zero baseline.
    /// Seeing generation two first proves an event was skipped and therefore
    /// fails closed even when the latest precise scope is unrelated.
    @Test func nilBaselineToGenerationTwoFailsClosed() {
        let item = reference(
            "00000000-0000-0000-0000-000000009B0A",
            version: 1
        )
        let unrelated = reference(
            "00000000-0000-0000-0000-000000009B0B",
            version: 1
        )
        var fence = HistoryDetailsLoadFence()
        let token = fence.begin()
        #expect(token != nil)

        #expect(
            fence.reconcile(
                HistorySurfacePurge(
                    generation: 2,
                    scope: .item(unrelated.id)
                ),
                item: item
            ) == .all
        )
        if let token {
            #expect(!fence.owns(token))
        }
    }

    /// Clear Unpinned's visible-row membership cannot classify an off-query
    /// details reference. The derived surface therefore retires even when its
    /// ID is absent from the request-time list; a pinned row may reopen it.
    @Test func clearUnpinnedRetiresOffQueryDetailsFailClosed() {
        let offQuery = reference(
            "00000000-0000-0000-0000-000000009B0C",
            version: 1
        )
        let purge = HistorySurfacePurge(
            generation: 1,
            scope: .unpinned
        )
        var fence = HistoryDetailsLoadFence()

        #expect(fence.reconcile(purge, item: offQuery) == purge.scope)
        #expect(fence.begin() == nil)
    }

    /// A parked request is fenced by a purge read directly at completion.
    /// The late payload cannot be accepted even if no child-view change
    /// callback was delivered while the request was suspended.
    @Test func currentPurgeAtParkedReadCompletionRejectsLatePayload() {
        let item = reference(
            "00000000-0000-0000-0000-000000009B06",
            version: 1
        )
        var fence = HistoryDetailsLoadFence()
        #expect(fence.reconcile(nil, item: item) == nil)
        let token = fence.begin()
        #expect(token != nil)
        guard let token else { return }

        let current = HistorySurfacePurge(
            generation: 1,
            scope: .revision(
                old: item,
                new: HistoryItemReference(
                    id: item.id,
                    contentVersion: ContentVersion(rawValue: 2)
                )
            )
        )
        #expect(fence.reconcile(current, item: item) == current.scope)
        #expect(
            !fence.accepts(
                token,
                returned: item,
                expected: item,
                isCancelled: false
            )
        )
    }

    /// If two purge generations replace one another while a read is parked,
    /// the latest scope cannot prove the hidden intermediate scope was
    /// unrelated. A generation gap therefore retires this details surface.
    @Test func missedPurgeGenerationRejectsParkedCompletion() {
        let item = reference(
            "00000000-0000-0000-0000-000000009B07",
            version: 1
        )
        let unrelated = reference(
            "00000000-0000-0000-0000-000000009B08",
            version: 1
        )
        var fence = HistoryDetailsLoadFence(baselinePurgeGeneration: 9)
        #expect(
            fence.reconcile(
                HistorySurfacePurge(
                    generation: 10,
                    scope: .item(unrelated.id)
                ),
                item: item
            ) == nil
        )
        let token = fence.begin()
        #expect(token != nil)
        guard let token else { return }

        #expect(
            fence.reconcile(
                HistorySurfacePurge(
                    generation: 12,
                    scope: .item(unrelated.id)
                ),
                item: item
            ) == .all
        )
        #expect(!fence.owns(token))
    }

    /// Task cancellation and exact-reference mismatch independently reject a
    /// result even while its generation token is otherwise current.
    @Test func acceptanceRequiresLiveTaskAndExactReturnedReference() {
        let expected = reference(
            "00000000-0000-0000-0000-000000009B04",
            version: 1
        )
        let newer = HistoryItemReference(
            id: expected.id,
            contentVersion: ContentVersion(rawValue: 2)
        )
        var fence = HistoryDetailsLoadFence()
        let token = fence.begin()
        #expect(token != nil)
        guard let token else { return }

        #expect(
            fence.accepts(
                token,
                returned: expected,
                expected: expected,
                isCancelled: false
            )
        )
        #expect(
            !fence.accepts(
                token,
                returned: expected,
                expected: expected,
                isCancelled: true
            )
        )
        #expect(
            !fence.accepts(
                token,
                returned: newer,
                expected: expected,
                isCancelled: false
            )
        )
    }

    /// Revision invalidation is reference-exact: an unrelated old reference
    /// does not discard this screen, while this screen's own old reference
    /// does and fences its read.
    @Test func revisionPurgeMatchesOnlyTheOldExactReference() {
        let item = reference(
            "00000000-0000-0000-0000-000000009B02",
            version: 1
        )
        let revised = HistoryItemReference(
            id: item.id,
            contentVersion: ContentVersion(rawValue: 2)
        )
        let unrelated = reference(
            "00000000-0000-0000-0000-000000009B03",
            version: 1
        )
        let unrelatedNew = HistoryItemReference(
            id: unrelated.id,
            contentVersion: ContentVersion(rawValue: 2)
        )
        var fence = HistoryDetailsLoadFence()
        let read = fence.begin()
        #expect(read != nil)

        let didPurgeUnrelated = fence.purge(
            .revision(old: unrelated, new: unrelatedNew),
            item: item
        )
        #expect(!didPurgeUnrelated)
        if let read {
            #expect(fence.owns(read))
        }
        let didPurgeItem = fence.purge(
            .revision(old: item, new: revised),
            item: item
        )
        #expect(didPurgeItem)
        if let read {
            #expect(!fence.owns(read))
        }
    }

    /// An authoritative editor Reload may retarget the existing Details owner
    /// from v1 to v2. The old in-flight token is retired, while a new read can
    /// accept only the newly advanced exact reference.
    @Test func editorReferenceAdvanceInvalidatesOldLoadAndAdmitsLatest() {
        let original = reference(
            "00000000-0000-0000-0000-000000009B0D",
            version: 1
        )
        let latest = HistoryItemReference(
            id: original.id,
            contentVersion: ContentVersion(rawValue: 2)
        )
        var fence = HistoryDetailsLoadFence()
        let oldToken = fence.begin()
        #expect(oldToken != nil)

        let didAdvance = fence.advanceReference(from: original, to: latest)
        #expect(didAdvance)
        if let oldToken {
            #expect(!fence.owns(oldToken))
        }

        let latestToken = fence.begin()
        #expect(latestToken != nil)
        if let latestToken {
            #expect(
                fence.accepts(
                    latestToken,
                    returned: latest,
                    expected: latest,
                    isCancelled: false
                )
            )
            #expect(
                !fence.accepts(
                    latestToken,
                    returned: original,
                    expected: latest,
                    isCancelled: false
                )
            )
        }
    }

    /// Retargeting is narrowly monotonic for the same item and cannot revive
    /// a Details surface already retired by authoritative purge semantics.
    @Test func editorReferenceAdvanceRejectsForeignRegressionAndPurgedOwner() {
        let original = reference(
            "00000000-0000-0000-0000-000000009B0E",
            version: 2
        )
        let foreign = reference(
            "00000000-0000-0000-0000-000000009B0F",
            version: 3
        )
        let older = HistoryItemReference(
            id: original.id,
            contentVersion: ContentVersion(rawValue: 1)
        )
        let newer = HistoryItemReference(
            id: original.id,
            contentVersion: ContentVersion(rawValue: 3)
        )
        var fence = HistoryDetailsLoadFence()

        let acceptedForeign = fence.advanceReference(
            from: original,
            to: foreign
        )
        let acceptedRegression = fence.advanceReference(
            from: original,
            to: older
        )
        let didPurge = fence.purge(.item(original.id), item: original)
        let acceptedAfterPurge = fence.advanceReference(
            from: original,
            to: newer
        )
        let tokenAfterPurge = fence.begin()

        #expect(!acceptedForeign)
        #expect(!acceptedRegression)
        #expect(didPurge)
        #expect(!acceptedAfterPurge)
        #expect(tokenAfterPurge == nil)
    }
}
