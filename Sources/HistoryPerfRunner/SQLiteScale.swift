/// V2-09 §10: separate seed and fresh-process measurement invocations.
/// Example: --sqlite-scale seed /tmp/scale/store.sqlite 10000 256 seed.json
///          --sqlite-scale measure /tmp/scale/store.sqlite 10000 256 measure.json
import Foundation
import HistoryCore
import HistoryStorage

enum SQLiteScaleError: Error {
    case invalidArguments
    case unexpectedStore
    case unexpectedResult
    case memoryUnavailable
    case diskUnavailable
}

struct SQLiteScaleArguments: Sendable {
    enum Mode: String, Sendable { case seed, measure }
    let mode: Mode
    let storeURL: URL
    let retainedRows: Int
    let bodyBytes: Int
    let outputURL: URL

    init(_ arguments: [String]) throws {
        guard arguments.count == 5,
              let mode = Mode(rawValue: arguments[0]),
              let rows = Int(arguments[2]), (2...1_000_000).contains(rows),
              let bytes = Int(arguments[3]), (64...262_144).contains(bytes) else {
            throw SQLiteScaleError.invalidArguments
        }
        self.mode = mode
        storeURL = URL(fileURLWithPath: arguments[1])
        retainedRows = rows
        bodyBytes = bytes
        outputURL = URL(fileURLWithPath: arguments[4])
    }
}

