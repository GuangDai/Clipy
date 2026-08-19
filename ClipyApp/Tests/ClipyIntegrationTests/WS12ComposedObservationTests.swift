/// WS12Composed — Observation snapshot-replacement through the REAL observe
/// loop (docs/06-cross-cutting.md §8 WS12; docs/04-coherence.md §5):
/// several commits after activation coalesce into fresh REPLACEMENT pages
/// so the view state always converges on the newest position — the composed
/// form of the registration-race gate (its pause-between-registration-and-
/// query interleavings need the storage-side suspension seams and stay in
/// `Tests/HistoryStorageTests/WS12ObservationRaceTests.swift`).
///
/// Also pins the composed debounce behavior (V2-07 §4 feel): a search edit
/// restarts observation ONCE, 250 ms later, into the search query shape.
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

struct WS12ComposedObservationTests {

    /// WS12 (docs/06-cross-cutting.md §8): a burst of later commits (three
    /// inserts) coalesces for the observer — the view state, already
    /// activated, converges on the complete three-row page at the newest
    /// position; each incoming page REPLACES rows (04 §5), never appends,
    /// which the intermediate two-row state observes on its way past.
    @Test @MainActor
    func commitBurstConvergesToReplacementPagesAtLatestPosition() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()

        let base = Date(timeIntervalSinceReferenceDate: 700_201_700)
        var ids: [HistoryItemID] = []
        for index in 0..<3 {
            let receipt = try await history.perform(.capture(
                ComposedSupport.textCapture(
                    "ws12 composed item \(index)",
                    observedAt: base.addingTimeInterval(Double(index) * 100),
                    source: "com.example.ws12composed"
                )
            ))
            ids.append(
                try #require(
                    ComposedSupport.insertedReference(from: receipt, "WS12 burst")
                ).id
            )
        }

        // The final page is the complete three-row snapshot; snapshot
        // replacement means an intermediate page was seen on the way
        // (two rows after the second insert) and then replaced.
        let converged = await ComposedSupport.waitFor {
            viewState.rows.count == 3
                && Set(viewState.rows.map(\.item.id)) == Set(ids)
        }
        #expect(converged, "WS12: the loop yields the latest complete page")
        #expect(viewState.failure == nil)

        // Unpinned lane order is recency-descending (05 §14.1): the newest
        // copy leads. The page is authoritative state, not a delta stream.
        #expect(
            viewState.unpinnedRows.map(\.item.id) == Array(ids.reversed()),
            "WS12 (05 §14.1): the composed page is newest-first"
        )
    }

    /// WS12 composed debounce companion (docs/04-coherence.md §5; V2-07
    /// §4): a search edit re-observes under the new query shape after the
    /// 250 ms debounce — the loop restarts (kind `.search`) and its first
    /// replacement page contains the matching row, then a NEW commit while
    /// still searching reaches the same loop (one query shape, one stream).
    @Test @MainActor
    func searchRestartObservesTheSearchQueryShapeAfterDebounce() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()

        let base = Date(timeIntervalSinceReferenceDate: 700_201_800)
        let receipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "ws12 composed unique needle",
                observedAt: base,
                source: "com.example.ws12composed.search"
            )
        ))
        let needleID = try #require(
            ComposedSupport.insertedReference(from: receipt, "WS12 search arrange")
        ).id
        _ = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "ws12 composed unrelated filler",
                observedAt: base.addingTimeInterval(50),
                source: "com.example.ws12composed.search"
            )
        ))
        #expect(
            await ComposedSupport.waitFor { viewState.rows.count == 2 },
            "WS12: recent kind observed before the edit"
        )

        // One edit, then the debounce window passes; the restarted loop's
        // page contains ONLY the matching row (kind .search, default mode).
        viewState.searchText = "needle"
        #expect(viewState.isSearchActive)
        let searched = await ComposedSupport.waitFor(timeout: 3) {
            viewState.rows.count == 1 && viewState.rows.first?.item.id == needleID
        }
        #expect(
            searched,
            "WS12: the debounced restart observes the search query shape"
        )

        // A commit made WHILE searching reaches the same restarted loop.
        let secondNeedle = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "ws12 composed second needle",
                observedAt: base.addingTimeInterval(100),
                source: "com.example.ws12composed.search"
            )
        ))
        let secondID = try #require(
            ComposedSupport.insertedReference(from: secondNeedle, "WS12 search live")
        ).id
        #expect(
            await ComposedSupport.waitFor {
                viewState.rows.map(\.item.id) == [secondID, needleID]
            },
            "WS12: a later commit while searching replaces the page in-kind"
        )
        #expect(viewState.failure == nil)
    }
}
