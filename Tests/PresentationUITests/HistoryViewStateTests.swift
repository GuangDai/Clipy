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
        #expect(state.isLoadingFirstPage)
        #expect(!state.hasAuthoritativeFirstPage)

        #expect(await pollUntil { state.rows.count == 4 })
        #expect(state.rows.map(\.title) == firstPage.rows.map(\.title))
        #expect(state.pinnedRows.map(\.title) == ["pinned-alpha", "pinned-beta"])
        #expect(state.unpinnedRows.map(\.title) == ["recent-gamma", "recent-delta"])
        #expect(state.hasNextPage)
        #expect(!state.isLoadingPage)
        #expect(!state.isLoadingFirstPage)
        #expect(state.hasAuthoritativeFirstPage)
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

    /// AppDelegate and SwiftUI may both announce the same panel-open episode.
    /// Activation is idempotent while one observe loop is already owned;
    /// only a real deactivate/reactivate transition starts another stream.
    @Test func repeatedActivateKeepsOneObservationUntilDeactivated() async {
        let history = ScriptedHistory()
        let state = HistoryViewState(history: history)

        state.activate()
        #expect(await pollUntil { await history.observeRequests.count == 1 })
        #expect(state.isLoadingFirstPage)

        state.activate()
        await Task.yield()
        #expect(await history.observeRequests.count == 1)

        state.deactivate()
        #expect(!state.isLoadingFirstPage)
        state.activate()
        #expect(await pollUntil { await history.observeRequests.count == 2 })

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
        #expect(state.failureEpisode == 1)

        // The retry browses from the OBSERVED cursor again and re-appends.
        state.loadNextPage()
        #expect(await pollUntil { state.rows.count == 4 })
        #expect(state.failure == nil)
        #expect(state.failureEpisode == 1)
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

    /// Pagination belongs to the active browsing lifecycle. Deactivation
    /// clears its loading state immediately, and a non-cooperative completion
    /// released afterwards cannot append rows or restore its cursor.
    @Test func deactivateInvalidatesNonCooperativePagination() async {
        let cursor = fixtureCursor("parked-on-close")
        let firstPage = fixturePage(
            rows: [fixtureRow(
                id: "00000000-0000-0000-0000-000000000045",
                title: "visible"
            )],
            next: "parked-on-close"
        )
        let stalePage = fixturePage(
            rows: [fixtureRow(
                id: "00000000-0000-0000-0000-000000000046",
                title: "must-not-append"
            )],
            next: "stale-next"
        )
        let history = ScriptedHistory(
            observedFirstPage: firstPage,
            browseScript: [cursor: .paused(stalePage)]
        )
        let state = HistoryViewState(history: history)
        state.activate()
        #expect(await pollUntil { state.rows.map(\.title) == ["visible"] })

        state.loadNextPage()
        #expect(await pollUntil { await history.isBrowsePaused(after: cursor) })
        #expect(state.isLoadingPage)

        state.deactivate()
        #expect(!state.isLoadingPage)

        await history.resumeBrowse(after: cursor)
        #expect(
            await pollUntil {
                let completed = await history.completedPausedBrowseCursors
                return completed.contains(cursor)
            }
        )
        await Task.yield()
        #expect(state.rows.map(\.title) == ["visible"])
        #expect(state.hasNextPage)
        #expect(!state.isLoadingPage)

        await history.finishObservation()
    }

    /// A raw query edit invalidates the old cursor generation immediately;
    /// debounce delays only the replacement observe request, never ownership
    /// of an already-running page.
    @Test func queryEditImmediatelyInvalidatesNonCooperativePagination() async {
        let cursor = fixtureCursor("parked-before-query-edit")
        let firstPage = fixturePage(
            rows: [fixtureRow(
                id: "00000000-0000-0000-0000-00000000004A",
                title: "old-query-row"
            )],
            next: "parked-before-query-edit"
        )
        let stalePage = fixturePage(
            rows: [fixtureRow(
                id: "00000000-0000-0000-0000-00000000004B",
                title: "stale-page"
            )],
            next: nil
        )
        let history = ScriptedHistory(
            observedFirstPage: firstPage,
            browseScript: [cursor: .paused(stalePage)]
        )
        let state = HistoryViewState(history: history)
        state.activate()
        #expect(await pollUntil { state.rows.map(\.title) == ["old-query-row"] })

        state.loadNextPage()
        #expect(await pollUntil { await history.isBrowsePaused(after: cursor) })
        #expect(state.isLoadingPage)

        state.searchText = "new query"
        #expect(!state.isLoadingPage)

        await history.resumeBrowse(after: cursor)
        #expect(
            await pollUntil {
                let completed = await history.completedPausedBrowseCursors
                return completed.contains(cursor)
            }
        )
        await Task.yield()
        #expect(!state.rows.map(\.title).contains("stale-page"))

        state.deactivate()
        await history.finishObservation()
    }

    /// A superseded non-cooperative page cannot mutate the replacement
    /// query's rows and cannot clear the spinner owned by its newer page.
    @Test func stalePaginationCannotAppendOrClearNewerRequestSpinner() async {
        let fuzzyCursor = fixtureCursor("fuzzy-page")
        let exactCursor = fixtureCursor("exact-page")
        let fuzzyFirst = fixturePage(
            rows: [fixtureRow(
                id: "00000000-0000-0000-0000-000000000047",
                title: "fuzzy-first"
            )],
            next: "fuzzy-page"
        )
        let exactFirst = fixturePage(
            rows: [fixtureRow(
                id: "00000000-0000-0000-0000-000000000048",
                title: "exact-first"
            )],
            next: "exact-page"
        )
        let staleFuzzyPage = fixturePage(
            rows: [fixtureRow(
                id: "00000000-0000-0000-0000-000000000049",
                title: "stale-fuzzy"
            )],
            next: nil
        )
        let exactSecond = fixturePage(
            rows: [fixtureRow(
                id: "00000000-0000-0000-0000-000000000050",
                title: "exact-second"
            )],
            next: nil
        )
        let history = ScriptedHistory(
            observedFirstPage: fuzzyFirst,
            browseScript: [
                fuzzyCursor: .paused(staleFuzzyPage),
                exactCursor: .paused(exactSecond),
            ]
        )
        let state = HistoryViewState(history: history)
        state.activate()
        #expect(await pollUntil { state.rows.map(\.title) == ["fuzzy-first"] })

        state.loadNextPage()
        #expect(await pollUntil { await history.isBrowsePaused(after: fuzzyCursor) })

        state.searchMode = .exact
        #expect(!state.isLoadingPage)
        #expect(await pollUntil { await history.observeRequests.count == 2 })
        await history.emitObservedPage(exactFirst)
        #expect(await pollUntil { state.rows.map(\.title) == ["exact-first"] })
        state.loadNextPage()
        #expect(await pollUntil { await history.isBrowsePaused(after: exactCursor) })
        #expect(state.isLoadingPage)

        await history.resumeBrowse(after: fuzzyCursor)
        #expect(
            await pollUntil {
                let completed = await history.completedPausedBrowseCursors
                return completed.contains(fuzzyCursor)
            }
        )
        await Task.yield()
        #expect(state.rows.map(\.title) == ["exact-first"])
        #expect(state.isLoadingPage)

        await history.resumeBrowse(after: exactCursor)
        #expect(
            await pollUntil {
                state.rows.map(\.title) == ["exact-first", "exact-second"]
                    && !state.isLoadingPage
            }
        )

        state.deactivate()
        await history.finishObservation()
    }

    // MARK: - Search restarts (V2-07 §4 feel)

    /// A query intent invalidates executable results synchronously. The
    /// replacement observation may take arbitrarily long to produce its first
    /// authoritative page; while it is pending, old rows/cursors cannot be
    /// rendered or copied. The emitted replacement page settles that narrow
    /// first-page loading phase.
    @Test func queryEditImmediatelyHidesOldRowsUntilReplacementPage() async {
        let oldRow = fixtureRow(
            id: "00000000-0000-0000-0000-00000000004C",
            title: "old-query-row"
        )
        let newRow = fixtureRow(
            id: "00000000-0000-0000-0000-00000000004D",
            title: "new-query-row"
        )
        let history = ScriptedHistory(
            observedFirstPage: fixturePage(rows: [oldRow], next: "old-next"),
            repeatsObservedFirstPage: false
        )
        let state = HistoryViewState(history: history)
        let recorder = PasteCallRecorder()
        state.onPaste = { item in
            Task { await recorder.record(item) }
        }
        state.activate()
        #expect(await pollUntil { state.rows == [oldRow] })
        #expect(!state.isLoadingFirstPage)

        state.searchText = "replacement"

        #expect(state.rows.isEmpty)
        #expect(state.isLoadingFirstPage)
        #expect(!state.hasNextPage)
        state.requestPasteFromDisplayedRow(oldRow.item)
        let receivedAfterOldRequest = await recorder.received
        #expect(receivedAfterOldRequest.isEmpty)

        #expect(await pollUntil { await history.observeRequests.count == 2 })
        await history.emitObservedPage(fixturePage(rows: [newRow], next: nil))

        #expect(
            await pollUntil {
                state.rows == [newRow] && !state.isLoadingFirstPage
            }
        )
        state.requestPasteFromDisplayedRow(newRow.item)
        #expect(await pollUntil { await recorder.received == [newRow.item] })

        state.deactivate()
        await history.finishObservation()
    }

    /// `HistoryItemReference` equality, not item ID alone, is the list's
    /// submission fence. An old row closure for v1 cannot submit after the
    /// authoritative display has replaced that same item with v2; the exact
    /// displayed v2 reference remains executable. This admission fence does
    /// not pin the later History read to v2 (`DEC-PASTE-REFERENCE`, 04 §8).
    @Test func displayedRowPasteAdmissionRequiresTheExactContentVersion() async {
        let currentRow = fixtureRow(
            id: "00000000-0000-0000-0000-00000000004E",
            title: "current-version",
            contentVersion: 2
        )
        let staleReference = HistoryItemReference(
            id: currentRow.item.id,
            contentVersion: ContentVersion(rawValue: 1)
        )
        let history = ScriptedHistory(
            observedFirstPage: fixturePage(rows: [currentRow], next: nil)
        )
        let state = HistoryViewState(history: history)
        let recorder = SynchronousPasteCallRecorder()
        state.onPaste = { item in
            recorder.record(item)
        }
        state.activate()
        #expect(await pollUntil { state.rows == [currentRow] })

        state.requestPasteFromDisplayedRow(staleReference)
        #expect(recorder.received.isEmpty)

        state.requestPasteFromDisplayedRow(currentRow.item)
        #expect(recorder.received == [currentRow.item])

        state.deactivate()
        await history.finishObservation()
    }

    /// A malformed regexp is an authoritative typed outcome, not an empty
    /// history snapshot. It ends first-page loading and remains available to
    /// the panel's failure banner while the raw search intent stays active.
    @Test func invalidRegexpFailureSettlesFirstPageLoading() async {
        let history = ScriptedHistory()
        let state = HistoryViewState(history: history)

        state.searchText = "("
        state.searchMode = .regexp
        #expect(state.rows.isEmpty)
        #expect(state.isLoadingFirstPage)
        #expect(state.isSearchActive)
        #expect(
            await pollUntil {
                let requests = await history.observeRequests
                return requests.last?.kind == .search(text: "(", mode: .regexp)
            }
        )

        await history.failObservation(
            .invalidInput(.invalidRegularExpression)
        )

        #expect(
            await pollUntil {
                !state.isLoadingFirstPage
                    && state.failure
                        == .invalidInput(.invalidRegularExpression)
            }
        )
        #expect(state.rows.isEmpty)
        #expect(state.isSearchActive)
        #expect(state.failureEpisode == 1)
        #expect(state.canRetryFailureByRefreshing)

        state.refresh()
        #expect(state.failure == nil)
        #expect(state.failureEpisode == 1)

        state.deactivate()
    }

    /// Search-field edits debounce into ONE restarted observation carrying
    /// the final text in the current mode; the rapid intermediate edit is
    /// folded away.
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

        state.deactivate()
        await history.finishObservation()
    }

    /// SwiftUI controls may write their current binding value again while
    /// mounting or taking focus. An equal draft/mode is not a new search
    /// intent and must not cancel the live observation or arm a debounce.
    @Test func equalSearchBindingWritesKeepTheCurrentObservation() async {
        let firstPage = fixturePage(
            rows: [
                fixtureRow(
                    id: "00000000-0000-0000-0000-000000000054",
                    title: "unchanged-search"
                ),
            ],
            next: nil
        )
        let history = ScriptedHistory(observedFirstPage: firstPage)
        let state = HistoryViewState(history: history)
        state.activate()
        #expect(await pollUntil { state.hasAuthoritativeFirstPage })

        state.searchText = state.searchText
        state.searchMode = state.searchMode

        #expect(state.rows.map(\.title) == ["unchanged-search"])
        #expect(state.hasAuthoritativeFirstPage)
        #expect(!state.isLoadingFirstPage)
        #expect(await history.observeRequests.count == 1)

        state.deactivate()
        await history.finishObservation()
    }

    /// UI-16/Card 15D: the draft itself is not a result. Only the final
    /// debounced query's authoritative first page announces, exactly once.
    /// The page's cursor is carried with the count so the app shell can say
    /// "N+ results" instead of fabricating an exact total. A later identical
    /// observation snapshot, same-query refresh, and a one-shot continuation
    /// page stay silent.
    @Test func settledSearchFirstPageAnnouncesOnceButSnapshotsAndPaginationDoNot() async {
        let cursor = fixtureCursor("search-announcement-next")
        let firstPage = fixturePage(
            rows: [
                fixtureRow(
                    id: "00000000-0000-0000-0000-000000000052",
                    title: "settled-one"
                ),
                fixtureRow(
                    id: "00000000-0000-0000-0000-000000000053",
                    title: "settled-two"
                ),
            ],
            next: "search-announcement-next"
        )
        let continuationPage = fixturePage(
            rows: [fixtureRow(
                id: "00000000-0000-0000-0000-000000000054",
                title: "continued"
            )],
            next: nil
        )
        let history = ScriptedHistory(
            browseScript: [cursor: .page(continuationPage)]
        )
        let state = HistoryViewState(history: history)
        var announcements: [(count: Int, hasNextPage: Bool)] = []
        state.onSettledSearchResultCount = { count, hasNextPage in
            announcements.append((count, hasNextPage))
        }

        state.activate()
        #expect(await pollUntil { await history.observeRequests.count == 1 })
        await history.emitObservedPage(fixturePage(rows: [], next: nil))
        #expect(await pollUntil { state.hasAuthoritativeFirstPage })
        #expect(announcements.isEmpty)

        state.searchText = "cl"
        state.searchText = "clipy"
        #expect(announcements.isEmpty)
        #expect(
            await pollUntil {
                let requests = await history.observeRequests
                return requests.count == 2
                    && requests.last?.kind
                        == .search(text: "clipy", mode: .fuzzy)
            }
        )

        await history.emitObservedPage(firstPage)
        #expect(await pollUntil { announcements.count == 1 })
        #expect(announcements[0].count == 2)
        #expect(announcements[0].hasNextPage)

        await history.emitObservedPage(firstPage)
        await Task.yield()
        #expect(announcements.count == 1)

        state.refresh()
        #expect(await pollUntil { await history.observeRequests.count == 3 })
        await history.emitObservedPage(firstPage)
        #expect(await pollUntil { state.rows == firstPage.rows })
        #expect(announcements.count == 1)

        state.loadNextPage()
        #expect(await pollUntil { state.rows.count == 3 })
        #expect(announcements.count == 1)

        state.deactivate()
        await history.finishObservation()
    }

    /// Replacing a query cancels its exact observation stream before the new
    /// debounce settles. A page then offered to that historical stream cannot
    /// announce or replace rows; the current query's empty authoritative page
    /// announces one real zero-result outcome.
    @Test func supersededSearchObservationCannotAnnounceForCurrentQueryGeneration() async {
        let history = ScriptedHistory()
        let state = HistoryViewState(history: history)
        var announcements: [(count: Int, hasNextPage: Bool)] = []
        state.onSettledSearchResultCount = { count, hasNextPage in
            announcements.append((count, hasNextPage))
        }
        state.activate()
        #expect(await pollUntil { await history.observeRequests.count == 1 })

        state.searchText = "superseded"
        #expect(await pollUntil { await history.observeRequests.count == 2 })
        state.searchText = "current"
        #expect(state.isLoadingFirstPage)

        let stalePage = fixturePage(
            rows: [fixtureRow(
                id: "00000000-0000-0000-0000-000000000055",
                title: "must-not-announce"
            )],
            next: nil
        )
        await history.emitObservedPage(stalePage, observationIndex: 1)
        await Task.yield()
        #expect(announcements.isEmpty)
        #expect(state.rows.isEmpty)

        #expect(
            await pollUntil {
                let requests = await history.observeRequests
                return requests.count == 3
                    && requests.last?.kind
                        == .search(text: "current", mode: .fuzzy)
            }
        )
        await history.emitObservedPage(fixturePage(rows: [], next: nil))

        #expect(await pollUntil { announcements.count == 1 })
        #expect(announcements[0].count == 0)
        #expect(!announcements[0].hasNextPage)
        #expect(state.rows.isEmpty)
        #expect(state.hasAuthoritativeFirstPage)

        state.deactivate()
        await history.finishObservation()
    }

    /// Exact and regexp are syntax-bearing modes: leading, trailing, and
    /// whitespace-only drafts cross the History seam byte-for-byte. Only an
    /// actually empty draft becomes `.recent`.
    @Test(arguments: [SearchMode.exact, .regexp])
    func syntaxBearingQueriesPreserveRawWhitespace(mode: SearchMode) async {
        let history = ScriptedHistory()
        let state = HistoryViewState(history: history)

        state.searchText = "  needle  "
        state.searchMode = mode
        #expect(
            await pollUntil {
                let requests = await history.observeRequests
                return requests.last?.kind
                    == .search(text: "  needle  ", mode: mode)
            }
        )
        #expect(state.searchText == "  needle  ")
        #expect(state.isSearchActive)

        state.searchText = "   "
        #expect(
            await pollUntil {
                let requests = await history.observeRequests
                return requests.last?.kind == .search(text: "   ", mode: mode)
            }
        )
        #expect(state.isSearchActive)

        state.searchText = ""
        #expect(
            await pollUntil {
                let requests = await history.observeRequests
                return requests.last?.kind == .recent
            }
        )
        #expect(!state.isSearchActive)

        state.deactivate()
        await history.finishObservation()
    }

    /// Switching a long exact draft to fuzzy admits one bounded query intent
    /// without first publishing an invalid fuzzy request. The raw draft stays
    /// untouched so switching back to a syntax-bearing mode is lossless.
    @Test func longExactToFuzzyIsOneAtomicAdmittedIntent() async {
        let history = ScriptedHistory()
        let state = HistoryViewState(history: history)
        let rawDraft = String(repeating: "x", count: 65)
        let admittedDraft = String(repeating: "x", count: 64)

        state.searchText = rawDraft
        state.searchMode = .exact
        #expect(
            await pollUntil {
                let requests = await history.observeRequests
                return requests.last?.kind == .search(text: rawDraft, mode: .exact)
            }
        )
        let requestCountBeforeSwitch = await history.observeRequests.count

        state.searchMode = .fuzzy
        #expect(
            await pollUntil {
                await history.observeRequests.count == requestCountBeforeSwitch + 1
            }
        )

        let allRequests = await history.observeRequests
        let switchedRequests = allRequests.dropFirst(requestCountBeforeSwitch)
        #expect(switchedRequests.count == 1)
        #expect(
            switchedRequests.first?.kind
                == .search(text: admittedDraft, mode: .fuzzy)
        )
        #expect(state.searchText == rawDraft)

        state.deactivate()
        await history.finishObservation()
    }

    /// The visible Clear control uses this immediate intent instead of
    /// waiting through the ordinary typing debounce.
    @Test func clearSearchImmediatelyStartsOneRecentObservation() async {
        let history = ScriptedHistory()
        let state = HistoryViewState(history: history)
        state.activate()
        #expect(await pollUntil { await history.observeRequests.count == 1 })

        state.searchText = "needle"
        #expect(
            await pollUntil {
                let requests = await history.observeRequests
                return requests.last?.kind
                    == .search(text: "needle", mode: .fuzzy)
            }
        )
        let countBeforeClear = await history.observeRequests.count

        state.clearSearch()
        #expect(state.searchText.isEmpty)
        #expect(!state.isSearchActive)
        #expect(
            await pollUntil {
                let requests = await history.observeRequests
                return requests.count == countBeforeClear + 1
                    && requests.last?.kind == .recent
            }
        )

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
    /// `HistoryAction`s to `perform` and leave `failure` clear. Observation
    /// owns ordinary row refresh; effective destructive receipts additionally
    /// retire executable rows during the delivery gap.
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

    /// Card 9B's purge signal is receipt-driven: merely issuing Clear cannot
    /// erase surface state, and neither `.unchanged` nor a typed failure is a
    /// destructive commit. A literal committed Clear is the first point at
    /// which the surface owner receives a whole-surface purge generation.
    @Test func clearPublishesWholeSurfacePurgeOnlyAfterCommittedReceipt() async throws {
        let page = fixturePage(
            rows: [
                fixtureRow(
                    id: "00000000-0000-0000-0000-000000009B10",
                    title: "must-retire"
                ),
            ],
            next: "pre-clear-cursor"
        )
        let history = PausableMutationHistory(observedFirstPage: page)
        let state = HistoryViewState(history: history)
        state.activate()
        try #require(await pollUntil { state.rows == page.rows })
        #expect(state.hasNextPage)

        let unchangedClear = Task {
            try await state.clearAwaitingReceipt(.all)
        }
        try #require(await pollUntil { await history.requestCount == 1 })
        #expect(state.surfacePurge == nil)
        await history.complete(with: .success(.unchanged))
        _ = try await unchangedClear.value
        #expect(state.surfacePurge == nil)
        #expect(state.rows == page.rows)
        #expect(state.hasNextPage)

        let failedClear = Task {
            try await state.clearAwaitingReceipt(.all)
        }
        try #require(await pollUntil { await history.requestCount == 2 })
        await history.complete(
            with: .failure(.temporarilyUnavailable(.dedupIndexRebuild))
        )
        do {
            _ = try await failedClear.value
            Issue.record("typed Clear failure unexpectedly returned a receipt")
        } catch let failure as HistoryFailure {
            #expect(failure == .temporarilyUnavailable(.dedupIndexRebuild))
        }
        #expect(state.failure == .temporarilyUnavailable(.dedupIndexRebuild))
        #expect(state.surfacePurge == nil)
        #expect(state.rows == page.rows)
        #expect(state.hasNextPage)

        let committedClear = Task {
            try await state.clearAwaitingReceipt(.all)
        }
        try #require(await pollUntil { await history.requestCount == 3 })
        await history.complete(
            with: .success(
                .committed(
                    HistoryCommit(
                        position: ChangePosition(rawValue: 17),
                        outcome: .cleared(count: 4)
                    )
                )
            )
        )
        _ = try await committedClear.value
        #expect(state.surfacePurge?.generation == 1)
        #expect(state.surfacePurge?.scope == .all)
        #expect(state.rows.isEmpty)
        #expect(!state.hasNextPage)
        #expect(!state.isLoadingPage)
        #expect(state.failure == nil)

        state.deactivate()
    }

    /// Remove is precise to its item rather than resetting unrelated surface
    /// state. The event is still withheld until the literal remove commit is
    /// returned by the public History boundary.
    @Test func removePublishesItemPurgeAfterCommittedReceipt() async throws {
        let itemID = HistoryItemID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000009B")!
        )
        let removed = fixtureRow(
            id: "00000000-0000-0000-0000-00000000009B",
            title: "removed"
        )
        let survivor = fixtureRow(
            id: "00000000-0000-0000-0000-000000009B11",
            title: "survivor"
        )
        let history = PausableMutationHistory(
            observedFirstPage: fixturePage(
                rows: [removed, survivor],
                next: "pre-remove-cursor"
            )
        )
        let state = HistoryViewState(history: history)
        var committedRemovalAnnouncements = 0
        state.onCommittedUserRemoval = { _ in
            committedRemovalAnnouncements += 1
        }
        state.activate()
        try #require(await pollUntil { state.rows.count == 2 })

        let removal = Task {
            try await state.removeAwaitingReceipt(itemID)
        }
        try #require(await pollUntil { await history.requestCount == 1 })
        #expect(state.surfacePurge == nil)
        await history.complete(
            with: .success(
                .committed(
                    HistoryCommit(
                        position: ChangePosition(rawValue: 18),
                        outcome: .removed(count: 1)
                    )
                )
            )
        )

        _ = try await removal.value
        #expect(state.surfacePurge?.scope == .item(itemID))
        #expect(state.rows == [survivor])
        #expect(!state.hasNextPage)
        #expect(!state.isLoadingPage)
        #expect(committedRemovalAnnouncements == 1)

        state.deactivate()
    }

    @Test func unchangedAndFailedRemoveDoNotOptimisticallyPurge() async throws {
        let itemID = HistoryItemID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000009B12"
            )!
        )
        let retained = fixtureRow(
            id: "00000000-0000-0000-0000-000000009B12",
            title: "retained-until-remove-receipt"
        )
        let page = fixturePage(rows: [retained], next: "retained-next")
        let history = ScriptedHistory(
            observedFirstPage: page,
            performReceipt: .unchanged
        )
        let state = HistoryViewState(history: history)
        var committedRemovalAnnouncements = 0
        state.onCommittedUserRemoval = { _ in
            committedRemovalAnnouncements += 1
        }
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows == page.rows })

        _ = try await state.removeAwaitingReceipt(itemID)
        #expect(committedRemovalAnnouncements == 0)
        #expect(state.surfacePurge == nil)
        #expect(state.rows == page.rows)
        #expect(state.hasNextPage)

        await history.setPerformFailure(.temporarilyUnavailable(.factProof))
        await #expect(throws: HistoryFailure.self) {
            _ = try await state.removeAwaitingReceipt(itemID)
        }
        #expect(committedRemovalAnnouncements == 0)
        #expect(state.surfacePurge == nil)
        #expect(state.rows == page.rows)
        #expect(state.hasNextPage)
    }

    /// Held pin metadata may trail a committed Unpin. Clear Unpinned therefore
    /// empties every executable row at receipt time and restarts observation;
    /// only its post-receipt page restores the true survivors.
    @Test func clearUnpinnedReceiptEmptiesRowsUntilRestartedObservation() async throws {
        let formerlyPinned = fixtureRow(
            id: "00000000-0000-0000-0000-000000009B14",
            title: "committed-unpin-not-observed",
            pinned: 0
        )
        let pinnedSurvivor = fixtureRow(
            id: "00000000-0000-0000-0000-000000009B15",
            title: "pinned-survivor",
            pinned: 1
        )
        let newUnpinned = fixtureRow(
            id: "00000000-0000-0000-0000-000000009B16",
            title: "post-request-capture"
        )
        let history = PausableMutationHistory(
            observedFirstPage: fixturePage(
                rows: [formerlyPinned, pinnedSurvivor],
                next: "pre-clear-unpinned"
            )
        )
        let state = HistoryViewState(history: history)
        let pasteRecorder = PasteCallRecorder()
        state.onPaste = { item in
            Task { await pasteRecorder.record(item) }
        }
        state.activate()
        try #require(
            await pollUntil { state.rows == [formerlyPinned, pinnedSurvivor] }
        )

        // The write is committed, but no observation carrying the new
        // unpinned metadata has arrived. The held row still looks pinned.
        let unpin = Task {
            try await state.unpinAwaitingReceipt(formerlyPinned.item.id)
        }
        try #require(await pollUntil { await history.requestCount == 1 })
        await history.complete(
            with: .success(
                .committed(
                    HistoryCommit(
                        position: ChangePosition(rawValue: 19),
                        outcome: .unpinned(formerlyPinned.item.id)
                    )
                )
            )
        )
        _ = try await unpin.value
        #expect(state.rows == [formerlyPinned, pinnedSurvivor])

        let clear = Task { try await state.clearAwaitingReceipt(.unpinned) }
        try #require(await pollUntil { await history.requestCount == 2 })

        // Even an observation delivered before the receipt is retired at the
        // receipt boundary; its pin classification cannot authorize copying.
        await history.emitObservedPage(
            fixturePage(
                rows: [pinnedSurvivor, newUnpinned],
                next: "survivor-continuation"
            )
        )
        try #require(
            await pollUntil { state.rows == [pinnedSurvivor, newUnpinned] }
        )

        await history.complete(
            with: .success(
                .committed(
                    HistoryCommit(
                        position: ChangePosition(rawValue: 20),
                        outcome: .cleared(count: 1)
                    )
                )
            )
        )
        _ = try await clear.value

        #expect(state.surfacePurge?.scope == .unpinned)
        #expect(state.rows.isEmpty)
        #expect(!state.hasNextPage)
        #expect(!state.isLoadingPage)
        #expect(state.isLoadingFirstPage)
        try #require(
            await pollUntil { await history.observationRequestCount == 2 }
        )

        state.requestPasteFromDisplayedRow(pinnedSurvivor.item)
        state.requestPasteFromDisplayedRow(newUnpinned.item)
        await Task.yield()
        #expect(await pasteRecorder.received.isEmpty)

        await history.emitObservedPage(
            fixturePage(rows: [pinnedSurvivor, newUnpinned], next: nil)
        )
        try #require(
            await pollUntil {
                state.rows == [pinnedSurvivor, newUnpinned]
                    && !state.isLoadingFirstPage
            }
        )

        state.deactivate()
    }

    /// Revise already exposes an awaiting call. Its old exact reference is
    /// the eviction target; the newly committed reference must remain
    /// eligible for observation, preview, and thumbnail loading.
    @Test func revisePublishesExactTransitionOnlyAfterCommittedReceipt() async throws {
        let itemID = HistoryItemID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000009C")!
        )
        let oldReference = HistoryItemReference(
            id: itemID,
            contentVersion: ContentVersion(rawValue: 1)
        )
        let newReference = HistoryItemReference(
            id: itemID,
            contentVersion: ContentVersion(rawValue: 2)
        )
        let oldRow = fixtureRow(
            id: "00000000-0000-0000-0000-00000000009C",
            title: "old-version"
        )
        let survivor = fixtureRow(
            id: "00000000-0000-0000-0000-000000009B12",
            title: "survivor"
        )
        let history = PausableMutationHistory(
            observedFirstPage: fixturePage(
                rows: [oldRow, survivor],
                next: "pre-revise-cursor"
            )
        )
        let state = HistoryViewState(history: history)
        state.activate()
        try #require(await pollUntil { state.rows.count == 2 })
        let request = RevisionRequest(
            itemID: itemID,
            expected: oldReference.contentVersion,
            intent: .replace(
                RevisionDraft(
                    decisions: [
                        RevisionDecision(
                            typeIdentifier: "public.utf8-plain-text",
                            action: .replace(bytes: Data("new".utf8))
                        )
                    ]
                )
            )
        )

        let revision = Task { try await state.revise(request) }
        try #require(await pollUntil { await history.requestCount == 1 })
        #expect(state.surfacePurge == nil)
        await history.complete(
            with: .success(
                .committed(
                    HistoryCommit(
                        position: ChangePosition(rawValue: 19),
                        outcome: .revised(newReference)
                    )
                )
            )
        )

        _ = try await revision.value
        #expect(state.surfacePurge?.generation == 1)
        #expect(
            state.surfacePurge?.scope == .revision(
                old: oldReference,
                new: newReference
            )
        )
        #expect(state.rows == [survivor])
        #expect(!state.hasNextPage)
        #expect(!state.isLoadingPage)

        state.deactivate()
    }

    /// The embedded editor's receipt continuation must retarget its Details
    /// owner before the matching revision purge becomes observable. This is
    /// the sole ordering difference from ordinary `revise`; the same receipt
    /// and exact purge are still published afterward.
    @Test func editorReceivesCommittedReferenceBeforeRevisionPurge() async throws {
        let itemID = HistoryItemID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000009B13"
            )!
        )
        let old = HistoryItemReference(
            id: itemID,
            contentVersion: ContentVersion(rawValue: 1)
        )
        let current = HistoryItemReference(
            id: itemID,
            contentVersion: ContentVersion(rawValue: 2)
        )
        let history = ScriptedHistory(
            performReceipt: .committed(
                HistoryCommit(
                    position: ChangePosition(rawValue: 20),
                    outcome: .revised(current)
                )
            )
        )
        let state = HistoryViewState(history: history)
        let request = RevisionRequest(
            itemID: itemID,
            expected: old.contentVersion,
            intent: .replace(
                RevisionDraft(decisions: [
                    RevisionDecision(
                        typeIdentifier: "public.utf8-plain-text",
                        action: .replace(bytes: Data("v2".utf8))
                    )
                ])
            )
        )
        var callbackReference: HistoryItemReference?
        var callbackSawPublishedPurge = true

        _ = try await state.reviseFromEditor(request) { reference in
            callbackReference = reference
            callbackSawPublishedPurge = state.surfacePurge != nil
        }

        #expect(callbackReference == current)
        #expect(!callbackSawPublishedPurge)
        #expect(
            state.surfacePurge?.scope == .revision(old: old, new: current)
        )
    }

    /// A retention expansion may delete rows or prune revision bytes while
    /// its caller-visible outcome remains the primary Revise/Policy result.
    /// The receipt's authoritative effect bit therefore widens the existing
    /// exact purge to `.all`; presentation never guesses victims from held
    /// rows or from outcome counters.
    @Test func destructiveRetentionEffectsPublishWholeSurfacePurge() async throws {
        let oldRow = fixtureRow(
            id: "00000000-0000-0000-0000-000000009C10",
            title: "possibly-retired"
        )
        let history = PausableMutationHistory(
            observedFirstPage: fixturePage(
                rows: [oldRow],
                next: "pre-retention-cursor"
            )
        )
        let state = HistoryViewState(history: history)
        state.activate()
        try #require(await pollUntil { state.rows == [oldRow] })

        let policies = Task {
            try await state.applyRetentionPolicies(
                HistoryRetentionPolicies(
                    age: nil,
                    storage: nil,
                    revisions: RevisionRetention(
                        maxRevisionsPerItem: 1,
                        maxRevisionBytesPerItem: nil
                    )
                )
            )
        }
        try #require(await pollUntil { await history.requestCount == 1 })
        await history.complete(
            with: .success(.committed(HistoryCommit(
                position: ChangePosition(rawValue: 20),
                outcome: .retentionPoliciesSet(
                    retiredItems: 0,
                    prunedRevisions: 1
                ),
                hasDestructiveRetentionEffects: true
            )))
        )
        _ = try await policies.value

        #expect(state.surfacePurge?.generation == 1)
        #expect(state.surfacePurge?.scope == .all)
        #expect(state.rows.isEmpty)
        #expect(!state.hasNextPage)

        state.deactivate()
    }

    /// If observation has already delivered a newer authoritative snapshot,
    /// the older receipt must still purge derived caches but must not erase
    /// rows containing a concurrent edit that observation already included.
    @Test func destructiveReceiptPreservesNewerObservedRows() async throws {
        let oldRow = fixtureRow(
            id: "00000000-0000-0000-0000-000000009C30",
            title: "old"
        )
        let concurrentRow = fixtureRow(
            id: "00000000-0000-0000-0000-000000009C31",
            title: "concurrent"
        )
        let history = PausableMutationHistory(
            observedFirstPage: fixturePage(rows: [oldRow], next: nil)
        )
        let state = HistoryViewState(history: history)
        state.activate()
        try #require(await pollUntil { state.rows == [oldRow] })

        let policies = Task {
            try await state.applyRetentionPolicies(
                HistoryRetentionPolicies(
                    age: AgeRetention(maxAge: 60),
                    storage: nil,
                    revisions: nil
                )
            )
        }
        try #require(await pollUntil { await history.requestCount == 1 })
        await history.emitObservedPage(HistoryPage(
            position: ChangePosition(rawValue: 31),
            rows: [concurrentRow],
            next: nil
        ))
        try #require(await pollUntil { state.rows == [concurrentRow] })
        await history.complete(
            with: .success(.committed(HistoryCommit(
                position: ChangePosition(rawValue: 30),
                outcome: .retentionPoliciesSet(
                    retiredItems: 1,
                    prunedRevisions: 0
                ),
                hasDestructiveRetentionEffects: true
            )))
        )
        _ = try await policies.value

        #expect(state.surfacePurge?.scope == .all)
        #expect(state.rows == [concurrentRow])

        state.deactivate()
    }

    /// A composed Revise that also prunes/retires cannot use only the exact
    /// old-reference purge: other presentation-derived state may be stale.
    @Test func reviseWithDestructiveRetentionEffectsPublishesWholeSurfacePurge() async throws {
        let itemID = HistoryItemID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000009C20")!
        )
        let oldRow = fixtureRow(
            id: "00000000-0000-0000-0000-000000009C20",
            title: "old-version"
        )
        let survivor = fixtureRow(
            id: "00000000-0000-0000-0000-000000009C21",
            title: "may-be-retired"
        )
        let history = PausableMutationHistory(
            observedFirstPage: fixturePage(rows: [oldRow, survivor], next: nil)
        )
        let state = HistoryViewState(history: history)
        state.activate()
        try #require(await pollUntil { state.rows.count == 2 })
        let request = RevisionRequest(
            itemID: itemID,
            expected: ContentVersion(rawValue: 1),
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(
                    typeIdentifier: "public.utf8-plain-text",
                    action: .replace(bytes: Data("new".utf8))
                ),
            ]))
        )

        let revision = Task { try await state.revise(request) }
        try #require(await pollUntil { await history.requestCount == 1 })
        await history.complete(
            with: .success(.committed(HistoryCommit(
                position: ChangePosition(rawValue: 21),
                outcome: .revised(HistoryItemReference(
                    id: itemID,
                    contentVersion: ContentVersion(rawValue: 2)
                )),
                hasDestructiveRetentionEffects: true
            )))
        )
        _ = try await revision.value

        #expect(state.surfacePurge?.scope == .all)
        #expect(state.rows.isEmpty)

        state.deactivate()
    }

    /// Details-owned pin toggles expose an awaiting receipt seam. The readback
    /// can start only after success; a typed failure is still published by the
    /// shared mutation boundary for the existing inline/banner presentation.
    @Test func awaitingPinAndUnpinCompleteAtTheReceiptBoundary() async throws {
        let history = PausableMutationHistory()
        let state = HistoryViewState(history: history)
        let itemID = HistoryItemID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000009B13")!
        )

        let pin = Task { try await state.pinAwaitingReceipt(itemID) }
        try #require(await pollUntil { await history.requestCount == 1 })
        let pinActions = await history.recordedActions
        #expect(pinActions.count == 1)
        if let action = pinActions.first,
           case .placePinned(let recordedID, at: .first) = action {
            #expect(recordedID == itemID)
        } else {
            Issue.record("awaiting Pin forwarded the wrong action")
        }
        await history.complete(with: .success(.unchanged))
        let pinReceipt = try await pin.value
        if case .unchanged = pinReceipt {
            // Expected: the awaiting seam returns the literal receipt.
        } else {
            Issue.record("awaiting Pin returned the wrong receipt")
        }
        #expect(state.failure == nil)

        let failure = HistoryFailure.temporarilyUnavailable(.dedupIndexRebuild)
        let unpin = Task { try await state.unpinAwaitingReceipt(itemID) }
        try #require(await pollUntil { await history.requestCount == 2 })
        await history.complete(with: .failure(failure))
        do {
            _ = try await unpin.value
            Issue.record("typed Unpin failure unexpectedly returned a receipt")
        } catch let returned as HistoryFailure {
            #expect(returned == failure)
        }
        #expect(state.failure == failure)
    }

    /// Banner dismissal belongs to one failure publication, not to the
    /// equatable failure value. An ordinary observed snapshot cannot erase a
    /// mutation failure; a later successful mutation does, and publishing the
    /// same typed failure again creates a new episode that is visible again
    /// (review Card 8H).
    @Test func repeatedMutationFailurePublishesANewEpisodeAfterRecovery() async {
        let failure = HistoryFailure.temporarilyUnavailable(.dedupIndexRebuild)
        let firstPage = fixturePage(
            rows: [fixtureRow(
                id: "00000000-0000-0000-0000-000000000082",
                title: "before-mutation"
            )],
            next: nil
        )
        let healthyPage = fixturePage(
            rows: [fixtureRow(
                id: "00000000-0000-0000-0000-000000000083",
                title: "healthy-observation"
            )],
            next: nil
        )
        let history = ScriptedHistory(
            observedFirstPage: firstPage,
            performFailure: failure
        )
        let state = HistoryViewState(history: history)
        let target = HistoryItemID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000084")!
        )
        state.activate()
        #expect(await pollUntil { state.rows == firstPage.rows })

        state.unpin(target)
        #expect(
            await pollUntil {
                state.failure == failure && state.failureEpisode == 1
            }
        )
        let dismissedEpisode = state.failureEpisode

        await history.emitObservedPage(healthyPage)
        #expect(await pollUntil { state.rows == healthyPage.rows })
        #expect(state.failure == failure)
        #expect(state.failureEpisode == dismissedEpisode)
        #expect(!state.canRetryFailureByRefreshing)

        await history.setPerformFailure(nil)
        state.unpin(target)
        #expect(await pollUntil { state.failure == nil })
        #expect(state.failureEpisode == dismissedEpisode)

        await history.setPerformFailure(failure)
        state.unpin(target)
        #expect(
            await pollUntil {
                state.failure == failure
                    && state.failureEpisode == dismissedEpisode + 1
            }
        )
        #expect(state.failureEpisode != dismissedEpisode)
        #expect(!state.canRetryFailureByRefreshing)

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

