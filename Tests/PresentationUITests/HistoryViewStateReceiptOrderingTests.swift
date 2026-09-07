import Foundation
import HistoryCore
import PresentationUI
import Testing

/// Caller ordering proofs, not storage mutation semantics: the public receipt
/// arrives before an already-produced observation/browse snapshot (04 §5/§6).
@MainActor
struct HistoryViewStateReceiptOrderingTests {
    enum Mutation: CaseIterable, Equatable, Sendable {
        case remove, revision, externalRevision, clearAll, clearUnpinned, retention
    }

    @Test(arguments: Mutation.allCases)
    func oldObservationCannotRestoreReceiptPurgedRows(mutation: Mutation) async throws {
        let old = fixtureRow(
            id: "00000000-0000-0000-0000-00000000B601", title: "retired"
        )
        let survivor = fixtureRow(
            id: "00000000-0000-0000-0000-00000000B602", title: "survivor", pinned: 0
        )
        let current = HistoryItemReference(
            id: old.item.id, contentVersion: ContentVersion(rawValue: 2)
        )
        let outcome: HistoryCommitOutcome
        switch mutation {
        case .remove: outcome = .removed(count: 1)
        case .revision, .externalRevision: outcome = .revised(current)
        case .clearAll, .clearUnpinned: outcome = .cleared(count: 1)
        case .retention:
            outcome = .retentionPoliciesSet(retiredItems: 1, prunedRevisions: 0)
        }
        let commit = HistoryCommit(
            position: ChangePosition(rawValue: 2), outcome: outcome,
            hasDestructiveRetentionEffects: mutation == .retention
        )
        let history = ReceiptOrderedHistory(backing: ScriptedHistory(
            performReceipt: .committed(commit)
        ))
        let state = HistoryViewState(history: history)
        state.activate()
        try #require(await pollUntil { await history.observations.count == 1 })
        let original = await history.observations[0]
        try await deliver(page([old, survivor], position: 1, next: "old"), to: original)
        #expect(state.rows == [old, survivor])

        switch mutation {
        case .remove: _ = try await state.removeAwaitingReceipt(old.item.id)
        case .revision:
            _ = try await state.revise(RevisionRequest(
                itemID: old.item.id, expected: old.item.contentVersion,
                intent: .revert(to: .canonical)
            ))
        case .externalRevision:
            _ = state.acceptCommittedExternalRevision(from: old.item, commit: commit)
        case .clearAll: _ = try await state.clearAwaitingReceipt(.all)
        case .clearUnpinned: _ = try await state.clearAwaitingReceipt(.unpinned)
        case .retention:
            _ = try await state.applyRetentionPolicies(HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 60), storage: nil, revisions: nil
            ))
        }
        let expectedRows = state.rows
        #expect(!expectedRows.contains(old))
        #expect(!state.hasNextPage)
        if mutation == .clearUnpinned {
            try #require(await pollUntil { await history.observations.count == 2 })
        }
        let live = try #require(await history.observations.last)
        let wasLoading = state.isLoadingFirstPage
        try await deliver(page([old, survivor], position: 1, next: "stale"), to: live)
        #expect(state.rows == expectedRows)
        #expect(!state.hasNextPage)
        #expect(state.isLoadingFirstPage == wasLoading)
        var pasted: HistoryItemReference?
        state.onPaste = { pasted = $0 }
        state.requestPasteFromDisplayedRow(old.item)
        #expect(pasted == nil)

        let revised = fixtureRow(
            id: "00000000-0000-0000-0000-00000000B601", title: "revised", contentVersion: 2
        )
        let accepted = mutation == .revision || mutation == .externalRevision
            ? revised : survivor
        // A later snapshot can include a post-clear capture, or the new
        // exact content reference of a revised item, without reviving old.
        try await deliver(page([accepted], position: 3, next: "current"), to: live)
        #expect(state.rows == [accepted])
        #expect(state.hasNextPage)
        #expect(!state.isLoadingFirstPage)
        state.requestPasteFromDisplayedRow(old.item)
        #expect(pasted == nil)
        state.requestPasteFromDisplayedRow(accepted.item)
        #expect(pasted == accepted.item)
        state.deactivate()
        await history.finishObservations()
    }

    @Test func receiptFloorSurvivesCloseAndQueryAndNeverMovesBackwards() async throws {
        let row = fixtureRow(
            id: "00000000-0000-0000-0000-00000000B603", title: "matching", pinned: 0
        )
        let history = ReceiptOrderedHistory(backing: ScriptedHistory())
        let state = HistoryViewState(history: history)
        state.activate()
        try #require(await pollUntil { await history.observations.count == 1 })
        let first = await history.observations[0]
        try await deliver(page([row], position: 1), to: first)
        state.showsPinnedOnly = true
        state.deactivate()

        // A capture receipt can be delivered while the panel is closed. It
        // records durable knowledge but must not reopen an observation.
        state.acceptCaptureReceipt(.committed(HistoryCommit(
            position: ChangePosition(rawValue: 10), outcome: .inserted(row.item)
        )))
        state.acceptCaptureReceipt(.committed(HistoryCommit(
            position: ChangePosition(rawValue: 9), outcome: .coalesced(row.item)
        )))
        #expect(state.rows.isEmpty)
        #expect(await history.observations.count == 1)
        #expect(!state.isLoadingFirstPage)
        state.activate()
        try #require(await pollUntil { await history.observations.count == 2 })
        let reopened = await history.observations[1]
        try await deliver(page([row], position: 9, next: "closed-stale"), to: reopened)
        #expect(state.rows.isEmpty)
        #expect(state.isLoadingFirstPage)
        #expect(!state.hasNextPage)
        try await deliver(page([row], position: 10), to: reopened)
        #expect(state.rows == [row])
        #expect(state.showsPinnedOnly)

        var announcements = 0
        state.onSettledSearchResultCount = { _, _ in announcements += 1 }
        state.searchText = "matching"
        state.refresh()
        try #require(await pollUntil { await history.observations.count == 3 })
        let searched = await history.observations[2]
        try await deliver(page([row], position: 9, next: "query-stale"), to: searched)
        #expect(state.rows.isEmpty)
        #expect(state.isLoadingFirstPage)
        #expect(announcements == 0)
        try await deliver(page([row], position: 10), to: searched)
        #expect(state.displayedRows == [row])
        #expect(announcements == 1)
        #expect(state.searchText == "matching")
        #expect(state.showsPinnedOnly)
        state.deactivate()
        await history.finishObservations()
    }

    @Test func inFlightPageOlderThanNonDestructiveCaptureReceiptCannotAppend() async throws {
        let first = fixtureRow(
            id: "00000000-0000-0000-0000-00000000B604", title: "first"
        )
        let obsolete = fixtureRow(
            id: "00000000-0000-0000-0000-00000000B605", title: "obsolete"
        )
        let fresh = fixtureRow(
            id: "00000000-0000-0000-0000-00000000B606", title: "fresh"
        )
        let oldCursor = fixtureCursor("old-page")
        let newCursor = fixtureCursor("new-page")
        let backing = ScriptedHistory(browseScript: [
            oldCursor: .paused(page([obsolete], position: 1, next: "obsolete-next")),
            newCursor: .page(page([fresh], position: 2))
        ])
        let history = ReceiptOrderedHistory(backing: backing)
        let state = HistoryViewState(history: history)
        state.activate()
        try #require(await pollUntil { await history.observations.count == 1 })
        let live = await history.observations[0]
        try await deliver(page([first], position: 1, next: "old-page"), to: live)
        state.loadNextPage()
        try #require(await pollUntil { await backing.isBrowsePaused(after: oldCursor) })
        // No destructive purge invalidates the task here: the receipt floor
        // itself must prevent the still-owned browse from appending old rows.
        state.acceptCaptureReceipt(.committed(HistoryCommit(
            position: ChangePosition(rawValue: 2), outcome: .inserted(fresh.item)
        )))
        #expect(state.isLoadingPage)
        try await deliver(page([obsolete], position: 1, next: "stale-observe"), to: live)
        #expect(state.isLoadingPage)
        #expect(state.rows == [first])
        await backing.resumeBrowse(after: oldCursor)
        try #require(await pollUntil { !state.isLoadingPage })
        #expect(state.rows == [first])
        #expect(!state.hasNextPage)
        #expect(state.failure == nil)

        try await deliver(page([first], position: 2, next: "new-page"), to: live)
        state.loadNextPage()
        try #require(await pollUntil { state.rows == [first, fresh] })
        #expect(!state.isLoadingPage)
        #expect(!state.hasNextPage)
        state.deactivate()
        await history.finishObservations()
    }

    private func page(
        _ rows: [HistoryRow], position: UInt64, next: String? = nil
    ) -> HistoryPage {
        HistoryPage(
            position: ChangePosition(rawValue: position), rows: rows,
            next: next.map(fixtureCursor)
        )
    }

    /// A new next() call proves the prior page passed through the consumer's
    /// loop body. Assertions of absence do not depend on a settling sleep.
    private func deliver(_ page: HistoryPage, to delivery: ReceiptPageDelivery) async throws {
        try #require(await pollUntil { await delivery.isWaiting })
        let previousCalls = await delivery.nextCalls
        await delivery.release(page)
        try #require(await pollUntil { await delivery.nextCalls > previousCalls })
    }
}

