import Foundation
import HistoryCore
@testable import HistoryPerfRunner
@testable import HistoryStorage
import Testing

/// Isolated opt-in experiment. Only this test's disposable History acquires
/// an extra SQLite index; product schema and public interfaces stay intact.
@Suite(.serialized)
struct RecentIndexExperimentTests {
    @Test(arguments: [10_000, 100_000])
    func measuresOnePrivateStoreBeforeAndAfterCoveringIndex(rows: Int) async throws {
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .temporary, initialMaximumUnpinnedItems: nil
        ))
        let mixed = SQLiteScaleFixtureProfile(kind: .mixed, fixedBodyBytes: 1_024)
        let fixed = SQLiteScaleFixtureProfile(kind: .fixed, fixedBodyBytes: 128)
        _ = try await history.seedPerformanceFixture(rowCount: rows - 1) { mixed.capture(at: $0) }
        await history.authority.waitForBlobCleanup()

        // Finish at exactly N rows through a real public capture, then a real
        // coalescing update. These single-operation samples include commit.
        let beforeWrites = try await mutationPair(history, capture: fixed.capture(at: rows - 1), label: "without-index")
        let before = try await history.authority.recentIndexExperimentSnapshot()
        let position = try await history.usage().position
        let probes = try await pageProbes(history, rows: rows)
        let beforeSamples = try await readSamples(history, probes: probes, rows: rows, position: position, label: "without-index")

        let buildMilliseconds = try await history.authority.installRecentIndexExperiment()
        let after = try await history.authority.recentIndexExperimentSnapshot()
        try #require(try await history.usage().position == position)
        try #require(after.metadata == before.metadata)
        let afterSamples = try await readSamples(history, probes: probes, rows: rows, position: position, label: "with-index")
        try await verifyAllRowsAgainstTable(history, rows: rows, position: position)

        let afterWrites = try await mutationPair(history, capture: fixed.capture(at: rows), label: "with-index")
        let afterWritesSnapshot = try await history.authority.recentIndexExperimentSnapshot()
#if DEBUG
        let buildConfiguration = "Debug"
#else
        let buildConfiguration = "Release"
