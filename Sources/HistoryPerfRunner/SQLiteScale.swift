/// V2-09 §10: separate seed and fresh-process measurement invocations.
/// Example: --sqlite-scale seed /tmp/scale/store.sqlite 100000 1024 seed.json mixed
///          --sqlite-scale measure /tmp/scale/store.sqlite 100000 1024 measure.json mixed
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
    let fixtureProfile: SQLiteScaleFixtureProfile
    let largeBodyIndex: Int

    init(_ arguments: [String]) throws {
        guard (5...6).contains(arguments.count),
              let mode = Mode(rawValue: arguments[0]),
              let rows = Int(arguments[2]), (2...100_000).contains(rows),
              let bytes = Int(arguments[3]), (64...262_144).contains(bytes) else {
            throw SQLiteScaleError.invalidArguments
        }
        guard let profile = SQLiteScaleFixtureProfile.Kind(rawValue: arguments.count == 6 ? arguments[5] : "fixed") else {
            throw SQLiteScaleError.invalidArguments
        }
        fixtureProfile = SQLiteScaleFixtureProfile(kind: profile, fixedBodyBytes: bytes)
        largeBodyIndex = fixtureProfile.largestBodyIndex(in: rows)
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
        var projections: PerformanceProjectionLengths?
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
                projections = try await measureSQLiteScale(phase: "projection-statistics", samples: &samples) {
                    try await opened.performanceProjectionLengths()
                }
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
                try await exerciseSQLiteScale(
                    history: opened, options: options, samples: &samples, projections: &projections
                )
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
        let generatedLengths = SQLiteScaleLengthStatistics(histogram: sqliteScaleRawLengthHistogram(
            profile: options.fixtureProfile, count: options.retainedRows
        ))
        let rawLengths: SQLiteScaleLengthStatistics?
        if let usage, usage.itemCount == options.retainedRows, Int64(usage.canonicalBytes) == generatedLengths.totalBytes {
            rawLengths = generatedLengths
        } else {
            rawLengths = nil
            failure = failure ?? "fixture raw byte totals do not match the retained corpus"
        }
        let report = SQLiteScaleReport(
            mode: options.mode.rawValue, retainedRows: options.retainedRows,
            bodyBytes: options.fixtureProfile.kind == .fixed ? options.bodyBytes : nil,
            fixtureStatistics: SQLiteScaleFixtureStatistics(
                profile: options.fixtureProfile.kind.rawValue,
                rawUTF8Bytes: rawLengths,
                indexedTitleUTF8Bytes: projections.map { SQLiteScaleLengthStatistics(histogram: $0.titleUTF8Bytes) },
                indexedSearchBodyUTF8Bytes: projections.map { SQLiteScaleLengthStatistics(histogram: $0.searchBodyUTF8Bytes) }
            ),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            machine: admissionMachineMetadata(),
            swiftVersion: commandOutput("/usr/bin/xcrun", arguments: ["swift", "--version"]),
            samples: samples, logicalBefore: before.map(SQLiteScaleUsage.init),
            logicalAfter: usage.map(SQLiteScaleUsage.init),
            diskAfter: disk, failure: failure,
            notes: [
                "Mixed is a synthetic reference mixture, not measured user behavior: per 100k, 20000 short/64000 medium/14400 long/1520 large/80 very-large items. Lengths use 2048 evenly spaced sample points per band. fixed preserves the former equal-size fixture.",
                "rawUTF8Bytes reports generated content lengths; indexedTitleUTF8Bytes/indexedSearchBodyUTF8Bytes aggregate actual persisted production projection lengths before revision. Nearest-rank percentiles and floating-point population moments use complete length histograms. The two read/statistics phases are outside query timing.",
                "Record-only observations; no numeric performance threshold is enforced.",
                "Any operation, resource read or result-validation failure makes the report fail and the process exit nonzero. Independent search cases may still collect later evidence; their earlier failure is rethrown after the search suite and is never converted into success. A pre-operation resource failure carries no invented latency/memory/row sample.",
                "Run seed and measure as separate processes. Measure open is cold-process; OS filesystem caches are uncontrolled, not cold-disk evidence.",
                "RSS/footprint are whole-process endpoint samples. Peak RSS is since process launch, not a resettable per-phase peak; no sampled peak-footprint claim.",
                "Logical content bytes, returned payload bytes, and observed filesystem allocation are different quantities. No total owned-memory attribution is available in this standalone runner.",
                "Disk enumeration runs after operation samples; compare seed/measure diskAfter values for growth. APFS shared/compressed blocks are not exclusive allocation.",
                "The synthetic corpus contains one distinct UTF-8 text representation per item. Each title is its first-line marker; all bodies contain bodyhit, only the oldest contains rarebody, and the largest raw value contains largebodyhit near its durable projection tail. Scroll retains at most the first 100 rows plus the current page, oldest row and designated large row to independently check search identities.",
                "Mixed lengths do not imply diverse text entropy: bodies repeat seven text-shaped blocks. Fixed bodies use ASCII padding. These synthetic cases do not establish performance for arbitrary user text or worst-case index posting distributions.",
                "Seed and traversal report processedFixtureRows separately; returnedRows is the count of returned browse/search DTO rows. searchWork records same-request Swift decode/evaluation work, including partial work on failure, and excludes SQLite posting-list/planner work.",
                "Each search page records one saved warmup (sampleIndex 0, isWarmup true) followed by five timed repetitions (sampleIndex 1...5, isWarmup false) in this same process and store. elapsedMilliseconds is the raw request time; group timed records by phase for a median and exclude warmup. Every repetition independently validates identities, page boundaries and presentation. These are warm-cache observations after open/scroll and preceding queries, not cold-disk measurements; non-search phases remain single observations and omit repetition fields. Older report samples omit these optional fields.",
                "first-page recentWork and full-scroll recentWork/recentPages come from the same production recent-page requests as the results, including partial failed work. full-scroll records each page's raw request latency and sums native counters; its whole-phase timer also includes fixture validation and traversal bookkeeping. VM/fullscan/sort count primary scalar SELECTs, including SQL-filter predicates, anchors/ties/lookahead. Position/transaction SQL, cursor encoding and separate source-validation SQL VM are excluded. Cache hits/misses are connection counter differences across each scalar SELECT prepare/step/decode/source-validation interval, not physical I/O bytes or OS page faults. No SQL complexity conclusion follows from one total traversal time.",
                "Search cases cover absent terms, the oldest item, dense title/body hits, rare large-body tail snippets with UTF-16 match validation, both common/rare AND operand orders including a common title term, a structural regexp, and a fuzzy substitution typo. Dense matches measure two pages separately; one additional first-page expression repeats the common title term 128 times to expose redundant planner/posting probes. Query metadata records expected total matches; returnedRows records returned rows, not internal decoded/evaluated rows.",
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
    let profile = options.fixtureProfile
    let largeBodyIndex = options.largeBodyIndex
    _ = try await measureSQLiteScale(phase: "seed", samples: &samples) {
        try await history.seedPerformanceFixture(rowCount: rowCount - 1) { index in
            profile.capture(at: index, includeLargeBodyHit: index == largeBodyIndex)
        } progress: { rows in
            if rows.isMultiple(of: 10_000) { print("sqlite-scale seededRows=\(rows)") }
        }
    } fixtureRows: { $0.retainedRows }
    _ = try await measureSQLiteScale(phase: "public-capture", samples: &samples) {
        try await capturePreparedItem(history, capture: profile.capture(
            at: rowCount - 1, includeLargeBodyHit: rowCount - 1 == largeBodyIndex
        ))
    }
}

private func exerciseSQLiteScale(
    history: SQLiteHistory,
    options: SQLiteScaleArguments,
    samples: inout [SQLiteScaleSample],
    projections: inout PerformanceProjectionLengths?
) async throws {
    let first = try await measureSQLiteScale(phase: "first-page", samples: &samples) {
        await history.measureRecentPage(HistoryBrowseRequest(kind: .recent, limit: 50))
    } facts: { (try $0.result.get().rows.count, 0) }
    recentWork: { SQLiteScaleRecentWork($0.metrics) }
    let page = try first.result.get()
    guard let selected = page.rows.first?.item else { throw SQLiteScaleError.unexpectedResult }
    let scroll = try await measureSQLiteScale(phase: "full-scroll", samples: &samples) {
        await measureSQLiteScaleRecentTraversal(
            history: history, expectedCount: options.retainedRows, largeBodyIndex: options.largeBodyIndex
        )
    } facts: { _ = try $0.result.get(); return (0, 0) }
    recentWork: { $0.work }
    recentPages: { $0.pages }
    fixtureRows: { try? $0.result.get().count }
    let traversed = try scroll.result.get()
    try await exerciseSQLiteScaleSearches(
        history: history, corpus: traversed, position: page.position, samples: &samples
    )
    projections = try await measureSQLiteScale(phase: "projection-statistics", samples: &samples) {
        try await history.performanceProjectionLengths()
    }
    let payload = try await measureSQLiteScale(phase: "copy-current", samples: &samples) {
        try await history.pastePayload(for: selected.id)
    } facts: { (0, $0.representations.reduce(0) { $0 + $1.bytes.count }) }
    guard payload.representations.count == 1,
          payload.representations[0].bytes == options.fixtureProfile.capture(
            at: options.retainedRows - 1, includeLargeBodyHit: options.retainedRows - 1 == options.largeBodyIndex
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

/// Keep 100 leading rows, the oldest row and one designated large-body row as
/// an independent search oracle.
/// Caller memory stays bounded; the position check detects mixed snapshots.
func traverseSQLiteScale(
    history: SQLiteHistory,
    expectedCount: Int,
    largeBodyIndex: Int? = nil
) async throws -> SQLiteScaleBrowseEvidence {
    let measured = await measureSQLiteScaleRecentTraversal(
        history: history, expectedCount: expectedCount, largeBodyIndex: largeBodyIndex
    )
    return try measured.result.get()
}
