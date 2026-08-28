/// 46-4 external-clone validation child pair — doc 11 §4.3's
/// "External-clone 验证子进程" row and the 05 blind spot
/// (`05-evidence-and-open-questions.md`:165: existing CI evidence
/// "未证明逐个 hydrate 所有 external-backed canonical/revision payload").
///
/// A seed child commits the fixed six-fixture table — plain text,
/// non-ASCII text, a real 1×1 grayscale PNG, one dual text+PNG capture
/// whose canonical order is the scalar-sorted [png, text], an 8 MiB
/// `public.data` blob the same child revises to a byte-distinct 8 MiB
/// pattern, and one more text — exits normally, and a fresh validator
/// child then walks the public browse/details/pastePayload surface and
/// compares every hydrated canonical, effective, and revision payload
/// byte-for-byte with the deterministic fixtures, never a digest.
///
/// As with the largeBlob chain, `@Attribute(.externalStorage)` is only an
/// opaque placement hint (Apple documents that a value *may* be
/// externalized, with no threshold or locator contract): these fixtures
/// assert neither an external file nor any sidecar, and claim no fsync,
/// sudden-power-loss atomicity, or permanent external placement.
import Foundation
import Testing

@Suite("External-clone validation child")
struct ExternalCloneValidationChildTests {
    private enum FixtureError: Error {
        case childFailed(phase: String)
    }

    @Test("fresh validator hydrates every payload after the seed child exits")
    func validatorChildHydratesAllPayloadsAfterSeedExit() throws {
        let fixture = try Self.makeFixtureRoot(prefix: "external-clone-validation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Serial by construction: the validator must observe exactly the
        // terminated seed owner's durable state.
        try Self.runSuccessfulChild(
            phase: "validateSeed",
            storeURL: fixture.store,
            probeURL: fixture.probe
        )
        try Self.runSuccessfulChild(
            phase: "validateAll",
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
