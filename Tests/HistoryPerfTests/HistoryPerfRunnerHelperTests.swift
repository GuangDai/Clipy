/// Direct proofs for the pure HistoryPerfRunner measurement helpers and the
/// Part VI §9 workload coverage map (docs/06-cross-cutting.md §9;
/// V1-Verified/04 `perf-helpers-no-unit-tests-and-no-coverage-map`).
import Foundation
import Testing
@testable import HistoryPerfRunner

struct HistoryPerfRunnerHelperTests {
    @Test func medianUsesMiddleValueForOddSamples() {
        #expect(median([9, 1, 5]) == 5)
    }

    @Test func medianAveragesBothMiddleValuesForEvenSamples() {
        #expect(median([10, 2, 8, 4]) == 6)
    }

    @Test func safeRatioRejectsEveryNonPositiveMeasurement() {
        #expect(safeRatio(0, 1).isInfinite)
        #expect(safeRatio(-1, 1).isInfinite)
        #expect(safeRatio(1, 0).isInfinite)
        #expect(safeRatio(1, -1).isInfinite)
        #expect(safeRatio(0, 0).isInfinite)
        #expect(safeRatio(6, 2) == 3)
    }

    @Test func durationToMillisecondsPreservesFractionalMilliseconds() {
        let duration = Duration.seconds(2) + .milliseconds(250) + .microseconds(500)
        #expect(durationToMs(duration) == 2_250.5)
    }

    @Test func persistentOpenChildReportsOnlyOneInternalDuration() throws {
        let encoded = try encodePersistentOpenChildDuration(12.5)

        #expect(String(decoding: encoded, as: UTF8.self) == "12.5\n")
        #expect(try decodePersistentOpenChildDuration(encoded) == 12.5)
    }

