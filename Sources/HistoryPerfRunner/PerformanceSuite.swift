/// Performance experiments over the public ClipboardHistory surface and real
/// SQLiteHistory store. Fixtures record medians, measured ratios, bounds, and
/// machine metadata. Numeric bounds reject observed growth at these scales;
/// they do not establish an asymptotic proof or an absolute latency target.
/// Workloads without reopen use disposable SQLite/blob directories. Persistent
/// open is measured in fresh child processes; thumbnail sharing uses the
/// package-only ThumbnailService seam to separate decode from source fetching.
import Foundation
import HistoryCore
import HistoryStorage

// MARK: - Runner entry point

/// Runs the experiments, writes fixture JSON, and returns an exit code
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

    print("HistoryPerfRunner: starting performance experiments")
    print(
        "  machine: \(metadata.hardwareModel) / \(metadata.processorModel) "
            + "(\(metadata.architecture)) — \(metadata.osVersion)"
    )

    var allFixtures: [WorkloadFixture] = []
    allFixtures.append(contentsOf: await workloadCaptureScaling())
    allFixtures.append(contentsOf: await workloadPersistentStoreOpenScaling())
    allFixtures.append(contentsOf: await workloadPinReorder())
    allFixtures.append(contentsOf: await workloadRetentionAndClear())
    allFixtures.append(contentsOf: await workloadActiveRetentionExpansion())
    allFixtures.append(contentsOf: await workloadRecentBrowse())
    allFixtures.append(contentsOf: await workloadSearchModesScaling())
    allFixtures.append(contentsOf: await workloadDetailAndPaste())
    allFixtures.append(contentsOf: await workloadThumbnailSingleFlight())

    let perfFixture = PerfFixture(
        schemaVersion: 4,
        machine: metadata,
        swiftVersion: swiftVersion,
        date: dateString,
        workloads: allFixtures
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
    if failures.isEmpty {
        print("HistoryPerfRunner: all \(allFixtures.count) workload check(s) PASSED")
        return 0
    } else {
        print(
            "HistoryPerfRunner: \(failures.count)/\(allFixtures.count) workload check(s) FAILED"
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
        } else if arguments.first == "--sqlite-scale" {
            exitCode = await runSQLiteScale(arguments: Array(arguments.dropFirst()))
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
