import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct RecentReadMeasurementTests {
    @Test(arguments: HistorySortOrder.allCases)
    func measurementPreservesPublicPagesAcrossPinsTiesFiltersAndAnchors(sortOrder: HistorySortOrder) async throws {
        let history = try await fixture(count: 97, tiedDates: true)
        let initial = try await history.browse(.init(kind: .recent, limit: 100))
        for row in initial.rows.prefix(7) {
            _ = try await history.perform(.placePinned(row.item.id, at: .last))
        }
        let filter = HistoryFilter(type: .text, sourceApplicationIDs: ["com.clipy.evidence.a"])
        for kind in [HistoryBrowseKind.recent, .search(text: "", mode: .exact)] {
            let firstRequest = HistoryBrowseRequest(kind: kind, limit: 11, filter: filter, sortOrder: sortOrder)
            let first = try await compareWithPublicBrowse(firstRequest, in: history)
            let next = try #require(first.next)
            let second = try await compareWithPublicBrowse(.init(
                kind: kind, limit: 11, cursor: next, filter: filter, sortOrder: sortOrder
            ), in: history)
            let previous = try #require(second.previous)
            let backward = try await compareWithPublicBrowse(.init(
                kind: kind, limit: 11, cursor: previous, filter: filter, sortOrder: sortOrder
            ), in: history)
            #expect(backward == first)
            let remembered = try #require(second.rows.last?.item.id)
            _ = try await compareWithPublicBrowse(.init(
                kind: kind, limit: 11, filter: filter, sortOrder: sortOrder, startAround: remembered
            ), in: history)
        }
    }

    @Test func shallowAndDeepPagesRecordTheirOwnNativeWork() async throws {
        let history = try await fixture(count: 1_024, tiedDates: false)
        let first = try await history.browse(.init(kind: .recent, limit: 50))
        let shallowCursor = try #require(first.next)
        let deepID = try await history.authority.withTestDatabase { owner in
            let row = try owner.database.prepare("SELECT id FROM history_items WHERE lastCopiedAt=?",
                                                  bindings: [.real(600_000_200)])
            defer { row.finalize() }
            try #require(try row.step())
            return HistoryItemID(rawValue: try #require(UUID(uuidString: row.text(at: 0))))
        }
        let deepStart = try await history.browse(.init(kind: .recent, limit: 50, startAround: deepID))
        let deepCursor = try #require(deepStart.next)
        for (depth, cursor) in [("shallow", shallowCursor), ("deep", deepCursor)] {
            let request = HistoryBrowseRequest(kind: .recent, limit: 50, cursor: cursor)
            let measured = await history.measureRecentPage(request)
            let page = try measured.result.get()
            #expect(page == (try await history.browse(request)))
            #expect(measured.metrics.rowsDecoded >= page.rows.count)
            #expect(measured.metrics.virtualMachineSteps > 0)
            let work = measured.metrics
            // Native work is evidence to inspect in CI, with no latency gate
            // or fixed statement-step threshold. Page semantics are asserted.
            print("recent-read native-work depth=\(depth) rows=\(page.rows.count) statements=\(work.statementCount) decoded=\(work.rowsDecoded) vmSteps=\(work.virtualMachineSteps) fullScanSteps=\(work.fullScanSteps) sorts=\(work.sortOperations) cacheHits=\(work.cacheHits) cacheMisses=\(work.cacheMisses)")
        }
    }

    @Test func failedProjectionKeepsPartialWorkAndCancellationDoesNotReuseEarlierCounts() async throws {
        let history = try await fixture(count: 12, tiedDates: false)
        let request = HistoryBrowseRequest(kind: .recent, limit: 5)
        let successful = await history.measureRecentPage(request)
        let original = try successful.result.get()
        let item = try #require(original.rows.first?.item.id)
        let types = try await history.authority.withTestDatabase { owner in
            let row = try owner.database.prepare("SELECT effectiveTypeIdentifiersBlob FROM history_items WHERE id=?",
                                                  bindings: [.text(item.rawValue.uuidString)])
            defer { row.finalize() }
            try #require(try row.step())
            let original = try row.blob(at: 0)
            row.finalize()
            try owner.database.execute("UPDATE history_items SET effectiveTypeIdentifiersBlob=X'00' WHERE id=?",
                                       bindings: [.text(item.rawValue.uuidString)])
            return original
        }
        let failed = await history.measureRecentPage(request)
        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) { try failed.result.get() }
        #expect(failed.metrics.rowsDecoded > 0)
        #expect(failed.metrics.virtualMachineSteps > 0)
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) { try await history.browse(request) }
        try await history.authority.withTestDatabase { owner in
            try owner.database.execute("UPDATE history_items SET effectiveTypeIdentifiersBlob=? WHERE id=?",
                                       bindings: [.blob(types), .text(item.rawValue.uuidString)])
        }

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await history.measureRecentPage(request)
        }
        let cancelledResult = await cancelled.value
        #expect(throws: CancellationError.self) { try cancelledResult.result.get() }
        #expect(cancelledResult.metrics.statementCount == 0)
        #expect(cancelledResult.metrics.rowsDecoded == 0)
        #expect(cancelledResult.metrics.virtualMachineSteps == 0)
        let resumed = await history.measureRecentPage(request)
        #expect(try resumed.result.get() == original)
        #expect(resumed.metrics.rowsDecoded == successful.metrics.rowsDecoded)
    }

    #if DEBUG
    @Test func cancellationAfterScalarReadsPreservesNativeWorkAndAllowsTheNextPage() async throws {
        let history = try await fixture(count: 12, tiedDates: false)
        let request = HistoryBrowseRequest(kind: .recent, limit: 5)
        let original = try await history.browse(request)
        await history.authority.setStorageLifecycleDebugProbe(.init(isEnabled: true) { event in
            if event.phase == .recentFetchComplete {
                // The real scalar SELECTs have finished and their native work
                // has been sampled. Cancel before the public page is built.
                withUnsafeCurrentTask { $0?.cancel() }
            }
        })
        let cancelled = Task { await history.measureRecentPage(request) }
        let measured = await cancelled.value
        await history.authority.setStorageLifecycleDebugProbe(.init(isEnabled: false))
        #expect(throws: CancellationError.self) { try measured.result.get() }
        #expect(measured.metrics.rowsDecoded >= original.rows.count)
        #expect(measured.metrics.virtualMachineSteps > 0)
        let next = await history.measureRecentPage(request)
        #expect(try next.result.get() == original)
    }
    #endif

    private func compareWithPublicBrowse(
        _ request: HistoryBrowseRequest, in history: SQLiteHistory
    ) async throws -> HistoryPage {
        let measured = await history.measureRecentPage(request)
        let page = try measured.result.get()
        #expect(page == (try await history.browse(request)))
        #expect(measured.metrics.rowsDecoded >= page.rows.count)
        #expect(measured.metrics.virtualMachineSteps > 0)
        return page
    }

    private func fixture(count: Int, tiedDates: Bool) async throws -> SQLiteHistory {
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .temporary, initialMaximumUnpinnedItems: nil
        ))
        _ = try await history.seedPerformanceFixture(rowCount: count) { index in
            WSSupport.textCapture(
                "native-work-\(index)-" + String(repeating: "x", count: 64),
                observedAt: Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(tiedDates ? index / 4 : index)),
                source: index.isMultiple(of: 2) ? "com.clipy.evidence.a" : "com.clipy.evidence.b"
            )
        }
        return history
    }
}
