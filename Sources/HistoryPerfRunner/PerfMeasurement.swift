/// Sampling and report helpers for the performance experiments.
import Foundation

// MARK: - Errors

/// Internal runner errors (not HistoryFailure; never crosses the History seam).
enum PerfError: Error, Sendable {
    case captureUnexpectedOutcome
    case reviseUnexpectedOutcome
    case searchUnexpectedResult
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

/// Settings used directly by the selected experiment.
func complexityEnvelope(for key: String) -> WorkloadComplexityEnvelope {
    guard let envelope = workloadEnvelopes[key] else {
        preconditionFailure("missing measurement settings for workload \(key)")
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
