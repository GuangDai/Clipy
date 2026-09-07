/// Public open-failure characterization through one fresh process per
/// invalid current store. Non-SQLite bytes and a read-only store directory
/// fail closed as corruptStoredValue and openStore respectively; neither permits automatic
/// empty-store recreation. No migration or historical schema is involved.
import Foundation
import Testing

@Suite("Public open-failure classification child characterization")
struct StoreOpenFailureCharacterizationTests {
    private enum FixtureError: Error {
        case childFailed(phase: String)
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
        // Framework diagnostics can contain the store path, and any stderr
        // line carrying "error:" fails CI through `scripts/diagnostic_scan.py`
        // (DATA-14 keeps the evidence channel typed and content-free instead).
        process.standardError = FileHandle.nullDevice

        try process.run()
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        let expected = Data("\(phase.uppercased())_OK\n".utf8)
        guard process.terminationReason == .exit,
              process.terminationStatus == EXIT_SUCCESS,
              result == expected else {
            // Phase-tagged (not termination-detail-tagged) so the message can
            // never carry a scanner-sensitive "error:" fragment; which fixture
            // failed is the fact the Red→Green table needs first.
            throw FixtureError.childFailed(phase: phase)
        }
    }

    private static func probeURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/HistoryRestartProbe")
    }

    @Test("fresh owner rejects non-SQLite bytes without replacing the file")
    func corruptBytesStoreFailsOpenInFreshChild() throws {
        let probeURL = Self.probeURL()
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-open-reject-corrupt-bytes-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let storeURL = storeRoot.appendingPathComponent("history.store")

        // Fixed literal, 19 bytes per repetition × 256 repetitions = 4_864
        // bytes of a repeated non-SQLite ASCII pattern. Never zero bytes —
        // SQLite treats a zero-byte file as a valid empty store, which would
        // let open succeed and silently destroy the fixture's point.
        let corruptBytes = Data(
            String(repeating: "not-a-sqlite-store/", count: 256).utf8
        )
        #expect(corruptBytes.count == 4_864)
        try corruptBytes.write(to: storeURL, options: .atomic)
        // The on-disk fixture is the bytes actually at the store path (the
        // symmetric read-back of the future-schema fixture's fileExists).
        #expect(try Data(contentsOf: storeURL) == corruptBytes)

        try Self.runChild(
            phase: "openRejectCorruptBytes",
            storeURL: storeURL,
            probeURL: probeURL
        )
        #expect(try Data(contentsOf: storeURL) == corruptBytes)
    }

    @Test("fresh owner maps a read-only store directory to the public open failure")
    func readOnlyDirectoryStoreFailsOpenInFreshChild() throws {
        let probeURL = Self.probeURL()
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-open-reject-read-only-dir-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storeRoot,
            withIntermediateDirectories: false
        )
        // Cleanup is registered as soon as the root exists (the sibling
        // cells' discipline) so even a failed permission staging below
        // cannot leak the fixture directory.
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        // The store directory EXISTS but its owner write bit is removed, so
        // SQLite cannot create the database file inside it — the
        // storage-layer permission shape. 0500 keeps read+execute: the
        // refusal is "cannot write", not an unstatable path (0000 would make
        // EACCES and ENOENT indistinguishable). Teardown restores write
        // permission BEFORE the root removal above runs, or the cleanup
        // itself is refused and leaves a 0500 directory behind in TMP.
        let historyStoreDirectory = storeRoot.appendingPathComponent(
            "HistoryStore",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: historyStoreDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o500)],
            ofItemAtPath: historyStoreDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: historyStoreDirectory.path
            )
        }
        let storeURL = historyStoreDirectory
            .appendingPathComponent("history.store")

        // Fixture self-check, symmetric with the two cells above: if the
        // runner cannot stage the permission shape, the characterization
        // would silently prove nothing, so the staging fact is asserted in
        // the test process before the child launches.
        let stagedPermissions = try FileManager.default.attributesOfItem(
            atPath: historyStoreDirectory.path
        )[.posixPermissions] as? NSNumber
        #expect(stagedPermissions?.int16Value == 0o500)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))

        try Self.runChild(
            phase: "openRejectReadOnlyDirectory",
            storeURL: storeURL,
            probeURL: probeURL
        )
    }
}
