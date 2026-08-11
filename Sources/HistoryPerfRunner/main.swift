/// HistoryPerfRunner — release-like performance runner for the Part VI §9
/// performance proofs (docs/06-cross-cutting.md §9). Drives the PUBLIC
/// ClipboardHistory surface via the production SwiftDataHistory facade. Each
/// workload records fixture data (medians, complexity ratios, bounds) and
/// exits non-zero if any complexity check fails.
///
/// Acceptance (docs/06-cross-cutting.md §9; docs/roadmap/README.md §3 step 8):
/// the proofs are COMPLEXITY claims, not latency targets — "No numeric latency
/// target in a future PR may be declared satisfied by the current repository's
/// implementation" (§9). General complexity bounds keep at least 1.5× the
/// theoretical linear ratio. WL1a is the explicit exception: capture's
/// sanctioned O(retained-scalar) inventory load makes its ratio approach the
/// 5× corpus span, so its 6× bound deliberately keeps 1.2× headroom to
/// reject super-linear work instead of widening past quadratic sensitivity.
/// Machine metadata accompanies every fixture (§9: "recorded fixtures and
/// machine metadata").
///
/// Store medium: §9 measures algorithmic complexity (rows/bytes scaling), not
/// durability. Workloads that never reopen durable state run on `.memory`
/// stores — Part V §2 states `.memory` changes the durability medium only and
/// uses the same Authority, planners, codecs, and transaction path — so the
/// measured algorithm is identical without paying per-commit fsync during
/// (untimed) population. Bullet 3 measures the complete warm persistent-open
/// construct, whose startup includes Signature Index rebuild, and therefore
/// uses `.persistent` stores. Each fixture records its medium.
///
/// Fixture sizes: §9 pins complexity envelopes, not absolute sizes. The 5,000
/// retained-item value is the hard bound, not a required per-PR measurement
/// size or an absolute-latency claim.
/// Population counts stay well below that cap and retained-corpus spans are
/// 3×-5×; WL8 separately compares concurrency widths 1→8. Every bound keeps at
/// least 1.5× headroom over its declared linear/constant theoretical ratio
/// except WL1a's documented asymptotic-inventory exception above, so each proof
/// keeps its intended sensitivity while the suite fits the CI wall-clock budget.
///
/// Import confinement (Part I §8): the runner imports Foundation, HistoryCore,
/// and HistoryStorage — HistoryStorage was added to the HistoryPerfRunner
/// allowlist because the runner drives the public SwiftDataHistory concrete
/// facade. WL8 additionally uses the package-only `ThumbnailService` proof
/// seam so it measures single-flight decode sharing without conflating the
/// Authority's intentionally serialized source-fetch prefix.
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

// MARK: - Errors

/// Internal runner errors (not HistoryFailure; never crosses the History seam).
enum PerfError: Error, Sendable {
    case captureUnexpectedOutcome
}

// MARK: - Measurement helpers

/// Converts a Duration to milliseconds as a Double (sub-ms precision).
func durationToMs(_ duration: Duration) -> Double {
    let attosecondsPerMillisecond = 1_000_000_000_000_000.0
    let components = duration.components
    return Double(components.seconds) * 1_000.0
         + Double(components.attoseconds) / attosecondsPerMillisecond
}

/// Median of a non-empty array of doubles. Even-sized samples use the mean of
/// the two central values; WL8 intentionally records eight sequential calls,
/// so selecting only the upper middle would bias its baseline upward.
func median(_ values: [Double]) -> Double {
    precondition(!values.isEmpty, "median requires at least one sample")
    let sorted = values.sorted()
    let upperIndex = sorted.count / 2
    guard sorted.count.isMultiple(of: 2) else {
        return sorted[upperIndex]
    }
    return (sorted[upperIndex - 1] + sorted[upperIndex]) / 2
}

/// Safe ratio. A non-positive measurement on either side is suspicious and
/// fails every finite performance envelope rather than producing a trivial
/// zero ratio or dividing by zero.
func safeRatio(_ numerator: Double, _ denominator: Double) -> Double {
    numerator > 0 && denominator > 0 ? numerator / denominator : .infinity
}

/// Validates the declarative §9 workload map against the fixtures emitted by
/// one run. This is structural coverage, independent from each workload's own
/// pass/fail result: a thrown workload still proves that its gate remains wired,
/// while a deleted/renamed workload or a drifted bullet label fails the runner.
func section9CoverageIssues(_ fixtures: [WorkloadFixture]) -> [String] {
    var issues: [String] = []
    var fixturesByKey: [String: [WorkloadFixture]] = [:]
    for fixture in fixtures {
        fixturesByKey[fixture.key, default: []].append(fixture)
    }

    for key in fixturesByKey.keys.sorted() {
        guard let matchingFixtures = fixturesByKey[key] else { continue }
        if matchingFixtures.count != 1 {
            issues.append(
                "workload \(key) emitted \(matchingFixtures.count) fixtures; expected 1"
            )
        }
        guard let expectation = section9WorkloadCoverage[key] else {
            issues.append("workload \(key) is absent from the §9 coverage map")
            continue
        }
        for fixture in matchingFixtures where fixture.bullet != expectation.bulletLabel {
            issues.append(
                "workload \(key) labels bullet \(fixture.bullet); "
                    + "expected \(expectation.bulletLabel)"
            )
        }
    }

    for key in section9WorkloadCoverage.keys.sorted()
    where fixturesByKey[key] == nil {
        issues.append("required §9 workload \(key) did not emit a fixture")
    }

    let declaredBullets = section9WorkloadCoverage.values.reduce(into: Set<Int>()) {
        $0.formUnion($1.bulletNumbers)
    }
    if declaredBullets != requiredSection9Bullets {
        issues.append(
            "coverage map declares \(declaredBullets.sorted()); expected "
                + "\(requiredSection9Bullets.sorted())"
        )
    }

    let emittedBullets = fixturesByKey.keys.reduce(into: Set<Int>()) { result, key in
        guard let expectation = section9WorkloadCoverage[key] else { return }
        result.formUnion(expectation.bulletNumbers)
    }
    if emittedBullets != requiredSection9Bullets {
        issues.append(
            "emitted workloads cover \(emittedBullets.sorted()); expected "
                + "\(requiredSection9Bullets.sorted())"
        )
    }
    return issues.sorted()
}

