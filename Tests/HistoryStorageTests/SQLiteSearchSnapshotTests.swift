#if DEBUG
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

/// The actual SQLite reader is exercised against public capture mutations,
/// including a writer committing while an independent read transaction is
/// parked. Array fixtures remain only the matcher-equivalence oracle.
struct SQLiteSearchSnapshotTests {
    private struct Fixture {
        let location: HistoryStoreLocation
        let history: SQLiteHistory
        let bodies: [HistoryItemID: String]
        let recent: HistoryPage
    }

    private actor Once {
        private var available = true
        func take() -> Bool {
            defer { available = false }
            return available
        }
    }

    @Test(arguments: [SearchMode.exact, .regexp, .fuzzy])
    func SQLBatchesAndContinuationsPreserveTheExistingMatcherResults(mode: SearchMode) async throws {
        let bodies = (0..<70).map { index in
            "\(index)\n" + String(repeating: "x ", count: index % 8) + "needle e\u{301} 😀 \(index)"
        }
        let fixture = try await makeFixture(bodies)
        let worker = SearchWorker()
        let rows = fixture.recent.rows.map { row in
            SearchCorpusRow(
                id: row.item.id, contentVersion: row.item.contentVersion, title: row.title,
                searchBody: fixture.bodies[row.item.id]!, debugTitleUTF8Bytes: row.title.utf8.count,
                debugSearchBodyUTF8Bytes: fixture.bodies[row.item.id]!.utf8.count,
                typeIdentifiers: row.typeIdentifiers, lastCopiedAt: row.lastCopiedAt,
                copyCount: row.copyCount, lastSource: row.lastSource,
                pinOrdinal: row.pinnedPosition.map { PinOrdinal(rawValue: $0) }
            )
        }
        let kind = HistoryBrowseKind.search(text: "needle", mode: mode)
        let marker = UUID()
        let oracle = try await worker.page(
            HistoryBrowseRequest(kind: kind, limit: 500),
            in: SearchCorpusSnapshot(
                position: fixture.recent.position, rows: rows,
                debugTrace: SearchDebugTrace(id: UUID(), startedAt: ContinuousClock().now)
            ), continuationAnchor: nil, processMarker: marker
        )
        try #require(oracle.rows.count == bodies.count)
        var collected: [HistoryRow] = []
        var cursor: HistoryPageCursor?
        repeat {
            let page = try await worker.page(
                HistoryBrowseRequest(kind: kind, limit: 7, after: cursor),
                store: fixture.location, processMarker: marker
            )
            #expect(page.position == oracle.position)
            collected += page.rows
            cursor = page.next
        } while cursor != nil && collected.count <= bodies.count
        #expect(collected == oracle.rows)
        #expect(cursor == nil)
    }

    @Test func readSnapshotKeepsRemovedRowsAndTheirFinalBodyUntilTheRequestEnds() async throws {
        let fixture = try await makeFixture((0..<70).map { "\($0)\nneedle old body \($0)" })
        let removed = try #require(fixture.recent.rows.first?.item)
        let worker = SearchWorker()
        let gate = SuspensionGate()
        let once = Once()
        await worker.setSuspensionHandler { point in
            if point == .sqliteBatchComplete, await once.take() {
                await gate.park(at: point.rawValue)
            }
        }
        let task = Task {
            try await worker.searchPage(
                HistoryBrowseRequest(kind: .search(text: "needle", mode: .exact), limit: 500),
                store: fixture.location, processMarker: UUID()
            )
        }
        await gate.waitForPark(SearchWorkerSuspensionPoint.sqliteBatchComplete.rawValue)
        do {
            _ = try await fixture.history.perform(.remove(removed.id))
        } catch {
            task.cancel()
            await gate.resume(SearchWorkerSuspensionPoint.sqliteBatchComplete.rawValue)
            _ = try? await task.value
            throw error
        }
        await gate.resume(SearchWorkerSuspensionPoint.sqliteBatchComplete.rawValue)
        let old = try await task.value
        #expect(old.page.position == fixture.recent.position)
        #expect(old.page.rows.count == 70)
        let oldRow = try #require(old.page.rows.first { $0.item == removed })
        #expect(oldRow.search?.snippet == fixture.bodies[removed.id])
        #expect(old.revisionCounts[removed.id] == 0)
        let current = try await fixture.history.browse(HistoryBrowseRequest(
            kind: .search(text: "needle", mode: .exact), limit: 500
        ))
        #expect(current.position > old.page.position)
        #expect(current.rows.count == 69)
        #expect(!current.rows.contains { $0.item == removed })
    }

