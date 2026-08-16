/// RET-PLATFORM-1b(e) — the ENGINE-LEVEL interruption proof
/// (`docs/v2/V2-02-retention.md` Record 3: "prove on the macOS runner that
/// an interrupted migration (process death mid-backfill) leaves the store
/// openable and that the re-run reproduces exactly the (a)/(b) invariants").
///
/// `HistoryMigrationTests` (d) proves the MODEL-level clause — a second
/// backfill over one live context. This suite proves the ENGINE-level
/// clause: a genuine child PROCESS dies mid-backfill — inside the custom
/// stage's `didMigrate` during `ModelContainer` construction, killed by
/// `exit(EXIT_FAILURE)` with no error thrown, no rollback, and no cleanup —
/// and the SAME on-disk store then re-opens through the complete public
/// `SwiftDataHistory.open` path with every RET-PLATFORM-1b (a)/(b)/(c)
/// invariant reproduced exactly.
///
/// Mechanism (all three pieces DEBUG-only, cited, and inert in release):
/// 1. the seam — `MigrationBackfillAbortProbe`
///    (`Sources/HistoryStorage/RetainedBytesBackfill.swift`), gated exactly
///    like `StorageLifecycleDebugProbe.environmentConfigured` (`#if DEBUG`
///    plus one `ProcessInfo` environment read): armed only when
///    `CLIPY_MIGRATION_BACKFILL_ABORT_AFTER` holds a positive row count, it
///    emits one fixed stderr marker and exits at that computed-row count,
///    mid-loop, BEFORE any projection write;
/// 2. the child — the hidden `--migration-abort-child` runner mode
///    (`Sources/HistoryPerfRunner/MigrationInterruptionChild.swift`), which
///    runs the complete public `SwiftDataHistory.open` path over the seeded
///    v1 store and exists solely so a test can spawn a real process that
///    dies inside the hop;
/// 3. the spawn — the repo's established child-process discipline
///    (`PersistentOpenChild.runPersistentOpenChildProcess`): one combined
///    stdout+stderr pipe drained BEFORE `waitUntilExit` (CoreData
///    diagnostics can fill a pipe's kernel buffer and deadlock a
///    wait-then-read parent), null stdin, and a fixed-string failure
///    vocabulary that never echoes store paths or store-derived values.
///
/// Child-spawn pattern choice (documented per the gate's requirement): the
/// test lane cannot re-invoke the Swift Testing bundle as a child
/// (unsupported), and the repo's own process-spawning seam is the RUNNER
/// spawning ITSELF (`PersistentOpenChild` — only an executable reliably
/// knows its `Bundle.main.executableURL`). The fixture therefore locates
/// the DEBUG runner binary at `<packageRoot>/.build/debug/HistoryPerfRunner`
/// (derived from `#filePath`; valid wherever `swift build`/`swift test`
/// share the default scratch path — exactly the CI spm job's layout, and
/// the `HistoryStorageTests → HistoryPerfRunner` Package.swift edge
/// guarantees `swift test` builds the executable even without a prior
/// `swift build`). The parent arms the seam ONLY in the child's
/// environment; this test process keeps it disarmed so its own re-open
/// cannot die at the seam.
///
/// The fixture seeds the IDENTICAL three-item v1 store as
/// `HistoryMigrationTests` (b) (`MigrationSeeding`): A (single text
/// representation), B (text + PNG Canonical with two stored revisions — the
/// revision-bearing shape), C (single text representation), plus the
/// position singleton at 3. The seam is armed after 2 of the 3 rows, so
/// death is provably MID-loop (row 3 never computes; the backfill's
/// transaction never begins).
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("V1 → V2 migration interruption (RET-PLATFORM-1b(e) engine level)")
struct HistoryMigrationInterruptionTests {

    // MARK: - Fixtures

    /// Every way the spawn itself can be invalid (distinct from the
    /// migration invariants under proof).
    private enum FixtureError: Error, Equatable {
        /// The DEBUG runner executable is not where the default SwiftPM
        /// scratch path puts it (run `swift build` before `swift test`, or
        /// use the default `--scratch-path`).
        case runnerExecutableUnavailable
        /// The child did not die at the seam (wrong exit status, or the
        /// fixed marker missing) — the interruption never happened, so the
        /// re-open assertions below would prove nothing.
        case childDidNotDieAtSeam
    }