/// Validates the declarative complexity-envelope table independently from any
/// timing result. This catches a workload deletion, a malformed corpus span,
/// a bound that no longer preserves its declared headroom, or an attempt to
/// apply WL1a's narrow exception to another workload before CI pays the cost of
/// constructing the release fixtures.
func section9ComplexityEnvelopeIssues(
    envelopes: [String: WorkloadComplexityEnvelope] = section9WorkloadEnvelopes
) -> [String] {
    var issues: [String] = []
    let declaredKeys = Set(section9WorkloadCoverage.keys)
    let expectedEnvelopeKeys = declaredKeys.subtracting(section9RecordOnlyWorkloads)
    let envelopeKeys = Set(envelopes.keys)

    for key in section9RecordOnlyWorkloads.sorted()
    where !declaredKeys.contains(key) {
        issues.append("record-only workload \(key) is absent from the §9 coverage map")
    }
    for key in expectedEnvelopeKeys.subtracting(envelopeKeys).sorted() {
        issues.append("gated workload \(key) has no complexity envelope")
    }
    for key in envelopeKeys.subtracting(expectedEnvelopeKeys).sorted() {
        issues.append("unexpected complexity envelope for workload \(key)")
    }

    for key in envelopes.keys.sorted() {
        guard let envelope = envelopes[key] else { continue }
        let scales = envelope.measurementScales
        guard scales.count >= 2 else {
            issues.append(
                "workload \(key) needs at least two measurement scales"
            )
            continue
        }
        guard scales.allSatisfy({ $0 > 0 }) else {
            issues.append("workload \(key) measurement scales must be positive")
            continue
        }
        guard zip(scales, scales.dropFirst()).allSatisfy({ pair in
            pair.0 < pair.1
        }) else {
            issues.append(
                "workload \(key) measurement scales must be strictly increasing"
            )
            continue
        }
        guard envelope.bound.isFinite, envelope.bound > 0 else {
            issues.append("workload \(key) bound must be positive and finite")
            continue
        }

        let scaleSpan = envelope.scaleSpan
        guard scaleSpan.isFinite, scaleSpan > 1 else {
            issues.append(
                "workload \(key) scale span must be finite and greater than one"
            )
            continue
        }
        let theoreticalRatio = envelope.theoreticalRatio
        guard theoreticalRatio.isFinite, theoreticalRatio > 0 else {
            issues.append(
                "workload \(key) theoretical ratio must be positive and finite"
            )
            continue
        }

        switch envelope.headroomPolicy {
        case .standard:
            if key == "captureScalesWithRetainedCount" {
                issues.append(
                    "workload \(key) must declare the WL1a retained-inventory exception"
                )
            }
        case .wl1aRetainedInventoryException:
            if key != "captureScalesWithRetainedCount" {
                issues.append(
                    "workload \(key) cannot use WL1a's retained-inventory exception"
                )
            }
        }

        let minimumHeadroom = envelope.headroomPolicy.minimumFactor
        if envelope.headroomFactor < minimumHeadroom {
            issues.append(
                "workload \(key) headroom \(envelope.headroomFactor)× is below "
                    + "the \(minimumHeadroom)× policy floor over theoretical "
                    + "ratio \(theoreticalRatio)"
            )
        }
    }
    return issues.sorted()
}

/// Returns a validated declaration to a workload body. `runAll()` executes no
/// workloads when the declaration validator reports an issue; the precondition
/// is a defensive backstop for direct package/test calls.
func complexityEnvelope(for key: String) -> WorkloadComplexityEnvelope {
    let issues = section9ComplexityEnvelopeIssues()
    precondition(
        issues.isEmpty,
        "invalid §9 complexity-envelope table: \(issues.joined(separator: "; "))"
    )
    guard let envelope = section9WorkloadEnvelopes[key] else {
        preconditionFailure("missing complexity envelope for workload \(key)")
    }
    return envelope
}

/// Captures a short local tool result for reproducible machine/toolchain
/// metadata. Failures are recorded as `unavailable`; stderr is suppressed so
/// an optional metadata probe cannot pollute the zero-warning perf log.
func commandOutput(_ executable: String, arguments: [String]) -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return "unavailable"
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return "unavailable" }
    let data: Data
    do {
        data = try output.fileHandleForReading.readToEnd() ?? Data()
    } catch {
        return "unavailable"
    }
    let value = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "unavailable" : value
}

/// Measures the median milliseconds of a caller-supplied async operation
/// across `warmups + iterations` runs (warmups are discarded). A capture
/// caller times the public `perform` path, including off-Authority preparation;
/// §9's narrower commit-interval exclusions are proven by construction, not
/// inferred from this end-to-end wall time (05 §6.1).
func measureMedian(
    warmups: Int = 1,
    iterations: Int = 5,
    operation: () async throws -> Void
) async throws -> Double {
    for _ in 0..<warmups {
        try await operation()
    }
    let clock = ContinuousClock()
    var samples: [Double] = []
    for _ in 0..<iterations {
        let start = clock.now
        try await operation()
        samples.append(durationToMs(start.duration(to: clock.now)))
    }
    return median(samples)
}

// MARK: - Store helpers

/// A unique temp store URL (parent directory created upfront to suppress
/// CoreData file-status diagnostics — same pattern as WS tests,
/// Tests/HistoryStorageTests/Support/WalkingSkeletonSupport.swift).
func makeStoreURL(_ label: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipy-perf-\(label)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
        at: dir,
        withIntermediateDirectories: true
    )
    return dir.appendingPathComponent("store.sqlite")
}

/// Removes the store directory created by `makeStoreURL`.
func removeStoreDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

/// Opens the public facade over a persistent temp store with a generous
/// initial retention cap (avoids eviction during population). 05 §2: the
/// initial value is written to the durable singleton for a new store.
func openStore(url: URL, maxUnpinned: Int = 5_000) async throws -> SwiftDataHistory {
    try await SwiftDataHistory.open(
        configuration: HistoryConfiguration(
            persistence: .persistent(storeURL: url),
            initialMaximumUnpinnedItems: maxUnpinned
        )
    )
}

