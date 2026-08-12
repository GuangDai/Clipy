/// Manual performance-admission workloads for measurement-gated deferred
/// work (docs/06-cross-cutting.md §9; V1-Verified G2/G5/G8).
///
/// These workloads are intentionally absent from per-push CI. A dispatch-only
/// workflow runs the release binary against one 5,000-row persistent corpus,
/// records all 101 latency samples plus nearest-rank p50/p95/p99, and wraps
/// each process with macOS `/usr/bin/time -l` for peak-RSS evidence. Results
/// are record-only until an authoritative product budget is admitted; this
/// runner must not turn an observed value into a passing threshold by itself.
import Foundation
import HistoryCore
import HistoryStorage

struct AdmissionProfile: Sendable, Equatable {
    let retainedRows: Int
    let searchBodyBytes: Int
    let sampleCount: Int
    let warmupCount: Int
    let pageLimit: Int

    static let full = AdmissionProfile(
        retainedRows: 5_000,
        searchBodyBytes: 256 * 1_024,
        sampleCount: 101,
        warmupCount: 1,
        pageLimit: 50
    )

    /// Crosses the exact platform failure interval observed after the 750-row
    /// marker and before 1,000, with identical per-row storage pressure.
    static let prepareSmoke = AdmissionProfile(
        retainedRows: 1_000,
        searchBodyBytes: 256 * 1_024,
        sampleCount: 0,
        warmupCount: 0,
        pageLimit: 50
    )
}

let admissionProfile = AdmissionProfile.full
let admissionRetainedRows = admissionProfile.retainedRows
let admissionSearchBodyBytes = admissionProfile.searchBodyBytes
let admissionSampleCount = admissionProfile.sampleCount
let admissionWarmupCount = admissionProfile.warmupCount
let admissionPageLimit = admissionProfile.pageLimit

enum AdmissionMode: String, Sendable, Equatable {
    case seed
    case seedSmoke = "seed-smoke"
    case prepare
    case prepareSmoke = "prepare-smoke"
    case browseTies = "browse-ties"
    case exactSearch = "exact-search"
    case exactSearchProbe = "exact-search-probe"
    case openOnce = "open-once"
    case openOnceAndValidate = "open-once-and-validate"
    case warmOpen = "warm-open"

    var createsStore: Bool {
        switch self {
        case .seed, .seedSmoke:
            return true
        case .prepare, .prepareSmoke, .browseTies, .exactSearch,
             .exactSearchProbe,
             .openOnce, .openOnceAndValidate, .warmOpen:
            return false
        }
    }

    var profile: AdmissionProfile {
        switch self {
        case .seedSmoke, .prepareSmoke:
            return .prepareSmoke
        case .seed, .prepare, .browseTies, .exactSearch, .exactSearchProbe,
             .openOnce,
             .openOnceAndValidate, .warmOpen:
            return .full
        }
    }

    var expectedSeedMode: AdmissionMode? {
        switch self {
        case .prepare:
            return .seed
        case .prepareSmoke:
            return .seedSmoke
        case .seed, .seedSmoke, .browseTies, .exactSearch, .exactSearchProbe,
             .openOnce,
             .openOnceAndValidate, .warmOpen:
            return nil
        }
    }

    var isSetupFixture: Bool {
        self == .prepare || self == .prepareSmoke
    }
}

enum AdmissionError: Error, Sendable, Equatable {
    case storeAlreadyExists
    case storeMissing
    case unexpectedSeedFixture
    case unexpectedPage
    case unexpectedPosition
    case diagnosticConfigurationMissing
}

struct AdmissionPercentiles: Codable, Sendable {
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double
}

struct AdmissionFixture: Codable, Sendable {
    let schemaVersion: UInt16
    let mode: String
    let sampleUnit: String
    let machine: MachineMetadata
    let swiftVersion: String
    let date: String
    let corpusRows: Int
    let bodyBytesPerRow: Int
    let warmupCount: Int
    let setupWallTimeMs: Double?
    let rawSamplesMs: [Double]
    let percentiles: AdmissionPercentiles?
    let validation: [String: String]
    let notes: [String]
}

struct AdmissionSeedFixture: Codable, Sendable, Equatable {
    let schemaVersion: UInt16
    let mode: String
    let corpusRows: Int
    let bodyBytesPerRow: Int
    let seededRows: Int
    let seedTransactions: Int
    let seedBatchSize: Int
    let seedPosition: UInt64
    let seedWallTimeMs: Double
}

