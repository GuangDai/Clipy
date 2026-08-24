/// Evidence Card 1C-1 plus the REVIEW §4.3 Retention-config restart tail —
/// public-API-only, normally terminated process tracers over one StoreRoot.
///
/// The test process owns no `ModelContainer`, context, model, facade, item ID,
/// or content manifest. It creates only the temporary StoreRoot; child A owns
/// the two-label UUID manifest, child B reopens/reads/mutates and exits, and
/// child C fresh reopens and verifies the IDs plus complete literal public
/// projection. The Package.swift test-target dependency guarantees the probe is
/// already built; the test launches the same `.build/debug` product convention
/// used by the existing migration-abort child, without nesting another SwiftPM
/// process inside `swift test`.
import Foundation
import Testing

@Suite("True child-process restart")
struct TrueRestartChildTests {
    private enum FixtureError: Error {
        case childFailed
    }

    private static func runChild(
        phase: String,
        storeURL: URL,
        probeURL: URL
    ) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = probeURL
        process.arguments = [
            phase,
            storeURL.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        // Framework diagnostics can contain the store path. They are neither
        // evidence nor useful parent output, so keep the tracer channel fixed
        // and content-free.
        process.standardError = FileHandle.nullDevice

        try process.run()
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        let expected = Data("\(phase.uppercased())_OK\n".utf8)
        guard process.terminationReason == .exit,
              process.terminationStatus == EXIT_SUCCESS,
              result == expected else {
            throw FixtureError.childFailed
        }
    }

    private static func probeURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/HistoryRestartProbe")
    }

    @Test("seed, operate, and verify use three terminated owners")
    func seedOperateVerifyAcrossThreeProcesses() throws {
        let probeURL = Self.probeURL()
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-true-restart-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let storeURL = storeRoot.appendingPathComponent("history.store")

        try Self.runChild(
            phase: "seed",
            storeURL: storeURL,
            probeURL: probeURL
        )
        try Self.runChild(
            phase: "operate",
            storeURL: storeURL,
            probeURL: probeURL
        )
        try Self.runChild(
            phase: "verify",
            storeURL: storeURL,
            probeURL: probeURL
        )
    }

    /// Four sequential owners close the true-restart half of the frozen §4.3
    /// Retention singleton tail: A writes exact count + R1/R2/R3 values, B
    /// fresh-opens and reads them, C fresh-opens, rechecks, and updates them,
    /// and D fresh-opens and reads the updated values. Every child has
    /// normally terminated before the next starts; this proves reopen
    /// persistence, not migration, full-disk, SIGKILL, crash/power-loss, or
    /// external-storage durability.
    @Test("retention write, read, update, and read use four terminated owners")
    func retentionWriteReadUpdateReadAcrossFourProcesses() throws {
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-retention-restart-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let storeURL = storeRoot.appendingPathComponent("history.store")
        let probeURL = Self.probeURL()
        for phase in [
            "retentionSeed",
            "retentionVerify",
            "retentionUpdate",
            "retentionVerifyUpdated",
        ] {
            try Self.runChild(
                phase: phase,
                storeURL: storeURL,
                probeURL: probeURL
            )
        }
    }
}
