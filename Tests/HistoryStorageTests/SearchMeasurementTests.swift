#if DEBUG
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SearchMeasurementTests {
    @Test(arguments: [SearchMode.exact, .regexp, .fuzzy])
    func abundantMatchesResumeWithoutDecodingEarlierPages(mode: SearchMode) async throws {
        let history = try await fixture(count: 128)
        var cursor: HistoryPageCursor?
        var collected: [HistoryItemReference] = []
        for pageNumber in 0..<8 {
            let measured = await history.measureSearch(HistoryBrowseRequest(
                kind: .search(text: "needle", mode: mode), limit: 7, cursor: cursor
            ))
            let page = try measured.result.get()
            #expect(page.rows.count == 7)
            #expect(measured.metrics.rowsDecoded == 32)
            #expect(measured.metrics.batchCount == 1)
            if mode == .fuzzy {
                #expect(measured.metrics.rowsEvaluated == 32)
                #expect(measured.metrics.matchesFound == 32)
                #expect(measured.metrics.stopReason == .provenBestScore)
            } else {
                // The first page evaluates page+lookahead. Continuations
                // also evaluate their inclusive anchor before dropping it.
                #expect(measured.metrics.rowsEvaluated == (pageNumber == 0 ? 8 : 9))
                #expect(measured.metrics.matchesFound == measured.metrics.rowsEvaluated)
                #expect(measured.metrics.stopReason == .pageBudget)
            }
            collected += page.rows.map(\.item)
            let next = try #require(page.next)
            cursor = next
        }
        let recent = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 128))
        #expect(collected == Array(recent.rows.prefix(56).map(\.item)))
    }

    @Test func missesDistinguishFullProjectionScanFromAnIndexProof() async throws {
        let history = try await fixture(count: 70)
        let scanned = await history.measureSearch(HistoryBrowseRequest(
            kind: .search(text: "(?:absent)", mode: .regexp), limit: 7
        ))
        #expect(try scanned.result.get().rows.isEmpty)
        #expect(scanned.metrics.rowsDecoded == 70)
        #expect(scanned.metrics.rowsEvaluated == 70)
        #expect(scanned.metrics.matchesFound == 0)
        #expect(scanned.metrics.batchCount == 3)
        #expect(scanned.metrics.stopReason == .exhausted)

        let proved = await history.measureSearch(HistoryBrowseRequest(
            kind: .search(text: "nZZZZZZZ", mode: .fuzzy), limit: 7
        ))
        #expect(try proved.result.get().rows.isEmpty)
        #expect(proved.metrics.rowsDecoded == 0)
        #expect(proved.metrics.rowsEvaluated == 0)
        #expect(proved.metrics.matchesFound == 0)
        #expect(proved.metrics.batchCount == 0)
        #expect(proved.metrics.stopReason == .provenNoMatch)
    }

    @Test func typoPagesStopAtTheProvenEditFloorWithMixedBodyVocabulary() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let bodies = [
            "meeting agenda: 中文记录 😀",
            "greeting from teammate: 数据说明",
            "rg --glob '*.swift' source search\n项目分析",
            "release log: CJK 表格, العربية",
        ]
        _ = try await history.seedPerformanceFixture(rowCount: 128) { index in
            WSSupport.textCapture(
                "perf-item-\(index)\n" + bodies[index % bodies.count],
                observedAt: Date(timeIntervalSinceReferenceDate: Double(index))
            )
        }
        let floor = try await history.authority.withTestDatabase { authority in
            try SQLiteSearchIndex.lowestPossibleFuzzyScore(term: "perg-item-", in: authority.database)
        }
        #expect(floor == 0.1)
        var cursor: HistoryPageCursor?
        var collected: [HistoryItemReference] = []
        for _ in 0..<8 {
            let measured = await history.measureSearch(HistoryBrowseRequest(
                kind: .search(text: "perg-item-", mode: .fuzzy), limit: 7, cursor: cursor
            ))
            let page = try measured.result.get()
            #expect(page.rows.count == 7)
            #expect(measured.metrics.rowsDecoded == 32)
            #expect(measured.metrics.rowsEvaluated == 32)
            #expect(measured.metrics.matchesFound == 32)
            #expect(measured.metrics.batchCount == 1)
            #expect(measured.metrics.stopReason == .provenBestScore)
            collected += page.rows.map(\.item)
            let next = try #require(page.next)
            cursor = next
        }
        let recent = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 128))
        #expect(collected == Array(recent.rows.prefix(56).map(\.item)))
    }

    @Test func aFloorScoreCursorWithInsufficientTailStillSearchesEarlierWorseScores() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        var newestWorse: HistoryItemReference?
        for index in 0..<32 {
            newestWorse = try await capture("xneedle\n\(index)", date: Double(100 + index), history: history)
        }
        let floor = try await capture("needle\nold", date: 1, history: history)
        let first = await history.measureSearch(HistoryBrowseRequest(
            kind: .search(text: "needle", mode: .fuzzy), limit: 1
        ))
        let page = try first.result.get()
        #expect(page.rows.map(\.item) == [floor])
        let cursor = try #require(page.next)
        let second = await history.measureSearch(HistoryBrowseRequest(
            kind: .search(text: "needle", mode: .fuzzy), limit: 1, cursor: cursor
        ))
        let expected = try #require(newestWorse)
        #expect(try second.result.get().rows.map(\.item) == [expected])
        #expect(second.metrics.rowsDecoded == 33)
        #expect(second.metrics.rowsEvaluated == 33)
        #expect(second.metrics.matchesFound == 33)
        #expect(second.metrics.batchCount == 2)
        #expect(second.metrics.stopReason == .exhausted)
    }

    @Test func cancelledMeasurementRetainsCompletedBatchWorkAndOriginalError() async throws {
        let history = try await fixture(count: 70)
        let suspension = SuspensionGate()
        await history.searchWorker.setSuspensionHandler { point in
            if point == .sqliteBatchComplete { await suspension.park(at: point.rawValue) }
        }
        let task = Task {
            await history.measureSearch(HistoryBrowseRequest(
                kind: .search(text: "needle", mode: .exact), limit: 100
            ))
        }
        await suspension.waitForPark(SearchWorkerSuspensionPoint.sqliteBatchComplete.rawValue)
        let replacement = await history.measureSearch(HistoryBrowseRequest(
            kind: .search(text: "nZZZZZZZ", mode: .fuzzy), limit: 7
        ))
        #expect(try replacement.result.get().rows.isEmpty)
        #expect(replacement.metrics.rowsDecoded == 0)
        #expect(replacement.metrics.rowsEvaluated == 0)
        task.cancel()
        await suspension.resume(SearchWorkerSuspensionPoint.sqliteBatchComplete.rawValue)
        let measured = await task.value
        #expect(throws: CancellationError.self) { _ = try measured.result.get() }
        #expect(measured.metrics.rowsDecoded == 32)
        #expect(measured.metrics.rowsEvaluated == 32)
        #expect(measured.metrics.matchesFound == 32)
        #expect(measured.metrics.batchCount == 1)
        #expect(measured.metrics.stopReason == .cancelled)
    }

    @Test func deadlineMeasurementRetainsTheInterruptedRow() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        _ = try await capture(String(repeating: "a", count: 1_000), date: 1, history: history)
        await history.searchWorker.setRegexpEngineDeadline(.zero)
        let measured = await history.measureSearch(HistoryBrowseRequest(
            kind: .search(text: "a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b", mode: .regexp), limit: 7
        ))
        #expect(throws: HistoryFailure.temporarilyUnavailable(.searchEngineDeadline)) {
            _ = try measured.result.get()
        }
        #expect(measured.metrics.rowsDecoded == 1)
        #expect(measured.metrics.rowsEvaluated == 1)
        #expect(measured.metrics.matchesFound == 0)
        #expect(measured.metrics.batchCount == 1)
        #expect(measured.metrics.stopReason == .deadline)
    }

    private func fixture(count: Int) async throws -> SQLiteHistory {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        _ = try await history.seedPerformanceFixture(rowCount: count) { index in
            WSSupport.textCapture("needle\n\(index)", observedAt: Date(timeIntervalSinceReferenceDate: Double(index)))
        }
        return history
    }

    private func capture(_ text: String, date: Double, history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: date)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }
}
#endif