/// One Debug-only diagnostic request. This deliberately has no raw-sample or
/// percentile fields, so it cannot be mistaken for canonical Release evidence.
struct AdmissionExactSearchProbeFixture: Codable, Sendable, Equatable {
    let schemaVersion: UInt16
    let mode: String
    let evidenceClass: String
    let buildConfiguration: String
    let traceEnvironmentEnabled: Bool
    let canonicalPercentileEvidence: Bool
    let publicRequestCount: Int
    let corpusRows: Int
    let bodyBytesPerRow: Int
    let elapsedMs: Double
    let position: UInt64
    let matchedRows: Int
    let hasNextPage: Bool
    let completionMarker: String
}

/// Privacy-safe checkpoints for the long-running admission measurement. The
/// event carries only workload control-flow facts: never query text, row
/// content, item identifiers, or store paths (06 §9; V1-Verified G2/G8).
enum AdmissionProgressEvent: Sendable, Equatable {
    case validationBegan
    case validationCompleted(elapsedMs: Double)
    case warmupBegan(index: Int, total: Int)
    case warmupCompleted(index: Int, total: Int, elapsedMs: Double)
    case sampleBegan(index: Int, total: Int)
    case sampleCompleted(index: Int, total: Int, elapsedMs: Double)
    case diagnosticRequestBegan
    case diagnosticRequestCompleted(elapsedMs: Double)
}

private struct AdmissionOpenSample: Codable, Sendable {
    let schemaVersion: UInt16
    let openLatencyMs: Double
    let validatedRows: Int?
    let validatedPages: Int?
}

/// Nearest-rank percentile over a non-empty sample. For N=101, p99 selects
/// rank 100 (the second-highest ordered sample), rather than interpolating an
/// unobserved latency. Raw samples remain in the fixture for re-analysis.
func nearestRankPercentile(
    _ values: [Double],
    percentile: Double
) -> Double {
    precondition(!values.isEmpty, "percentile requires at least one sample")
    precondition(
        (0...1).contains(percentile),
        "percentile must be inside the closed interval zero through one"
    )
    let ordered = values.sorted()
    if percentile == 0 {
        return ordered[0]
    }
    let rank = Int(ceil(percentile * Double(ordered.count)))
    return ordered[min(ordered.count - 1, rank - 1)]
}

func admissionPercentiles(_ samples: [Double]) -> AdmissionPercentiles {
    AdmissionPercentiles(
        p50Ms: nearestRankPercentile(samples, percentile: 0.50),
        p95Ms: nearestRankPercentile(samples, percentile: 0.95),
        p99Ms: nearestRankPercentile(samples, percentile: 0.99)
    )
}

func admissionPercentilesIfSampled(
    _ samples: [Double]
) -> AdmissionPercentiles? {
    guard !samples.isEmpty else {
        return nil
    }
    return admissionPercentiles(samples)
}

private func admissionProgressElapsedText(_ elapsedMs: Double) -> String {
    String(
        format: "%.3f",
        locale: Locale(identifier: "en_US_POSIX"),
        elapsedMs
    )
}

func admissionProgressLine(
    mode: AdmissionMode,
    event: AdmissionProgressEvent
) -> String {
    let prefix = "HistoryPerfRunner admission progress mode=\(mode.rawValue)"
    switch event {
    case .validationBegan:
        return "\(prefix) phase=validation state=begin"
    case let .validationCompleted(elapsedMs):
        return "\(prefix) phase=validation state=completed "
            + "elapsed_ms=\(admissionProgressElapsedText(elapsedMs))"
    case let .warmupBegan(index, total):
        return "\(prefix) phase=warmup index=\(index) total=\(total) state=begin"
    case let .warmupCompleted(index, total, elapsedMs):
        return "\(prefix) phase=warmup index=\(index) total=\(total) "
            + "state=completed elapsed_ms=\(admissionProgressElapsedText(elapsedMs))"
    case let .sampleBegan(index, total):
        return "\(prefix) phase=sample index=\(index) total=\(total) state=begin"
    case let .sampleCompleted(index, total, elapsedMs):
        return "\(prefix) phase=sample index=\(index) total=\(total) "
            + "state=completed elapsed_ms=\(admissionProgressElapsedText(elapsedMs))"
    case .diagnosticRequestBegan:
        return "\(prefix) phase=diagnostic-request state=begin"
    case let .diagnosticRequestCompleted(elapsedMs):
        return "\(prefix) phase=diagnostic-request state=completed "
            + "elapsed_ms=\(admissionProgressElapsedText(elapsedMs))"
    }
}

