/// RET-PLATFORM-1b(e) engine-level interruption child (`V2-02` Record 3:
/// "prove on the macOS runner that an interrupted migration (process death
/// mid-backfill) leaves the store openable and that the re-run reproduces
/// exactly the (a)/(b) invariants") — the hidden DEBUG child mode that
/// `Tests/HistoryStorageTests/HistoryMigrationInterruptionTests.swift`
/// spawns.
///
/// Child-spawn pattern (the repo's only supported process-spawning seam):
/// `PersistentOpenChild` established that the RUNNER spawns itself because
/// only an executable reliably knows its own `Bundle.main.executableURL`;
/// the test lane can neither re-invoke the Swift Testing bundle as a child
/// (unsupported) nor reach this binary as a module. The test therefore
/// locates the DEBUG runner executable on disk (its `#filePath`-derived
/// `.build/debug/HistoryPerfRunner`, guaranteed built by the
/// `HistoryStorageTests → HistoryPerfRunner` Package.swift edge) and spawns
/// this mode as a `Process` child.
///
/// The child runs the complete PUBLIC `SwiftDataHistory.open` path over the
/// given on-disk store. The parent arms the `RetainedBytesBackfill`
/// interruption seam through this child's environment
/// (`CLIPY_MIGRATION_BACKFILL_ABORT_AFTER`), so the custom stage's
/// `didMigrate` backfill kills the process mid-loop (`exit(EXIT_FAILURE)`)
/// during `ModelContainer` construction — inside the single `V1 → V2` hop,
/// with no error handling, no cleanup, and no chance for the migration
/// machinery to roll back in-process. The parent then proves the
/// interrupted store re-opens and that the engine-level re-run reproduces
/// the RET-PLATFORM-1b (a)/(b) invariants exactly.
///
/// Failure output is deliberately fixed-string (the `PersistentOpenChild`
/// stance): neither the store URL nor any underlying error can carry runner
/// paths or store-derived values into CI evidence.
import Foundation
import HistoryCore
import HistoryStorage

/// The hidden argv contract of this mode (a literal duplicated by the
/// spawning fixture — the two processes share no module).
internal let migrationInterruptionChildFlag = "--migration-abort-child"

/// Runs one interruption child over `arguments[0]` (the store path).
/// Returns only when the seam FAILED to kill the process: every success
/// shape of this mode is death inside `SwiftDataHistory.open`.
internal func runMigrationInterruptionChild(arguments: [String]) async -> Int {
    guard arguments.count == 1 else { return 1 }
#if DEBUG
    do {
        _ = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .persistent(
                    storeURL: URL(fileURLWithPath: arguments[0])
                )
            )
        )
        // Reaching here means the seam never fired — the environment was not
        // armed, or the store needed no migration. Either way the
        // interruption proof is invalid: fail distinctly so the parent
        // reports a disarmed fixture rather than a silent success.
        try? FileHandle.standardError.write(contentsOf: Data(
            "HistoryPerfRunner migration-abort child: seam did not fire\n".utf8
        ))
        return 1
    } catch {
        try? FileHandle.standardError.write(contentsOf: Data(
            "HistoryPerfRunner migration-abort child: open failed before the seam\n".utf8
        ))
        return 1
    }
#else
    // Release: the RET-PLATFORM-1b(e) seam is compiled out, so this mode
    // must never appear to have interrupted anything.
    return 1
#endif
}
