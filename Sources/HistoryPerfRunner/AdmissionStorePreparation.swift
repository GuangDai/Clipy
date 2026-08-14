/// Persistent admission-corpus seeding, preparation, and browse-tie measurement.
/// Split out of Admission.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryStorage

func seedAdmissionStore(
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

func prepareAdmissionStore(
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
    let openStart = clock.now
    writeAdmissionProgress(
        mode: mode,
        event: .preparationPhaseBegan(.openStore)
    )
    let history = try await openStore(
        url: storeURL,
        maxUnpinned: profile.retainedRows
    )
    writeAdmissionProgress(
        mode: mode,
        event: .preparationPhaseCompleted(
            .openStore,
            elapsedMs: durationToMs(openStart.duration(to: clock.now))
        )
    )
    let coalesceStart = clock.now
    writeAdmissionProgress(
        mode: mode,
        event: .preparationPhaseBegan(.publicCoalesce)
    )
    let coalesceReceipt = try await history.perform(.capture(
        admissionCapture(index: 0, profile: profile)
    ))
    let coalesceWallTimeMs = durationToMs(
        coalesceStart.duration(to: clock.now)
    )
    writeAdmissionProgress(
        mode: mode,
        event: .preparationPhaseCompleted(
            .publicCoalesce,
            elapsedMs: coalesceWallTimeMs
        )
    )
    guard case .committed(let coalesceCommit) = coalesceReceipt,
          case .coalesced = coalesceCommit.outcome
    else {
        throw AdmissionError.unexpectedPage
    }

    let insertStart = clock.now
    writeAdmissionProgress(
        mode: mode,
        event: .preparationPhaseBegan(.publicInsert)
    )
    let insertReceipt = try await history.perform(.capture(
        admissionCapture(index: profile.retainedRows - 1, profile: profile)
    ))
    let insertWallTimeMs = durationToMs(insertStart.duration(to: clock.now))
    writeAdmissionProgress(
        mode: mode,
        event: .preparationPhaseCompleted(
            .publicInsert,
            elapsedMs: insertWallTimeMs
        )
    )
    guard case .committed(let insertCommit) = insertReceipt,
          case .inserted = insertCommit.outcome
    else {
        throw AdmissionError.unexpectedPage
    }

    let recentStart = clock.now
    writeAdmissionProgress(
        mode: mode,
        event: .preparationPhaseBegan(.recentBrowse)
    )
    let page = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: profile.pageLimit)
    )
    writeAdmissionProgress(
        mode: mode,
        event: .preparationPhaseCompleted(
            .recentBrowse,
            elapsedMs: durationToMs(recentStart.duration(to: clock.now))
        )
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

func traverseAdmissionRecent(
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

func measureAdmissionBrowseTies(
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

func admissionExactSearchRequest() -> HistoryBrowseRequest {
    HistoryBrowseRequest(
        kind: .search(
            text: "term-that-does-not-exist-in-the-admission-corpus",
            mode: .exact
        ),
        limit: admissionPageLimit
    )
}