private func writeAdmissionProgress(
    mode: AdmissionMode,
    event: AdmissionProgressEvent
) {
    // FileHandle writes immediately even when the runner is piped through tee;
    // a timeout therefore leaves the last entered/completed checkpoint behind.
    try? FileHandle.standardError.write(
        contentsOf: Data("\(admissionProgressLine(mode: mode, event: event))\n".utf8)
    )
}

func measureAdmissionSamples(
    warmups: Int = admissionWarmupCount,
    samples: Int = admissionSampleCount,
    progress: ((AdmissionProgressEvent) -> Void)? = nil,
    operation: () async throws -> Void
) async throws -> [Double] {
    precondition(warmups >= 0)
    precondition(samples > 0)
    let clock = ContinuousClock()
    for index in 0..<warmups {
        progress?(.warmupBegan(index: index + 1, total: warmups))
        let start = clock.now
        try await operation()
        progress?(.warmupCompleted(
            index: index + 1,
            total: warmups,
            elapsedMs: durationToMs(start.duration(to: clock.now))
        ))
        await Task.yield()
    }

    var values: [Double] = []
    values.reserveCapacity(samples)
    for index in 0..<samples {
        progress?(.sampleBegan(index: index + 1, total: samples))
        let start = clock.now
        try await operation()
        let elapsedMs = durationToMs(start.duration(to: clock.now))
        values.append(elapsedMs)
        progress?(.sampleCompleted(
            index: index + 1,
            total: samples,
            elapsedMs: elapsedMs
        ))
        // Yield outside the measured interval so released facades/DTOs get a
        // scheduling opportunity without contaminating operation latency.
        await Task.yield()
    }
    return values
}

private func admissionMachineMetadata() -> MachineMetadata {
    let processInfo = ProcessInfo.processInfo
    return MachineMetadata(
        osVersion: processInfo.operatingSystemVersionString,
        architecture: commandOutput("/usr/bin/uname", arguments: ["-m"]),
        hardwareModel: commandOutput(
            "/usr/sbin/sysctl",
            arguments: ["-n", "hw.model"]
        ),
        processorModel: commandOutput(
            "/usr/sbin/sysctl",
            arguments: ["-n", "machdep.cpu.brand_string"]
        ),
        processorCount: processInfo.processorCount,
        physicalMemory: processInfo.physicalMemory
    )
}

private func admissionDate() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}

func admissionCapture(
    index: Int,
    profile: AdmissionProfile = .full
) -> ClipboardCapture {
    let prefix = Data("admission-row-\(index)-".utf8)
    let suffix = Data("-tail-\(index)".utf8)
    precondition(prefix.count + suffix.count <= profile.searchBodyBytes)

    // ASCII bytes are valid UTF-8 and make the durable search projection hit
    // its full 256 KiB bound. Build one row at a time so fixture preparation
    // retains O(bodyBytes), not O(rows × bodyBytes), in user-invisible setup.
    var body = Data(repeating: 0x78, count: profile.searchBodyBytes)
    body.replaceSubrange(0..<prefix.count, with: prefix)
    body.replaceSubrange(
        (body.count - suffix.count)..<body.count,
        with: suffix
    )
    return ClipboardCapture(
        representations: [CapturedRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: body
        )],
        origin: CopyOriginObservation(
            sourceApplication: "perf-admission",
            lineageHint: nil
        ),
        // One timestamp intentionally forces every recent-page boundary into
        // the UUID-tie exactness lane.
        observedAt: Date(timeIntervalSinceReferenceDate: 650_000_000)
    )
}