/// Opens the public facade over an in-memory store.
///
/// §9 measures algorithmic complexity (rows/bytes scaling), not durability:
/// Part V §2 states `.memory` changes the durability medium only and uses
/// the same Authority, planners, codecs, and transaction path, so a workload
/// that does not need to REOPEN durable state runs against the identical
/// algorithm without paying per-commit fsync — population is the runner's
/// dominant cost and is never part of a measurement. Only bullet 3 (index
/// rebuild across a durable reopen) keeps `.persistent`; every fixture note
/// records the medium.
func openMemoryStore(maxUnpinned: Int = 5_000) async throws -> SwiftDataHistory {
    try await SwiftDataHistory.open(
        configuration: HistoryConfiguration(
            persistence: .memory,
            initialMaximumUnpinnedItems: maxUnpinned
        )
    )
}

// MARK: - Deterministic capture helpers (no UUID/random in the measurement path)

/// A deterministic raw text capture (index-derived text; capture IDs come from
/// receipts, not from UUID/random in the content path).
func deterministicTextCapture(
    index: Int,
    bodyBytes: Int = 64,
    baseTime: Double = 600_000_000
) -> ClipboardCapture {
    let prefix = "perf-item-\(index)-"
    let padding = String(repeating: "a", count: max(0, bodyBytes - prefix.utf8.count))
    return ClipboardCapture(
        representations: [CapturedRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data((prefix + padding).utf8)
        )],
        origin: CopyOriginObservation(
            sourceApplication: "perf-runner",
            lineageHint: nil
        ),
        observedAt: Date(timeIntervalSinceReferenceDate: baseTime + Double(index))
    )
}

/// Captures one distinct item and returns its reference.
func captureItem(
    _ history: SwiftDataHistory,
    index: Int,
    bodyBytes: Int = 64
) async throws -> HistoryItemReference {
    let receipt = try await history.perform(
        .capture(deterministicTextCapture(index: index, bodyBytes: bodyBytes))
    )
    guard case .committed(let commit) = receipt,
          case .inserted(let ref) = commit.outcome else {
        throw PerfError.captureUnexpectedOutcome
    }
    return ref
}

/// Performs one already-built capture so a workload can keep String/Data
/// fixture construction outside its timed interval.
func capturePreparedItem(
    _ history: SwiftDataHistory,
    capture: ClipboardCapture
) async throws -> HistoryItemReference {
    let receipt = try await history.perform(.capture(capture))
    guard case .committed(let commit) = receipt,
          case .inserted(let reference) = commit.outcome else {
        throw PerfError.captureUnexpectedOutcome
    }
    return reference
}

/// Populates a store with `count` distinct unpinned items (untimed).
func populateItems(
    _ history: SwiftDataHistory,
    count: Int,
    bodyBytes: Int = 64
) async throws {
    for i in 0..<count {
        _ = try await captureItem(history, index: i, bodyBytes: bodyBytes)
    }
}

/// Populates a store and returns the first item's reference for later queries.
func populateAndReturnFirstRef(
    _ history: SwiftDataHistory,
    count: Int,
    bodyBytes: Int = 64
) async throws -> HistoryItemReference {
    let firstRef = try await captureItem(history, index: 0, bodyBytes: bodyBytes)
    for i in 1..<count {
        _ = try await captureItem(history, index: i, bodyBytes: bodyBytes)
    }
    return firstRef
}

// MARK: - Output helpers

/// Prints one summary line for a workload result.
func printResult(_ key: String, _ bullet: String, _ ratio: Double, _ bound: Double?, _ passed: Bool) {
    let status = passed ? "PASS" : "FAIL"
    if let bound {
        print(String(format: "  [%@] %@ (§9 bullet %@): ratio %.2f, bound %.1f", status, key, bullet, ratio, bound))
    } else {
        print(String(format: "  [%@] %@ (§9 bullet %@): ratio %.2f, bound n/a (record-only)", status, key, bullet, ratio))
    }
}

/// Builds a failure fixture for a workload that could not complete.
func failureFixture(key: String, bullet: String, error: Error) -> WorkloadFixture {
    print("  [FAIL] \(key) (§9 bullet \(bullet)): workload threw \(error)")
    return WorkloadFixture(
        key: key,
        bullet: bullet,
        sizes: [],
        mediansMs: [],
        ratio: nil,
        bound: nil,
        pass: false,
        note: "workload threw \(error)"
    )
}

// MARK: - Workload 1: capture scales with incoming bytes, not commit shape
//   (§9 bullets 1-2)

