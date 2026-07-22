/// Deterministic-concurrency harness for the walking-skeleton proofs WS12
/// (observation registration race), WS13 (transaction failure), WS15
/// (thumbnail version fence), and WS20 (concurrent revision and coalescing)
/// in docs/06-cross-cutting.md §8.
///
/// Roadmap-owned test infrastructure (docs/roadmap/03-historystorage.md,
/// "Deliverables — test infrastructure"): scaffolded at step 0 as
/// `SuspensionGate`, finished at step 5 with `resumeAll()` and the
/// `runParked(at:operation:whileCommitting:)` helper. The file is
/// self-contained on purpose — it imports nothing, in particular nothing from
/// HistoryStorage: production code cannot reference a test-target type, so
/// HistoryAuthority's seams (including the WS13 transaction-injection seam
/// inside its transaction closure) are exposed as plain named points, and the
/// test side wires each name to `park(at:)` on a gate it owns.
///
/// Intended WS-test shape (drives one exact interleaving deterministically):
///
/// 1. Run the operation under test in a task; at each seam HistoryAuthority
///    exposes (e.g. between the two phases of a revision), it awaits
///    `park(at:)` on a uniquely named point.
/// 2. The test awaits `waitForPark(_:)` to know the operation reached the
///    seam.
/// 3. The test performs the interfering commit, then calls `resume(_:)` so
///    the parked operation continues into the asserted interleaving.
///
/// `runParked(at:operation:whileCommitting:)` packages exactly this shape;
/// reach for the raw primitives when an interleaving needs more than one
/// named point or extra assertions between park and resume.
///
/// Usage rules: each named point parks at most one task at a time, and
/// `resume(_:)` is edge-triggered — resuming a point with nothing parked is a
/// no-op and does not latch for a later park.
actor SuspensionGate {
    /// Tasks currently parked, keyed by suspension-point name.
    private var parked: [String: CheckedContinuation<Void, Never>] = [:]
    /// Test-side waiters blocked in `waitForPark(_:)`, keyed by point name.
    private var parkObservers: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Parks the calling task at the suspension point named `point` until the
    /// harness calls `resume(_:)` or `resumeAll()`. Wakes any tasks blocked in
    /// `waitForPark(_:)` for the same point.
    func park(at point: String) async {
        await withCheckedContinuation { continuation in
            precondition(
                parked[point] == nil,
                "SuspensionGate: two tasks parked at '\(point)'"
            )
            parked[point] = continuation
            for observer in parkObservers.removeValue(forKey: point) ?? [] {
                observer.resume()
            }
        }
    }

    /// Resumes the task parked at `point`. No-op when nothing is parked there.
    func resume(_ point: String) {
        parked.removeValue(forKey: point)?.resume()
    }

    /// Resumes every task currently parked at any named point.
    ///
    /// Intended for teardown and failure paths: a task left parked would
    /// otherwise suspend forever. Tasks blocked in `waitForPark(_:)` keep
    /// waiting — resuming is not parking.
    func resumeAll() {
        let continuations = Array(parked.values)
        parked.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    /// Waits until some task has parked at `point`. Returns immediately when a
    /// task is already parked there.
    func waitForPark(_ point: String) async {
        if parked[point] != nil { return }
        await withCheckedContinuation { continuation in
            parkObservers[point, default: []].append(continuation)
        }
    }

    /// Runs `operation` paused at the named point while `interference`
    /// commits, then resumes the paused operation — the canonical WS12/WS15/
    /// WS20 interleaving, driven deterministically.
    ///
    /// Sequence: `operation` starts in a child task; once it is parked at
    /// `point`, `interference` runs to completion on the calling task (the
    /// interfering commit); the parked operation is then resumed and its
    /// result awaited. Returns both results as `(paused:, interfering:)`.
    ///
    /// Contract: `operation` must park at `point` exactly once; an operation
    /// that never parks leaves the helper suspended rather than proceeding
    /// nondeterministically. A failure thrown by either closure resumes every
    /// parked point, cancels the child task, and awaits it before
    /// rethrowing, so no task is left parked behind a failed test.
    func runParked<Paused: Sendable, Interfering: Sendable>(
        at point: String,
        operation: @Sendable () async throws -> Paused,
        whileCommitting interference: @Sendable () async throws -> Interfering
    ) async throws -> (paused: Paused, interfering: Interfering) {
        let task = Task { try await operation() }
        do {
            await waitForPark(point)
            let interfering = try await interference()
            resume(point)
            let paused = try await task.value
            return (paused: paused, interfering: interfering)
        } catch {
            // Failure path: never leave the operation parked at this or any
            // later point of the same interleaving, and never let the child
            // task outlive the helper.
            resumeAll()
            task.cancel()
            _ = try? await task.value
            throw error
        }
    }
}