private func makeAdmissionFixture(
    mode: AdmissionMode,
    profile: AdmissionProfile = .full,
    sampleUnit: String,
    samples: [Double],
    setupWallTimeMs: Double? = nil,
    validation: [String: String],
    notes: [String]
) -> AdmissionFixture {
    precondition(samples.isEmpty == (setupWallTimeMs != nil))
    precondition(
        setupWallTimeMs.map { $0.isFinite && $0 > 0 } ?? true
    )
    return AdmissionFixture(
        schemaVersion: 2,
        mode: mode.rawValue,
        sampleUnit: sampleUnit,
        machine: admissionMachineMetadata(),
        swiftVersion: commandOutput(
            "/usr/bin/xcrun",
            arguments: ["swift", "--version"]
        ),
        date: admissionDate(),
        corpusRows: profile.retainedRows,
        bodyBytesPerRow: profile.searchBodyBytes,
        warmupCount: mode.isSetupFixture ? 0 : profile.warmupCount,
        setupWallTimeMs: setupWallTimeMs,
        rawSamplesMs: samples,
        percentiles: admissionPercentilesIfSampled(samples),
        validation: validation,
        notes: notes
    )
}

private func writeAdmissionFixture<Fixture: Encodable>(
    _ fixture: Fixture,
    to outputPath: String
) throws {
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(fixture).write(to: outputURL)
}

private func readAdmissionSeedFixture(
    from outputPath: String
) throws -> AdmissionSeedFixture {
    let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
    return try JSONDecoder().decode(AdmissionSeedFixture.self, from: data)
}

@discardableResult
func validateAdmissionSeedFixture(
    _ fixture: AdmissionSeedFixture,
    for mode: AdmissionMode,
    profile: AdmissionProfile
) throws -> AdmissionSeedFixture {
    guard let expectedSeedMode = mode.expectedSeedMode,
          fixture.schemaVersion == 1,
          fixture.mode == expectedSeedMode.rawValue,
          fixture.corpusRows == profile.retainedRows,
          fixture.bodyBytesPerRow == profile.searchBodyBytes,
          fixture.seededRows == profile.retainedRows - 1,
          fixture.seedBatchSize == SwiftDataHistory.performanceFixtureSeedBatchSize
    else {
        throw AdmissionError.unexpectedSeedFixture
    }
    let completeBatches = fixture.seededRows / fixture.seedBatchSize
    let partialBatch = fixture.seededRows % fixture.seedBatchSize == 0 ? 0 : 1
    guard fixture.seedTransactions == completeBatches + partialBatch,
          fixture.seedPosition == UInt64(fixture.seedTransactions),
          fixture.seedWallTimeMs.isFinite,
          fixture.seedWallTimeMs > 0
    else {
        throw AdmissionError.unexpectedSeedFixture
    }
    return fixture
}

private func seedAdmissionStore(
    storeURL: URL,
    outputPath: String,
    mode: AdmissionMode,
    profile: AdmissionProfile
) async throws {
    let clock = ContinuousClock()
    let seededRows = profile.retainedRows - 1
    let start = clock.now
    // This facade lives until the dedicated seed CLI process exits. Process
    // termination, not lexical scope, is the deterministic ModelContainer
    // teardown boundary before validation reopens the persistent store.
    let history = try await openStore(
        url: storeURL,
        maxUnpinned: profile.retainedRows
    )
    let seedReceipt = try await history.seedPerformanceFixture(
        rowCount: seededRows,
        makeCapture: { index in
            admissionCapture(index: index, profile: profile)
        },
        progress: { count in
            if count.isMultiple(of: 256) || count == seededRows {
                print("  batch-seeded \(count)/\(seededRows) rows")
            }
        }
    )
    let seedWallTimeMs = durationToMs(start.duration(to: clock.now))
    let expectedSeedTransactions = (
        seededRows + seedReceipt.batchSize - 1
    ) / seedReceipt.batchSize
    guard seedReceipt.retainedRows == seededRows,
          seedReceipt.transactionCount == expectedSeedTransactions,
          seedReceipt.position.rawValue == UInt64(seedReceipt.transactionCount)
    else {
        throw AdmissionError.unexpectedPage
    }

    let fixture = AdmissionSeedFixture(
        schemaVersion: 1,
        mode: mode.rawValue,
        corpusRows: profile.retainedRows,
        bodyBytesPerRow: profile.searchBodyBytes,
        seededRows: seedReceipt.retainedRows,
        seedTransactions: seedReceipt.transactionCount,
        seedBatchSize: seedReceipt.batchSize,
        seedPosition: seedReceipt.position.rawValue,
        seedWallTimeMs: seedWallTimeMs
    )
    try writeAdmissionFixture(fixture, to: outputPath)
}