func workloadCaptureScaling() async -> [WorkloadFixture] {
    let bullet = "1-2"
    var fixtures: [WorkloadFixture] = []
    let retainedKey = "captureScalesWithRetainedCount"
    let retainedEnvelope = complexityEnvelope(for: retainedKey)
    let smallRetainedCount = retainedEnvelope.measurementScales[0]
    let largeRetainedCount = retainedEnvelope.measurementScales[
        retainedEnvelope.measurementScales.count - 1
    ]

    // 1a: Retained-count envelope — a single capture's candidate generation
    // is proportional to incoming bytes + posting-set/candidate confirmation
    // work, not all Canonical blobs (§9 bullet 2). Capture ALSO performs the
    // sanctioned O(retained scalar) retention-inventory load (05 §7.1 step 5:
    // scalar summaries only, no blob decode), so the ratio sits AT the size
    // span asymptotically; the bound is span × 1.2 so only a super-linear
    // regression (per-item blob decode, O(n²)) breaks the envelope. Capture
    // commit interval excludes fingerprinting (§9 bullet 1); this end-to-end
    // timer includes it, while its exclusion from the serialized interval is
    // proven structurally by the separate preparation actor (05 §6.1).
    do {
        let smallStore = try await openMemoryStore()
        try await populateItems(smallStore, count: smallRetainedCount)
        let largeStore = try await openMemoryStore()
        try await populateItems(largeStore, count: largeRetainedCount)

        var smallNext = smallRetainedCount
        var largeNext = largeRetainedCount
        let smallMedian = try await measureMedian {
            _ = try await captureItem(smallStore, index: smallNext)
            smallNext += 1
        }
        let largeMedian = try await measureMedian {
            _ = try await captureItem(largeStore, index: largeNext)
            largeNext += 1
        }

        let ratio = safeRatio(largeMedian, smallMedian)
        let bound = retainedEnvelope.bound
        let passed = ratio <= bound
        fixtures.append(WorkloadFixture(
            key: retainedKey,
            bullet: bullet,
            sizes: [
                "\(smallRetainedCount)-retained",
                "\(largeRetainedCount)-retained",
            ],
            mediansMs: [smallMedian, largeMedian],
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Envelope: ratio ≤ \(retainedEnvelope.headroomFactor)× the \(retainedEnvelope.scaleSpan)× span. Candidate generation ∝ incoming bytes + posting-set work, not all Canonical blobs (§9 bullet 2); the sanctioned O(retained scalar) retention-inventory load (05 §7.1 step 5) puts the ratio AT the span asymptotically, so only a super-linear regression breaks the envelope. Preparation/fingerprinting off-Authority (05 §6.1)."
        ))
        printResult(retainedKey, bullet, ratio, bound, passed)
    } catch {
        fixtures.append(failureFixture(
            key: retainedKey,
            bullet: bullet,
            error: error
        ))
    }

    // 1b: Body-size scaling — RECORDS byte-proportional scaling (no bound;
    // the expected behavior is linear-in-incoming-bytes per §9 bullet 2).
    do {
        let store = try await openMemoryStore()
        try await populateItems(store, count: 200)

        let captures1KiB = (200..<206).map {
            deterministicTextCapture(index: $0, bodyBytes: 1_024)
        }
        let captures256KiB = (206..<212).map {
            deterministicTextCapture(index: $0, bodyBytes: 256 * 1_024)
        }
        var next1KiB = 0
        let median1KiB = try await measureMedian(warmups: 1, iterations: 5) {
            _ = try await capturePreparedItem(
                store,
                capture: captures1KiB[next1KiB]
            )
            next1KiB += 1
        }
        var next256KiB = 0
        let median256KiB = try await measureMedian(warmups: 1, iterations: 5) {
            _ = try await capturePreparedItem(
                store,
                capture: captures256KiB[next256KiB]
            )
            next256KiB += 1
        }
        let ratio = safeRatio(median256KiB, median1KiB)
        fixtures.append(WorkloadFixture(
            key: "captureScalesWithIncomingBytes",
            bullet: bullet,
            sizes: ["1KiB-body", "256KiB-body"],
            mediansMs: [median1KiB, median256KiB],
            ratio: ratio,
            bound: nil,
            pass: true,
            note: "End-to-end History capture work scales with incoming bytes (§9 bullet 2). Capture fixtures are prebuilt outside the timer, so the measurement covers History preparation/fingerprint/commit rather than harness String/Data construction. Record-only: byte-proportional scaling is expected."
        ))
        printResult("captureScalesWithIncomingBytes", bullet, ratio, nil, true)
    } catch {
        fixtures.append(failureFixture(key: "captureScalesWithIncomingBytes", bullet: bullet, error: error))
    }

    return fixtures
}

// MARK: - Workload 2: warm persistent-store open scales with retained metadata
//   (§9 bullet 3)

func workloadPersistentStoreOpenScaling() async -> [WorkloadFixture] {
    let bullet = "3"
    let key = "persistentStoreOpenScalesWithRetainedMetadata"
    let envelope = complexityEnvelope(for: key)
    let bound = envelope.bound
    let sizes = envelope.measurementScales

    do {
        var medians: [Double] = []
        for size in sizes {
            let url = makeStoreURL("wl2-open-\(size)")

            // Phase 1: populate the store (untimed) in an inner scope so the
            // facade is released before the measurement reopens it.
            do {
                let populateStore = try await openStore(url: url)
                try await populateItems(populateStore, count: size)
            }
            await Task.yield()

            // Phase 2: measure repeated public SwiftDataHistory.open calls.
            // This is deliberately the complete warm persistent-store-open
            // construct: ModelContainer/SQLite open, singleton and startup
            // validation, scalar metadata reads, and Signature Index rebuild
            // (05 §13). It is not an isolated index-rebuild timer, cold-start
            // proof, or G5 absolute-latency fixture. Inner scope + yield makes
            // facade release best-effort; SwiftData exposes no deterministic
            // close/teardown seam, so the fixture records a scaling envelope
            // rather than making a resource-teardown claim.
            let clock = ContinuousClock()
            // Warmup.
            _ = try await openStore(url: url)
            await Task.yield()
            // Timed.
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = clock.now
                _ = try await openStore(url: url)
                let elapsed = start.duration(to: clock.now)
                samples.append(durationToMs(elapsed))
                await Task.yield()
            }
            medians.append(median(samples))
            removeStoreDir(url)
        }

        let ratio = safeRatio(medians[medians.count - 1], medians[0])
        let passed = ratio <= bound
        let fixture = WorkloadFixture(
            key: key,
            bullet: bullet,
            sizes: sizes.map { "\($0)-items" },
            mediansMs: medians,
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Warm repeated persistent-store open over retained metadata: ModelContainer/SQLite open, singleton/startup validation, scalar metadata reads, and Signature Index rebuild (§9 bullet 3; 05 §13). This is not an isolated rebuild, cold-start, teardown, or G5 absolute-latency proof. \(envelope.scaleSpan)× items, \(bound)× bound = \(envelope.headroomFactor)× linear headroom.",
            medium: ".persistent"
        )
        printResult(key, bullet, ratio, bound, passed)
        return [fixture]
    } catch {
        return [failureFixture(
            key: key,
            bullet: bullet,
            error: error
        )]
    }
}

// MARK: - Workload 3: pin reorder linear in pinned count (§9 bullet 4)

