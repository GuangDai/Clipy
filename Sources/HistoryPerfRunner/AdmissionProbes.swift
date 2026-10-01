/// Exact-search probe and warm/cold open measurements.
/// Split out of Admission.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryStorage

func measureAdmissionExactSearchProbe(
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

func measureAdmissionExactSearch(
    storeURL: URL,
    outputPath: String
) async throws {
    try await measureAdmissionNoHitSearch(
        storeURL: storeURL, outputPath: outputPath,
        mode: .exactSearch, request: admissionExactSearchRequest(), expectedScannedRows: nil,
        notes: [
            "The historical absent term is retained for comparison. Necessary-gram indexing can reject it without decoding the whole corpus; this is not full-scan evidence.",
            "Request-local decoded/evaluated rows accompany every latency sample. SQLite posting-list and planner work are outside these row counters.",
        ]
    )
}

func measureAdmissionExactScan(
    storeURL: URL,
    outputPath: String
) async throws {
    try await measureAdmissionNoHitSearch(
        storeURL: storeURL, outputPath: outputPath,
        mode: .exactScan, request: admissionExactScanRequest(), expectedScannedRows: admissionRetainedRows,
        notes: [
            "The negative query retains every fixture candidate. Each validation, warmup and sample must decode and evaluate all 5,000 rows with no result, or the workload fails instead of claiming a complete scan.",
            "This measures full-candidate projection reads and exact evaluation with bounded batches, not a single in-memory corpus snapshot or a proven slowest possible matcher input.",
        ]
    )
}

func validateAdmissionNoHitSearch(
    _ measured: MeasuredSearchPage,
    expectedPosition: ChangePosition? = nil,
    expectedScannedRows: Int? = nil
) throws -> HistoryPage {
    let page = try measured.result.get()
    guard page.position.rawValue > 0,
          expectedPosition.map({ page.position == $0 }) ?? true,
          page.rows.isEmpty, page.next == nil else {
        throw AdmissionError.unexpectedPage
    }
    if let expectedScannedRows {
        guard measured.metrics.rowsDecoded == expectedScannedRows,
              measured.metrics.rowsEvaluated == expectedScannedRows,
              measured.metrics.matchesFound == 0,
              measured.metrics.batchCount > 0,
              measured.metrics.stopReason == .exhausted else {
            throw AdmissionError.unexpectedPage
        }
    }
    return page
}

private func measureAdmissionNoHitSearch(
    storeURL: URL,
    outputPath: String,
    mode: AdmissionMode,
    request: HistoryBrowseRequest,
    expectedScannedRows: Int?,
    notes: [String]
) async throws {
    let history = try await openStore(url: storeURL)
    let clock = ContinuousClock()
    writeAdmissionProgress(mode: mode, event: .validationBegan)
    let validationStart = clock.now
    let validation = await history.measureSearch(request)
    let validationPage = try validateAdmissionNoHitSearch(validation, expectedScannedRows: expectedScannedRows)
    writeAdmissionProgress(
        mode: mode,
        event: .validationCompleted(
            elapsedMs: durationToMs(validationStart.duration(to: clock.now))
        )
    )

    var work: [SQLiteScaleSearchWork] = []
    let samples = try await measureAdmissionSamples(
        warmups: admissionExactSearchWarmupCount,
        samples: admissionExactSearchSampleCount,
        progress: { event in
            writeAdmissionProgress(mode: mode, event: event)
        }
    ) {
        let measured = await history.measureSearch(request)
        _ = try validateAdmissionNoHitSearch(
            measured, expectedPosition: validationPage.position, expectedScannedRows: expectedScannedRows
        )
        work.append(SQLiteScaleSearchWork(measured.metrics))
    }
    let fixture = makeAdmissionFixture(
        mode: mode,
        sampleUnit: "production-exact-search-request",
        samples: samples,
        validation: [
            "matchedRows": "0",
            "position": String(validationPage.position.rawValue),
            "rowsDecoded": String(validation.metrics.rowsDecoded),
            "rowsEvaluated": String(validation.metrics.rowsEvaluated),
        ],
        notes: notes + [
            "11 timed samples follow one warmup and a separate validation. Only p50 is supported; p95/p99 are omitted instead of reporting the sample maximum.",
            "Peak RSS is the whole-process high-water mark, not per-query transient allocation or concurrent DTO ownership.",
            "Pair this JSON with its matching time file; no absolute product budget is inferred.",
        ],
        searchWork: Array(work.dropFirst(admissionExactSearchWarmupCount))
    )
    try writeAdmissionFixture(fixture, to: outputPath)
}

func measureAdmissionOpenOnce(
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

func summarizeAdmissionWarmOpen(
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