private func prepareAdmissionStore(
    storeURL: URL,
    outputPath: String,
    mode: AdmissionMode,
    profile: AdmissionProfile
) async throws {
    let seedFixture = try validateAdmissionSeedFixture(
        readAdmissionSeedFixture(from: outputPath),
        for: mode,
        profile: profile
    )
    let seedPosition = ChangePosition(rawValue: seedFixture.seedPosition)
    guard let expectedCoalescePosition = seedPosition.successor(),
          let expectedInsertPosition = expectedCoalescePosition.successor()
    else {
        throw AdmissionError.unexpectedSeedFixture
    }

    // This invocation starts only after the seed process has exited. Public
    // captures therefore prove durable startup reconstruction without two
    // live CoreData coordinators sharing external-storage references.
    let clock = ContinuousClock()
    let validationStart = clock.now
    let history = try await openStore(
        url: storeURL,
        maxUnpinned: profile.retainedRows
    )
    let coalesceStart = clock.now
    let coalesceReceipt = try await history.perform(.capture(
        admissionCapture(index: 0, profile: profile)
    ))
    let coalesceWallTimeMs = durationToMs(
        coalesceStart.duration(to: clock.now)
    )
    guard case .committed(let coalesceCommit) = coalesceReceipt,
          case .coalesced = coalesceCommit.outcome
    else {
        throw AdmissionError.unexpectedPage
    }

    let insertStart = clock.now
    let insertReceipt = try await history.perform(.capture(
        admissionCapture(index: profile.retainedRows - 1, profile: profile)
    ))
    let insertWallTimeMs = durationToMs(insertStart.duration(to: clock.now))
    guard case .committed(let insertCommit) = insertReceipt,
          case .inserted = insertCommit.outcome
    else {
        throw AdmissionError.unexpectedPage
    }

    let page = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: profile.pageLimit)
    )
    guard expectedCoalescePosition == coalesceCommit.position,
          page.position == insertCommit.position,
          expectedInsertPosition == insertCommit.position
    else {
        throw AdmissionError.unexpectedPosition
    }
    guard page.rows.count == profile.pageLimit else {
        throw AdmissionError.unexpectedPage
    }
    let validationWallTimeMs = durationToMs(
        validationStart.duration(to: clock.now)
    )
    let setupWallTimeMs = seedFixture.seedWallTimeMs + validationWallTimeMs
    guard validationWallTimeMs.isFinite,
          validationWallTimeMs > 0,
          setupWallTimeMs.isFinite,
          setupWallTimeMs > 0
    else {
        throw AdmissionError.unexpectedSeedFixture
    }

    let fixture = makeAdmissionFixture(
        mode: mode,
        profile: profile,
        sampleUnit: "persistent-corpus-setup",
        samples: [],
        setupWallTimeMs: setupWallTimeMs,
        validation: [
            "firstPageRows": String(page.rows.count),
            "publicCoalesceWallTimeMs": String(coalesceWallTimeMs),
            "publicInsertWallTimeMs": String(insertWallTimeMs),
            "position": String(page.position.rawValue),
            "publicValidationCaptures": "2",
            "seedBatchSize": String(seedFixture.seedBatchSize),
            "seedPosition": String(seedFixture.seedPosition),
            "seedTransactions": String(seedFixture.seedTransactions),
            "seedWallTimeMs": String(seedFixture.seedWallTimeMs),
            "seededRows": String(seedFixture.seededRows),
            "validationWallTimeMs": String(validationWallTimeMs),
        ],
        notes: [
            "Setup is the sum of seed- and validation-process phase durations, never a percentile sample.",
            "The sum excludes the process-launch gap between those phases.",
            "All rows share one timestamp and carry the profile's full-bound search body.",
            "Bounded fixture batches use production preparation/codecs and the sole writer.",
            "A separate process performs public coalesce and insert validation.",
            "Pair this JSON with the workflow's seed and prepare peak-RSS records.",
        ]
    )
    try writeAdmissionFixture(fixture, to: outputPath)
}