    /// The DEBUG runner executable under the default SwiftPM scratch path
    /// (`#filePath` = `<packageRoot>/Tests/HistoryStorageTests/<this
    /// file>`; three `deletingLastPathComponent()` calls reach the package
    /// root). Valid for the CI spm job (`swift build` then `swift test` in
    /// the workspace root) and any local run sharing that layout; the
    /// Package.swift `HistoryStorageTests → HistoryPerfRunner` edge
    /// guarantees the binary is built.
    private static func debugRunnerExecutableURL() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executable = packageRoot
            .appendingPathComponent(".build/debug/HistoryPerfRunner")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw FixtureError.runnerExecutableUnavailable
        }
        return executable
    }

    /// Spawns one interruption child over `storeURL` with the seam armed
    /// after `abortAfterRows` computed rows, applying the
    /// `PersistentOpenChild` process discipline (combined pipe, drain
    /// before reap, null stdin). The child's inherited environment is
    /// copied and the seam variable set ONLY there.
    private static func runInterruptionChild(
        executableURL: URL,
        storeURL: URL,
        abortAfterRows: Int
    ) throws -> (terminationStatus: Int32, output: Data) {
        let process = Process()
        let combinedOutput = Pipe()
        process.executableURL = executableURL
        // The argv contract of
        // Sources/HistoryPerfRunner/MigrationInterruptionChild.swift (a
        // literal duplicated across the process boundary — the two share no
        // module).
        process.arguments = ["--migration-abort-child", storeURL.path]
        process.standardInput = FileHandle.nullDevice
        // One combined stream, drained while the child is alive: waiting
        // before draining separate pipes can deadlock when CoreData emits
        // enough diagnostics to fill either pipe's kernel buffer.
        process.standardOutput = combinedOutput
        process.standardError = combinedOutput
        var environment = ProcessInfo.processInfo.environment
        environment[MigrationBackfillAbortProbe.environmentKey] = String(abortAfterRows)
        process.environment = environment

        try process.run()
        // `readToEnd` drains concurrently with execution and returns after
        // the child closes both inherited descriptors; output is interpreted
        // only after termination and never surfaced verbatim.
        let output = try combinedOutput.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    // MARK: - RET-PLATFORM-1b(e): process death mid-backfill

    /// One complete engine-level interruption cycle over an on-disk v1
    /// store:
    ///
    /// 1. seed the genuine three-item v1 store (old schema, no migration
    ///    plan — the `HistoryMigrationTests` (b) fixture, via
    ///    `MigrationSeeding`);
    /// 2. spawn the child; it runs the public `SwiftDataHistory.open` path
    ///    and dies AT the seam — `EXIT_FAILURE` via a plain exit (not a
    ///    signal), with the fixed marker on stderr proving the death point
    ///    is the backfill's compute loop after row 2 of 3;
    /// 3. re-open the SAME store through the complete public
    ///    `SwiftDataHistory.open` path in THIS process — the "leaves the
    ///    store openable" clause, and the engine-level re-run: the child
    ///    died before any projection write, so every `RetainedBytesRow`
    ///    present afterwards was produced by this re-run;
    /// 4. prove the re-run reproduced the invariants EXACTLY as
    ///    `HistoryMigrationTests` (b) does — byte-identical items
    ///    ((c): ids, Content Version, all three blobs per item), the
    ///    surviving position singleton, the BOTH-directions 1:1 projection
    ///    law ((a)), and scalars equal to an independent codec
    ///    recomputation cross-checked against the literal fixture
    ///    arithmetic ((b)) — plus the all-disabled config bootstrap of the
    ///    full open path (the (c)-test shape).
    @Test("process death mid-backfill leaves the store openable; the re-run reproduces (a)/(b) exactly")
    func processDeathMidBackfillLeavesStoreOpenableAndRerunReproducesInvariants() async throws {
        let storeURL = WSSupport.tempStoreURL("v2-migration-interruption")
        defer { WSSupport.removeStore(storeURL) }

        // 1. A genuine v1 store with the OLD schema and no migration plan.
        let v1Container = try MigrationSeeding.makeV1Container(storeURL: storeURL)
        let v1Context = ModelContext(v1Container)
        v1Context.autosaveEnabled = false
        let seeded = try await MigrationSeeding.seedV1Store(into: v1Context)
        #expect(seeded.count == 3)

        // RET-PLATFORM-1: the seeded position singleton's value BEFORE any
        // hop runs (scalar copies — a `@Model` stays bound to the context
        // that fetched it).
        let seededPositionRows = try v1Context.fetch(
            FetchDescriptor<LastChangePositionRow>()
        )
        #expect(seededPositionRows.count == 1)
        let seededPosition = try #require(seededPositionRows.first)
        let seededPositionKey = seededPosition.key
        let seededPositionValue = seededPosition.rawValue
        let seededPositionMaximumUnpinned = seededPosition.maximumUnpinnedItems

        // 2. The interruption child: armed after 2 of the 3 rows, so death
        //    is provably MID-loop (row 3 never computes; the backfill's
        //    transaction never begins).
        let child = try Self.runInterruptionChild(
            executableURL: try Self.debugRunnerExecutableURL(),
            storeURL: storeURL,
            abortAfterRows: 2
        )
        guard child.terminationStatus == EXIT_FAILURE,
              child.terminationReason == Process.TerminationReason.exit,
              String(decoding: child.output, as: UTF8.self)
                  .contains(MigrationBackfillAbortProbe.markerLine) else {
            throw FixtureError.childDidNotDieAtSeam
        }

        // 3. The interrupted store RE-OPENS through the complete public
        //    open path (steps 1–10: the migration hop inside `ModelContainer`
        //    construction, then the Authority startup). The seam is disarmed
        //    in THIS process, so the engine-level re-run runs to completion.
        _ = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .persistent(storeURL: storeURL),
                initialMaximumUnpinnedItems: 200
            )
        )

        // 4. The invariants, through the INDEPENDENT container (never the
        //    Authority's actor-isolated one).
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)

        // RET-PLATFORM-1b(c): every item still present, byte-identical —
        // neither the interrupted hop nor the re-run mutated a v1
        // blob/id/version.
        let rows = try context.fetch(FetchDescriptor<HistoryItemRow>())
        #expect(rows.count == seeded.count)
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(Set(rowsByID.keys) == Set(seeded.map(\.id)))
        for item in seeded {
            let row = try #require(rowsByID[item.id])
            #expect(row.contentVersionRaw == item.contentVersionRaw)
            #expect(row.canonicalBlob == item.canonicalBlob)
            #expect(row.revisionStateBlob == item.revisionStateBlob)
            #expect(row.canonicalSignatureBlob == item.canonicalSignatureBlob)
        }

        // RET-PLATFORM-1: the singleton position survived the interrupted
        // hop AND the re-run byte-identically.
        let migratedPositionRows = try context.fetch(
            FetchDescriptor<LastChangePositionRow>()
        )
        #expect(migratedPositionRows.count == 1)
        let migratedPosition = try #require(migratedPositionRows.first)
        #expect(migratedPosition.key == seededPositionKey)
        #expect(migratedPosition.rawValue == seededPositionValue)
        #expect(
            migratedPosition.maximumUnpinnedItems == seededPositionMaximumUnpinned
        )

        // RET-PLATFORM-1b(a): every item has exactly one RetainedBytesRow
        // AND every RetainedBytesRow names a retained item (both
        // directions). The child wrote nothing (death pre-transaction), so
        // these rows are exactly the re-run's output.
        let bytesRows = try context.fetch(FetchDescriptor<RetainedBytesRow>())
        #expect(bytesRows.count == seeded.count)
        #expect(Set(bytesRows.map(\.itemID)) == Set(seeded.map(\.id)))

        // RET-PLATFORM-1b(b): each scalar equals an independently recomputed
        // value from the same codecs, cross-checked against the literal
        // fixture arithmetic — the exact `HistoryMigrationTests` (b) proof.
        let bytesByItemID = Dictionary(
            uniqueKeysWithValues: bytesRows.map { ($0.itemID, $0) }
        )
        for item in seeded {
            let recomputed = try MigrationSeeding.recomputedScalars(
                for: try #require(rowsByID[item.id])
            )
            #expect(recomputed.canonicalBytes == item.expectedCanonicalBytes)
            #expect(recomputed.revisionCount == item.expectedRevisionCount)
            #expect(recomputed.revisionBytes == item.expectedRevisionBytes)

            let bytesRow = try #require(bytesByItemID[item.id])
            #expect(bytesRow.canonicalBytes == recomputed.canonicalBytes)
            #expect(bytesRow.revisionCount == recomputed.revisionCount)
            #expect(bytesRow.revisionBytes == recomputed.revisionBytes)
            #expect(bytesRow.bytesSchemaVersion == 1)
        }

        // The full open bootstrapped exactly one all-disabled config row
        // (open's step 5, never migration's — the `HistoryMigrationTests`
        // (c) shape; V2-02 §3.3 literals, not from the bootstrap code).
        let configs = try context.fetch(
            FetchDescriptor<RetentionExpansionConfigRow>()
        )
        #expect(configs.count == 1)
        let config = try #require(configs.first)
        #expect(config.key == "retention-expansion")
        #expect(config.agePolicyEnabled == false)
        #expect(config.ageMaxSeconds == 0)
        #expect(config.storagePolicyEnabled == false)
        #expect(config.storageMaxBytes == 0)
        #expect(config.revisionPolicyEnabled == false)
        #expect(config.revisionMaxCount == nil)
        #expect(config.revisionMaxBytes == nil)
        #expect(config.configSchemaVersion == 1)
    }
}
