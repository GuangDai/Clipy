import Foundation
import HistoryCore
import Testing
@testable import HistoryPerfRunner

extension SQLiteScaleTests {
    @Test func recentTraversalKeepsSamePageWorkAndBoundedSearchEvidence() async throws {
        let count = 120
        let history = try await openMemoryStore()
        let profile = SQLiteScaleFixtureProfile(kind: .mixed, fixedBodyBytes: 128)
        let largeBodyIndex = profile.largestBodyIndex(in: count)
        _ = try await history.seedPerformanceFixture(rowCount: count) { index in
            profile.capture(at: index, includeLargeBodyHit: index == largeBodyIndex)
        }
        let expectedFirst = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 50))
        var samples: [SQLiteScaleSample] = []
        let first = try await measureSQLiteScale(phase: "first-page", samples: &samples) {
            await history.measureRecentPage(HistoryBrowseRequest(kind: .recent, limit: 50))
        } facts: { (try $0.result.get().rows.count, 0) }
        recentWork: { SQLiteScaleRecentWork($0.metrics) }
        #expect(try first.result.get() == expectedFirst)
        let scroll = try await measureSQLiteScale(phase: "full-scroll", samples: &samples) {
            await measureSQLiteScaleRecentTraversal(
                history: history, expectedCount: count, largeBodyIndex: largeBodyIndex
            )
        } facts: { _ = try $0.result.get(); return (0, 0) }
        recentWork: { $0.work }
        recentPages: { $0.pages }
        fixtureRows: { try? $0.result.get().count }
        let evidence = try scroll.result.get()
        #expect(evidence.count == count)
        #expect(evidence.leadingRows.prefix(50).map(\.item) == expectedFirst.rows.map(\.item))
        #expect(evidence.leadingRows.count == 100)
        #expect(evidence.oldestRow?.title == "perf-item-0-")
        #expect(evidence.largeBodyRow?.title == "perf-item-\(largeBodyIndex)-")
        #expect(scroll.pages.map(\.pageIndex) == [0, 1, 2])
        #expect(scroll.pages.map(\.returnedRows) == [50, 50, 20])
        #expect(scroll.pages.allSatisfy {
            $0.failure == nil && $0.elapsedMilliseconds.isFinite && $0.elapsedMilliseconds > 0
                && $0.work.pageRequests == 1 && $0.work.statementCount > 0 && $0.work.virtualMachineSteps > 0
        })
        #expect(scroll.work.pageRequests == scroll.pages.count)
        #expect(scroll.work.rowsDecoded == scroll.pages.reduce(0) { $0 + $1.work.rowsDecoded })
        #expect(scroll.work.virtualMachineSteps == scroll.pages.reduce(0) { $0 + $1.work.virtualMachineSteps })
        #expect(scroll.work.cacheMisses == scroll.pages.reduce(0) { $0 + $1.work.cacheMisses })
        let firstSample = try #require(samples.first)
        #expect(firstSample.recentWork?.pageRequests == 1)
        #expect(firstSample.recentPages == nil)
        let scrollSample = try #require(samples.last)
        #expect(scrollSample.processedFixtureRows == count)
        #expect(scrollSample.recentWork?.pageRequests == 3)
        #expect(scrollSample.recentPages?.count == 3)
        #expect(samples.allSatisfy { $0.failure == nil && $0.searchWork == nil })
    }

    @Test func failedRecentTraversalRetainsNativeWorkWithoutSuccessfulRowFacts() async throws {
        let history = try await openMemoryStore()
        _ = try await history.seedPerformanceFixture(rowCount: 4) { index in
            SQLiteScaleFixtureProfile(kind: .fixed, fixedBodyBytes: 64).capture(at: index)
        }
        var samples: [SQLiteScaleSample] = []
        await #expect(throws: SQLiteScaleError.self) {
            _ = try await measureSQLiteScale(phase: "full-scroll", samples: &samples) {
                // The request succeeds, but five expected rows cannot be
                // validated against this four-row real store.
                await measureSQLiteScaleRecentTraversal(history: history, expectedCount: 5)
            } facts: { _ = try $0.result.get(); return (0, 0) }
            recentWork: { $0.work }
            recentPages: { $0.pages }
            fixtureRows: { try? $0.result.get().count }
        }
        let sample = try #require(samples.first)
        #expect(sample.failure != nil)
        #expect(sample.returnedRows == nil && sample.processedFixtureRows == nil)
        let work = try #require(sample.recentWork)
        #expect(work.pageRequests == 1 && work.rowsDecoded >= 4 && work.virtualMachineSteps > 0)
        let page = try #require(sample.recentPages?.first)
        #expect(page.failure != nil && page.returnedRows == nil)
        #expect(page.work.rowsDecoded == work.rowsDecoded)
    }
}
