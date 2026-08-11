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

let admissionRetainedRows = 5_000
let admissionSearchBodyBytes = 256 * 1_024
let admissionSampleCount = 101
let admissionWarmupCount = 1
let admissionPageLimit = 50

enum AdmissionMode: String, Sendable, Equatable {
    case prepare
    case browseTies = "browse-ties"
    case exactSearch = "exact-search"
    case openOnce = "open-once"
    case openOnceAndValidate = "open-once-and-validate"
    case warmOpen = "warm-open"
}

enum AdmissionError: Error, Sendable {
    case storeAlreadyExists
    case storeMissing
    case unexpectedPage
    case unexpectedPosition
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

func measureAdmissionSamples(
    warmups: Int = admissionWarmupCount,
    samples: Int = admissionSampleCount,
    operation: () async throws -> Void
) async throws -> [Double] {
    precondition(warmups >= 0)
    precondition(samples > 0)
    for _ in 0..<warmups {
        try await operation()
        await Task.yield()
    }

    let clock = ContinuousClock()
    var values: [Double] = []
    values.reserveCapacity(samples)
    for _ in 0..<samples {
        let start = clock.now
        try await operation()
        values.append(durationToMs(start.duration(to: clock.now)))
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

private func admissionCapture(index: Int) -> ClipboardCapture {
    let prefix = Data("admission-row-\(index)-".utf8)
    let suffix = Data("-tail-\(index)".utf8)
    precondition(prefix.count + suffix.count <= admissionSearchBodyBytes)

    // ASCII bytes are valid UTF-8 and make the durable search projection hit
    // its full 256 KiB bound. Build one row at a time so fixture preparation
    // retains O(bodyBytes), not O(rows × bodyBytes), in user-invisible setup.
    var body = Data(repeating: 0x78, count: admissionSearchBodyBytes)
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
        corpusRows: admissionRetainedRows,
        bodyBytesPerRow: admissionSearchBodyBytes,
        warmupCount: mode == .prepare ? 0 : admissionWarmupCount,
        setupWallTimeMs: setupWallTimeMs,
        rawSamplesMs: samples,
        percentiles: admissionPercentilesIfSampled(samples),
        validation: validation,
        notes: notes
    )
}

private func writeAdmissionFixture(
    _ fixture: AdmissionFixture,
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

private func prepareAdmissionStore(
    storeURL: URL,
    outputPath: String
) async throws {
    guard !FileManager.default.fileExists(atPath: storeURL.path) else {
        throw AdmissionError.storeAlreadyExists
    }
    let clock = ContinuousClock()
    let start = clock.now
    let history = try await openStore(
        url: storeURL,
        maxUnpinned: admissionRetainedRows
    )
    for index in 0..<admissionRetainedRows {
        _ = try await capturePreparedItem(
            history,
            capture: admissionCapture(index: index)
        )
        if (index + 1).isMultiple(of: 250) {
            print("  prepared \(index + 1)/\(admissionRetainedRows) rows")
        }
    }
    let elapsed = durationToMs(start.duration(to: clock.now))

    let page = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: admissionPageLimit)
    )
    guard page.position.rawValue == UInt64(admissionRetainedRows) else {
        throw AdmissionError.unexpectedPosition
    }
    guard page.rows.count == admissionPageLimit else {
        throw AdmissionError.unexpectedPage
    }

    let fixture = makeAdmissionFixture(
        mode: .prepare,
        sampleUnit: "persistent-corpus-setup",
        samples: [],
        setupWallTimeMs: elapsed,
        validation: [
            "firstPageRows": String(page.rows.count),
            "position": String(page.position.rawValue),
        ],
        notes: [
            "Setup is one wall-time observation, never a percentile sample.",
            "All rows share one timestamp and carry a full-bound 256 KiB search body.",
            "Pair this JSON with the workflow's prepare.time peak-RSS record.",
        ]
    )
    try writeAdmissionFixture(fixture, to: outputPath)
}

private func traverseAdmissionRecent(
    _ history: SwiftDataHistory,
    validateUniqueIDs: Bool
) async throws -> (rows: Int, pages: Int) {
    var cursor: HistoryPageCursor?
    var rowCount = 0
    var pageCount = 0
    var uniqueIDs: Set<HistoryItemID> = []

    repeat {
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: admissionPageLimit,
            after: cursor
        ))
        guard page.position.rawValue == UInt64(admissionRetainedRows) else {
            throw AdmissionError.unexpectedPosition
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

    guard rowCount == admissionRetainedRows,
          pageCount == admissionRetainedRows / admissionPageLimit,
          !validateUniqueIDs || uniqueIDs.count == admissionRetainedRows
    else {
        throw AdmissionError.unexpectedPage
    }
    return (rowCount, pageCount)
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
        guard page.position.rawValue == UInt64(admissionRetainedRows),
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

private func measureAdmissionExactSearch(
    storeURL: URL,
    outputPath: String
) async throws {
    let history = try await openStore(url: storeURL)
    let request = HistoryBrowseRequest(
        kind: .search(
            text: "term-that-does-not-exist-in-the-admission-corpus",
            mode: .exact
        ),
        limit: admissionPageLimit
    )
    let validationPage = try await history.browse(request)
    guard validationPage.position.rawValue == UInt64(admissionRetainedRows),
          validationPage.rows.isEmpty,
          validationPage.next == nil
    else {
        throw AdmissionError.unexpectedPage
    }

    let samples = try await measureAdmissionSamples {
        let page = try await history.browse(request)
        guard page.rows.isEmpty, page.next == nil else {
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
    let validation: (rows: Int, pages: Int)?
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
        if mode != .prepare,
           !FileManager.default.fileExists(atPath: storeURL.path) {
            throw AdmissionError.storeMissing
        }
        print("HistoryPerfRunner admission: starting \(mode.rawValue)")
        switch mode {
        case .prepare:
            try await prepareAdmissionStore(
                storeURL: storeURL,
                outputPath: arguments[2]
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
