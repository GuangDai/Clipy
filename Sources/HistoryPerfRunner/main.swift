/// HistoryPerfRunner — release-like performance-runner scaffold for the
/// Part VI §9 performance proofs (docs/06-cross-cutting.md §9). Step 0 records
/// machine metadata only; recorded fixtures populate as HistoryStorage matures
/// (roadmap steps 5–8, docs/roadmap/README.md §3). Foundation-only.
import Foundation

/// Machine context that must accompany any recorded perf fixture
/// (docs/06-cross-cutting.md §9: claims require "recorded fixtures and machine
/// metadata").
struct MachineMetadata: Codable {
    let osVersion: String
    let processorCount: Int
    let physicalMemory: UInt64
    let hostName: String
}

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "perf-fixtures/machine-metadata.json"

let processInfo = ProcessInfo.processInfo
let metadata = MachineMetadata(
    osVersion: processInfo.operatingSystemVersionString,
    processorCount: processInfo.processorCount,
    physicalMemory: processInfo.physicalMemory,
    hostName: processInfo.hostName
)

do {
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(metadata).write(to: outputURL)
    print("HistoryPerfRunner: wrote machine metadata to \(outputPath)")
} catch {
    FileHandle.standardError.write(Data("HistoryPerfRunner failed: \(error)\n".utf8))
    exit(1)
}
