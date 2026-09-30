import Foundation

// MARK: - Fixture types (docs/testing.md)

/// Machine context that must accompany any recorded perf fixture
/// (docs/testing.md: "machine metadata").
struct MachineMetadata: Codable, Sendable {
    let osVersion: String
    let architecture: String
    let hardwareModel: String
    let processorModel: String
    let processorCount: Int
    let physicalMemory: UInt64
}

/// One recorded workload measurement.
struct WorkloadFixture: Codable, Sendable {
    /// Deterministic workload key (e.g. captureScalesWithRetainedCount).
    let key: String
    /// Informational report grouping; it is not used to validate a workload.
    let bullet: String
    /// Human-readable size labels, one per measurement point.
    let sizes: [String]
    /// Median milliseconds per size point (1 warmup + 5 timed iterations).
    let mediansMs: [Double]
    /// A one-shot wall-clock construct when the workload compares a total
    /// concurrent duration against a sampled median. It is deliberately not
    /// mislabeled as a median (WL8).
    var wallTimeMs: Double? = nil
    /// large/small ratio (nil when N/A).
    let ratio: Double?
    /// Complexity bound (nil = record-only, no check).
    let bound: Double?
    /// Whether the complexity claim holds at this bound.
    let pass: Bool
    /// Interpretation and limits of the recorded measurement.
    let note: String
    /// Disposable or persistent storage used by the experiment.
    /// `var` lets the memberwise initializer override the default medium.
    var medium: String = ".temporary"
}

/// The complete fixture document written as JSON.
struct PerfFixture: Codable, Sendable {
    let schemaVersion: UInt16
    let machine: MachineMetadata
    let swiftVersion: String
    let date: String
    let workloads: [WorkloadFixture]
}

/// The expected asymptotic response to the dimension varied by a workload.
/// A linear workload's theoretical ratio is its large/small scale span; a
/// constant workload should remain independent of that span and therefore has
/// a theoretical ratio of one (docs/testing.md).
enum WorkloadGrowthExpectation: Sendable {
    case constant
    case linear
}

/// Measurement scales and the observed-ratio bound for one experiment.
/// Growth describes the varied dimension for the fixture's explanatory note;
/// it does not validate experiment names, labels, or declaration structure.
struct WorkloadComplexityEnvelope: Sendable {
    let measurementScales: [Int]
    let growth: WorkloadGrowthExpectation
    let bound: Double

    var scaleSpan: Double {
        guard let first = measurementScales.first,
              let last = measurementScales.last,
              first > 0
        else {
            return .nan
        }
        return Double(last) / Double(first)
    }

    var theoreticalRatio: Double {
        switch growth {
        case .constant:
            return 1
        case .linear:
            return scaleSpan
        }
    }

    var headroomFactor: Double {
        bound / theoreticalRatio
    }
}

/// Direct experiment settings. Scales and bounds are consumed by the
/// measurement bodies; adding or removing an experiment needs no coverage map.
let workloadEnvelopes: [String: WorkloadComplexityEnvelope] = [
    "captureScalesWithRetainedCount": WorkloadComplexityEnvelope(
        measurementScales: [200, 1_000],
        growth: .linear,
        bound: 6
    ),
    "persistentStoreOpenScalesWithRetainedMetadata": WorkloadComplexityEnvelope(
        measurementScales: [200, 500, 1_000],
        growth: .linear,
        bound: 8
    ),
    "pinReorderLinearInPinnedCount": WorkloadComplexityEnvelope(
        measurementScales: [50, 200],
        growth: .linear,
        bound: 6
    ),
    "retentionMassEviction": WorkloadComplexityEnvelope(
        measurementScales: [100, 300],
        growth: .linear,
        bound: 6
    ),
    "clearUnpinned": WorkloadComplexityEnvelope(
        measurementScales: [100, 300],
        growth: .linear,
        bound: 6
    ),
    "retentionExpansionCapture": WorkloadComplexityEnvelope(
        measurementScales: [100, 300],
        growth: .linear,
        bound: 6
    ),
    "retentionExpansionRevise": WorkloadComplexityEnvelope(
        measurementScales: [100, 300],
        growth: .linear,
        bound: 6
    ),
    "retentionPolicySweep": WorkloadComplexityEnvelope(
        measurementScales: [100, 300],
        growth: .linear,
        bound: 6
    ),
    "recentBrowseIndependentOfRetainedCount": WorkloadComplexityEnvelope(
        measurementScales: [100, 400],
        growth: .constant,
        bound: 3
    ),
    "exactSearchScalesWithRetainedCount": WorkloadComplexityEnvelope(
        measurementScales: [100, 400],
        growth: .linear,
        bound: 8
    ),
    "fuzzySearchScalesWithRetainedCount": WorkloadComplexityEnvelope(
        measurementScales: [100, 400],
        growth: .linear,
        bound: 8
    ),
    "regexpSearchScalesWithRetainedCount": WorkloadComplexityEnvelope(
        measurementScales: [100, 400],
        growth: .linear,
        bound: 8
    ),
    "detailDecodeOneItem": WorkloadComplexityEnvelope(
        measurementScales: [100, 400],
        growth: .constant,
        bound: 3
    ),
    "pastePayloadDecodeOneItem": WorkloadComplexityEnvelope(
        measurementScales: [100, 400],
        growth: .constant,
        bound: 3
    ),
    "thumbnailSingleFlightSharesDecode": WorkloadComplexityEnvelope(
        measurementScales: [1, 8],
        growth: .constant,
        bound: 4
    ),
]
