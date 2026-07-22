/// Deterministic-concurrency harness — **step-0 scaffold** for the
/// walking-skeleton proofs WS12 (observation registration race), WS13
/// (transaction failure), WS15 (thumbnail version fence), and WS20 (concurrent
/// revision and coalescing) in docs/06-cross-cutting.md §8.
///
/// Step 0 ships only `SuspensionGate`. The transaction-injection seam that
/// WS13 drives finishes inside HistoryAuthority at roadmap step 5
/// (docs/roadmap/README.md §3), which is why this file imports nothing from
/// HistoryStorage: gates are generic and will be wired to seams when the
/// Authority exposes them.
///
/// Intended WS-test shape (drives one exact interleaving deterministically):
///
/// 1. Run the operation under test in a task; at each seam HistoryAuthority
///    exposes (e.g. between the two phases of a revision), it awaits
///    `park(at:)` on a uniquely named point.
/// 2. The test awaits `waitForPark(_:)` to know the operation reached the seam.
/// 3. The test performs the interfering commit, then calls `resume(_:)` so the
///    parked operation continues into the asserted interleaving.
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
    /// harness calls `resume(_:)`. Wakes any tasks blocked in
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

    /// Waits until some task has parked at `point`. Returns immediately when a
    /// task is already parked there.
    func waitForPark(_ point: String) async {
        if parked[point] != nil { return }
        await withCheckedContinuation { continuation in
            parkObservers[point, default: []].append(continuation)
        }
    }
}
