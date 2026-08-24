/// Two bounded child-process crash proofs from REVIEW §4.2/§4.3.
///
/// The Gateway chain parks at the exact V2-05 §5.2 boundary: its succeeded
/// read audit has committed, but the immutable public result has not crossed
/// the Authority method boundary. A fresh owner then sees exactly one matching
/// audit through the public admin facade. The large-payload chain separately
/// commits one schema-`externalStorage`-hinted representation, terminates
/// abnormally, and forces byte-exact hydration through public browse, details,
/// and paste-payload calls in a fresh process.
///
/// These fixtures establish process-crash/reopen behavior on the pinned
/// macOS/SwiftData lane only. They do not inspect sidecar layout or claim fsync,
/// sudden-power-loss atomicity, or permanent external placement.
import Foundation
import Testing

@Suite("Gateway audit and large-payload crash restart")
struct GatewayAuditAndLargeBlobCrashRestartTests {
    private enum FixtureError: Error {
        case childFailed(phase: String)
        case childDidNotCrash(phase: String)
    }

    @Test("crash after succeeded read audit leaves exactly one durable record")
    func readAuditCommitPrecedesPublicResultAcrossCrash() throws {
        let fixture = try Self.makeFixtureRoot(prefix: "gateway-audit-crash")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try Self.runSuccessfulChild(
            phase: "gatewayAuditSeed",
            storeURL: fixture.store,
            probeURL: fixture.probe
        )
        try Self.runCrashingChild(
            phase: "gatewayAuditCrash",
            storeURL: fixture.store,
            probeURL: fixture.probe
        )
        try Self.runSuccessfulChild(
            phase: "gatewayAuditVerify",
            storeURL: fixture.store,
            probeURL: fixture.probe
        )
    }

    @Test("committed large payload survives abnormal owner exit byte exactly")
    func largePayloadHydratesThroughFreshPublicReads() throws {
        let fixture = try Self.makeFixtureRoot(prefix: "large-blob-crash")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try Self.runCrashingChild(
            phase: "largeBlobCrashCommit",
            storeURL: fixture.store,
            probeURL: fixture.probe
        )
        try Self.runSuccessfulChild(
            phase: "largeBlobVerify",
            storeURL: fixture.store,
            probeURL: fixture.probe
        )
    }

    private static func makeFixtureRoot(
        prefix: String
    ) throws -> (root: URL, store: URL, probe: URL) {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-\(prefix)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        return (
            root,
            root.appendingPathComponent("history.store"),
            packageRoot.appendingPathComponent(
                ".build/debug/HistoryRestartProbe"
            )
        )
    }

    private static func runSuccessfulChild(
        phase: String,
        storeURL: URL,
        probeURL: URL
    ) throws {
        let process = makeProcess(
            phase: phase,
            storeURL: storeURL,
            probeURL: probeURL
        )
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == EXIT_SUCCESS,
              result == Data("\(phase.uppercased())_OK\n".utf8) else {
            throw FixtureError.childFailed(phase: phase)
        }
    }

    private static func runCrashingChild(
        phase: String,
        storeURL: URL,
        probeURL: URL
    ) throws {
        let process = makeProcess(
            phase: phase,
            storeURL: storeURL,
            probeURL: probeURL
        )
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .uncaughtSignal else {
            throw FixtureError.childDidNotCrash(phase: phase)
        }
    }

    private static func makeProcess(
        phase: String,
        storeURL: URL,
        probeURL: URL
    ) -> Process {
        let process = Process()
        process.executableURL = probeURL
        process.arguments = [phase, storeURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}
