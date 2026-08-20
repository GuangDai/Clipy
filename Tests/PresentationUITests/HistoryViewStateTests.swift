/// HistoryViewStateTests — the panel view-state acceptance suite against a
/// scripted `ClipboardHistory` double (docs/01-architecture.md §6; docs/
/// roadmap/05-presentationui.md). These pin the VIEW-STATE semantics, not
/// storage semantics (docs/01-architecture.md §4): observation is snapshot
/// replacement (docs/04-coherence.md §5 — an incoming `HistoryPage` REPLACES
/// rows, never appends), pagination is one-shot `browse` whose
/// `.snapshotExpired` failure falls back to the observed first page and
/// resumes from its cursor (docs/03a-instruction-set.md §7; docs/
/// 04-coherence.md §6), search edits debounce into a restarted observation,
/// and mutating interactions swallow typed failures into `failure`
/// (docs/03b-instruction-set.md §10).
///
/// All waits poll on stable conditions — a state that stays true once true —
/// through `pollUntil`, so the suite stays deterministic apart from the
/// sanctioned short settle sleeps.
import Foundation
import HistoryCore
import PresentationUI
import Testing

@MainActor
struct HistoryViewStateTests {

    // MARK: - Observation lifecycle (04 §5)

    /// `activate()` applies the observed first page and its lanes: rows are
    /// the page's rows (replacement, not append), pinned/unpinned lanes
    /// split by `pinnedPosition`, and the page's `next` cursor drives
    /// `hasNextPage` (docs/04-coherence.md §5; docs/
    /// 03b-instruction-set.md §8).
    @Test func activateAppliesObservedFirstPageAndDerivedState() async {
        let firstPage = fixturePage(
            rows: [
                fixtureRow(
                    id: "00000000-0000-0000-0000-000000000001",
                    title: "pinned-alpha",
                    pinned: 0
                ),
                fixtureRow(
                    id: "00000000-0000-0000-0000-000000000002",
                    title: "pinned-beta",
                    pinned: 1
                ),
                fixtureRow(
                    id: "00000000-0000-0000-0000-000000000003",
                    title: "recent-gamma"
                ),
                fixtureRow(
                    id: "00000000-0000-0000-0000-000000000004",
                    title: "recent-delta"
                ),
            ],
            next: "after-first"
        )
        let history = ScriptedHistory(observedFirstPage: firstPage)
        let state = HistoryViewState(history: history, pageLimit: 25)
        state.activate()

        #expect(await pollUntil { state.rows.count == 4 })
        #expect(state.rows.map(\.title) == firstPage.rows.map(\.title))
        #expect(state.pinnedRows.map(\.title) == ["pinned-alpha", "pinned-beta"])
        #expect(state.unpinnedRows.map(\.title) == ["recent-gamma", "recent-delta"])
        #expect(state.hasNextPage)
        #expect(!state.isLoadingPage)
        #expect(state.failure == nil)
        #expect(state.pageLimit == 25)

        // The observation request carries the current kind and page limit
        // (docs/03a-instruction-set.md §7).
        let requests = await history.observeRequests
        #expect(requests.count == 1)
        #expect(requests.first?.kind == .recent)
        #expect(requests.first?.limit == 25)

        state.deactivate()
        await history.finishObservation()
    }

    /// `deactivate()` stops the loop — a page emitted afterwards is never
    /// applied — and a later `activate()` starts a fresh observation;
    /// `refresh()` re-observes immediately (V2-07 §4 re-browse on user
    /// action).
    @Test func deactivateHaltsLoopAndReactivateObservesAgain() async {
        let firstPage = fixturePage(
            rows: [
                fixtureRow(id: "00000000-0000-0000-0000-000000000011", title: "one"),
                fixtureRow(id: "00000000-0000-0000-0000-000000000012", title: "two"),
            ],
            next: nil
        )
        let history = ScriptedHistory(observedFirstPage: firstPage)
        let state = HistoryViewState(history: history)
        state.activate()
        #expect(await pollUntil { state.rows.count == 2 })

        // Cancelled loop: the emitted page has no live consumer, so it can
        // never be applied. The sleep is a stable-negative settle, not a
        // race window — nothing can apply the page later either.
        state.deactivate()
        await history.emitObservedPage(fixturePage(
            rows: [fixtureRow(id: "00000000-0000-0000-0000-000000000013", title: "post-deactivate")],
            next: nil
        ))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(state.rows.count == 2)

        // Re-activation starts a new observation (04 §5) whose live stream
        // still receives later pages.
        state.activate()
        #expect(await pollUntil { await history.observeRequests.count == 2 })
        await history.emitObservedPage(fixturePage(
            rows: [fixtureRow(id: "00000000-0000-0000-0000-000000000014", title: "replacement")],
            next: nil
        ))
        #expect(
            await pollUntil {
                state.rows.count == 1 && state.rows.first?.title == "replacement"
            }
        )

