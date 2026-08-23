/// Probe-only diagnostic contract for the physical Card 6B APFS workflow.
///
/// This does not simulate ENOSPC. It protects the observable subprocess seam:
/// normal executions remain silent, explicit evidence executions expose fixed
/// stage labels, and those labels never contain a StoreRoot path or fixture
/// content. The physical filesystem behavior remains owned by
/// `run_apfs_enospc.sh` on a macOS runner.
import Foundation
import Testing

@Suite("APFS probe diagnostics")
struct APFSProbeDiagnosticsTests {
    private struct ChildResult {
        let standardOutput: Data
        let diagnosticLines: [String]
        let terminationStatus: Int32
    }

    @Test("ordinary probe execution emits no owned diagnostics")
    func diagnosticsAreOptIn() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storeRoot) }

        let result = try Self.runSeed(
            storeURL: fixture.storeURL,
            probeURL: fixture.probeURL,
            diagnosticsEnabled: false
        )

        #expect(result.terminationStatus == EXIT_SUCCESS)
        #expect(result.standardOutput == Data("SEED_OK\n".utf8))
        #expect(result.diagnosticLines.isEmpty)
    }

    @Test("evidence execution emits fixed content-free seed stages")
    func enabledDiagnosticsAreBoundedAndContentFree() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storeRoot) }

        let result = try Self.runSeed(
            storeURL: fixture.storeURL,
            probeURL: fixture.probeURL,
            diagnosticsEnabled: true
        )

        #expect(result.terminationStatus == EXIT_SUCCESS)
        #expect(result.standardOutput == Data("SEED_OK\n".utf8))
        #expect(result.diagnosticLines == [
            "CLIPY_PROBE event=process.phase=seed start",
            "CLIPY_PROBE event=seed.phase-start",
            "CLIPY_PROBE event=seed.store-opened",
            "CLIPY_PROBE event=seed.first-capture-committed",
            "CLIPY_PROBE event=seed.second-capture-committed",
            "CLIPY_PROBE event=seed.manifest-written",
            "CLIPY_PROBE event=process.phase=seed complete",
        ])

        let diagnostics = result.diagnosticLines.joined(separator: "\n")
        #expect(!diagnostics.contains(fixture.storeRoot.path))
        #expect(!diagnostics.contains("restart alpha"))
        #expect(!diagnostics.contains("restart bravo"))
        #expect(!diagnostics.contains("restart.seed"))
    }

    private static func makeFixture() throws -> (
        probeURL: URL,
        storeRoot: URL,
        storeURL: URL
    ) {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let probeURL = packageRoot
            .appendingPathComponent(".build/debug/HistoryRestartProbe")
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-apfs-probe-diagnostics-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: false
        )
        return (
            probeURL,
            storeRoot,
            storeRoot.appendingPathComponent("history.store")
        )
    }

    private static func runSeed(
        storeURL: URL,
        probeURL: URL,
        diagnosticsEnabled: Bool
    ) throws -> ChildResult {
        let process = Process()
        let output = Pipe()
        let diagnostics = Pipe()
        process.executableURL = probeURL
        process.arguments = ["seed", storeURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = diagnostics
        var environment = ProcessInfo.processInfo.environment
        environment["OS_ACTIVITY_MODE"] = "disable"
        if diagnosticsEnabled {
            environment["CLIPY_APFS_PROBE_DIAGNOSTICS"] = "1"
        } else {
            environment.removeValue(forKey: "CLIPY_APFS_PROBE_DIAGNOSTICS")
        }
        process.environment = environment

        try process.run()
        let standardOutput = try output.fileHandleForReading.readToEnd() ?? Data()
        let standardError = try diagnostics.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        let lines = String(decoding: standardError, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("CLIPY_PROBE ") }
        return ChildResult(
            standardOutput: standardOutput,
            diagnosticLines: lines,
            terminationStatus: process.terminationStatus
        )
    }
}
