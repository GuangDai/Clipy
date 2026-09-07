/// 05-OQ9 / 05-CE26 (`05-evidence-and-open-questions.md` §7 Q9 and §3 CE26;
/// Card 1C-2 in `04-tdd-remediation-playbook.md`; DATA-13 in
/// `01-findings.md`): the mid-transaction process-kill atomicity cell, one
/// proof cycle per kill point.
///
/// Each cycle terminates inside the real SQLite write transaction for an
/// 8 MiB capture: once before the position UPDATE, once immediately before
/// COMMIT. Both must leave complete old History state after restart; neither
/// interrupts the COMMIT syscall itself. Published but unreferenced immutable
/// files may remain for cleanup (V2-09 §6).
///
/// The fresh child checks all original fields and continued writability.
/// A fixed stderr marker proves the child reached the selected instruction.
/// Existing receipt-following crash tests prove complete new state. These
/// are process-death tests, not sudden-power-loss or filesystem durability
/// measurements.
import Foundation
import Testing

@Suite("Mid-transaction kill atomicity restart")
struct MidTransactionKillRestartTests {

    // MARK: - Fixture vocabulary

    private enum FixtureError: Error {
        /// A child that must exit cleanly did not (wrong status, reason, or
        /// success token).
        case childFailed(phase: String)
        /// The kill child neither died by signal nor at the seam marker —
        /// the interruption never happened where claimed, so the verify
        /// assertions below would prove nothing.
        case childDidNotDieAtSeam(phase: String)
    }

    /// The fixed kill-seam stderr markers, duplicated across the process
    /// boundary (the probe and this
    /// bundle intentionally keep no shared symbol for them).
    private static let closureKillMarker = "[CLIPY_TX_KILL] point=beforePositionWrite"
    private static let saveKillMarker = "[CLIPY_TX_KILL] point=beforeCommit"

    // MARK: - One proof cycle per kill point (Card 1C-2)

    @Test("kill before the position write leaves complete old state and a writable store")
    func closureKillBeforeSaveIsAtomicAcrossRestart() throws {
        let fixture = try Self.makeFixtureRoot(prefix: "midtx-kill-closure")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try Self.runSuccessfulChild(
            phase: "seed",
            storeURL: fixture.store,
            probeURL: fixture.probe
        )
        try Self.runKilledChild(
            phase: "largeBlobMidTransactionKillClosure",
            expectedMarker: Self.closureKillMarker,
            storeURL: fixture.store,
            probeURL: fixture.probe
        )
        try Self.runSuccessfulChild(
            phase: "largeBlobMidTransactionVerify",
            storeURL: fixture.store,
            probeURL: fixture.probe
        )
    }

    @Test("kill immediately before COMMIT leaves complete old state and a writable store")
    func preCommitKillLeavesOldStateAcrossRestart() throws {
        let fixture = try Self.makeFixtureRoot(prefix: "midtx-kill-save")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try Self.runSuccessfulChild(
            phase: "seed",
            storeURL: fixture.store,
            probeURL: fixture.probe
        )
        try Self.runKilledChild(
            phase: "largeBlobMidTransactionKillSave",
            expectedMarker: Self.saveKillMarker,
            storeURL: fixture.store,
            probeURL: fixture.probe
        )
        try Self.runSuccessfulChild(
            phase: "largeBlobMidTransactionVerify",
            storeURL: fixture.store,
            probeURL: fixture.probe
        )
    }

    // MARK: - Child spawn (the GatewayAuditAndLargeBlobCrashRestartTests
    // discipline, fused with HistoryMigrationInterruptionTests' combined-pipe
    // drain-before-reap for the killed child)

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
            root.appendingPathComponent("history.sqlite"),
            packageRoot.appendingPathComponent(
                ".build/debug/HistoryRestartProbe"
            )
        )
    }

    /// Runs one child to clean completion and requires its exact success
    /// token on stdout (stderr is discarded to the null device).
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
        process.standardError = FileHandle.nullDevice
        try process.run()
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == EXIT_SUCCESS,
              result == Data("\(phase.uppercased())_OK\n".utf8) else {
            throw FixtureError.childFailed(phase: phase)
        }
    }

    /// Runs the kill child and requires BOTH an uncaught signal AND the
    /// fixed seam marker: the phase's own `fatalError` fallback (an armed
    /// seam that never fired) produces a signal without the marker, so the
    /// marker assertion keeps a silent seam from greening the cycle. One
    /// combined stdout+stderr stream is drained BEFORE `waitUntilExit` —
    /// waiting before draining separate pipes can deadlock when CoreData
    /// diagnostics fill either pipe's kernel buffer.
    private static func runKilledChild(
        phase: String,
        expectedMarker: String,
        storeURL: URL,
        probeURL: URL
    ) throws {
        let process = makeProcess(
            phase: phase,
            storeURL: storeURL,
            probeURL: probeURL
        )
        let combined = Pipe()
        process.standardOutput = combined
        process.standardError = combined
        try process.run()
        let output = try combined.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationReason == .uncaughtSignal,
              String(decoding: output, as: UTF8.self)
                  .contains(expectedMarker) else {
            throw FixtureError.childDidNotDieAtSeam(phase: phase)
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
        return process
    }
}