private func traverseAdmissionRecent(
    _ history: SwiftDataHistory,
    validateUniqueIDs: Bool
) async throws -> (rows: Int, pages: Int, position: ChangePosition) {
    var cursor: HistoryPageCursor?
    var rowCount = 0
    var pageCount = 0
    var uniqueIDs: Set<HistoryItemID> = []
    var authoritativePosition: ChangePosition?

    repeat {
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: admissionPageLimit,
            after: cursor
        ))
        if let authoritativePosition {
            guard page.position == authoritativePosition else {
                throw AdmissionError.unexpectedPosition
            }
        } else {
            guard page.position.rawValue > 0 else {
                throw AdmissionError.unexpectedPosition
            }
            authoritativePosition = page.position
        }
        guard !page.rows.isEmpty else {
            throw AdmissionError.unexpectedPage
        }
        rowCount += page.rows.count
        pageCount += 1
        if validateUniqueIDs {
            for row in page.rows {
                guard uniqueIDs.insert(row.item.id).inserted else {
                    throw AdmissionError.unexpectedPage
                }
            }
        }
        cursor = page.next
        guard pageCount <= admissionRetainedRows / admissionPageLimit else {
            throw AdmissionError.unexpectedPage
        }
    } while cursor != nil

    guard let authoritativePosition,
          rowCount == admissionRetainedRows,
          pageCount == admissionRetainedRows / admissionPageLimit,
          !validateUniqueIDs || uniqueIDs.count == admissionRetainedRows
    else {
        throw AdmissionError.unexpectedPage
    }
    return (rowCount, pageCount, authoritativePosition)
}

private func measureAdmissionBrowseTies(
    storeURL: URL,
    outputPath: String
) async throws {
    let history = try await openStore(url: storeURL)
    let validation = try await traverseAdmissionRecent(
        history,
        validateUniqueIDs: true
    )

    var cursor: HistoryPageCursor?
    var operationCount = 0
    var sampledContinuationPages = 0
    var sampledFallbackBoundaries = 0
    let samples = try await measureAdmissionSamples {
        let isSample = operationCount >= admissionWarmupCount
        let isContinuation = cursor != nil
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: admissionPageLimit,
            after: cursor
        ))
        guard page.position == validation.position,
              page.rows.count == admissionPageLimit
        else {
            throw AdmissionError.unexpectedPage
        }
        if isSample {
            if isContinuation {
                sampledContinuationPages += 1
            }
            // Every non-final page has a 50/51 same-date boundary. The
            // production exactness guard must therefore take its bounded
            // fallback; the final page proves termination but has no boundary.
            if page.next != nil {
                sampledFallbackBoundaries += 1
            }
        }
        cursor = page.next
        operationCount += 1
    }
    guard sampledContinuationPages == 100,
          sampledFallbackBoundaries == 100
    else {
        throw AdmissionError.unexpectedPage
    }
    let fixture = makeAdmissionFixture(
        mode: .browseTies,
        sampleUnit: "public-browse-page",
        samples: samples,
        validation: [
            "fallbackBoundarySamples": String(sampledFallbackBoundaries),
            "pagesPerTraversal": String(validation.pages),
            "position": String(validation.position.rawValue),
            "rowsPerTraversal": String(validation.rows),
            "sampledContinuationPages": String(sampledContinuationPages),
            "sampledPages": String(samples.count),
            "uniqueRows": String(admissionRetainedRows),
        ],
        notes: [
            "One untimed complete traversal validates 5,000 unique rows across 100 pages.",
            "Each timed sample is one public page call, matching G2's browse-page p95 unit.",
            "All rows share lastCopiedAt; every non-final 50-row boundary "
                + "structurally forces the UUID-tie fallback.",
            "Pair this JSON with browse-ties.time for process peak RSS.",
        ]
    )
    try writeAdmissionFixture(fixture, to: outputPath)
}

private func admissionExactSearchRequest() -> HistoryBrowseRequest {
    HistoryBrowseRequest(
        kind: .search(
            text: "term-that-does-not-exist-in-the-admission-corpus",
            mode: .exact
        ),
        limit: admissionPageLimit
    )
}