func workloadPinReorder() async -> [WorkloadFixture] {
    let bullet = "4"
    let key = "pinReorderLinearInPinnedCount"
    let envelope = complexityEnvelope(for: key)
    let bound = envelope.bound

    do {
        var medians: [(Int, Double)] = []
        for pinnedCount in envelope.measurementScales {
            let store = try await openMemoryStore()

            // Capture items and pin each at .last (ordinal grows 0..<count).
            var refs: [HistoryItemReference] = []
            for i in 0..<pinnedCount {
                let ref = try await captureItem(store, index: i)
                refs.append(ref)
                _ = try await store.perform(.placePinned(ref.id, at: .last))
            }

            // Measure: move a different item to .first each iteration (always
            // a real reorder — item[0] stays at .first after first pin). The
            // placePinned action reorders O(pinned count) ordinals (§9 bullet 4).
            var idx = 1
            let medianMs = try await measureMedian {
                if idx >= refs.count { idx = 1 }
                _ = try await store.perform(.placePinned(refs[idx].id, at: .first))
                idx += 1
            }
            medians.append((pinnedCount, medianMs))
        }

        let ratio = safeRatio(medians[medians.count - 1].1, medians[0].1)
        let passed = ratio <= bound
        let fixture = WorkloadFixture(
            key: key,
            bullet: bullet,
            sizes: medians.map { "\($0.0)-pinned" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Pin reorder O(pinned count), bounded by retained count (§9 bullet 4). \(envelope.scaleSpan)× pinned, \(bound)× bound = \(envelope.headroomFactor)× linear headroom."
        )
        printResult(key, bullet, ratio, bound, passed)
        return [fixture]
    } catch {
        return [failureFixture(key: key, bullet: bullet, error: error)]
    }
}

// MARK: - Workload 4: retention and clear linear in retained scalar (§9 bullet 5)

func workloadRetentionAndClear() async -> [WorkloadFixture] {
    let bullet = "5"
    let retentionKey = "retentionMassEviction"
    let retentionEnvelope = complexityEnvelope(for: retentionKey)
    let clearKey = "clearUnpinned"
    let clearEnvelope = complexityEnvelope(for: clearKey)
    // Five timed samples remove the old max-of-two noise rationale. A 6×
    // envelope over a 3× corpus still leaves 2× linear headroom while failing
    // the 9× ratio expected from an accidental quadratic path.
    var fixtures: [WorkloadFixture] = []

    // --- Retention: setRetentionPolicy(1) mass eviction ---
    // §9 bullet 5: O(retained scalar metadata), bounded by retained count.
    do {
        var medians: [(Int, Double)] = []
        for count in retentionEnvelope.measurementScales {
            var samples: [Double] = []
            let clock = ContinuousClock()
            for iteration in 0..<6 {  // 1 warmup + 5 timed
                let store = try await openMemoryStore(maxUnpinned: 5_000)
                try await populateItems(store, count: count)
                let start = clock.now
                _ = try await store.perform(.setRetentionPolicy(maximumUnpinnedItems: 1))
                let elapsed = start.duration(to: clock.now)
                if iteration > 0 {  // discard warmup
                    samples.append(durationToMs(elapsed))
                }
            }
            medians.append((count, median(samples)))
        }
        let ratio = safeRatio(medians[medians.count - 1].1, medians[0].1)
        let passed = ratio <= retentionEnvelope.bound
        fixtures.append(WorkloadFixture(
            key: retentionKey,
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: retentionEnvelope.bound,
            pass: passed,
            note: "Retention O(retained scalar metadata), bounded by retained count (§9 bullet 5). Five timed samples; \(retentionEnvelope.scaleSpan)× retained and \(retentionEnvelope.bound)× bound leave \(retentionEnvelope.headroomFactor)× linear headroom while rejecting quadratic scaling."
        ))
        printResult(
            retentionKey,
            bullet,
            ratio,
            retentionEnvelope.bound,
            passed
        )
    } catch {
        fixtures.append(failureFixture(
            key: retentionKey,
            bullet: bullet,
            error: error
        ))
    }

    // --- Clear: clear(.unpinned) ---
    do {
        var medians: [(Int, Double)] = []
        for count in clearEnvelope.measurementScales {
            var samples: [Double] = []
            let clock = ContinuousClock()
            for iteration in 0..<6 {  // 1 warmup + 5 timed
                let store = try await openMemoryStore(maxUnpinned: 5_000)
                try await populateItems(store, count: count)
                let start = clock.now
                _ = try await store.perform(.clear(.unpinned))
                let elapsed = start.duration(to: clock.now)
                if iteration > 0 {
                    samples.append(durationToMs(elapsed))
                }
            }
            medians.append((count, median(samples)))
        }
        let ratio = safeRatio(medians[medians.count - 1].1, medians[0].1)
        let passed = ratio <= clearEnvelope.bound
        fixtures.append(WorkloadFixture(
            key: clearKey,
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: clearEnvelope.bound,
            pass: passed,
            note: "Clear O(retained scalar metadata), bounded by retained count (§9 bullet 5). Five timed samples; \(clearEnvelope.scaleSpan)× retained and \(clearEnvelope.bound)× bound leave \(clearEnvelope.headroomFactor)× linear headroom while rejecting quadratic scaling."
        ))
        printResult(clearKey, bullet, ratio, clearEnvelope.bound, passed)
    } catch {
        fixtures.append(failureFixture(
            key: clearKey,
            bullet: bullet,
            error: error
        ))
    }

    return fixtures
}

// MARK: - Workload 5: recent browse independent of retained count (§9 bullet 6)

func workloadRecentBrowse() async -> [WorkloadFixture] {
    let bullet = "6"
    let key = "recentBrowseIndependentOfRetainedCount"
    let envelope = complexityEnvelope(for: key)
    let bound = envelope.bound

    do {
        var medians: [(Int, Double)] = []
        for count in envelope.measurementScales {
            let store = try await openMemoryStore()
            try await populateItems(store, count: count)
            // §9 bullet 6: recent browse materializes at most limit+1 scalar
            // rows after the storage query/order strategy is proved.
            let medianMs = try await measureMedian {
                _ = try await store.browse(
                    HistoryBrowseRequest(kind: .recent, limit: 50)
                )
            }
            medians.append((count, medianMs))
        }
        let ratio = safeRatio(medians[medians.count - 1].1, medians[0].1)
        let passed = ratio <= bound
        let fixture = WorkloadFixture(
            key: key,
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Recent browse materializes ≤ limit+1 scalar rows (§9 bullet 6). \(envelope.scaleSpan)× retained, theoretical ratio \(envelope.theoreticalRatio)×, \(bound)× bound = \(envelope.headroomFactor)× headroom for retained-count independence."
        )
        printResult(key, bullet, ratio, bound, passed)
        return [fixture]
    } catch {
        return [failureFixture(key: key, bullet: bullet, error: error)]
    }
}

// MARK: - Workload 6: all search modes scan bounded projections (§9 bullet 7)

func workloadSearchModesScaling() async -> [WorkloadFixture] {
    let bullet = "7"
    // A 4× retained-row span with an 8× bound leaves 2× linear headroom
    // while rejecting the nominal 16× ratio of a quadratic regression.
    let definitions: [(key: String, label: String, mode: SearchMode, term: String)] = [
        ("exactSearchScalesWithRetainedCount", "exact", .exact, "needle"),
        ("fuzzySearchScalesWithRetainedCount", "fuzzy", .fuzzy, "nedle"),
        (
            "regexpSearchScalesWithRetainedCount",
            "regexp",
            .regexp,
            "needle-in-haystack-[0-9]+"
        ),
    ]
    let envelopes = definitions.map { definition in
        complexityEnvelope(for: definition.key)
    }
    let measurementScales = envelopes[0].measurementScales
    precondition(
        envelopes.dropFirst().allSatisfy { envelope in
            envelope.measurementScales == measurementScales
        },
        "search modes must share one §9 corpus span"
    )

    do {
        var medians: [[(Int, Double)]] =
            Array(repeating: [], count: definitions.count)
        var allMatched = Array(repeating: true, count: definitions.count)
        for count in measurementScales {
            // The three modes reuse one populated store at each size. This
            // keeps fixture construction identical and prevents population
            // cost from tripling merely to characterize another evaluator.
            let store = try await openMemoryStore()

            // Populate with deterministic items; embed "needle" in the middle item.
            for i in 0..<count {
                let text = (i == count / 2) ? "needle-in-haystack-\(i)" : "perf-search-\(i)"
                let capture = ClipboardCapture(
                    representations: [CapturedRepresentation(
                        typeIdentifier: "public.utf8-plain-text",
                        bytes: Data(text.utf8)
                    )],
                    origin: CopyOriginObservation(
                        sourceApplication: "perf-runner",
                        lineageHint: nil
                    ),
                    observedAt: Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(i))
                )
                _ = try await store.perform(.capture(capture))
            }

            // §9 bullet 7: exact, fuzzy, and regexp each evaluate the same
            // bounded scalar corpus; no cache is added without G2 evidence.
            for definitionIndex in definitions.indices {
                let definition = definitions[definitionIndex]
                let request = HistoryBrowseRequest(
                    kind: .search(text: definition.term, mode: definition.mode),
                    limit: 50
                )
                let medianMs = try await measureMedian {
                    _ = try await store.browse(request)
                }
                medians[definitionIndex].append((count, medianMs))

                // The performance gate cannot pass on an empty or otherwise
                // semantically wrong evaluation merely because it completed
                // quickly. Every frozen mode must return the planted row.
                let page = try await store.browse(request)
                if !page.rows.contains(where: { $0.title.contains("needle") }) {
                    allMatched[definitionIndex] = false
                }
            }
        }

        return definitions.indices.map { definitionIndex in
            let definition = definitions[definitionIndex]
            let envelope = envelopes[definitionIndex]
            let modeMedians = medians[definitionIndex]
            let ratio = safeRatio(
                modeMedians[modeMedians.count - 1].1,
                modeMedians[0].1
            )
            let passed = allMatched[definitionIndex] && ratio <= envelope.bound
            let fixture = WorkloadFixture(
                key: definition.key,
                bullet: bullet,
                sizes: modeMedians.map { "\($0.0)-retained" },
                mediansMs: modeMedians.map { $0.1 },
                ratio: ratio,
                bound: envelope.bound,
                pass: passed,
                note: "\(definition.label) search over the bounded scalar projection corpus (§9 bullet 7). The expected planted row must match; \(envelope.scaleSpan)× retained rows and an \(envelope.bound)× bound leave \(envelope.headroomFactor)× linear headroom while rejecting nominal quadratic scaling. This complexity envelope is not G2 absolute-latency evidence."
            )
            printResult(
                definition.key,
                bullet,
                ratio,
                envelope.bound,
                passed
            )
            return fixture
        }
    } catch {
        return definitions.map { definition in
            failureFixture(key: definition.key, bullet: bullet, error: error)
        }
    }
}

