/// Probe-only diagnostic contract for the physical Card 6B APFS workflow.
///
/// This does not simulate ENOSPC. It protects the observable subprocess seam:
/// normal executions remain silent, successful evidence executions expose fixed
/// stage labels, and failing evidence executions retain the full bounded
/// platform-error evidence needed to debug a macOS runner. The physical behavior remains owned by
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

    @Test("failing evidence execution includes the full platform error and path")
    func failingDiagnosticsPreserveNSErrorEvidence() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.storeRoot) }

        let result = try Self.runProbe(
            phase: "verifySeed",
            storeURL: fixture.storeURL,
            probeURL: fixture.probeURL,
            diagnosticsEnabled: true,
            runtimeDiagnosticsEnabled: true
        )

        let diagnostics = result.diagnosticLines.joined(separator: "\n")
        #expect(result.terminationStatus == EXIT_FAILURE)
        #expect(result.standardOutput == Data("VERIFYSEED_FAIL\n".utf8))
        #expect(diagnostics.contains("platform-error depth=0 edge=root"))
        #expect(diagnostics.contains("swift_type=\""))
        #expect(diagnostics.contains("domain=\"NSCocoaErrorDomain\""))
        #expect(diagnostics.contains("localized_description=\""))
        #expect(diagnostics.contains("platform-error-user-info depth=0"))
        #expect(diagnostics.contains(fixture.storeRoot.path))
        #expect(diagnostics.contains("restart-manifest.txt"))
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
        try runProbe(
            phase: "seed",
            storeURL: storeURL,
            probeURL: probeURL,
            diagnosticsEnabled: diagnosticsEnabled,
            runtimeDiagnosticsEnabled: false
        )
    }

    private static func runProbe(
        phase: String,
        storeURL: URL,
        probeURL: URL,
        diagnosticsEnabled: Bool,
        runtimeDiagnosticsEnabled: Bool
    ) throws -> ChildResult {
        let process = Process()
        let output = Pipe()
        let diagnostics = Pipe()
        process.executableURL = probeURL
        process.arguments = [phase, storeURL.path]
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
        if runtimeDiagnosticsEnabled {
            environment["CLIPY_RUNTIME_DIAGNOSTICS"] = "1"
        } else {
            environment.removeValue(forKey: "CLIPY_RUNTIME_DIAGNOSTICS")
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