#endif
        let report = RecentIndexExperimentReport(
            machine: admissionMachineMetadata(), buildConfiguration: buildConfiguration,
            seedMixedRows: rows - 1, measuredRows: rows, position: position.rawValue,
            buildMilliseconds: buildMilliseconds, before: before, after: after,
            usedDatabaseBytesGrowth: (after.pageCount - after.freePageCount - before.pageCount + before.freePageCount) * after.pageSize,
            beforeReadSamples: beforeSamples, afterReadSamples: afterSamples,
            beforeMutationSamples: beforeWrites, afterMutationSamples: afterWrites,
            afterMutations: afterWritesSnapshot,
            notes: [
                "One private temporary SQLiteHistory per case. N-1 rows use the mixed profile; the last row is a fixed 128-byte public capture followed by one coalescing update. This controlled exception is recorded, not counted as an unchanged mixed corpus.",
                "Each selected page and whole traversal has one saved warmup (0), then five raw timed observations (1...5), in this same process, store and History position. Filesystem caches are uncontrolled; these are not cold-disk comparisons.",
                "Read timing includes measurement calls and traversal bookkeeping. Per-page elapsedMilliseconds excludes subsequent fixture validation. All selected page results equal their saved public browse pages, including IDs, metadata and cursors. Full traversal checks exact fixture order/count; a separate streaming verification checks every returned scalar against a primary-key original-table point read.",
                "Native VM/fullscan/sort counts describe the actual primary scalar SELECTs. Pager hit/miss differences include synchronous source validation, but are not physical I/O bytes. Position/transaction SQL and Swift cursor construction are excluded from native counters.",
                "Index creation runs in the sole Authority transaction after all before reads and before all after reads. No History rows, position or codecs change there. Metadata-length and file/page measurements occur outside read timers.",
                "Used-database growth includes any schema-page allocation and accounts for freelist reuse. dbstat index bytes are optional and include overflow pages when supported; an unavailable measurement is reported explicitly. Apparent/allocated whole-store file bytes include SQLite/WAL/SHM and blobs, not exclusive APFS ownership.",
                "Mutation samples are single public capture/coalesce commits, not repetitions or percentile estimates. Both inserts use a fixed 128-byte value; their sequential fixture markers differ. The before pair completes the N-row fixture; the after pair adds row N+1 after all read comparisons. Changing store counts, warm state and timing noise limit causal write-cost conclusions.",
                "Reports retain numeric page observations and at most three 50-row probes plus the existing traversal's first 100/oldest rows while running. No full-store ID collection, payload corpus, checksum, migration or product index is introduced.",
            ]
        )
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOG_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("clipy-recent-index-evidence").path,
            isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("recent-index-experiment-\(rows).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output)
        print("recent-index-experiment rows=\(rows) buildMs=\(buildMilliseconds) usedDatabaseBytesGrowth=\(report.usedDatabaseBytesGrowth) report=\(output.path)")
    }

    private func pageProbes(_ history: SQLiteHistory, rows: Int) async throws -> [RecentIndexPageProbe] {
        var probes: [RecentIndexPageProbe] = []
        let headRequest = HistoryBrowseRequest(kind: .recent, limit: 50)
        probes.append(RecentIndexPageProbe(label: "head", request: headRequest,
                                         expected: try await history.browse(headRequest)))
        for (label, index) in [("middle", rows / 2), ("deep", 100)] {
            let id = try await history.authority.recentIndexExperimentItem(at: index)
            let around = try await history.browse(.init(kind: .recent, limit: 50, startAround: id))
            let cursor = try #require(around.next)
            let request = HistoryBrowseRequest(kind: .recent, limit: 50, cursor: cursor)
            probes.append(RecentIndexPageProbe(label: label, request: request,
                                             expected: try await history.browse(request)))
        }
        return probes
    }

    private func readSamples(
        _ history: SQLiteHistory, probes: [RecentIndexPageProbe], rows: Int,
        position: ChangePosition, label: String
    ) async throws -> [RecentIndexReadSample] {
        var samples: [RecentIndexReadSample] = []
        for probe in probes {
            for index in 0...5 {
                try Task.checkCancellation()
                let start = ContinuousClock.now
                let measured = await history.measureRecentPage(probe.request)
                let elapsed = recentIndexMilliseconds(start.duration(to: ContinuousClock.now))
                let page = try measured.result.get()
                try #require(page == probe.expected)
                try #require(page.position == position)
                samples.append(RecentIndexReadSample(configuration: label, operation: probe.label,
                    sampleIndex: index, isWarmup: index == 0, elapsedMilliseconds: elapsed,
                    work: SQLiteScaleRecentWork(measured.metrics), pages: nil))
            }
        }
        for index in 0...5 {
            try Task.checkCancellation()
            let start = ContinuousClock.now
            let measured = await measureSQLiteScaleRecentTraversal(history: history, expectedCount: rows)
            let elapsed = recentIndexMilliseconds(start.duration(to: ContinuousClock.now))
            let traversed = try measured.result.get()
            try #require(traversed.count == rows)
            try #require(traversed.leadingRows.first?.item == probes.first?.expected.rows.first?.item)
            try #require(try await history.usage().position == position)
            samples.append(RecentIndexReadSample(configuration: label, operation: "full-scroll",
                sampleIndex: index, isWarmup: index == 0, elapsedMilliseconds: elapsed,
                work: measured.work, pages: measured.pages))
            print("recent-index-experiment configuration=\(label) rows=\(rows) sample=\(index) scrollMs=\(elapsed) vmSteps=\(measured.work.virtualMachineSteps) misses=\(measured.work.cacheMisses)")
        }
        return samples
    }

    private func mutationPair(
        _ history: SQLiteHistory, capture: ClipboardCapture, label: String
    ) async throws -> [RecentIndexMutationSample] {
        var result: [RecentIndexMutationSample] = []
        for operation in ["capture", "coalesce"] {
            let before = try await history.usage()
            let start = ContinuousClock.now
            let receipt = try await history.perform(.capture(capture))
            let elapsed = recentIndexMilliseconds(start.duration(to: ContinuousClock.now))
            guard case .committed(let commit) = receipt else {
                throw RecentIndexExperimentFailure.unexpectedMutation
            }
            switch (operation, commit.outcome) {
            case ("capture", .inserted(_)), ("coalesce", .coalesced(_)): break
            default: throw RecentIndexExperimentFailure.unexpectedMutation
            }
            let after = try await history.usage()
            #expect(after.position.rawValue == before.position.rawValue + 1)
            #expect(after.itemCount == before.itemCount + (operation == "capture" ? 1 : 0))
            result.append(RecentIndexMutationSample(configuration: label, operation: operation,
                elapsedMilliseconds: elapsed, positionBefore: before.position.rawValue,
                positionAfter: after.position.rawValue, rowsBefore: before.itemCount, rowsAfter: after.itemCount))
        }
        return result
    }

    private func verifyAllRowsAgainstTable(_ history: SQLiteHistory, rows: Int, position: ChangePosition) async throws {
        var cursor: HistoryPageCursor?
        var count = 0
        for _ in 0...rows / 50 {
            let page = try await history.browse(.init(kind: .recent, limit: 50, cursor: cursor))
            guard page.position == position, !page.rows.isEmpty else {
                throw RecentIndexExperimentFailure.unexpectedPage
            }
            try await history.authority.verifyRecentIndexExperimentRows(page.rows)
            for row in page.rows {
                let index = rows - count - 1
                guard row.lastCopiedAt == Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(index)),
                      row.title == "perf-item-\(index)-" else {
                    throw RecentIndexExperimentFailure.unexpectedPage
                }
                count += 1
            }
            cursor = page.next
            if cursor == nil { break }
        }
        guard cursor == nil, count == rows else { throw RecentIndexExperimentFailure.unexpectedPage }
    }
}