// MARK: - Workload 7: detail and paste decode one item (§9 bullet 8)

func workloadDetailAndPaste() async -> [WorkloadFixture] {
    let bullet = "8"
    let detailKey = "detailDecodeOneItem"
    let detailEnvelope = complexityEnvelope(for: detailKey)
    let pasteKey = "pastePayloadDecodeOneItem"
    let pasteEnvelope = complexityEnvelope(for: pasteKey)
    var fixtures: [WorkloadFixture] = []

    // --- Details ---
    // §9 bullet 8: detail/paste decode one item's bounded lineage.
    do {
        var medians: [(Int, Double)] = []
        for count in detailEnvelope.measurementScales {
            let store = try await openMemoryStore()
            let firstRef = try await populateAndReturnFirstRef(store, count: count)
            let medianMs = try await measureMedian {
                _ = try await store.details(for: firstRef.id)
            }
            medians.append((count, medianMs))
        }
        let ratio = safeRatio(medians[medians.count - 1].1, medians[0].1)
        let passed = ratio <= detailEnvelope.bound
        fixtures.append(WorkloadFixture(
            key: detailKey,
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: detailEnvelope.bound,
            pass: passed,
            note: "Detail decodes one item's bounded lineage (§9 bullet 8). \(detailEnvelope.scaleSpan)× retained, theoretical ratio \(detailEnvelope.theoreticalRatio)×, and \(detailEnvelope.bound)× bound leave \(detailEnvelope.headroomFactor)× headroom for O(1) retained-count behavior."
        ))
        printResult(
            detailKey,
            bullet,
            ratio,
            detailEnvelope.bound,
            passed
        )
    } catch {
        fixtures.append(failureFixture(
            key: detailKey,
            bullet: bullet,
            error: error
        ))
    }

    // --- Paste payload ---
    do {
        var medians: [(Int, Double)] = []
        for count in pasteEnvelope.measurementScales {
            let store = try await openMemoryStore()
            let firstRef = try await populateAndReturnFirstRef(store, count: count)
            let medianMs = try await measureMedian {
                _ = try await store.pastePayload(for: firstRef.id)
            }
            medians.append((count, medianMs))
        }
        let ratio = safeRatio(medians[medians.count - 1].1, medians[0].1)
        let passed = ratio <= pasteEnvelope.bound
        fixtures.append(WorkloadFixture(
            key: pasteKey,
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: pasteEnvelope.bound,
            pass: passed,
            note: "Paste payload decodes one item's current Effective Content (§9 bullet 8). \(pasteEnvelope.scaleSpan)× retained, theoretical ratio \(pasteEnvelope.theoreticalRatio)×, and \(pasteEnvelope.bound)× bound leave \(pasteEnvelope.headroomFactor)× headroom for O(1) retained-count behavior."
        ))
        printResult(
            pasteKey,
            bullet,
            ratio,
            pasteEnvelope.bound,
            passed
        )
    } catch {
        fixtures.append(failureFixture(
            key: pasteKey,
            bullet: bullet,
            error: error
        ))
    }

    return fixtures
}