/// One-operation-at-a-time public History boundary used to place the Card 9B
/// assertion exactly before or after the real receipt, without timing sleeps.
private actor PausableMutationHistory: ClipboardHistory {
    enum Completion: Sendable {
        case success(HistoryReceipt)
        case failure(HistoryFailure)
    }

    private var requests: [HistoryAction] = []
    private var continuation: CheckedContinuation<HistoryReceipt, Error>?
    private let observedFirstPage: HistoryPage?
    private var observationContinuation:
        AsyncThrowingStream<HistoryPage, Error>.Continuation?
    private var observationRequests = 0

    init(observedFirstPage: HistoryPage? = nil) {
        self.observedFirstPage = observedFirstPage
    }

    var requestCount: Int { requests.count }
    var recordedActions: [HistoryAction] { requests }
    var observationRequestCount: Int { observationRequests }

    func emitObservedPage(_ page: HistoryPage) {
        observationContinuation?.yield(page)
    }

    func complete(with completion: Completion) {
        guard let continuation else { return }
        self.continuation = nil
        switch completion {
        case .success(let receipt):
            continuation.resume(returning: receipt)
        case .failure(let failure):
            continuation.resume(throwing: failure)
        }
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        requests.append(action)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        HistoryPage(position: ChangePosition(rawValue: 0), rows: [], next: nil)
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        observationRequests += 1
        let (stream, continuation) =
            AsyncThrowingStream<HistoryPage, Error>.makeStream()
        observationContinuation = continuation
        if observationRequests == 1, let observedFirstPage {
            continuation.yield(observedFirstPage)
        }
        return stream
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        throw HistoryFailure.notFound(id)
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        throw HistoryFailure.notFound(id)
    }

    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        nil
    }

    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        .newStoreDefaults
    }
}