    @Test func largeBodiesRespectBothBatchBoundsAfterThePageAlreadyFilled() async throws {
        let fixture = try await makeFixture((0..<10).map {
            "\($0)\nneedle " + String(repeating: "x", count: 262_000)
        })
        let worker = SearchWorker()
        let (events, continuation) = AsyncStream<SearchDebugEvent>.makeStream()
        await worker.setSearchDebugProbe(SearchDebugProbe(isEnabled: true) {
            _ = continuation.yield($0)
        })
        let page = try await worker.page(
            HistoryBrowseRequest(kind: .search(text: "needle", mode: .exact), limit: 1),
            store: fixture.location, processMarker: UUID()
        )
        continuation.finish()
        #expect(page.rows.count == 1)
        #expect(page.next != nil)
        var batches: [SearchDebugEvent] = []
        for await event in events where event.phase == "sqlite-batch" { batches.append(event) }
        #expect(batches.count > 1)
        #expect(batches.reduce(0) { $0 + $1.rowsProcessed } == 10)
        #expect(batches.allSatisfy {
            $0.rowsProcessed <= SearchWorker.maximumBatchRows
                && $0.sourceUTF8Bytes <= SearchWorker.maximumBatchUTF8Bytes
        })
    }

    @Test func cancellationAndDeadlineReleaseTheWALSnapshot() async throws {
        let fixture = try await makeFixture((0..<40).map { "\($0)\nneedle cancellation \($0)" })
        let worker = SearchWorker()
        let gate = SuspensionGate()
        let once = Once()
        await worker.setSuspensionHandler { point in
            if point == .sqliteBatchComplete, await once.take() { await gate.park(at: point.rawValue) }
        }
        let task = Task {
            try await worker.page(
                HistoryBrowseRequest(kind: .search(text: "needle", mode: .fuzzy), limit: 7),
                store: fixture.location, processMarker: UUID()
            )
        }
        await gate.waitForPark(SearchWorkerSuspensionPoint.sqliteBatchComplete.rawValue)
        do {
            _ = try await fixture.history.perform(.capture(WSSupport.textCapture(
                "new write while read snapshot is alive", observedAt: Date(timeIntervalSinceReferenceDate: 999)
            )))
        } catch {
            task.cancel()
            await gate.resume(SearchWorkerSuspensionPoint.sqliteBatchComplete.rawValue)
            _ = try? await task.value
            throw error
        }
        task.cancel()
        await gate.resume(SearchWorkerSuspensionPoint.sqliteBatchComplete.rawValue)
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let inspector = Inspector(location: fixture.location)
        #expect(try await inspector.checkpointIsUnblocked())
        await worker.setSnapshotLifetime(.zero)
        await #expect(throws: HistoryFailure.temporarilyUnavailable(.searchEngineDeadline)) {
            _ = try await worker.page(
                HistoryBrowseRequest(kind: .search(text: "needle", mode: .exact), limit: 7),
                store: fixture.location, processMarker: UUID()
            )
        }
        #expect(try await inspector.checkpointIsUnblocked())
    }

    @Test func corruptTailStillFailsAfterEnoughEarlierMatches() async throws {
        let fixture = try await makeFixture((0..<40).map { "\($0)\nneedle \($0)" })
        let oldest = try #require(fixture.recent.rows.last?.item.id)
        let inspector = Inspector(location: fixture.location)
        try await fixture.history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE history_items SET searchBodyUTF8 = ? WHERE id = ?",
                                           bindings: [.blob(Data([0xFF])), .text(oldest.rawValue.uuidString)])
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            _ = try await fixture.history.browse(HistoryBrowseRequest(
                kind: .search(text: "needle", mode: .exact), limit: 1
            ))
        }
        #expect(try await inspector.checkpointIsUnblocked())
    }

    private func makeFixture(_ bodies: [String]) async throws -> Fixture {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(
            persistence: .temporary
        ))
        let location = try await history.authority.withTestDatabase { $0.storeLocation }
        var byID: [HistoryItemID: String] = [:]
        for (index, body) in bodies.enumerated() {
            let receipt = try await history.perform(.capture(WSSupport.textCapture(
                body, observedAt: Date(timeIntervalSinceReferenceDate: 1_000 - Double(index / 3))
            )))
            guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            byID[item.id] = body
            if index < 3 { _ = try await history.perform(.placePinned(item.id, at: .last)) }
        }
        let recent = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 500))
        return Fixture(location: location, history: history, bodies: byID, recent: recent)
    }

    private actor Inspector {
        let location: HistoryStoreLocation
        init(location: HistoryStoreLocation) { self.location = location }
        func checkpointIsUnblocked() throws -> Bool {
            let database = try SQLiteDatabase(url: location.databaseURL)
            defer { try? database.close() }
            let statement = try database.prepare("PRAGMA wal_checkpoint(TRUNCATE)")
            defer { statement.finalize() }
            guard try statement.step() else { return false }
            return try statement.integer(at: 0) == 0
        }
    }
}
#endif
