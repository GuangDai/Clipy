#if DEBUG
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct FuzzyBackwardWindowTests {
    @Test func floorScorePreviousPagesDecodeOnlyTheNearestPredecessors() async throws {
        let history = try await fixture(count: 128, mixedScores: false)
        let forward = try await forwardPages(8, history: history)
        var current = try #require(forward.last)
        for index in stride(from: forward.count - 2, through: 0, by: -1) {
            let cursor = try #require(current.previous)
            let measured = await history.measureSearch(request(cursor: cursor))
            let page = try measured.result.get()
            #expect(page == forward[index])
            #expect(measured.metrics.rowsDecoded <= 32)
            #expect(measured.metrics.rowsEvaluated == measured.metrics.rowsDecoded)
            #expect(measured.metrics.batchCount == 1)
            #expect(measured.metrics.stopReason == (index == 0 ? .exhausted : .provenBestScore))
            current = page
        }
        #expect(current.previous == nil)
    }

    @Test func pinnedPreviousPagesNeverDecodeTheUnpinnedTail() async throws {
        let history = try await fixture(count: 90, mixedScores: false)
        let recent = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 90))
        for row in recent.rows.prefix(20) {
            _ = try await history.perform(.placePinned(row.item.id, at: .last))
        }
        let forward = try await forwardPages(4, history: history)
        let cursor = try #require(forward[2].previous)
        let measured = await history.measureSearch(request(cursor: cursor))
        #expect(try measured.result.get() == forward[1])
        // The inclusive pin-14 anchor plus its preceding pins are the only
        // candidates this reverse request needs, despite 70 unpinned hits.
        #expect(measured.metrics.rowsDecoded == 15)
        #expect(measured.metrics.rowsEvaluated == 15)
        #expect(measured.metrics.stopReason == .provenBestScore)

        let crossLaneCursor = try #require(forward[3].previous)
        let crossLane = await history.measureSearch(request(cursor: crossLaneCursor))
        #expect(try crossLane.result.get() == forward[2])
        #expect(crossLane.metrics.rowsDecoded <= 32)
        #expect(crossLane.metrics.stopReason == .provenBestScore)
    }

    @Test func reverseFloorWindowSkipsWorseScoresAndHigherScoreCursorsStillScanAllCandidates() async throws {
        let history = try await fixture(count: 120, mixedScores: true)
        let forward = try await forwardPages(7, history: history)
        // Page four starts in the old floor-score group. Its physical
        // predecessors contain 80 higher-score matches, which cannot fill
        // the reverse page even though they count as matched rows.
        let floorCursor = try #require(forward[3].previous)
        let floor = await history.measureSearch(request(cursor: floorCursor))
        let floorPage = try floor.result.get()
        #expect(floorPage == forward[2])
        #expect(floorPage.rows.allSatisfy { $0.title == "needle" })
        #expect(floor.metrics.rowsDecoded > 32)
        #expect(floor.metrics.rowsDecoded < 120)
        #expect(floor.metrics.matchesFound == floor.metrics.rowsEvaluated)
        #expect(floor.metrics.stopReason == .provenBestScore)

        // A cursor above the score floor can have better-score predecessors
        // anywhere in physical order; retain the complete candidate scan.
        let higherCursor = try #require(forward[6].previous)
        let higher = await history.measureSearch(request(cursor: higherCursor))
        #expect(try higher.result.get() == forward[5])
        #expect(higher.metrics.rowsDecoded == 120)
        #expect(higher.metrics.stopReason == .exhausted)
    }

    private func request(cursor: HistoryPageCursor? = nil) -> HistoryBrowseRequest {
        HistoryBrowseRequest(kind: .search(text: "needle", mode: .fuzzy), limit: 7, cursor: cursor)
    }

    private func forwardPages(_ count: Int, history: SQLiteHistory) async throws -> [HistoryPage] {
        var result: [HistoryPage] = []
        var cursor: HistoryPageCursor?
        for _ in 0..<count {
            let page = try await history.browse(request(cursor: cursor))
            result.append(page)
            let next: HistoryPageCursor = try #require(page.next)
            cursor = next
        }
        return result
    }

    private func fixture(count: Int, mixedScores: Bool) async throws -> SQLiteHistory {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        _ = try await history.seedPerformanceFixture(rowCount: count) { index in
            let title = mixedScores && (20..<100).contains(index) ? "xneedle" : "needle"
            return WSSupport.textCapture(
                "\(title)\n\(index)", observedAt: Date(timeIntervalSinceReferenceDate: Double(index))
            )
        }
        return history
    }
}
#endif