private func measureAdmissionExactSearchProbe(
    storeURL: URL,
    outputPath: String
) async throws {
    #if DEBUG
    guard ProcessInfo.processInfo.environment["CLIPY_SEARCH_TRACE"] == "1" else {
        throw AdmissionError.diagnosticConfigurationMissing
    }

    let history = try await openStore(url: storeURL)
    let request = admissionExactSearchRequest()
    let clock = ContinuousClock()
    writeAdmissionProgress(
        mode: .exactSearchProbe,
        event: .diagnosticRequestBegan
    )
    let start = clock.now
    let page = try await history.browse(request)
    let elapsedMs = durationToMs(start.duration(to: clock.now))
    guard elapsedMs.isFinite,
          elapsedMs > 0,
          page.position.rawValue > 0,
          page.rows.isEmpty,
          page.next == nil
    else {
        throw AdmissionError.unexpectedPage
    }
    writeAdmissionProgress(
        mode: .exactSearchProbe,
        event: .diagnosticRequestCompleted(elapsedMs: elapsedMs)
    )
    try writeAdmissionFixture(AdmissionExactSearchProbeFixture(
        schemaVersion: 1,
        mode: AdmissionMode.exactSearchProbe.rawValue,
        evidenceClass: "debug-diagnostic",
        buildConfiguration: "debug",
        traceEnvironmentEnabled: true,
        canonicalPercentileEvidence: false,
        publicRequestCount: 1,
        corpusRows: admissionRetainedRows,
        bodyBytesPerRow: admissionSearchBodyBytes,
        elapsedMs: elapsedMs,
        position: page.position.rawValue,
        matchedRows: page.rows.count,
        hasNextPage: page.next != nil,
        completionMarker: "single-public-exact-search-completed"
    ), to: outputPath)
    #else
    _ = storeURL
    _ = outputPath
    throw AdmissionError.diagnosticConfigurationMissing
    #endif
}

private func measureAdmissionExactSearch(
    storeURL: URL,
    outputPath: String
) async throws {
    let history = try await openStore(url: storeURL)
    let request = admissionExactSearchRequest()
    let clock = ContinuousClock()
    writeAdmissionProgress(mode: .exactSearch, event: .validationBegan)
    let validationStart = clock.now
    let validationPage = try await history.browse(request)
    guard validationPage.position.rawValue > 0,
          validationPage.rows.isEmpty,
          validationPage.next == nil
    else {
        throw AdmissionError.unexpectedPage
    }
    writeAdmissionProgress(
        mode: .exactSearch,
        event: .validationCompleted(
            elapsedMs: durationToMs(validationStart.duration(to: clock.now))
        )
    )

    let samples = try await measureAdmissionSamples(progress: { event in
        writeAdmissionProgress(mode: .exactSearch, event: event)
    }) {
        let page = try await history.browse(request)
        guard page.position == validationPage.position,
              page.rows.isEmpty,
              page.next == nil
        else {
            throw AdmissionError.unexpectedPage
        }
    }
    let fixture = makeAdmissionFixture(
        mode: .exactSearch,
        sampleUnit: "public-exact-search-request",
        samples: samples,
        validation: [
            "matchedRows": "0",
            "position": String(validationPage.position.rawValue),
        ],
        notes: [
            "Each public search snapshots 5,000 inline 256 KiB searchBody projections before exact evaluation.",
            "The absent term forces a complete bounded-corpus scan without result DTO retention.",
            "Peak RSS is a worst-bound process high-water ceiling, not "
                + "transient-hydration attribution or representative "
                + "concurrent-DTO G8 evidence.",
            "Pair this JSON with exact-search.time; no G2 or G8 budget is inferred.",
        ]
    )
    try writeAdmissionFixture(fixture, to: outputPath)
}

private func measureAdmissionOpenOnce(
    storeURL: URL,
    outputPath: String,
    validateCorpus: Bool
) async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let history = try await openStore(url: storeURL)
    let elapsed = durationToMs(start.duration(to: clock.now))

    // The one untimed warmup process validates the corpus after measuring its
    // discarded open. Timed processes do no post-open read before exit, so
    // their latency and RSS remain attributable to the open construct.
    let validation: (rows: Int, pages: Int, position: ChangePosition)?
    if validateCorpus {
        validation = try await traverseAdmissionRecent(
            history,
            validateUniqueIDs: true
        )
    } else {
        validation = nil
    }

    let sample = AdmissionOpenSample(
        schemaVersion: 1,
        openLatencyMs: elapsed,
        validatedRows: validation?.rows,
        validatedPages: validation?.pages
    )
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(sample).write(to: outputURL)
}

