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
        let bodies = (0..<73).map { index in
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
        var forwardPages: [HistoryPage] = []
        var cursor: HistoryPageCursor?
        repeat {
            let page = try await worker.page(
                HistoryBrowseRequest(kind: kind, limit: 7, cursor: cursor),
                store: fixture.location, processMarker: marker
            )
            #expect(page.position == oracle.position)
            collected += page.rows
            forwardPages.append(page)
            cursor = page.next
        } while cursor != nil && collected.count <= bodies.count
        #expect(collected == oracle.rows)
        #expect(cursor == nil)
        #expect(forwardPages.first?.previous == nil)
        #expect(forwardPages.last?.rows.count == 3)
        var current = try #require(forwardPages.last)
        for index in stride(from: forwardPages.count - 2, through: 0, by: -1) {
            let previous = try #require(current.previous)
            let decoded = try PageCursorCodec.decode(previous, processMarker: marker)
            #expect(decoded.direction == .backward)
            let request = HistoryBrowseRequest(kind: kind, limit: 7, cursor: previous)
            let result = try await worker.searchPage(request, store: fixture.location, processMarker: marker)
            let page = result.page
            #expect(page.rows == forwardPages[index].rows)
            #expect(Set(result.revisionCounts.keys) == Set(page.rows.map { $0.item.id }))
            #expect(result.revisionCounts.values.allSatisfy { $0 == 0 })
            let pure = try await worker.page(
                request,
                in: SearchCorpusSnapshot(position: fixture.recent.position, rows: rows,
                                         debugTrace: SearchDebugTrace(id: UUID(), startedAt: ContinuousClock().now)),
                continuationAnchor: decoded.anchor, processMarker: marker
            )
            #expect(pure == page)
            let next = try #require(page.next)
            let roundTrip = try await worker.page(
                HistoryBrowseRequest(kind: kind, limit: 7, cursor: next),
                store: fixture.location, processMarker: marker
            )
            #expect(roundTrip.rows == current.rows)
            current = page
        }
        #expect(current.previous == nil)
    }

    @Test func emptySearchBackwardAtSQLBatchEdgesKeepsAllPredecessors() async throws {
        let fixture = try await makeFixture((0..<65).map { "\($0)\nempty search row \($0)" })
        let worker = SearchWorker()
        let marker = UUID()
        for mode in [SearchMode.exact, .regexp, .fuzzy] {
            let kind = HistoryBrowseKind.search(text: "", mode: mode)
            let first = try await worker.searchPage(
                HistoryBrowseRequest(kind: kind, limit: 32), store: fixture.location, processMarker: marker
            )
            let firstNext = try #require(first.page.next)
            let middle = try await worker.searchPage(
                HistoryBrowseRequest(kind: kind, limit: 32, cursor: firstNext),
                store: fixture.location, processMarker: marker
            )
            let middleNext = try #require(middle.page.next)
            let tail = try await worker.searchPage(
                HistoryBrowseRequest(kind: kind, limit: 32, cursor: middleNext),
                store: fixture.location, processMarker: marker
            )
            #expect(first.page.rows.count == 32)
            #expect(middle.page.rows.count == 32)
            #expect(tail.page.rows.count == 1)
            #expect(first.page.previous == nil)
            #expect(tail.page.next == nil)
            let tailPrevious = try #require(tail.page.previous)
            let restoredMiddle = try await worker.searchPage(
                HistoryBrowseRequest(kind: kind, limit: 32, cursor: tailPrevious),
                store: fixture.location, processMarker: marker
            )
            #expect(restoredMiddle.page == middle.page)
            #expect(Set(restoredMiddle.revisionCounts.keys) == Set(middle.page.rows.map { $0.item.id }))
            let middlePrevious = try #require(restoredMiddle.page.previous)
            let restoredFirst = try await worker.searchPage(
                HistoryBrowseRequest(kind: kind, limit: 32, cursor: middlePrevious),
                store: fixture.location, processMarker: marker
            )
            #expect(restoredFirst.page == first.page)
            #expect(restoredFirst.page.rows.allSatisfy { $0.search == nil })
        }
    }

    @Test(arguments: [SearchMode.exact, .regexp, .fuzzy])
    func backwardAnchorMustMatchAndBeforeFirstHasNoPhantomLinks(mode: SearchMode) async throws {
        let fixture = try await makeFixture((0..<8).map { "\($0)\nneedle \($0)" } + ["999999"])
        let worker = SearchWorker()
        let marker = UUID()
        let request = HistoryBrowseRequest(kind: .search(text: "needle", mode: mode), limit: 1)
        let first = try await worker.page(request, store: fixture.location, processMarker: marker)
        let next = try #require(first.next)
        let decoded = try PageCursorCodec.decode(next, processMarker: marker)
        let beforeFirst = try PageCursorCodec.encode(
            ResolvedPageCursor(queryShape: decoded.queryShape, position: decoded.position,
                               anchor: decoded.anchor, direction: .backward), processMarker: marker
        )
        let empty = try await worker.page(
            HistoryBrowseRequest(kind: request.kind, limit: 1, cursor: beforeFirst),
            store: fixture.location, processMarker: marker
        )
        #expect(empty.rows.isEmpty)
        #expect(empty.previous == nil && empty.next == nil)
        let nonmatching = try #require(fixture.recent.rows.first { $0.title == "999999" })
        let anchor: StoredOrderingAnchor = mode == .fuzzy
            ? .fuzzyUnpinned(score: 0, lastCopiedAt: nonmatching.lastCopiedAt, id: nonmatching.item.id)
            : .defaultOrder(pinnedOrdinal: nil, lastCopiedAt: nonmatching.lastCopiedAt, id: nonmatching.item.id)
        let cursor = try PageCursorCodec.encode(
            ResolvedPageCursor(queryShape: StoredQueryShape(request: request), position: fixture.recent.position,
                               anchor: anchor, direction: .backward), processMarker: marker
        )
        await #expect(throws: HistoryFailure.snapshotExpired(current: fixture.recent.position)) {
            _ = try await worker.page(HistoryBrowseRequest(kind: request.kind, limit: 1, cursor: cursor),
                                      store: fixture.location, processMarker: marker)
        }
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

    @Test(arguments: [HistoryPageDirection.forward, .backward])
    func cancellationAndDeadlineReleaseTheWALSnapshot(direction: HistoryPageDirection) async throws {
        let fixture = try await makeFixture((0..<40).map { "\($0)\nneedle cancellation \($0)" })
        let worker = SearchWorker()
        let marker = UUID()
        let kind = HistoryBrowseKind.search(text: "needle", mode: .fuzzy)
        let cursor: HistoryPageCursor?
        if direction == .backward {
            cursor = try await backwardCursor(worker: worker, fixture: fixture, kind: kind, marker: marker)
        } else { cursor = nil }
        let gate = SuspensionGate()
        let once = Once()
        await worker.setSuspensionHandler { point in
            if point == .sqliteBatchComplete, await once.take() { await gate.park(at: point.rawValue) }
        }
        let task = Task {
            try await worker.page(
                HistoryBrowseRequest(kind: kind, limit: 7, cursor: cursor),
                store: fixture.location, processMarker: marker
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
        await worker.setSuspensionHandler(nil)
        let deadlineCursor: HistoryPageCursor?
        if direction == .backward {
            deadlineCursor = try await backwardCursor(worker: worker, fixture: fixture, kind: kind, marker: marker)
        } else { deadlineCursor = nil }
        await worker.setSnapshotLifetime(.zero)
        await #expect(throws: HistoryFailure.temporarilyUnavailable(.searchEngineDeadline)) {
            _ = try await worker.page(
                HistoryBrowseRequest(kind: kind, limit: 7, cursor: deadlineCursor),
                store: fixture.location, processMarker: marker
            )
        }
        #expect(try await inspector.checkpointIsUnblocked())
    }

    @Test func corruptTailStillFailsAfterEnoughEarlierMatches() async throws {
        let fixture = try await makeFixture((0..<40).map { "\($0)\nneedle \($0)" })
        let oldest = try #require(fixture.recent.rows.last?.item.id)
        let inspector = Inspector(location: fixture.location)
        var previousCursors: [(SearchMode, HistoryPageCursor)] = []
        for mode in [SearchMode.exact, .regexp, .fuzzy] {
            let kind = HistoryBrowseKind.search(text: "needle", mode: mode)
            let first = try await fixture.history.browse(HistoryBrowseRequest(kind: kind, limit: 1))
            let next = try #require(first.next)
            let second = try await fixture.history.browse(HistoryBrowseRequest(kind: kind, limit: 1, cursor: next))
            previousCursors.append((mode, try #require(second.previous)))
        }
        try await fixture.history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE history_items SET searchBodyUTF8 = ? WHERE id = ?",
                                           bindings: [.blob(Data([0xFF])), .text(oldest.rawValue.uuidString)])
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            _ = try await fixture.history.browse(HistoryBrowseRequest(
                kind: .search(text: "needle", mode: .exact), limit: 1
            ))
        }
        for (mode, previous) in previousCursors {
            await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
                _ = try await fixture.history.browse(HistoryBrowseRequest(
                    kind: .search(text: "needle", mode: mode), limit: 1, cursor: previous
                ))
            }
        }
        #expect(try await inspector.checkpointIsUnblocked())
    }

    private func backwardCursor(
        worker: SearchWorker, fixture: Fixture, kind: HistoryBrowseKind, marker: UUID
    ) async throws -> HistoryPageCursor {
        let first = try await worker.page(HistoryBrowseRequest(kind: kind, limit: 7),
                                          store: fixture.location, processMarker: marker)
        let next = try #require(first.next)
        let second = try await worker.page(HistoryBrowseRequest(kind: kind, limit: 7, cursor: next),
                                           store: fixture.location, processMarker: marker)
        return try #require(second.previous)
    }

    private func makeFixture(_ bodies: [String]) async throws -> Fixture {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(
            persistence: .temporary
        ))
        let location = await history.authority.withTestDatabase { $0.storeLocation }
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
