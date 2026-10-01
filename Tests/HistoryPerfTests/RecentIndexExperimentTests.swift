import Foundation
import HistoryCore
@testable import HistoryPerfRunner
@testable import HistoryStorage
import Testing

/// Isolated opt-in experiment. Only this test's disposable History acquires
/// an extra SQLite index; product schema and public interfaces stay intact.
@Suite(.serialized)
struct RecentIndexExperimentTests {
    @Test func boundedExpressionPreservesRealCodecMetadataAndBoundaryPages() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .temporary, initialMaximumUnpinnedItems: nil
        ))
        let inlineTypes = try boundaryTypes(blobBytes: 1_024)
        let fallbackTypes = try boundaryTypes(blobBytes: 1_025)
        let largeTypes = largeMetadataTypes()
        let largeBlobBytes = try EffectiveTypeIdentifiersBlobCodec.encode(largeTypes).count
        try #require(largeBlobBytes > 1_025)
        let types = [inlineTypes, fallbackTypes, largeTypes]
        var references: [HistoryItemReference] = []
        for (index, identifiers) in types.enumerated() {
            references.append(try await insertMetadataCapture(history, types: identifiers, index: index))
        }
        let request = HistoryBrowseRequest(kind: .recent, limit: 3)
        let original = try await history.browse(request)
        for (index, reference) in references.enumerated() {
            let blob = try await history.authority.recentIndexExperimentTypes(for: reference.id)
            let expected = types[index].map { Data($0.utf8) }
            #expect(try EffectiveTypeIdentifiersBlobCodec.decode(blob).map { Data($0.utf8) } == expected)
            #expect(try await history.representationMetadata(for: reference).map { Data($0.typeIdentifier.utf8) } == expected)
            let row = try #require(original.rows.first { $0.item == reference })
            #expect(row.typeIdentifiers.map { Data($0.utf8) } == expected)
            let projected = try await history.authority.recentIndexExperimentInlineTypes(for: reference.id)
            if index == 0 {
                #expect(blob.count == 1_024)
                #expect(projected == blob)
            } else {
                #expect(blob.count == (index == 1 ? 1_025 : largeBlobBytes))
                #expect(projected == nil)
            }
        }
        let position = original.position
        _ = try await history.authority.installRecentIndexExperiment()
        #expect(try await history.browse(request) == original)
        try await history.authority.verifyRecentIndexExperimentRows(original.rows)
        let inline = await history.measureRecentPage(metadataRequest(at: 0))
        let fallback = await history.measureRecentPage(metadataRequest(at: 1))
        #expect(try inline.result.get().rows.map(\.item) == [references[0]])
        #expect(try fallback.result.get().rows.map(\.item) == [references[1]])
        // Both one-row requests use the same page shape. The additional
        // statement is the required original-BLOB primary-key fallback.
        #expect(fallback.metrics.statementCount == inline.metrics.statementCount + 1)
        #expect(fallback.metrics.rowsDecoded == inline.metrics.rowsDecoded)
        #expect(fallback.metrics.virtualMachineSteps > 0)
        #expect(try await history.usage().position == position)
        for sortOrder in HistorySortOrder.allCases {
            let firstRequest = HistoryBrowseRequest(kind: .recent, limit: 2, sortOrder: sortOrder)
            let first = try await history.browse(firstRequest)
            let next = try #require(first.next)
            let second = try await history.browse(.init(kind: .recent, limit: 2, cursor: next, sortOrder: sortOrder))
            let previous = try #require(second.previous)
            #expect(try await history.browse(.init(kind: .recent, limit: 2, cursor: previous, sortOrder: sortOrder)) == first)
            let around = try await history.browse(.init(kind: .recent, limit: 2, sortOrder: sortOrder, startAround: references[1].id))
            #expect(around.rows.first?.item == references[1])
            try await history.authority.verifyRecentIndexExperimentRows(first.rows + second.rows + around.rows)
        }
        _ = try await history.perform(.placePinned(references[2].id, at: .last))
        let pinned = try await history.browse(request)
        #expect(pinned.rows.first?.item == references[2])
        try await history.authority.verifyRecentIndexExperimentRows(pinned.rows)
        let snapshot = try await history.authority.recentIndexExperimentSnapshot()
        print("recent-bounded-index semantic sqlite=\(snapshot.sqliteVersion) inlineBytes=1024 fallbackBytes=1025 largeBytes=\(largeBlobBytes) queryPlan=\(snapshot.queryPlan)")
    }

    @Test func fallbackRejectsInvalidOriginalMetadataAndKeepsPartialWork() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .temporary, initialMaximumUnpinnedItems: nil
        ))
        let reference = try await insertMetadataCapture(history, types: boundaryTypes(blobBytes: 1_025), index: 0)
        _ = try await history.authority.installRecentIndexExperiment()
        let request = metadataRequest(at: 0)
        let successful = await history.measureRecentPage(request)
        let page = try successful.result.get()
        let original = try await history.authority.recentIndexExperimentTypes(for: reference.id)
        // The existing NOT NULL schema rejects a stored NULL, even though a
        // NULL projected expression is a legitimate fallback sentinel.
        await #expect(throws: SQLiteFailure.self) {
            try await history.authority.replaceRecentIndexExperimentTypes(for: reference.id, value: .null)
        }
        #expect(try await history.browse(request) == page)
        let invalidValues: [SQLiteValue] = [
            .blob(Data([0])), .blob(Data(repeating: 0, count: 1_025)),
            .text(String(repeating: "x", count: 1_025)),
            .blob(Data(repeating: 0, count: EffectiveTypeIdentifiersBlobCodec.maximumBlobBytes() + 1)),
        ]
        for value in invalidValues {
            try await history.authority.replaceRecentIndexExperimentTypes(for: reference.id, value: value)
            let failed = await history.measureRecentPage(request)
            #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) { try failed.result.get() }
            await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) { try await history.browse(request) }
            #expect(failed.metrics.virtualMachineSteps > 0)
            let requiresFallback: Bool
            if case .blob(let bytes) = value, bytes.count == 1 { requiresFallback = false }
            else { requiresFallback = true }
            #expect(failed.metrics.statementCount == successful.metrics.statementCount - (requiresFallback ? 0 : 1))
            try await history.authority.replaceRecentIndexExperimentTypes(for: reference.id, value: .blob(original))
            let restored = await history.measureRecentPage(request)
            #expect(try restored.result.get() == page)
            #expect(restored.metrics.statementCount == successful.metrics.statementCount)
        }
    }

    @Test func fallbackRejectsNoncanonicalIDBeforePrimaryKeyRead() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .temporary, initialMaximumUnpinnedItems: nil
        ))
        let reference = try await insertMetadataCapture(history, types: boundaryTypes(blobBytes: 1_025), index: 0)
        _ = try await history.authority.installRecentIndexExperiment()
        let request = metadataRequest(at: 0)
        let successful = await history.measureRecentPage(request)
        _ = try successful.result.get()
        // This is a valid UUID spelling with the wrong canonical case. It
        // cannot be normalized and used to retrieve some other item's types.
        try await history.authority.replaceRecentIndexExperimentID(reference.id, with: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        let failed = await history.measureRecentPage(request)
        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) { try failed.result.get() }
        #expect(failed.metrics.virtualMachineSteps > 0)
        #expect(failed.metrics.rowsDecoded == 0)
        #expect(failed.metrics.statementCount == successful.metrics.statementCount - 1)
    }

    private func boundaryTypes(blobBytes: Int) throws -> [String] {
        let first = "com.clipy.boundary.a." + String(repeating: "x", count: 512 - "com.clipy.boundary.a.".utf8.count)
        let secondPrefix = "com.clipy.boundary.b."
        let overhead = try EffectiveTypeIdentifiersBlobCodec.encode([first, secondPrefix]).count
        let padding = blobBytes - overhead
        try #require(padding >= 0 && secondPrefix.utf8.count + padding <= 512)
        let identifiers = [first, secondPrefix + String(repeating: "x", count: padding)]
        let blob = try EffectiveTypeIdentifiersBlobCodec.encode(identifiers)
        try #require(blob.count == blobBytes)
        try #require(try EffectiveTypeIdentifiersBlobCodec.decode(blob) == identifiers)
        return identifiers
    }

    private func largeMetadataTypes() -> [String] {
        (0..<HistoryLimits.standard.maximumRepresentationsPerCaptureOrRevision).map { index in
            let prefix = "com.clipy.large.\(index).e\u{301}."
            return prefix + String(repeating: "x", count: 512 - prefix.utf8.count)
        }.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    private func insertMetadataCapture(_ history: SQLiteHistory, types: [String], index: Int) async throws -> HistoryItemReference {
        let capture = ClipboardCapture(
            representations: types.enumerated().map {
                CapturedRepresentation(typeIdentifier: $0.element, bytes: Data("metadata-\(index)-\($0.offset)".utf8))
            },
            origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(index))
        )
        guard case .committed(let commit) = try await history.perform(.capture(capture)),
              case .inserted(let reference) = commit.outcome else {
            throw RecentIndexExperimentFailure.unexpectedMutation
        }
        return reference
    }

    private func metadataRequest(at index: Int) -> HistoryBrowseRequest {
        HistoryBrowseRequest(kind: .recent, limit: 3, filter: .init(
            copiedAfter: Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(index)),
            copiedBefore: Date(timeIntervalSinceReferenceDate: 600_000_001 + Double(index))
        ))
    }

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
                "Native VM/fullscan/sort counts describe actual scalar SELECTs and required metadata fallback SELECTs, including partial failures. Pager hit/miss differences cover each primary SELECT interval once, including fallback and synchronous source validation, but are not physical I/O bytes. Position/transaction SQL and Swift cursor construction are excluded from native counters.",
                "The type projection uses one shared CASE expression: original BLOBs of at most 1024 bytes are indexed verbatim; larger BLOBs project NULL and are fetched by canonical UUID primary key inside the same read transaction, with the original codec envelope checked before copying. This bounds index duplication without changing admitted metadata or type spelling. Invalid originals still fail. Other indexed title/source fields retain their existing 1024-byte bounds.",
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
    let indexedInlineTypes: RecentIndexLengthStats
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
    let inlineTypeByteLimit: Int
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
    func recentIndexExperimentTypes(for id: HistoryItemID) throws -> Data {
        let row = try database.prepare("SELECT effectiveTypeIdentifiersBlob FROM history_items WHERE id=?",
                                       bindings: [.text(id.rawValue.uuidString)])
        defer { row.finalize() }
        guard try row.step() else { throw RecentIndexExperimentFailure.unexpectedPage }
        return try row.blob(at: 0)
    }

    func recentIndexExperimentInlineTypes(for id: HistoryItemID) throws -> Data? {
        let row = try database.prepare("SELECT \(ScalarReadRow.recentInlineTypesExpression) FROM history_items WHERE id=?",
                                       bindings: [.text(id.rawValue.uuidString)])
        defer { row.finalize() }
        guard try row.step() else { throw RecentIndexExperimentFailure.unexpectedPage }
        return try row.optionalBlob(at: 0)
    }

    func replaceRecentIndexExperimentTypes(for id: HistoryItemID, value: SQLiteValue) throws {
        guard storeLocation.ownedDirectoryURL != storeLocation.rootURL else {
            throw RecentIndexExperimentFailure.notDisposable
        }
        try database.execute("UPDATE history_items SET effectiveTypeIdentifiersBlob=? WHERE id=?",
                             bindings: [value, .text(id.rawValue.uuidString)])
    }

    func replaceRecentIndexExperimentID(_ id: HistoryItemID, with name: String) throws {
        guard storeLocation.ownedDirectoryURL != storeLocation.rootURL else {
            throw RecentIndexExperimentFailure.notDisposable
        }
        try database.execute("PRAGMA foreign_keys=OFF")
        defer { try? database.execute("PRAGMA foreign_keys=ON") }
        try database.execute("UPDATE history_items SET id=? WHERE id=?",
                             bindings: [.text(name), .text(id.rawValue.uuidString)])
    }

    func installRecentIndexExperiment() throws -> Double {
        guard storeLocation.ownedDirectoryURL != storeLocation.rootURL else {
            throw RecentIndexExperimentFailure.notDisposable
        }
        let start = ContinuousClock.now
        try database.writeTransaction(checkingCancellation: true) {
            try database.execute("""
                CREATE INDEX clipy_recent_projection_experiment ON history_items(
                    lastCopiedAt DESC, id ASC,
                    contentVersion, titleUTF8, \(ScalarReadRow.recentInlineTypesExpression),
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
            indexedInlineTypes: lengths(ScalarReadRow.recentInlineTypesExpression),
            lastSource: lengths("lastSource"), searchBody: lengths("searchBodyUTF8"))
        let plan = try database.prepare("""
            EXPLAIN QUERY PLAN SELECT \(ScalarReadRow.recentColumns) FROM history_items
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
            queryPlan: queryPlan, inlineTypeByteLimit: ScalarReadRow.recentInlineTypesMaximumBytes,
            indexBytes: indexBytes, indexSizeUnavailable: unavailable)
    }
}
