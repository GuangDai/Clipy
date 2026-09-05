/// StoreRootLeaseTests — the DATA-7a cross-process single-writer lease proof
/// (REVIEW docs/reviews/2026-08-22-clipy-maccy-deep-review/01-findings.md
/// DATA-7; 04-tdd-remediation-playbook.md PLAY-DISK-0B;
/// 11-ai-todo-map-2026-08-23.md §4.5).
///
/// A live probe child owns the store through the public facade (holding the
/// StoreRoot lease); a second process's open of the SAME root must fail with
/// the typed `.persistence(.storeAlreadyOpen)` before any `ModelContainer`
/// exists; after the owner's CLEAN exit — stdin EOF, ordinary process
/// termination — a fresh child reacquires. The record lock is released by
/// the kernel on any process exit, so no stale-lease reclamation exists to
/// test. The same-process member pins the per-process record-lock semantics
/// the in-process restart tests rely on (WS14/WS21 composed restart, HCR
/// owner-release): a second acquisition inside one process is permitted, and
/// the same-process no-second-writer rule stays at the app composition
/// root's `ClipyCompositionError.storeAlreadyOpen` guard.
///
/// The Package.swift test-target dependency guarantees the probe is already
/// built; the test launches the same `.build/debug` product convention used
/// by the sibling restart children, without nesting another SwiftPM process
/// inside `swift test`. The store directory is created upfront (repo CI
/// rule).
import Foundation
import Testing
@testable import HistoryStorage

@Suite("StoreRoot single-writer lease")
struct StoreRootLeaseTests {
    private enum FixtureError: Error {
        case childFailed
    }

    /// fcntl record locks are per-PROCESS: a second acquisition inside this
    /// same process succeeds. This pins the deliberate allowance the
    /// in-process sequential-reopen tests exercise; cross-process denial is
    /// the child proof below.
    @Test("a second acquisition in the same process is permitted")
    func sameProcessReacquisitionIsPermitted() throws {
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-store-lease-process-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let storeURL = storeRoot.appendingPathComponent("history.store")

        let first = try StoreRootLease.acquire(storeURL: storeURL)
        let second = try StoreRootLease.acquire(storeURL: storeURL)
        withExtendedLifetime((first, second)) {
            #expect(FileManager.default.fileExists(
                atPath: storeURL.deletingLastPathComponent()
                    .appendingPathComponent("history.store.lease").path
            ))
        }
    }

    @Test("second process lease is denied until the owner's clean exit")
    func secondProcessLeaseDeniedUntilOwnerExits() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let probeURL = packageRoot
            .appendingPathComponent(".build/debug/HistoryRestartProbe")
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-store-lease-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let storeURL = storeRoot.appendingPathComponent("history.store")

        // Owner child: opens through the public facade, reports the held
        // lease with the READY marker, then parks until stdin EOF.
        let owner = Process()
        owner.executableURL = probeURL
        owner.arguments = ["leaseHold", storeURL.path]
        let ownerOutput = Pipe()
        let ownerInput = Pipe()
        owner.standardInput = ownerInput
        owner.standardOutput = ownerOutput
        // Framework diagnostics can contain the store path. They are neither
        // evidence nor useful parent output, so keep the tracer channel
        // fixed and content-free.
        owner.standardError = FileHandle.nullDevice
        try owner.run()

        // Deterministic handshake — the marker, never a sleep, fences the
        // owner's acquired lease before the second process attempts its own.
        let readyMarker = Data("LEASEHOLD_READY\n".utf8)
        var transcript = Data()
        while transcript.range(of: readyMarker) == nil {
            let chunk = ownerOutput.fileHandleForReading.availableData
            guard !chunk.isEmpty else {
                owner.terminate()
                throw FixtureError.childFailed
            }
            transcript.append(chunk)
        }

        // The second process's open of the SAME StoreRoot fails with the
        // typed lease denial; the probe child asserts the exact
        // `HistoryFailure` through the production public open path.
        try Self.runChild(
            phase: "openRejectLeasedStore",
            storeURL: storeURL,
            probeURL: probeURL,
            expectedOutput: "OPENREJECTLEASEDSTORE_OK\n"
        )

        // Clean owner exit (stdin EOF → ordinary process termination)
        // releases the lease; the owner's store stays a healthy empty store.
        try ownerInput.fileHandleForWriting.close()
        let tail = try ownerOutput.fileHandleForReading.readToEnd() ?? Data()
        transcript.append(tail)
        owner.waitUntilExit()
        guard owner.terminationReason == .exit,
              owner.terminationStatus == EXIT_SUCCESS,
              transcript == Data("LEASEHOLD_READY\nLEASEHOLD_OK\n".utf8) else {
            throw FixtureError.childFailed
        }

        // A fresh child reacquires the released StoreRoot.
        try Self.runChild(
            phase: "leaseHold",
            storeURL: storeURL,
            probeURL: probeURL,
            expectedOutput: "LEASEHOLD_READY\nLEASEHOLD_OK\n"
        )
    }

    private static func runChild(
        phase: String,
        storeURL: URL,
        probeURL: URL,
        expectedOutput: String
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
        process.standardError = FileHandle.nullDevice

        try process.run()
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == EXIT_SUCCESS,
              result == Data(expectedOutput.utf8) else {
            throw FixtureError.childFailed
        }
    }
}
