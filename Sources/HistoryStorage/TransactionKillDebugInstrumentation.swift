#if DEBUG
import Foundation
import SwiftData

/// Process-death seam strictly inside the one durable commit transaction
/// (`docs/05-authority-kernel.md` §10), closing REVIEW 05-OQ9/05-CE26
/// (`05-evidence-and-open-questions.md` §7 Q9 and §3 CE26 — "SwiftData
/// custom migration在transaction中child kill、externalStorage写入中kill后的原子性";
/// "randomized child kill覆盖willSave/didSave/return") and Card 1C-2
/// (`04-tdd-remediation-playbook.md`: "在…transaction return，以及大型external
/// capture/revise/clear的已批准barrier执行process kill…fresh child重开只能看到
/// 完整old或完整new state"). Every earlier kill witness dies OUTSIDE the
/// commit boundary — `crashCommit`/`largeBlobCrashCommit` after the receipt,
/// `gatewayAuditCrash` post-commit at the publication seam, the migration
/// abort seam before any transaction begins — and the WS13 closure-throw
/// proofs keep the process alive. This seam adds the missing in-flight
/// death. Package-visible solely so `HistoryRestartProbe` can arm it; an
/// ordinary product call leaves the TaskLocal nil, and Release builds
/// compile the whole type out (the
/// `ExternalReadPublicationDebugInstrumentation` precedent,
/// GatewayExternalReads.swift).
///
/// Two kill points, one per physics of the commit window:
/// - `inClosurePreSave` (window A): every mutation, HCR, and audit row is
///   applied but still pending in memory only — the singleton position is
///   unwritten and the implicit save has not been attempted — so death here
///   deterministically produces complete-OLD.
/// - `saveAttemptWillSave` (window B): anchored at the START of the save
///   interval through the `ModelContext.willSave` notification (macOS 14+),
///   the closest public API anchor to the SQLite commit and any
///   externalStorage write-out; only an old-or-new verdict is admissible
///   afterwards because Apple publishes no externalStorage write-time or
///   atomicity contract (`apple-swiftdata-durability-memo.md` UNKNOWN list).
///   Process-kill evidence only — never an fsync, sudden-power-loss, or
///   sidecar-layout claim.
package enum TransactionKillDebugInstrumentation {
    /// The two process-death coordinates (see the type comment).
    package enum KillPoint: String, Sendable {
        /// Window A: inside the transaction closure, after staging, before
        /// the singleton write and any save attempt.
        case inClosurePreSave
        /// Window B: the save interval's start, via `ModelContext.willSave`.
        case saveAttemptWillSave
    }

    /// The armed kill point; nil in production and in every ordinary probe
    /// phase. Propagates across the `perform` → `commitCapture` actor hop
    /// within one task, exactly as `gatewayAuditCrash`'s TaskLocal already
    /// proves for this path.
    @TaskLocal package static var killPoint: KillPoint?

    /// Fixed, content-free stderr marker prefix emitted immediately before
    /// the injected death, so a parent fixture can prove the child died AT
    /// the seam rather than anywhere else — the
    /// `MigrationBackfillAbortProbe.markerLine` discipline. No store path,
    /// item identifier, or clipboard value can enter it.
    package static let markerPrefix = "[CLIPY_TX_KILL]"

    /// The complete fixed marker line for one kill point.
    package static func markerLine(for point: KillPoint) -> String {
        "\(markerPrefix) point=\(point.rawValue)"
    }

    /// Emits the fixed marker, then terminates. No rollback, cleanup, or
    /// framework code regains control after the marker.
    package static func terminate(at point: KillPoint) -> Never {
        FileHandle.standardError.write(
            Data((markerLine(for: point) + "\n").utf8)
        )
        fatalError("intentional mid-transaction kill point=\(point.rawValue)")
    }

    /// Window A site — called from inside the `ModelContext.transaction`
    /// closure at the X-HCR.2 WS-J1-5 window (b) interleave. A no-op unless
    /// the closure kill point is armed.
    package static func terminateIfClosureKillPointArmed() {
        guard killPoint == .inClosurePreSave else { return }
        terminate(at: .inClosurePreSave)
    }

    /// Window B site — called from `executeCommitTransaction` before
    /// `context.transaction` runs its implicit save. Registers a
    /// `ModelContext.willSave` observer; same-process notifications are
    /// delivered synchronously on the posting (saving) thread, so the kill
    /// lands at the save interval's start with the transaction call frame
    /// still live. The observer is NOT object-filtered: Apple does not
    /// document `willSave`'s `object` (it may be the backing
    /// NSManagedObjectContext rather than the ModelContext), so the
    /// widest-acceptance form is used — within the armed window this process
    /// performs exactly one save, by THIS operation-local context (browse
    /// and details are read-only, and the open-path startup transaction
    /// ran before the kill point was armed). Returns nil unless the save
    /// kill point is armed; the caller must `defer` the matching `disarm`
    /// for the only surviving path — the one where the save never reached
    /// this seam.
    package static func armSaveAttemptKillObserver(
        for context: ModelContext
    ) -> (any NSObjectProtocol)? {
        guard killPoint == .saveAttemptWillSave else { return nil }
        return NotificationCenter.default.addObserver(
            forName: ModelContext.willSave,
            object: nil,
            queue: nil
        ) { _ in
            terminate(at: .saveAttemptWillSave)
        }
    }

    /// Removes an observer returned by `armSaveAttemptKillObserver`. A kill
    /// at the seam never unwinds; this runs only when the armed transaction
    /// completed without posting `willSave`, keeping the observer from
    /// leaking past the operation-local context's lifetime.
    package static func disarmSaveAttemptKillObserver(
        _ observer: (any NSObjectProtocol)?
    ) {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
    }
}
#endif
