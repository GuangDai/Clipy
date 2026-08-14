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

    let samples = try await measureAdmissionSamples(
        warmups: admissionExactSearchWarmupCount,
        samples: admissionExactSearchSampleCount,
        progress: { event in
            writeAdmissionProgress(mode: .exactSearch, event: event)
        }
    ) {
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
            "IND-07 measurement budget: 11 samples (reduced from the 101-sample profile budget) because each absent-term request costs roughly 125 s; at n = 11 the nearest-rank p95 and p99 both select the sample maximum.",
            "Peak RSS is a worst-bound process high-water ceiling, not "
                + "transient-hydration attribution or representative "
                + "concurrent-DTO G8 evidence.",
            "Pair this JSON with exact-search.time; no G2 or G8 budget is inferred.",
        ]
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
