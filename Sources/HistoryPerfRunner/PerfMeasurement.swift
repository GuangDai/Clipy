/// Measurement helpers and §9 coverage/complexity checks.
/// Split out of PerformanceSuite.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryStorage

// MARK: - Errors

/// Internal runner errors (not HistoryFailure; never crosses the History seam).
enum PerfError: Error, Sendable {
    case captureUnexpectedOutcome
    case reviseUnexpectedOutcome
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

