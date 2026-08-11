/// Search-observation coherence coverage for docs/04-coherence.md §5/§7.
/// The existing WS12 position-recheck seam deterministically proves that a
/// search page evaluated at an older position is discarded and recomputed
/// before the first yield when a commit lands before the race-closing recheck.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct SearchObservationCoherenceTests {

/// One-shot arming keeps the second position recheck (after recomputation)
/// from parking at the same `SuspensionGate` point.
private actor SearchObservationParkLatch {
    private var armed = true

    func consume() -> Bool {
        let wasArmed = armed
        armed = false
        return wasArmed
    }
}

private static func installPositionRecheckPark(
    on authority: HistoryAuthority,
    gate: SuspensionGate,
    latch: SearchObservationParkLatch
) async {
    await authority.setSuspensionHandler { point in
        guard point == .positionRecheckEntry else { return }
        let shouldPark = await latch.consume()
        guard shouldPark else { return }
        await gate.park(at: point.rawValue)
    }
}

private static func installSearchEvaluationPark(
    on worker: SearchWorker,
    gate: SuspensionGate,
    latch: SearchObservationParkLatch
) async {
    await worker.setSuspensionHandler { point in
        guard point == .evaluationEntry else { return }
        let shouldPark = await latch.consume()
        guard shouldPark else { return }
        await gate.park(at: point.rawValue)
    }
}

/// 04 §5 step 4 + §7: the first exact-search evaluation completes against
/// the empty position-0 corpus, then its position recheck parks. A matching
/// capture advances the durable position while parked. The stale empty page
/// must be discarded; the first page visible to the subscriber is a fresh
/// search result containing the committed item at the newer position.
@Test func searchObservationDiscardsStaleFirstPageAndRecomputesAfterCommit() async throws {
    let storeURL = WSSupport.tempStoreURL("search-observation-recheck")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)
    let gate = SuspensionGate()
    let latch = SearchObservationParkLatch()
    await Self.installPositionRecheckPark(
        on: history.authority,
        gate: gate,
        latch: latch
    )

    let stream = await history.observe(HistoryObservationRequest(
        kind: .search(text: "needle", mode: .exact),
        limit: 10
    ))
    await gate.waitForPark(AuthoritySuspensionPoint.positionRecheckEntry.rawValue)

    do {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            "needle committed after initial search evaluation",
            observedAt: Date(timeIntervalSinceReferenceDate: 700_089_000),
            source: "com.example.search-observation"
        )))
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome else {
            Issue.record(
                "Search observation arrange: expected committed insertion, got \(receipt)"
            )
            await gate.resume(
                AuthoritySuspensionPoint.positionRecheckEntry.rawValue
            )
            await history.authority.setSuspensionHandler(nil)
            return
        }

        await gate.resume(AuthoritySuspensionPoint.positionRecheckEntry.rawValue)
        let consumer = Task { () -> HistoryPage in
            for try await page in stream {
                return page
            }
            throw HistoryFailure.persistence(.invariantViolation)
        }
        defer { consumer.cancel() }
        let page = try await consumer.value
        await history.authority.setSuspensionHandler(nil)

        #expect(
            page.position == commit.position,
            "the subscriber must never see the stale position-0 search page"
        )
        #expect(
            page.rows.map(\.item.id).contains(reference.id),
            "the recomputed first search page must contain the intervening capture"
        )
        let row = try #require(
            page.rows.first(where: { $0.item.id == reference.id })
        )
        #expect(row.search != nil, "the replacement came through the search lane")
    } catch {
        await gate.resume(AuthoritySuspensionPoint.positionRecheckEntry.rawValue)
        await history.authority.setSuspensionHandler(nil)
        throw error
    }
}


/// 04 §5 step 4 + §7: the first query has already captured an immutable
/// position-0 corpus when SearchWorker parks at evaluation entry. A matching
/// commit lands while that old snapshot is in-flight. Evaluation must retain
/// position 0, the fresh position recheck must discard it, and the subscriber's
/// first visible page must be the recomputed position-1 match.
@Test func searchObservationCommitDuringWorkerEvaluationDiscardsOldSnapshot() async throws {
    let storeURL = WSSupport.tempStoreURL("search-observation-worker-window")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)
    let gate = SuspensionGate()
    let latch = SearchObservationParkLatch()
    await Self.installSearchEvaluationPark(
        on: history.searchWorker,
        gate: gate,
        latch: latch
    )

    let stream = await history.observe(HistoryObservationRequest(
        kind: .search(text: "needle", mode: .exact),
        limit: 10
    ))
    let point = SearchWorkerSuspensionPoint.evaluationEntry.rawValue
    await gate.waitForPark(point)

    do {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            "needle committed during old search evaluation",
            observedAt: Date(timeIntervalSinceReferenceDate: 700_089_100),
            source: "com.example.search-observation.worker-window"
        )))
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome else {
            Issue.record(
                "Search observation arrange: expected insertion, got \(receipt)"
            )
            await gate.resume(point)
            await history.searchWorker.setSuspensionHandler(nil)
            return
        }

        await gate.resume(point)
        let consumer = Task { () -> HistoryPage in
            for try await page in stream {
                return page
            }
            throw HistoryFailure.persistence(.invariantViolation)
        }
        defer { consumer.cancel() }
        let page = try await consumer.value
        await history.searchWorker.setSuspensionHandler(nil)

        #expect(page.position == commit.position)
        #expect(page.rows.map(\.item.id).contains(reference.id))
        let row = try #require(
            page.rows.first(where: { $0.item.id == reference.id })
        )
        #expect(row.search != nil)
    } catch {
        await gate.resume(point)
        await history.searchWorker.setSuspensionHandler(nil)
        throw error
    }
}
}