private enum RecentIndexExperimentFailure: Error {
    case notDisposable, unexpectedPage, unexpectedMutation
}

private struct RecentIndexPageProbe: Sendable {
    let label: String
    let request: HistoryBrowseRequest
    let expected: HistoryPage
}

private struct RecentIndexReadSample: Codable, Sendable {
    let configuration: String
    let operation: String
    let sampleIndex: Int
    let isWarmup: Bool
    let elapsedMilliseconds: Double
    let work: SQLiteScaleRecentWork
    let pages: [SQLiteScaleRecentPageSample]?
}

private struct RecentIndexMutationSample: Codable, Sendable {
    let configuration: String
    let operation: String
    let elapsedMilliseconds: Double
    let positionBefore: UInt64
    let positionAfter: UInt64
    let rowsBefore: Int
    let rowsAfter: Int
}

private struct RecentIndexLengthStats: Codable, Sendable, Equatable {
    let nonnullCount: Int64
    let minimumBytes: Int64
    let maximumBytes: Int64
    let totalBytes: Int64
}

private struct RecentIndexMetadata: Codable, Sendable, Equatable {
    let rows: Int64
    let title: RecentIndexLengthStats
    let effectiveTypes: RecentIndexLengthStats
    let lastSource: RecentIndexLengthStats
    let searchBody: RecentIndexLengthStats
}

private struct RecentIndexStoreSnapshot: Codable, Sendable {
    let sqliteVersion: String
    let pageSize: Int64
    let pageCount: Int64
    let freePageCount: Int64
    let metadata: RecentIndexMetadata
    let disk: SQLiteScaleDisk
    let queryPlan: [String]
    let indexBytes: Int64?
    let indexSizeUnavailable: String?
}

private struct RecentIndexExperimentReport: Codable, Sendable {
    let machine: MachineMetadata
    let buildConfiguration: String
    let seedMixedRows: Int
    let measuredRows: Int
    let position: UInt64
    let buildMilliseconds: Double
    let before: RecentIndexStoreSnapshot
    let after: RecentIndexStoreSnapshot
    let usedDatabaseBytesGrowth: Int64
    let beforeReadSamples: [RecentIndexReadSample]
    let afterReadSamples: [RecentIndexReadSample]
    let beforeMutationSamples: [RecentIndexMutationSample]
    let afterMutationSamples: [RecentIndexMutationSample]
    let afterMutations: RecentIndexStoreSnapshot
    let notes: [String]
}

private func recentIndexMilliseconds(_ duration: Duration) -> Double {
    let value = duration.components
    return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
}

private extension HistoryAuthority {
    func installRecentIndexExperiment() throws -> Double {
        guard storeLocation.ownedDirectoryURL != storeLocation.rootURL else {
            throw RecentIndexExperimentFailure.notDisposable
        }
        let start = ContinuousClock.now
        try database.writeTransaction(checkingCancellation: true) {
            try database.execute("""
                CREATE INDEX clipy_recent_projection_experiment ON history_items(
                    lastCopiedAt DESC, id ASC,
                    contentVersion, titleUTF8, effectiveTypeIdentifiersBlob,
                    copyCount, lastSource, pinOrdinal, sourceCount
                ) WHERE pinOrdinal IS NULL
                """)
        }
        return recentIndexMilliseconds(start.duration(to: ContinuousClock.now))
    }