private func summarizeAdmissionWarmOpen(
    samplesDirectoryURL: URL,
    outputPath: String
) async throws {
    let sampleURLs = try FileManager.default.contentsOfDirectory(
        at: samplesDirectoryURL,
        includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard sampleURLs.count == admissionSampleCount + admissionWarmupCount else {
        throw AdmissionError.unexpectedPage
    }

    let decoder = JSONDecoder()
    let openSamples = try sampleURLs.map { url in
        try decoder.decode(AdmissionOpenSample.self, from: Data(contentsOf: url))
    }
    guard openSamples.allSatisfy({
        $0.schemaVersion == 1
            && $0.openLatencyMs.isFinite
            && $0.openLatencyMs > 0
    }) else {
        throw AdmissionError.unexpectedPosition
    }
    guard openSamples.first?.validatedRows == admissionRetainedRows,
          openSamples.first?.validatedPages
            == admissionRetainedRows / admissionPageLimit,
          openSamples.dropFirst().allSatisfy({
              $0.validatedRows == nil && $0.validatedPages == nil
          })
    else {
        throw AdmissionError.unexpectedPage
    }
    let samples = openSamples.dropFirst(admissionWarmupCount).map(\.openLatencyMs)
    let fixture = makeAdmissionFixture(
        mode: .warmOpen,
        sampleUnit: "public-persistent-open",
        samples: Array(samples),
        validation: [
            "independentProcesses": String(openSamples.count),
            "pagesPerValidationTraversal": String(
                admissionRetainedRows / admissionPageLimit
            ),
            "rowsPerValidationTraversal": String(admissionRetainedRows),
            "timedProcesses": String(samples.count),
        ],
        notes: [
            "Each sample runs one public persistent open in a fresh child "
                + "process; process exit supplies deterministic teardown.",
            "The OS page cache remains warm, so this is not a cold-start fixture.",
            "The recorded GitHub runner is not an approved minimum-hardware "
                + "profile; these latencies cannot alone trigger G5.",
            "Pair this JSON with per-process time files for peak RSS.",
            "This is neither crash-durability nor fsync evidence.",
        ]
    )
    try writeAdmissionFixture(fixture, to: outputPath)
}

/// Runs one dispatch-only admission mode. Arguments are exactly:
/// `<mode> <store.sqlite> <fixture.json>`.
/// Seed modes write a handoff fixture; the matching prepare mode consumes and
/// replaces that same path with the final setup fixture.
func runAdmission(arguments: [String]) async -> Int {
    guard let rawMode = arguments.first,
          let mode = AdmissionMode(rawValue: rawMode) else {
        print("HistoryPerfRunner admission: invalid arguments")
        return 2
    }
    guard arguments.count == (mode == .warmOpen ? 4 : 3) else {
        print("HistoryPerfRunner admission: invalid arguments")
        return 2
    }

    do {
        let storeURL = URL(fileURLWithPath: arguments[1])
        let storeExists = FileManager.default.fileExists(atPath: storeURL.path)
        if mode.createsStore, storeExists {
            throw AdmissionError.storeAlreadyExists
        }
        if !mode.createsStore, !storeExists {
            throw AdmissionError.storeMissing
        }
        print("HistoryPerfRunner admission: starting \(mode.rawValue)")
        switch mode {
        case .seed, .seedSmoke:
            try await seedAdmissionStore(
                storeURL: storeURL,
                outputPath: arguments[2],
                mode: mode,
                profile: mode.profile
            )
        case .prepare, .prepareSmoke:
            try await prepareAdmissionStore(
                storeURL: storeURL,
                outputPath: arguments[2],
                mode: mode,
                profile: mode.profile
            )
        case .browseTies:
            try await measureAdmissionBrowseTies(
                storeURL: storeURL,
                outputPath: arguments[2]
            )
        case .exactSearch:
            try await measureAdmissionExactSearch(
                storeURL: storeURL,
                outputPath: arguments[2]
            )
        case .exactSearchProbe:
            try await measureAdmissionExactSearchProbe(
                storeURL: storeURL,
                outputPath: arguments[2]
            )
        case .openOnce:
            try await measureAdmissionOpenOnce(
                storeURL: storeURL,
                outputPath: arguments[2],
                validateCorpus: false
            )
        case .openOnceAndValidate:
            try await measureAdmissionOpenOnce(
                storeURL: storeURL,
                outputPath: arguments[2],
                validateCorpus: true
            )
        case .warmOpen:
            try await summarizeAdmissionWarmOpen(
                samplesDirectoryURL: URL(fileURLWithPath: arguments[2]),
                outputPath: arguments[3]
            )
        }
        print("HistoryPerfRunner admission: completed \(mode.rawValue)")
        return 0
    } catch {
        print("HistoryPerfRunner admission: failed \(mode.rawValue): \(error)")
        return 1
    }
}
