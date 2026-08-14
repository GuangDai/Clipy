import Foundation
import HistoryCore
import HistoryStorage

// MARK: - Fixture types (docs/06-cross-cutting.md §9)

/// Machine context that must accompany any recorded perf fixture
/// (docs/06-cross-cutting.md §9: "machine metadata").
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
    /// The §9 bullet(s) this workload proves (e.g. "1-2").
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
    /// Human-readable note (spec citations, explanation).
    let note: String
    /// Store medium (Part V §2): `.memory` for algorithmic workloads,
    /// `.persistent` for bullet 3's durable reopen. Recorded per §9's
    /// "recorded fixtures" requirement. `var` so Codable decodes it and the
    /// memberwise initializer accepts the `.persistent` override.
    var medium: String = ".memory"
}

/// The complete fixture document written as JSON.
struct PerfFixture: Codable, Sendable {
    let schemaVersion: UInt16
    let machine: MachineMetadata
    let swiftVersion: String
    let date: String
    let workloads: [WorkloadFixture]
    /// Empty only when every required Part VI §9 bullet retains its named
    /// workload/label and every gated workload has a valid scale/bound/headroom
    /// declaration.
    let coverageIssues: [String]
}

/// One declarative entry in the Part VI §9 workload-coverage map. Keeping
/// the label beside its semantic bullet set makes a workload deletion, rename,
/// or free-form label drift machine-detectable instead of a documentation-only
/// promise (V1-Verified/04 `perf-helpers-no-unit-tests-and-no-coverage-map`).
struct WorkloadCoverageExpectation: Sendable {
    let bulletLabel: String
    let bulletNumbers: Set<Int>
}

/// The expected asymptotic response to the dimension varied by a workload.
/// A linear workload's theoretical ratio is its large/small scale span; a
/// constant workload should remain independent of that span and therefore has
/// a theoretical ratio of one (docs/06-cross-cutting.md §9).
enum WorkloadGrowthExpectation: Sendable {
    case constant
    case linear
}

/// The minimum noise headroom allowed above a workload's theoretical ratio.
/// The general floor is 1.5×. WL1a alone uses the named 1.2× exception because
/// its sanctioned O(retained-scalar) inventory load makes the measured ratio
/// approach the full 5× retained-count span; widening to 7.5× would weaken the
/// gate's ability to reject super-linear capture work (V1-Verified/04).
enum WorkloadHeadroomPolicy: Sendable {
    case standard
    case wl1aRetainedInventoryException

    var minimumFactor: Double {
        switch self {
        case .standard:
            return 1.5
        case .wl1aRetainedInventoryException:
            return 1.2
        }
    }
}

