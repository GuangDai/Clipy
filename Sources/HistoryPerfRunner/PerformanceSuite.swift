/// HistoryPerfRunner — release-like performance runner for the Part VI §9
/// performance proofs (docs/06-cross-cutting.md §9). Drives the PUBLIC
/// ClipboardHistory surface via the production SQLiteHistory facade. Each
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
/// Store medium: workloads without reopen use disposable `.temporary`
/// SQLite/blob directories, with the same WAL and synchronization settings
/// as `.persistent`. Bullet 3 uses persistent stores across child processes
/// and measures warm open over durable metadata. Startup does not rebuild a
/// process-wide Signature Index. Each fixture records its actual medium.
///
/// Fixture sizes: §9 pins complexity envelopes, not absolute sizes. The 5,000
/// retained-item value is the hard bound, not a required per-PR measurement
/// size or an absolute-latency claim.
/// Population counts stay well below that cap and retained-corpus spans are
/// 3×-5×; WL8 separately compares concurrency widths 1→8. Every bound keeps at
/// least 1.5× headroom over its declared linear/constant theoretical ratio
/// except WL1a's documented asymptotic-inventory exception above, so each proof
/// keeps its intended sensitivity while the suite fits the CI wall-clock budget.
/// The V2-02 R-active retention lanes (docs/v2/V2-02-retention.md Record 3
/// RET-PERF-1/2/3) reuse the same discipline: capture composition with R1+R2
/// active, the revise-path expansion with R2+R3 active, and the
/// `.setRetentionPolicies` scalar sweep each gate a 3× span at 6× (a 2×
/// bound over the measured span) so a quadratic-scale regression in the
/// expansion pass fails exactly as it would on the projection-maintenance-only
/// lanes. The retention and search lanes sort for eviction or corpus order,
/// so every envelope is no-quadratic-observed over the measured scales, not
/// a linear proof — a mild N-log-N regression passes (05 §5.5).
///
/// Import confinement (Part I §8): the runner imports Foundation, HistoryCore,
/// and HistoryStorage — HistoryStorage was added to the HistoryPerfRunner
/// allowlist because the runner drives the public SQLiteHistory concrete
/// facade. WL8 additionally uses the package-only `ThumbnailService` proof
/// seam so it measures single-flight decode sharing without conflating the
/// Authority's intentionally serialized source-fetch prefix.
import Foundation
import HistoryCore
import HistoryStorage

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
        allFixtures.append(contentsOf: await workloadActiveRetentionExpansion())
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

// MARK: - Executable entry point

@main
struct PerfRunner {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let exitCode: Int
        if let rawMode = arguments.first,
           let childMode = PersistentOpenChildMode(rawValue: rawMode) {
            exitCode = await runPersistentOpenChild(
                mode: childMode,
                arguments: Array(arguments.dropFirst())
            )
        } else if arguments.first == "--admission" {
            exitCode = await runAdmission(
                arguments: Array(arguments.dropFirst())
            )
        } else {
            exitCode = await runAll()
        }
        exit(Int32(exitCode))
    }
}