// MARK: - Workload 8: thumbnail single-flight shares decode (§9 bullet 9)

/// PNG's CRC-32/ISO-HDLC checksum (polynomial 0x04C11DB7 in reflected form).
/// Kept as a pure package-internal helper so the fixture's chunk integrity is
/// pinned by published known-answer vectors rather than trusted transitively
/// through ImageIO decode success.
func pngCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xEDB8_8320 : 0)
        }
    }
    return crc ^ 0xFFFF_FFFF
}

/// Deterministic Marsaglia xorshift32 stream used only to make the thumbnail
/// fixture incompressible. The explicit state value and recurrence give tests
/// a stable KAT seam without introducing system entropy into perf fixtures.
struct XorShift32: Sendable {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed
    }

    mutating func next() -> UInt32 {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return state
    }

    mutating func nextByte() -> UInt8 {
        UInt8(truncatingIfNeeded: next())
    }
}

/// Builds a deterministic 1024×1024 RGB PNG at runtime (Foundation-only).
/// The WS15 1×1 fixture decodes in microseconds and a compressible pattern
/// inflates as LZ77 match-copies — both make the single-flight ratio measure
/// Authority version-fence scheduling instead of decode sharing (runs
/// 30734054783, 30734466775). Incompressible xorshift noise forces genuine
/// inflate + unfilter cost (~ms for 3 MB scanlines), so the decode dominates
/// per-call cost and concurrent-8 ≈ one shared decode (§9 bullet 9). The
/// zlib stream comes from NSData's COMPRESSION_ZLIB — RFC 1950, the IDAT
/// payload format.
func makeNoisePNG(width: Int, height: Int) throws -> Data {
    func chunk(_ tag: String, _ payload: Data) -> Data {
        var out = Data()
        var length = UInt32(payload.count).bigEndian
        out.append(Data(bytes: &length, count: 4))
        let tagData = Data(tag.utf8)
        out.append(tagData)
        out.append(payload)
        var crc = pngCRC32(tagData + payload).bigEndian
        out.append(Data(bytes: &crc, count: 4))
        return out
    }

    // Signature + IHDR (bit depth 8, color type 2 = truecolor RGB).
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    var ihdr = Data()
    var widthBE = UInt32(width).bigEndian
    var heightBE = UInt32(height).bigEndian
    ihdr.append(Data(bytes: &widthBE, count: 4))
    ihdr.append(Data(bytes: &heightBE, count: 4))
    ihdr.append(contentsOf: [8, 2, 0, 0, 0])
    png.append(chunk("IHDR", ihdr))

    // Scanlines: filter byte 0 per row + deterministic xorshift32 noise.
    // Incompressible pixels make the deflate stream carry 3 MB of literals,
    // so the decoder pays real inflate + unfilter cost per decode.
    var byteGenerator = XorShift32(seed: 0x9E37_79B9)
    var raw = Data()
    raw.reserveCapacity(height * (1 + width * 3))
    for _ in 0..<height {
        raw.append(0)
        for _ in 0..<(width * 3) {
            raw.append(byteGenerator.nextByte())
        }
    }

    // zlib stream: real deflate via Foundation's COMPRESSION_ZLIB (RFC 1950),
    // so the ImageIO decode pays genuine inflate cost — stored blocks would
    // decompress as a memcpy and the decode would not dominate the ratio.
    let zstream = try (raw as NSData).compressed(using: .zlib) as Data
    png.append(chunk("IDAT", zstream))

    png.append(chunk("IEND", Data()))
    return png
}