    @Test func persistentOpenChildRejectsInvalidOrNoisyOutput() {
        let invalidOutputs = [
            Data(),
            Data("0\n".utf8),
            Data("-1\n".utf8),
            Data("nan\n".utf8),
            Data("12.5\n13.5\n".utf8),
            Data("HistoryPerfRunner: 12.5\n".utf8),
        ]

        for output in invalidOutputs {
            #expect(throws: PersistentOpenChildError.invalidMeasurement) {
                try decodePersistentOpenChildDuration(output)
            }
        }
    }

    @Test func persistentOpenWorkloadRunsPopulateWarmupAndFiveSamples() throws {
        var events: [String] = []
        var measurementCount = 0

        let samples = try runPersistentOpenChildSequence(populate: {
            events.append("populate")
        }, measure: {
            measurementCount += 1
            events.append("measure-\(measurementCount)")
            return Double(measurementCount)
        })

        #expect(persistentOpenChildSampleCount == 5)
        #expect(measurementCount == 6)
        #expect(events == [
            "populate",
            "measure-1",
            "measure-2",
            "measure-3",
            "measure-4",
            "measure-5",
            "measure-6",
        ])
        #expect(samples == [2, 3, 4, 5, 6])
    }

    @Test func persistentOpenChildFailureOutputCannotExposeStoreFacts() {
        let populate = String(
            decoding: persistentOpenChildFailureOutput(mode: .populate),
            as: UTF8.self
        )
        let measure = String(
            decoding: persistentOpenChildFailureOutput(mode: .measure),
            as: UTF8.self
        )

        #expect(populate == "HistoryPerfRunner WL2 child failed mode=populate\n")
        #expect(measure == "HistoryPerfRunner WL2 child failed mode=measure\n")
        #expect(!populate.contains("/"))
        #expect(!measure.contains("/"))
    }

    @Test func nearestRankPercentilesSelectObservedSamples() {
        let values = (1...101).reversed().map(Double.init)
        #expect(nearestRankPercentile(values, percentile: 0) == 1)
        #expect(nearestRankPercentile(values, percentile: 0.50) == 51)
        #expect(nearestRankPercentile(values, percentile: 0.95) == 96)
        #expect(nearestRankPercentile(values, percentile: 0.99) == 100)
        #expect(nearestRankPercentile(values, percentile: 1) == 101)
    }

    /// Nearest-rank percentiles are only reported when the sample count can
    /// select a rank BELOW the maximum: ceil(p·n) < n requires n ≥ 3 for p50
    /// (ceil(0.5·2) = 1… the 1st of 2 — supported at 3 for a non-degenerate
    /// median), n ≥ 20 for p95, and n ≥ 100 for p99. Below a threshold the
    /// rank encodes as JSON null instead of a disguised sample maximum —
    /// the 11-sample exact-search budget therefore reports p50 only.
    @Test func admissionPercentilesReportOnlySupportedRanks() {
        #expect(admissionP50MinimumSamples == 3)
        #expect(admissionP95MinimumSamples == 20)
        #expect(admissionP99MinimumSamples == 100)

        // 101 samples: every rank is supported and selects an interior
        // sample (p99 = the 100th of 101, not the max).
        let full = admissionPercentilesIfSupported((1...101).reversed().map(Double.init))
        #expect(full?.p50Ms == 51)
        #expect(full?.p95Ms == 96)
        #expect(full?.p99Ms == 100)

        // 100 samples: p99 selects the 99th (supported exactly at the floor).
        let hundred = admissionPercentilesIfSupported((1...100).map(Double.init))
        #expect(hundred?.p99Ms == 99)
        // 99 samples: p99 would select the maximum — unsupported.
        let ninetyNine = admissionPercentilesIfSupported((1...99).map(Double.init))
        #expect(ninetyNine?.p99Ms == nil)
        #expect(ninetyNine?.p95Ms != nil)

        // 20 samples: p95 selects the 19th (supported at the floor).
        let twenty = admissionPercentilesIfSupported((1...20).map(Double.init))
        #expect(twenty?.p95Ms == 19)
        #expect(twenty?.p99Ms == nil)
        // 19 samples: p95 would select the maximum — unsupported.
        let nineteen = admissionPercentilesIfSupported((1...19).map(Double.init))
        #expect(nineteen?.p95Ms == nil)
        #expect(nineteen?.p50Ms == 10)

        // 11 samples (the exact-search budget): p50 only.
        let eleven = admissionPercentilesIfSupported((1...11).map(Double.init))
        #expect(eleven?.p50Ms == 6)
        #expect(eleven?.p95Ms == nil)
        #expect(eleven?.p99Ms == nil)

        // Below the p50 floor nothing is reported.
        #expect(admissionPercentilesIfSupported([]) == nil)
        #expect(admissionPercentilesIfSupported([42]) == nil)
        #expect(admissionPercentilesIfSupported([1, 2]) == nil)
        // 3 samples: the first supported p50.
        #expect(admissionPercentilesIfSupported([3, 1, 2])?.p50Ms == 2)
    }

    @Test func admissionSampleProgressBracketsEveryOperation() async throws {
        var events: [AdmissionProgressEvent] = []
        var operationCount = 0

        let samples = try await measureAdmissionSamples(
            warmups: 2,
            samples: 3,
            progress: { events.append($0) }
        ) {
            operationCount += 1
        }

        #expect(operationCount == 5)
        #expect(samples.count == 3)
        #expect(events.count == 10)
        #expect(events[0] == .warmupBegan(index: 1, total: 2))
        #expect(Self.isCompletedWarmup(events[1], index: 1, total: 2))
        #expect(events[2] == .warmupBegan(index: 2, total: 2))
        #expect(Self.isCompletedWarmup(events[3], index: 2, total: 2))
        #expect(events[4] == .sampleBegan(index: 1, total: 3))
        #expect(Self.isCompletedSample(events[5], index: 1, total: 3))
        #expect(events[6] == .sampleBegan(index: 2, total: 3))
        #expect(Self.isCompletedSample(events[7], index: 2, total: 3))
        #expect(events[8] == .sampleBegan(index: 3, total: 3))
        #expect(Self.isCompletedSample(events[9], index: 3, total: 3))
    }

    @Test func admissionProgressLinesAreStructuredAndPrivacySafe() {
        let preparationPhases: [AdmissionPreparationPhase] = [
            .openStore,
            .publicCoalesce,
            .publicInsert,
            .recentBrowse,
        ]
        let expectedPhaseNames = [
            "open-store",
            "public-coalesce",
            "public-insert",
            "recent-browse",
        ]
        for (phase, expectedName) in zip(
            preparationPhases,
            expectedPhaseNames
        ) {
            #expect(admissionProgressLine(
                mode: .prepare,
                event: .preparationPhaseBegan(phase)
            ) == "HistoryPerfRunner admission progress mode=prepare "
                + "phase=\(expectedName) state=begin")
            #expect(admissionProgressLine(
                mode: .prepare,
                event: .preparationPhaseCompleted(
                    phase,
                    elapsedMs: 4_321.25
                )
            ) == "HistoryPerfRunner admission progress mode=prepare "
                + "phase=\(expectedName) state=completed elapsed_ms=4321.250")
        }
        #expect(admissionProgressLine(
            mode: .exactSearch,
            event: .validationBegan
        ) == "HistoryPerfRunner admission progress mode=exact-search "
            + "phase=validation state=begin")
        #expect(admissionProgressLine(
            mode: .exactSearch,
            event: .validationCompleted(elapsedMs: 12.5)
        ) == "HistoryPerfRunner admission progress mode=exact-search "
            + "phase=validation state=completed elapsed_ms=12.500")
        #expect(admissionProgressLine(
            mode: .exactSearch,
            event: .sampleCompleted(index: 9, total: 101, elapsedMs: 42.25)
        ) == "HistoryPerfRunner admission progress mode=exact-search "
            + "phase=sample index=9 total=101 state=completed elapsed_ms=42.250")

        let line = admissionProgressLine(
            mode: .exactSearch,
            event: .sampleBegan(index: 10, total: 101)
        )
        #expect(!line.contains("term-that-does-not-exist"))
        #expect(!line.contains("store.sqlite"))
        #expect(admissionProgressLine(
            mode: .exactSearchProbe,
            event: .diagnosticRequestCompleted(elapsedMs: 1_234.5)
        ) == "HistoryPerfRunner admission progress mode=exact-search-probe "
            + "phase=diagnostic-request state=completed elapsed_ms=1234.500")
    }

    @Test func exactSearchAdmissionUsesReducedSampleBudget() {
        // IND-07 measurement-budget freeze. Original basis: the absent-term
        // worst-bound scan cost ~125 s per request against the 5,000 × 256
        // KiB corpus (the Foundation-oracle diagnostic that opened IND-07),
        // so the 101-sample profile budget could not finish inside the
        // dispatch lane's 90-minute step ceiling. Re-baselined by
        // measurement: GOV-1 run 32685185124 recorded p50 2,666 ms per
        // request (11 samples, range 1,810–3,827 ms), at which 101 samples
        // would fit (103 × 3.8 s ≈ 7 min). The freeze stays at 11: the
        // fixture is record-only p50-trend evidence, and 13 requests still
        // fit in ≈27 min at the historical ~125 s Foundation-path cost if a
        // matcher regression restores it. At n = 11 the nearest-rank
        // p95/p99 fall below their 20/100-sample support floors and encode
        // as JSON null, which the fixture notes must state.
        #expect(admissionExactSearchWarmupCount == 1)
        #expect(admissionExactSearchSampleCount == 11)
    }

    @Test func admissionProfilesFreezeFullAndFailureReproductionShapes() {
        #expect(AdmissionProfile.full == AdmissionProfile(
            retainedRows: 5_000,
            searchBodyBytes: 256 * 1_024,
            sampleCount: 101,
            warmupCount: 1,
            pageLimit: 50
        ))
        #expect(AdmissionProfile.prepareSmoke == AdmissionProfile(
            retainedRows: 1_000,
            searchBodyBytes: 256 * 1_024,
            sampleCount: 0,
            warmupCount: 0,
            pageLimit: 50
        ))
        #expect(AdmissionMode.prepare.profile == .full)
        #expect(AdmissionMode.prepareSmoke.profile == .prepareSmoke)
        #expect(AdmissionMode.seed.profile == .full)
        #expect(AdmissionMode.seedSmoke.profile == .prepareSmoke)
        #expect(AdmissionMode.exactSearchProbe.profile == .full)
        #expect(AdmissionMode.exactMatcherAB.profile == .full)
        #expect(AdmissionMode.seed.createsStore)
        #expect(AdmissionMode.seedSmoke.createsStore)
        #expect(!AdmissionMode.prepare.createsStore)
        #expect(!AdmissionMode.prepareSmoke.createsStore)
        #expect(!AdmissionMode.browseTies.createsStore)
        #expect(!AdmissionMode.exactSearchProbe.createsStore)
        #expect(!AdmissionMode.exactMatcherAB.createsStore)
        #expect(AdmissionMode.prepare.expectedSeedMode == .seed)
        #expect(AdmissionMode.prepareSmoke.expectedSeedMode == .seedSmoke)
        #expect(AdmissionMode.seed.expectedSeedMode == nil)
        #expect(AdmissionMode.exactSearchProbe.expectedSeedMode == nil)
        #expect(AdmissionMode.exactMatcherAB.expectedSeedMode == nil)
        #expect(AdmissionMode.prepare.isSetupFixture)
        #expect(AdmissionMode.prepareSmoke.isSetupFixture)
        #expect(!AdmissionMode.seed.isSetupFixture)
        #expect(!AdmissionMode.exactMatcherAB.isSetupFixture)
    }

    @Test func exactSearchProbeFixtureIsExplicitlyNonCanonical() throws {
        let fixture = AdmissionExactSearchProbeFixture(
            schemaVersion: 1,
            mode: AdmissionMode.exactSearchProbe.rawValue,
            evidenceClass: "debug-diagnostic",
            buildConfiguration: "debug",
            traceEnvironmentEnabled: true,
            canonicalPercentileEvidence: false,
            publicRequestCount: 1,
            corpusRows: 5_000,
            bodyBytesPerRow: 256 * 1_024,
            elapsedMs: 1_234.5,
            position: 81,
            matchedRows: 0,
            hasNextPage: false,
            completionMarker: "single-public-exact-search-completed"
        )

        let encoded = try JSONEncoder().encode(fixture)
        #expect(try JSONDecoder().decode(
            AdmissionExactSearchProbeFixture.self,
            from: encoded
        ) == fixture)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("rawSamplesMs"))
        #expect(!json.contains("percentiles"))
        #expect(json.contains("canonicalPercentileEvidence"))
    }

    @Test func admissionSeedHandoffRoundTripsAndRejectsInvalidFacts() throws {
        let fixture = AdmissionSeedFixture(
            schemaVersion: 1,
            mode: AdmissionMode.seed.rawValue,
            corpusRows: 5_000,
            bodyBytesPerRow: 256 * 1_024,
            seededRows: 4_999,
            seedTransactions: 79,
            seedBatchSize: 64,
            seedPosition: 79,
            seedWallTimeMs: 42
        )

        let encoded = try JSONEncoder().encode(fixture)
        let decoded = try JSONDecoder().decode(
            AdmissionSeedFixture.self,
            from: encoded
        )
        #expect(decoded == fixture)
        #expect(try validateAdmissionSeedFixture(
            decoded,
            for: .prepare,
            profile: .full
        ) == fixture)

        let wrongMode = AdmissionSeedFixture(
            schemaVersion: fixture.schemaVersion,
            mode: AdmissionMode.seedSmoke.rawValue,
            corpusRows: fixture.corpusRows,
            bodyBytesPerRow: fixture.bodyBytesPerRow,
            seededRows: fixture.seededRows,
            seedTransactions: fixture.seedTransactions,
            seedBatchSize: fixture.seedBatchSize,
            seedPosition: fixture.seedPosition,
            seedWallTimeMs: fixture.seedWallTimeMs
        )
        #expect(throws: AdmissionError.unexpectedSeedFixture) {
            try validateAdmissionSeedFixture(
                wrongMode,
                for: .prepare,
                profile: .full
            )
        }

        let wrongBatch = AdmissionSeedFixture(
            schemaVersion: fixture.schemaVersion,
            mode: fixture.mode,
            corpusRows: fixture.corpusRows,
            bodyBytesPerRow: fixture.bodyBytesPerRow,
            seededRows: fixture.seededRows,
            seedTransactions: 40,
            seedBatchSize: 128,
            seedPosition: 40,
            seedWallTimeMs: fixture.seedWallTimeMs
        )
        #expect(throws: AdmissionError.unexpectedSeedFixture) {
            try validateAdmissionSeedFixture(
                wrongBatch,
                for: .prepare,
                profile: .full
            )
        }
    }

}
