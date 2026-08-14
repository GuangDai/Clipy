import Foundation
import HistoryCore
import HistoryStorage

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

/// Record-only Release A/B for IND-07's scalar matcher baseline. It never
/// opens SwiftData and cannot be used as G2/G8 or candidate-index evidence.
struct AdmissionExactMatcherABFixture: Codable, Sendable {
    let schemaVersion: UInt16
    let mode: String
    let evidenceClass: String
    let machine: MachineMetadata
    let swiftVersion: String
    let date: String
    let bodiesPerSample: Int
    let bodyBytes: Int
    let warmupCount: Int
    let sampleCount: Int
    let constructionsPerSample: Int
    let productionIntegrationEligible: Bool
    let scopeLimitations: [String]
    let cases: [AdmissionExactMatcherABCase]
}

struct AdmissionExactMatcherABCase: Codable, Sendable {
    let name: String
    let decisionClass: String
    let maximumPairedMedianRatio: Double
    let termUTF8Bytes: Int
    let logicalBytesPerSample: Int
    let foundationRawSamplesMs: [Double]
    let compiledRawSamplesMs: [Double]
    let pairedRawRatios: [Double]
    let foundationMedianMs: Double
    let compiledMedianMs: Double
    let compiledToFoundationRatio: Double
    let pairedMedianRatio: Double
    let pairedP25Ratio: Double
    let pairedP75Ratio: Double
    let passesDecisionThreshold: Bool
    let compiledConstructionRawSamplesMs: [Double]
    let compiledConstructionMedianMs: Double
    let checksum: UInt64
}

/// Privacy-safe checkpoints for the long-running admission measurement. The
/// event carries only workload control-flow facts: never query text, row
/// content, item identifiers, or store paths (06 §9; V1-Verified G2/G8).
enum AdmissionPreparationPhase: String, Sendable, Equatable {
    case openStore = "open-store"
    case publicCoalesce = "public-coalesce"
    case publicInsert = "public-insert"
    case recentBrowse = "recent-browse"
}

enum AdmissionProgressEvent: Sendable, Equatable {
    case preparationPhaseBegan(AdmissionPreparationPhase)
    case preparationPhaseCompleted(
        AdmissionPreparationPhase,
        elapsedMs: Double
    )
    case validationBegan
    case validationCompleted(elapsedMs: Double)
    case warmupBegan(index: Int, total: Int)
    case warmupCompleted(index: Int, total: Int, elapsedMs: Double)
    case sampleBegan(index: Int, total: Int)
    case sampleCompleted(index: Int, total: Int, elapsedMs: Double)
    case diagnosticRequestBegan
    case diagnosticRequestCompleted(elapsedMs: Double)
}

struct AdmissionOpenSample: Codable, Sendable {
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