    func recentIndexExperimentItem(at index: Int) throws -> HistoryItemID {
        let row = try database.prepare("SELECT id FROM history_items WHERE lastCopiedAt=?",
                                       bindings: [.real(600_000_000 + Double(index))])
        defer { row.finalize() }
        guard try row.step(), let id = UUID(uuidString: try row.text(at: 0)) else {
            throw RecentIndexExperimentFailure.unexpectedPage
        }
        return HistoryItemID(rawValue: id)
    }

    func verifyRecentIndexExperimentRows(_ rows: [HistoryRow]) throws {
        try database.readTransaction(checkingCancellation: true) {
            guard let first = rows.first else { throw RecentIndexExperimentFailure.unexpectedPage }
            let statement = try database.prepare("""
                SELECT \(ScalarReadRow.columns) FROM history_items
                INDEXED BY sqlite_autoindex_history_items_1 WHERE id=?
                """, bindings: [.text(first.item.id.rawValue.uuidString)])
            defer { statement.finalize() }
            for (index, row) in rows.enumerated() {
                try Task.checkCancellation()
                if index > 0 { try statement.reset(bindings: [.text(row.item.id.rawValue.uuidString)]) }
                guard try statement.step(), try ScalarReadRow(statement, limits: limits).toHistoryRow(limits: limits) == row else {
                    throw RecentIndexExperimentFailure.unexpectedPage
                }
            }
        }
    }

    func recentIndexExperimentSnapshot() throws -> RecentIndexStoreSnapshot {
        func integer(_ sql: String) throws -> Int64 {
            let row = try database.prepare(sql)
            defer { row.finalize() }
            guard try row.step() else { throw RecentIndexExperimentFailure.unexpectedPage }
            return try row.integer(at: 0)
        }
        func lengths(_ column: String) throws -> RecentIndexLengthStats {
            // BLOB length is available from the record header; do not turn
            // the statistics pass into a read/copy of every search body.
            let byteLength = column == "lastSource" ? "length(CAST(lastSource AS BLOB))" : "length(\(column))"
            let row = try database.prepare("""
                SELECT count(\(column)),coalesce(min(\(byteLength)),0),
                    coalesce(max(\(byteLength)),0),coalesce(sum(\(byteLength)),0)
                FROM history_items WHERE pinOrdinal IS NULL
                """)
            defer { row.finalize() }
            guard try row.step() else { throw RecentIndexExperimentFailure.unexpectedPage }
            return try RecentIndexLengthStats(nonnullCount: row.integer(at: 0), minimumBytes: row.integer(at: 1),
                                               maximumBytes: row.integer(at: 2), totalBytes: row.integer(at: 3))
        }
        let versionRow = try database.prepare("SELECT sqlite_version()")
        guard try versionRow.step() else { throw RecentIndexExperimentFailure.unexpectedPage }
        let version = try versionRow.text(at: 0)
        versionRow.finalize()
        let metadata = try RecentIndexMetadata(rows: integer("SELECT count(*) FROM history_items"),
            title: lengths("titleUTF8"), effectiveTypes: lengths("effectiveTypeIdentifiersBlob"),
            lastSource: lengths("lastSource"), searchBody: lengths("searchBodyUTF8"))
        let plan = try database.prepare("""
            EXPLAIN QUERY PLAN SELECT \(ScalarReadRow.columns) FROM history_items
            WHERE (pinOrdinal IS NULL) AND (1) ORDER BY lastCopiedAt DESC,id ASC LIMIT 50
            """)
        var queryPlan: [String] = []
        while try plan.step() { queryPlan.append(try plan.text(at: 3)) }
        plan.finalize()
        var indexBytes: Int64?
        var unavailable: String?
        do {
            indexBytes = try integer("SELECT coalesce(sum(pgsize),0) FROM dbstat WHERE name='clipy_recent_projection_experiment'")
        } catch {
            unavailable = String(describing: error)
        }
        return try RecentIndexStoreSnapshot(sqliteVersion: version, pageSize: integer("PRAGMA page_size"),
            pageCount: integer("PRAGMA page_count"), freePageCount: integer("PRAGMA freelist_count"),
            metadata: metadata, disk: SQLiteScaleDisk.read(root: storeLocation.ownedDirectoryURL),
            queryPlan: queryPlan, indexBytes: indexBytes, indexSizeUnavailable: unavailable)
    }
}