        // refresh() re-observes without debounce (V2-07 §4) and the fresh
        // stream re-applies the scripted first page.
        state.refresh()
        #expect(await pollUntil { await history.observeRequests.count == 3 })
        #expect(await pollUntil { state.rows.count == 2 })

        state.deactivate()
        await history.finishObservation()
    }

    /// A second observed page REPLACES rows wholesale (04 §5): the new
    /// page's rows replace the old ones — count and identity both change —
    /// instead of appending, and its own `next` cursor re-drives
    /// `hasNextPage`.
    @Test func secondObservedPageReplacesRowsWholesale() async {
        let firstPage = fixturePage(
            rows: [
                fixtureRow(id: "00000000-0000-0000-0000-000000000021", title: "old-one"),
                fixtureRow(id: "00000000-0000-0000-0000-000000000022", title: "old-two"),
                fixtureRow(id: "00000000-0000-0000-0000-000000000023", title: "old-three"),
            ],
            next: "after-first"
        )
        let history = ScriptedHistory(observedFirstPage: firstPage)
        let state = HistoryViewState(history: history)
        state.activate()
        #expect(await pollUntil { state.rows.count == 3 })
        #expect(state.hasNextPage)

        let secondPage = fixturePage(
            rows: [fixtureRow(id: "00000000-0000-0000-0000-000000000024", title: "new-only")],
            next: nil
        )
        await history.emitObservedPage(secondPage)

        #expect(await pollUntil { state.rows.count == 1 })
        // Replacement, not append (an append would show four rows) — 04 §5.
        #expect(state.rows.map(\.title) == ["new-only"])
        #expect(!state.hasNextPage)
        #expect(state.failure == nil)

        state.deactivate()
        await history.finishObservation()
    }

    // MARK: - Pagination (03a §7; 04 §6)

    /// `loadNextPage()` issues one one-shot `browse(after:)` with the page's
    /// cursor and kind, appends the returned rows, and `hasNextPage` flips
    /// false when the appended page's cursor is nil. With no next cursor,
    /// `loadNextPage()` is a no-op.
    @Test func loadNextPageAppendsBrowsePagesUntilCursorIsNil() async {
        let firstPage = fixturePage(
            rows: [
                fixtureRow(id: "00000000-0000-0000-0000-000000000031", title: "alpha-one"),
                fixtureRow(id: "00000000-0000-0000-0000-000000000032", title: "alpha-two"),
            ],
            next: "cursor-one"
        )
        let secondPage = fixturePage(
            rows: [
                fixtureRow(id: "00000000-0000-0000-0000-000000000033", title: "beta-one"),
                fixtureRow(id: "00000000-0000-0000-0000-000000000034", title: "beta-two"),
            ],
            next: nil
        )
        let history = ScriptedHistory(
            observedFirstPage: firstPage,
            browseScript: [fixtureCursor("cursor-one"): .page(secondPage)]
        )
        let state = HistoryViewState(history: history)
        state.activate()
        #expect(await pollUntil { state.rows.count == 2 && state.hasNextPage })

        state.loadNextPage()

        #expect(await pollUntil { state.rows.count == 4 && !state.hasNextPage })
        #expect(
            state.rows.map(\.title)
                == ["alpha-one", "alpha-two", "beta-one", "beta-two"]
        )
        #expect(!state.isLoadingPage)

        let browseRequests = await history.browseRequests
        #expect(browseRequests.count == 1)
        #expect(browseRequests.first?.kind == .recent)
        #expect(browseRequests.first?.limit == 50)
        #expect(browseRequests.first?.after == fixtureCursor("cursor-one"))

        // Cursor exhausted: the guarded call issues no further browse
        // (stable negative — the guard is synchronous).
        state.loadNextPage()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await history.browseRequests.count == 1)

        state.deactivate()
        await history.finishObservation()
    }

    /// A `.snapshotExpired` pagination failure (04 §6) drops the appended
    /// rows back to the observed first page, resumes pagination from the
    /// OBSERVED page's cursor — not the expired one — and surfaces the typed
    /// failure in the banner state.
    @Test func snapshotExpiredDropsAppendedRowsAndResumesFromObservedCursor() async {
        let observedPage = fixturePage(
            rows: [
                fixtureRow(id: "00000000-0000-0000-0000-000000000041", title: "observed-one"),
                fixtureRow(id: "00000000-0000-0000-0000-000000000042", title: "observed-two"),
            ],
            next: "observed-cursor"
        )
        let appendedPage = fixturePage(
            rows: [
                fixtureRow(id: "00000000-0000-0000-0000-000000000043", title: "appended-one"),
                fixtureRow(id: "00000000-0000-0000-0000-000000000044", title: "appended-two"),
            ],
            next: "expired-cursor"
        )
        let history = ScriptedHistory(
            observedFirstPage: observedPage,
            browseScript: [
                fixtureCursor("observed-cursor"): .page(appendedPage),
                fixtureCursor("expired-cursor"): .failure(
                    .snapshotExpired(current: ChangePosition(rawValue: 9))
                ),
            ]
        )
        let state = HistoryViewState(history: history)
        state.activate()
        #expect(await pollUntil { state.rows.count == 2 })

        // First append succeeds; the second page's cursor is stale.
        state.loadNextPage()
        #expect(await pollUntil { state.rows.count == 4 })
        state.loadNextPage()

        // 04 §6 recovery: appended rows dropped, pagination resumes from the
        // observed page's own cursor, failure surfaced.
        #expect(await pollUntil { state.rows.count == 2 && state.hasNextPage })
        #expect(state.rows.map(\.title) == ["observed-one", "observed-two"])
        #expect(state.failure == .snapshotExpired(current: ChangePosition(rawValue: 9)))

        // The retry browses from the OBSERVED cursor again and re-appends.
        state.loadNextPage()
        #expect(await pollUntil { state.rows.count == 4 })
        #expect(
            state.rows.map(\.title)
                == ["observed-one", "observed-two", "appended-one", "appended-two"]
        )
        let cursors = await history.browseRequests.map(\.after)
        #expect(
            cursors
                == [
                    fixtureCursor("observed-cursor"),
                    fixtureCursor("expired-cursor"),
                    fixtureCursor("observed-cursor"),
                ]
        )

        state.deactivate()
        await history.finishObservation()
    }

    // MARK: - Search restarts (V2-07 §4 feel)

    /// Search-field edits debounce into ONE restarted observation carrying
    /// the trimmed text in the current mode; the rapid intermediate edit is
    /// folded away, and whitespace-only text is not a search.
    @Test func searchTextEditsDebounceIntoOneRestartedObservation() async {
        let firstPage = fixturePage(
            rows: [fixtureRow(id: "00000000-0000-0000-0000-000000000051", title: "stable-row")],
            next: nil
        )
        let history = ScriptedHistory(observedFirstPage: firstPage)
        let state = HistoryViewState(history: history)
        state.activate()
        #expect(await pollUntil { await history.observeRequests.count == 1 })

        // Two rapid edits inside one debounce window (250 ms) must fold into
        // a single restart whose query is the FINAL text.
        state.searchText = "cl"
        state.searchText = "clipy"
        #expect(await pollUntil { await history.observeRequests.count >= 2 })

        let requests = await history.observeRequests
        #expect(requests.count == 2)
        #expect(requests.last?.kind == .search(text: "clipy", mode: .fuzzy))
        #expect(state.isSearchActive)

        // Settle past a full debounce window: no third restart materializes.
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await history.observeRequests.count == 2)

        // Whitespace-only text is not a query (docs/03a-instruction-set.md
        // §7 — it never reaches storage as an empty search term).
        state.searchText = "   "
        #expect(!state.isSearchActive)

        state.deactivate()
        await history.finishObservation()
    }

    /// A search-mode change restarts observation immediately in the new mode
    /// (docs/03a-instruction-set.md §7) — the request that lands carries the
    /// exact text with the new mode.
    @Test func searchModeChangeRestartsObservationInNewMode() async {
        let firstPage = fixturePage(
            rows: [fixtureRow(id: "00000000-0000-0000-0000-000000000061", title: "stable-row")],
            next: nil
        )
        let history = ScriptedHistory(observedFirstPage: firstPage)
        let state = HistoryViewState(history: history)
        state.activate()
        #expect(await pollUntil { await history.observeRequests.count == 1 })

        state.searchText = "clipy"
        #expect(await pollUntil { await history.observeRequests.count == 2 })

        state.searchMode = .exact
        #expect(
            await pollUntil {
                let requests = await history.observeRequests
                return requests.last?.kind == .search(text: "clipy", mode: .exact)
            }
        )
        #expect(state.searchMode == .exact)

        state.deactivate()
        await history.finishObservation()
    }

    // MARK: - Interactions (03a §5; 03b §10)

    /// On a healthy history, pin/unpin/remove/clear forward their
    /// `HistoryAction`s to `perform` and leave `failure` clear — row refresh
    /// comes from the observation loop, not from row surgery here.
    @Test func mutatingInteractionsForwardActionsAndKeepFailureClear() async {
        let firstPage = fixturePage(
            rows: [fixtureRow(id: "00000000-0000-0000-0000-000000000071", title: "row")],
            next: nil
        )
        let history = ScriptedHistory(observedFirstPage: firstPage)
        let state = HistoryViewState(history: history)
        state.activate()
        #expect(await pollUntil { state.rows.count == 1 })

        let pinnedTarget = HistoryItemID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000072")!
        )
        let removedTarget = HistoryItemID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000073")!
        )
        state.pin(pinnedTarget)
        state.unpin(pinnedTarget)
        state.remove(removedTarget)
        state.clear(.unpinned)

        #expect(await pollUntil { await history.performActions.count == 4 })
        let actions = await history.performActions
        #expect(
            actions.contains { action in
                if case .placePinned(let id, at: .first) = action {
                    return id == pinnedTarget
                }
                return false
            }
        )
        #expect(
            actions.contains { action in
                if case .unpin(let id) = action { return id == pinnedTarget }
                return false
            }
        )
        #expect(
            actions.contains { action in
                if case .remove(let id) = action { return id == removedTarget }
                return false
            }
        )
        #expect(
            actions.contains { action in
                if case .clear(let scope) = action { return scope == .unpinned }
                return false
            }
        )
        // Stable negative: successes never populate the banner state.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(state.failure == nil)

        state.deactivate()
        await history.finishObservation()
    }

    /// When `perform` throws a typed failure, the mutation methods store it
    /// into `failure` instead of throwing (docs/03b-instruction-set.md §10)
    /// — the action was still forwarded and recorded.
    @Test func mutatingInteractionsStoreTypedFailuresIntoFailure() async {
        let history = ScriptedHistory(
            performFailure: .temporarilyUnavailable(.dedupIndexRebuild)
        )
        let state = HistoryViewState(history: history)

        let target = HistoryItemID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000081")!
        )
        state.unpin(target)

        #expect(
            await pollUntil {
                state.failure == .temporarilyUnavailable(.dedupIndexRebuild)
            }
        )
        let actions = await history.performActions
        #expect(
            actions.contains { action in
                if case .unpin(let id) = action { return id == target }
                return false
            }
        )

        state.deactivate()
        await history.finishObservation()
    }

    /// `requestPaste(_:)` hands the reference to the composition-root
    /// `onPaste` hook (docs/01-architecture.md §5.6) — the view state never
    /// touches NSPasteboard.
    @Test func requestPasteHandsTheReferenceToOnPaste() async {
        let firstPage = fixturePage(
            rows: [fixtureRow(id: "00000000-0000-0000-0000-000000000091", title: "row")],
            next: nil
        )
        let history = ScriptedHistory(observedFirstPage: firstPage)
        let state = HistoryViewState(history: history)
        let recorder = PasteCallRecorder()
        state.onPaste = { item in
            Task { await recorder.record(item) }
        }

        let reference = HistoryItemReference(
            id: HistoryItemID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000092")!
            ),
            contentVersion: ContentVersion(rawValue: 2)
        )
        state.requestPaste(reference)

        #expect(await pollUntil { await recorder.received == [reference] })

        state.deactivate()
        await history.finishObservation()
    }

    // MARK: - Configured-policy read (V2-07 §5.2/§6.3; SPEC-IMPL-003)

    /// `retentionConfiguration()` is a thin passthrough to the public seam —
    /// the settings tabs' panel-open read (docs/v2/V2-07-ux.md §6.3, a
    /// one-shot read per §4.2.2; audit SPEC-IMPL-003): the scripted
    /// configured-policy value comes back unchanged and the read reaches the
    /// seam exactly once. Configured policy only — no live usage value
    /// exists on the surface (V2-07 §2.2 OPEN-2).
    @Test func retentionConfigurationReturnsTheScriptedConfiguredPolicy() async throws {
        let scripted = HistoryRetentionConfiguration(
            maximumUnpinnedItems: 42,
            policies: HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 30 * 86_400),
                storage: StorageRetention(maxTotalBytes: 500 * 1_048_576),
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 20,
                    maxRevisionBytesPerItem: 64 * 1_048_576
                )
            )
        )
        let history = ScriptedHistory(scriptedRetentionConfiguration: scripted)
        let state = HistoryViewState(history: history)

        let configuration = try await state.retentionConfiguration()

        #expect(configuration == scripted)
        #expect(await history.retentionConfigurationRequestCount == 1)
    }
}
