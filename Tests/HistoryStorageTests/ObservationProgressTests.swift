#if DEBUG
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct ObservationProgressTests {
    @Test(.timeLimit(.minutes(1)))
    func searchPublishesDuringWritesAndCatchesUpWhenTheyStop() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let maximumInterference = 4
        let burst = CaptureBurst(limit: maximumInterference)
        await history.searchWorker.setSuspensionHandler { point in
            // The search has already opened its SQLite snapshot at this hook.
            guard point == .evaluationEntry, let index = await burst.nextIndex() else { return }
            do {
                let receipt = try await history.perform(.capture(WSSupport.textCapture(
                    "needle \(index)", observedAt: Date(timeIntervalSinceReferenceDate: 820_001_000 + Double(index))
                )))
                guard case .committed(let commit) = receipt,
                      case .inserted(let item) = commit.outcome else {
                    Issue.record("Expected the interfering capture to insert a new item")
                    return
                }
                await burst.record(item.id, at: commit.position)
            } catch {
                Issue.record("Interfering capture failed: \(error)")
            }
        }
        let resume = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { resume.continuation.finish() }
        let stream = await ObservationDebugInstrumentation.$pageDidYield.withValue({ _ in
            guard await burst.stopAtFirstPublication() else { return }
            // Let the public consumer take the first page before the stream's
            // newest-page buffer can replace it with the catch-up page.
            var permit = resume.stream.makeAsyncIterator()
            _ = await permit.next()
        }) {
            await history.observe(HistoryObservationRequest(kind: .search(text: "needle", mode: .exact), limit: 10))
        }

        do {
            var pages = stream.makeAsyncIterator()
            let first = try #require(try await pages.next())
            let captures = await burst.commits
            try #require(captures.count < maximumInterference, "The observer waited for the entire write burst to finish")
            let last = try #require(captures.last)
            try #require(first.position < last.position, "Every read in the burst was superseded before publication")
            let visible = captures.filter { $0.position <= first.position }.map { $0.id }
            #expect(Set(first.rows.map(\.item.id)) == Set(visible))
            #expect(!first.rows.isEmpty)

            resume.continuation.yield(())
            let caughtUp = try #require(try await pages.next())
            #expect(caughtUp.position == last.position)
            #expect(Set(caughtUp.rows.map(\.item.id)) == Set(captures.map { $0.id }))
            #expect(await history.searchWorker.activeSnapshots == 0)
        } catch {
            await history.searchWorker.setSuspensionHandler(nil)
            throw error
        }
        await history.searchWorker.setSuspensionHandler(nil)
    }
}

private actor CaptureBurst {
    let limit: Int
    private(set) var commits: [(id: HistoryItemID, position: ChangePosition)] = []
    private var stopped = false

    init(limit: Int) { self.limit = limit }

    func nextIndex() -> Int? {
        guard !stopped, commits.count < limit else { return nil }
        return commits.count + 1
    }

    func record(_ id: HistoryItemID, at position: ChangePosition) {
        commits.append((id, position))
    }

    func stopAtFirstPublication() -> Bool {
        guard !stopped else { return false }
        stopped = true
        return true
    }
}
#endif