private actor ReceiptPageDelivery {
    private var continuation: CheckedContinuation<HistoryPage?, Never>?
    private(set) var nextCalls = 0
    var isWaiting: Bool { continuation != nil }

    func next() async -> HistoryPage? {
        nextCalls += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ page: HistoryPage?) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: page)
    }
}

/// Only observation delivery is controlled here. Other public requests use
/// the existing view-state script; no alternative storage semantics are added.
private actor ReceiptOrderedHistory: ClipboardHistory {
    let backing: ScriptedHistory
    private(set) var observations: [ReceiptPageDelivery] = []

    init(backing: ScriptedHistory) { self.backing = backing }

    func observe(_ request: HistoryObservationRequest) async -> AsyncThrowingStream<HistoryPage, Error> {
        let delivery = ReceiptPageDelivery()
        observations.append(delivery)
        return AsyncThrowingStream(unfolding: { await delivery.next() })
    }

    func finishObservations() async {
        for delivery in observations { await delivery.release(nil) }
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        try await backing.perform(action)
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        try await backing.browse(request)
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        try await backing.details(for: id)
    }

    func representation(_ request: HistoryRepresentationRequest) async throws -> HistoryRepresentation {
        try await backing.representation(request)
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        try await backing.pastePayload(for: id)
    }

    func thumbnail(for item: HistoryItemReference, pixels: PixelSize) async throws -> ThumbnailPayload? {
        try await backing.thumbnail(for: item, pixels: pixels)
    }

    func usage() async throws -> HistoryUsage { try await backing.usage() }

    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        try await backing.retentionConfiguration()
    }
}