func runSQLiteScale(arguments: [String]) async -> Int {
    do {
        let options = try SQLiteScaleArguments(arguments)
        var samples: [SQLiteScaleSample] = []
        var before: HistoryUsage?
        var history: SQLiteHistory?
        var failure: String?
        do {
            let exists = FileManager.default.fileExists(atPath: options.storeURL.path)
            guard exists == (options.mode == .measure) else {
                throw SQLiteScaleError.unexpectedStore
            }
            try FileManager.default.createDirectory(
                at: options.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let opened = try await measureSQLiteScale(phase: "open", samples: &samples) {
                try await SQLiteHistory.openPerformanceFixture(
                    storeURL: options.storeURL, retainedRows: options.retainedRows
                )
            }
            history = opened
            switch options.mode {
            case .seed:
                try await seedSQLiteScale(history: opened, options: options, samples: &samples)
            case .measure:
                // No validation browse before first-page timing. Idle includes
                // the production background blob cleanup scheduled by open.
                try await measureSQLiteScale(phase: "idle-2-seconds", samples: &samples) {
                    try await Task.sleep(for: .seconds(2))
                }
                before = try await opened.usage()
                guard before?.itemCount == options.retainedRows else {
                    throw SQLiteScaleError.unexpectedResult
                }
                try await exerciseSQLiteScale(history: opened, options: options, samples: &samples)
                try await measureSQLiteScale(phase: "end-idle-2-seconds", samples: &samples) {
                    try await Task.sleep(for: .seconds(2))
                }
            }
        } catch {
            failure = String(describing: error)
        }
        var usage: HistoryUsage?
        if let history {
            do {
                let current = try await history.usage()
                usage = current
                guard current.itemCount == options.retainedRows else {
                    throw SQLiteScaleError.unexpectedResult
                }
            } catch {
                failure = failure ?? String(describing: error)
            }
        }
        var disk: SQLiteScaleDisk?
        do {
            disk = try SQLiteScaleDisk.read(root: options.storeURL.deletingLastPathComponent())
        } catch {
            failure = failure ?? String(describing: error)
        }
        let report = SQLiteScaleReport(
            mode: options.mode.rawValue, retainedRows: options.retainedRows,
            bodyBytes: options.bodyBytes,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            samples: samples, logicalBefore: before.map(SQLiteScaleUsage.init),
            logicalAfter: usage.map(SQLiteScaleUsage.init),
            diskAfter: disk, failure: failure,
            notes: [
                "Record-only observations; no numeric performance threshold is enforced.",
                "Run seed and measure as separate processes. Measure open is cold-process; OS filesystem caches are uncontrolled, not cold-disk evidence.",
                "RSS/footprint are whole-process endpoint samples. Peak RSS is since process launch, not a resettable per-phase peak; no sampled peak-footprint claim.",
                "Logical content bytes, returned payload bytes, and observed filesystem allocation are different quantities. No total owned-memory attribution is available in this standalone runner.",
                "Disk enumeration runs after operation samples; compare seed/measure diskAfter values for growth. APFS shared/compressed blocks are not exclusive allocation.",
                "The synthetic corpus contains one distinct UTF-8 text representation per item. Scroll retains at most the first100 rows plus the current page and oldest row to independently check search result identities.",
                "Search cases cover absent terms, the oldest item, dense prefixes, a structural regexp, and a fuzzy substitution typo. Dense matches measure two pages separately. Query metadata records expected total matches; rowsVisited records returned rows, not internal decoded/evaluated rows.",
                "Canonical copy reads the original content after revision. Inactive revision payload copy and real OS pressure/app-cache recovery are not measured here.",
            ]
        )
        try FileManager.default.createDirectory(
            at: options.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: options.outputURL)
        return failure == nil && samples.allSatisfy({ $0.failure == nil }) ? 0 : 1
    } catch {
        print("sqlite-scale failed: \(error)")
        return 1
    }
}

private func seedSQLiteScale(
    history: SQLiteHistory,
    options: SQLiteScaleArguments,
    samples: inout [SQLiteScaleSample]
) async throws {
    let rowCount = options.retainedRows
    let bytes = options.bodyBytes
    _ = try await measureSQLiteScale(phase: "seed", samples: &samples) {
        try await history.seedPerformanceFixture(rowCount: rowCount - 1) { index in
            deterministicTextCapture(index: index, bodyBytes: bytes)
        } progress: { rows in
            if rows.isMultiple(of: 10_000) { print("sqlite-scale seededRows=\(rows)") }
        }
    } facts: { ($0.retainedRows, 0) }
    _ = try await measureSQLiteScale(phase: "public-capture", samples: &samples) {
        try await captureItem(history, index: rowCount - 1, bodyBytes: bytes)
    }
}

private func exerciseSQLiteScale(
    history: SQLiteHistory,
    options: SQLiteScaleArguments,
    samples: inout [SQLiteScaleSample]
) async throws {
    let page = try await measureSQLiteScale(phase: "first-page", samples: &samples) {
        try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 50))
    } facts: { ($0.rows.count, 0) }
    guard let selected = page.rows.first?.item else { throw SQLiteScaleError.unexpectedResult }
    let traversed = try await measureSQLiteScale(phase: "full-scroll", samples: &samples) {
        try await traverseSQLiteScale(history: history, expectedCount: options.retainedRows)
    } facts: { ($0.count, 0) }
    try await exerciseSQLiteScaleSearches(
        history: history, corpus: traversed, position: page.position, samples: &samples
    )
    let payload = try await measureSQLiteScale(phase: "copy-current", samples: &samples) {
        try await history.pastePayload(for: selected.id)
    } facts: { (0, $0.representations.reduce(0) { $0 + $1.bytes.count }) }
    guard payload.representations.count == 1,
          payload.representations[0].bytes == deterministicTextCapture(
            index: options.retainedRows - 1, bodyBytes: options.bodyBytes
          ).representations[0].bytes else { throw SQLiteScaleError.unexpectedResult }
    _ = try await measureSQLiteScale(phase: "enable-revision-pruning", samples: &samples) {
        try await history.perform(.setRetentionPolicies(HistoryRetentionPolicies(
            age: nil, storage: nil,
            revisions: RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
        )))
    }
    let firstRevision = try await measureSQLiteScale(phase: "revision", samples: &samples) {
        try await reviseItem(history, reference: selected, itemIndex: 0, appendSequence: 1)
    }
    let secondRevision = try await measureSQLiteScale(phase: "revision-with-prune", samples: &samples) {
        try await reviseItem(history, reference: firstRevision, itemIndex: 0, appendSequence: 2)
    }
    let canonical = try await measureSQLiteScale(phase: "copy-canonical", samples: &samples) {
        try await history.representation(HistoryRepresentationRequest(
            item: secondRevision, basis: .canonical, typeIdentifier: "public.utf8-plain-text"
        ))
    } facts: { (0, $0.bytes.count) }
    guard canonical.bytes == payload.representations[0].bytes else {
        throw SQLiteScaleError.unexpectedResult
    }
    let revisedPayload = try await measureSQLiteScale(phase: "copy-revised-current", samples: &samples) {
        try await history.pastePayload(for: selected.id)
    } facts: { (0, $0.representations.reduce(0) { $0 + $1.bytes.count }) }
    guard revisedPayload.item == secondRevision,
          revisedPayload.representations.count == 1,
          revisedPayload.representations[0].bytes != canonical.bytes else {
        throw SQLiteScaleError.unexpectedResult
    }
    let details = try await history.details(for: selected.id)
    guard details.revisions.count == 1, details.revisions[0].isActive else {
        throw SQLiteScaleError.unexpectedResult
    }
}

/// Keep100 leading rows and the oldest row as an independent search oracle.
/// Caller memory stays bounded; the position check detects mixed snapshots.
func traverseSQLiteScale(
    history: SQLiteHistory,
    expectedCount: Int
) async throws -> SQLiteScaleBrowseEvidence {
    var cursor: HistoryPageCursor?
    var position: ChangePosition?
    var count = 0
    var leadingRows: [HistoryRow] = []
    var oldestRow: HistoryRow?
    repeat {
        let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 50, cursor: cursor))
        if let position, page.position != position { throw SQLiteScaleError.unexpectedResult }
        position = page.position
        for row in page.rows {
            let expectedIndex = expectedCount - count - 1
            guard expectedIndex >= 0,
                  row.lastCopiedAt == Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(expectedIndex)),
                  row.title.hasPrefix("perf-item-\(expectedIndex)-") else {
                throw SQLiteScaleError.unexpectedResult
            }
            if leadingRows.count < 100 { leadingRows.append(row) }
            oldestRow = row
            count += 1
        }
        cursor = page.next
    } while cursor != nil
    guard count == expectedCount else { throw SQLiteScaleError.unexpectedResult }
    return SQLiteScaleBrowseEvidence(count: count, leadingRows: leadingRows, oldestRow: oldestRow)
}