func workloadThumbnailSingleFlight() async -> [WorkloadFixture] {
    let bullet = "9"
    let key = "thumbnailSingleFlightSharesDecode"
    let envelope = complexityEnvelope(for: key)
    precondition(
        envelope.measurementScales == [1, 8],
        "thumbnail single-flight fixture is structurally sequential-1/concurrent-8"
    )

    do {
        let store = try await openMemoryStore()

        let pngData = try makeNoisePNG(width: 1024, height: 1024)
        // Capture a text+png item so the thumbnail path has a valid image source.
        let capture = ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("thumbnail-perf-item".utf8)),
                CapturedRepresentation(typeIdentifier: "public.png", bytes: pngData),
            ],
            origin: CopyOriginObservation(sourceApplication: "perf-runner", lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 600_000_000)
        )
        let receipt = try await store.perform(.capture(capture))
        guard case .committed(let commit) = receipt,
              case .inserted(let ref) = commit.outcome else {
            throw PerfError.captureUnexpectedOutcome
        }
        let pixels = PixelSize(width: 32, height: 32)

        // Untimed end-to-end smoke: steps 1–7 remain wired through the public
        // facade. The single-flight ratio below deliberately isolates steps
        // 5–7; otherwise eight actor-serialized Authority source fetches hide
        // whether the decode itself is shared (V1-Verified/04).
        _ = try await store.thumbnail(for: ref, pixels: pixels)

        // The immutable source bytes are prepared exactly once before either
        // measurement. This package-only seam is the production service, not
        // a benchmark double; it removes only the source-fetch prefix from the
        // timed construct while retaining the real flight table and worker.
        let thumbnailService = ThumbnailService()

        // (a) 8 SEQUENTIAL thumbnail calls — record median per-call time.
        // Warmup.
        _ = try await thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        let clock = ContinuousClock()
        var seqSamples: [Double] = []
        for _ in 0..<8 {
            let start = clock.now
            _ = try await thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
            seqSamples.append(durationToMs(start.duration(to: clock.now)))
        }
        let seqMedian = median(seqSamples)

        // (b) 8 CONCURRENT identical-key calls via async let — record total
        // wall time. §9 bullet 9: after one bounded source fetch, thumbnail
        // performs one shared concurrent decode for an identical key. With
        // single-flight, concurrent-8 total ≈ 1 decode; without, ≈ 8 decodes.
        // Concurrent warmup (2 calls).
        async let warmA = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let warmB = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        _ = try await warmA
        _ = try await warmB

        let concStart = clock.now
        async let c1 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let c2 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let c3 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let c4 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let c5 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let c6 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let c7 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        async let c8 = thumbnailService.thumbnail(pngData, for: ref, pixels: pixels)
        _ = try await c1
        _ = try await c2
        _ = try await c3
        _ = try await c4
        _ = try await c5
        _ = try await c6
        _ = try await c7
        _ = try await c8
        let concTotal = durationToMs(concStart.duration(to: clock.now))

        let ratio = safeRatio(concTotal, seqMedian)
        let bound = envelope.bound
        let passed = ratio <= bound
        let fixture = WorkloadFixture(
            key: key,
            bullet: bullet,
            sizes: ["sequential-1"],
            mediansMs: [seqMedian],
            wallTimeMs: concTotal,
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "After one prefetched immutable source, the production ThumbnailService shares one decode for an identical key (§9 steps 5–7). Concurrent-8 total ≤ \(bound)× sequential-1 median (\(envelope.headroomFactor)× headroom over the one-decode theoretical ratio) proves a single shared decode, not eight; an untimed public-facade call smoke-tests the complete source-fetch pipeline."
        )
        printResult(key, bullet, ratio, bound, passed)
        return [fixture]
    } catch {
        return [failureFixture(key: key, bullet: bullet, error: error)]
    }
}

// MARK: - Runner entry point

/// Runs all §9 workloads, writes the fixture JSON, and returns an exit code
/// (0 = all checks passed, 1 = one or more checks failed, 2 = fixture write
/// error). All fixtures are recorded even when a check fails.
func runAll() async -> Int {
    let outputPath = CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : "ci-logs/perf-fixtures.json"

    let processInfo = ProcessInfo.processInfo
    let metadata = MachineMetadata(
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
    let swiftVersion = commandOutput(
        "/usr/bin/xcrun",
        arguments: ["swift", "--version"]
    )

    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime]
    let dateString = dateFormatter.string(from: Date())

    print("HistoryPerfRunner: starting Part VI §9 performance proofs")
    print(
        "  machine: \(metadata.hardwareModel) / \(metadata.processorModel) "
            + "(\(metadata.architecture)) — \(metadata.osVersion)"
    )

    let envelopeIssues = section9ComplexityEnvelopeIssues()
    var allFixtures: [WorkloadFixture] = []
    if envelopeIssues.isEmpty {
        allFixtures.append(contentsOf: await workloadCaptureScaling())
        allFixtures.append(contentsOf: await workloadPersistentStoreOpenScaling())
        allFixtures.append(contentsOf: await workloadPinReorder())
        allFixtures.append(contentsOf: await workloadRetentionAndClear())
        allFixtures.append(contentsOf: await workloadRecentBrowse())
        allFixtures.append(contentsOf: await workloadSearchModesScaling())
        allFixtures.append(contentsOf: await workloadDetailAndPaste())
        allFixtures.append(contentsOf: await workloadThumbnailSingleFlight())
    }

    let coverageIssues = envelopeIssues.isEmpty
        ? section9CoverageIssues(allFixtures)
        : envelopeIssues
    for issue in coverageIssues {
        print("  [FAIL] §9 workload structure: \(issue)")
    }

    let perfFixture = PerfFixture(
        schemaVersion: 2,
        machine: metadata,
        swiftVersion: swiftVersion,
        date: dateString,
        workloads: allFixtures,
        coverageIssues: coverageIssues
    )

    // Write JSON (prettyPrinted + sortedKeys).
    do {
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(perfFixture)
        try data.write(to: outputURL)
        print("HistoryPerfRunner: wrote fixtures to \(outputPath)")
    } catch {
        try? FileHandle.standardError.write(
            contentsOf: Data(
                "HistoryPerfRunner: failed to write fixtures: \(error)\n".utf8
            )
        )
        return 2
    }

    let failures = allFixtures.filter { !$0.pass }
    if failures.isEmpty && coverageIssues.isEmpty {
        print("HistoryPerfRunner: all \(allFixtures.count) workload check(s) PASSED")
        return 0
    } else {
        print(
            "HistoryPerfRunner: \(failures.count)/\(allFixtures.count) workload "
                + "check(s) and \(coverageIssues.count) coverage assertion(s) FAILED"
        )
        return 1
    }
}

// MARK: - @main

@main
struct PerfRunner {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let exitCode: Int
        if arguments.first == "--admission" {
            exitCode = await runAdmission(
                arguments: Array(arguments.dropFirst())
            )
        } else {
            exitCode = await runAll()
        }
        exit(Int32(exitCode))
    }
}
