/// StoreRootLease.swift — the cross-process single-writer lease on one
/// persistent StoreRoot (REVIEW 01-findings.md DATA-7;
/// 04-tdd-remediation-playbook.md PLAY-DISK-0B;
/// 11-ai-todo-map-2026-08-23.md §4.5 DATA-7a).
///
/// The lease is a dedicated zero-byte artifact beside the store file inside
/// the StoreRoot, created once and never unlinked: unlinking would let a new
/// creator race a still-locked inode held by a dying owner. Mutual exclusion
/// comes from a `fcntl(F_SETLK)` whole-file write lock on that artifact —
/// never on the SQLite store file itself, whose byte-range locks belong to
/// SQLite alone.
///
/// Chosen semantics, fixed by the review row:
///
/// - acquired nonblocking BEFORE any `ModelContainer` exists, held for the
///   owning facade's lifetime (process lifetime in the app);
/// - a second OWNER PROCESS is refused with the typed sibling failure
///   `HistoryFailure.persistence(.storeAlreadyOpen)`;
/// - the kernel releases the lock on ANY process exit, clean or crashed, so
///   a fresh owner reacquires without stale-PID scanning, grace periods, or
///   any other reclamation heuristic (PLAY-DISK-0B's "首个owner退出/崩溃后
///   fresh child可安全reacquire" holds by construction);
/// - record locks are per-PROCESS: a second acquisition inside the same
///   process succeeds. The same-process no-second-writer rule is not
///   re-enforced here — it stays at the app composition root's
///   `ClipyCompositionError.storeAlreadyOpen` guard (roadmap 06; PLAY-DISK-0A)
///   — and the in-process sequential-reopen tests (WS14/WS21 composed
///   restart, HCR owner-release) rely on this allowance. Documented boundary
///   of that allowance: closing ANY descriptor a process holds on the
///   artifact drops the process's record lock on it, so two simultaneously
///   live same-process owners would weaken the exclusion until the survivor
///   exits; the composition root's never-released reservation makes that
///   shape unreachable in the product.
import Foundation
import HistoryCore

/// The held lease: an open, locked descriptor. Release is descriptor close
/// at deallocation (or process exit) — there is deliberately no explicit
/// unlock call.
internal final class StoreRootLease: Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    /// Acquires the exclusive lease for the StoreRoot containing
    /// `storeURL`, creating the lease artifact on first use. Path spelling is
    /// irrelevant: aliases (`..`, symlinked parents) resolve to the same
    /// artifact inode, and the lock binds the inode (PLAY-DISK-0A's alias
    /// convergence at the process boundary).
    ///
    /// Failure mapping (03b §10): contention — another live process holds
    /// the lock — throws `.persistence(.storeAlreadyOpen)`; every other
    /// acquisition failure (a missing or unwritable StoreRoot directory, a
    /// non-regular artifact, a full volume) is part of preparing the store's
    /// location and stays the flattened `.persistence(.openStore)` (DATA-14)
    /// — fail-closed, with no stale-state inspection.
    internal static func acquire(storeURL: URL) throws -> StoreRootLease {
        let leaseURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent(storeURL.lastPathComponent + ".lease")
        let descriptor = Darwin.open(
            leaseURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw HistoryFailure.persistence(.openStore)
        }
        var request = flock()
        request.l_type = Int16(F_WRLCK)
        request.l_whence = Int16(SEEK_SET)
        request.l_start = 0
        request.l_len = 0
        guard Darwin.fcntl(descriptor, F_SETLK, &request) == 0 else {
            let failure = errno
            _ = Darwin.close(descriptor)
            if failure == EAGAIN || failure == EACCES {
                throw HistoryFailure.persistence(.storeAlreadyOpen)
            }
            throw HistoryFailure.persistence(.openStore)
        }
        return StoreRootLease(descriptor: descriptor)
    }
}