/// Declarative complexity envelope for one gated workload. Measurement code
/// consumes these scales and bounds directly; the structural validator proves
/// positive increasing scales, derives the span/theoretical ratio, and checks
/// the applicable headroom floor before any expensive workload runs.
struct WorkloadComplexityEnvelope: Sendable {
    let measurementScales: [Int]
    let growth: WorkloadGrowthExpectation
    let bound: Double
    let headroomPolicy: WorkloadHeadroomPolicy

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

let requiredSection9Bullets = Set(1...9)

let section9WorkloadCoverage: [String: WorkloadCoverageExpectation] = [
    "captureScalesWithRetainedCount": WorkloadCoverageExpectation(
        bulletLabel: "1-2",
        bulletNumbers: [1, 2]
    ),
    "captureScalesWithIncomingBytes": WorkloadCoverageExpectation(
        bulletLabel: "1-2",
        bulletNumbers: [1, 2]
    ),
    "persistentStoreOpenScalesWithRetainedMetadata": WorkloadCoverageExpectation(
        bulletLabel: "3",
        bulletNumbers: [3]
    ),
    "pinReorderLinearInPinnedCount": WorkloadCoverageExpectation(
        bulletLabel: "4",
        bulletNumbers: [4]
    ),
    "retentionMassEviction": WorkloadCoverageExpectation(
        bulletLabel: "5",
        bulletNumbers: [5]
    ),
    "clearUnpinned": WorkloadCoverageExpectation(
        bulletLabel: "5",
        bulletNumbers: [5]
    ),
    "recentBrowseIndependentOfRetainedCount": WorkloadCoverageExpectation(
        bulletLabel: "6",
        bulletNumbers: [6]
    ),
    "exactSearchScalesWithRetainedCount": WorkloadCoverageExpectation(
        bulletLabel: "7",
        bulletNumbers: [7]
    ),
    "fuzzySearchScalesWithRetainedCount": WorkloadCoverageExpectation(
        bulletLabel: "7",
        bulletNumbers: [7]
    ),
    "regexpSearchScalesWithRetainedCount": WorkloadCoverageExpectation(
        bulletLabel: "7",
        bulletNumbers: [7]
    ),
    "detailDecodeOneItem": WorkloadCoverageExpectation(
        bulletLabel: "8",
        bulletNumbers: [8]
    ),
    "pastePayloadDecodeOneItem": WorkloadCoverageExpectation(
        bulletLabel: "8",
        bulletNumbers: [8]
    ),
    "thumbnailSingleFlightSharesDecode": WorkloadCoverageExpectation(
        bulletLabel: "9",
        bulletNumbers: [9]
    ),
]

/// WL1b intentionally records incoming-byte scaling without enforcing a
/// numeric bound (§9 bullet 2). Every other declared workload has exactly one
/// machine-checked complexity envelope below.
let section9RecordOnlyWorkloads: Set<String> = [
    "captureScalesWithIncomingBytes",
]

/// The single source of truth for every gated workload's measurement scales,
/// expected asymptotic ratio, bound, and headroom policy. Workload bodies read
/// these values instead of repeating numeric literals.
let section9WorkloadEnvelopes: [String: WorkloadComplexityEnvelope] = [
    "captureScalesWithRetainedCount": WorkloadComplexityEnvelope(
        measurementScales: [200, 1_000],
        growth: .linear,
        bound: 6,
        headroomPolicy: .wl1aRetainedInventoryException
    ),
    "persistentStoreOpenScalesWithRetainedMetadata": WorkloadComplexityEnvelope(
        measurementScales: [200, 500, 1_000],
        growth: .linear,
        bound: 8,
        headroomPolicy: .standard
    ),
    "pinReorderLinearInPinnedCount": WorkloadComplexityEnvelope(
        measurementScales: [50, 200],
        growth: .linear,
        bound: 6,
        headroomPolicy: .standard
    ),
    "retentionMassEviction": WorkloadComplexityEnvelope(
        measurementScales: [100, 300],
        growth: .linear,
        bound: 6,
        headroomPolicy: .standard
    ),
    "clearUnpinned": WorkloadComplexityEnvelope(
        measurementScales: [100, 300],
        growth: .linear,
        bound: 6,
        headroomPolicy: .standard
    ),
    "recentBrowseIndependentOfRetainedCount": WorkloadComplexityEnvelope(
        measurementScales: [100, 400],
        growth: .constant,
        bound: 3,
        headroomPolicy: .standard
    ),
    "exactSearchScalesWithRetainedCount": WorkloadComplexityEnvelope(
        measurementScales: [100, 400],
        growth: .linear,
        bound: 8,
        headroomPolicy: .standard
    ),
    "fuzzySearchScalesWithRetainedCount": WorkloadComplexityEnvelope(
        measurementScales: [100, 400],
        growth: .linear,
        bound: 8,
        headroomPolicy: .standard
    ),
    "regexpSearchScalesWithRetainedCount": WorkloadComplexityEnvelope(
        measurementScales: [100, 400],
        growth: .linear,
        bound: 8,
        headroomPolicy: .standard
    ),
    "detailDecodeOneItem": WorkloadComplexityEnvelope(
        measurementScales: [100, 400],
        growth: .constant,
        bound: 3,
        headroomPolicy: .standard
    ),
    "pastePayloadDecodeOneItem": WorkloadComplexityEnvelope(
        measurementScales: [100, 400],
        growth: .constant,
        bound: 3,
        headroomPolicy: .standard
    ),
    "thumbnailSingleFlightSharesDecode": WorkloadComplexityEnvelope(
        measurementScales: [1, 8],
        growth: .constant,
        bound: 4,
        headroomPolicy: .standard
    ),
]

