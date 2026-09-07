/// Position singleton access (§3.2), invalidation registration (§14.4), and the roadmap step-5 test seams.
/// Split out of HistoryAuthority.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain

internal struct SQLitePositionRow: Sendable {
    internal let rawValue: UInt64
    internal let maximumUnpinnedItems: Int
}

extension HistoryAuthority {
    // MARK: Singleton access (docs/05-authority-kernel.md §3.2, §10)

    /// A point read of the current singleton. The caller owns any surrounding
    /// snapshot/write transaction; this helper never begins a nested one.
    internal static func fetchExactlyOnePositionRow(
        in database: SQLiteDatabase
    ) throws -> SQLitePositionRow {
        do {
            let statement = try database.prepare("""
                SELECT changePosition, maximumUnpinnedItems
                FROM history_state WHERE key = ? LIMIT 2
                """, bindings: [.text(positionSingletonKey)])
            defer { statement.finalize() }
            guard try statement.step() else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            let position = try sqliteUInt64(statement.blob(at: 0))
            guard let maximum = try Int(exactly: statement.integer(at: 1)) else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            guard try !statement.step() else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            return SQLitePositionRow(rawValue: position, maximumUnpinnedItems: maximum)
        } catch let failure as SQLiteFailure {
            throw failure.historyFailure
        }
    }

    /// The same current retention validation applies to point reads, page
    /// snapshots and commits; UInt64 ChangePosition keeps its complete range.
    internal static func decodePositionRow(
        _ row: SQLitePositionRow,
        limits: HistoryLimits
    ) throws -> (position: ChangePosition, retention: RetentionPolicy) {
        guard limits.userMaximumUnpinnedRange.contains(row.maximumUnpinnedItems) else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        return (
            position: ChangePosition(rawValue: row.rawValue),
            retention: RetentionPolicy(maximumUnpinnedItems: row.maximumUnpinnedItems)
        )
    }

    // MARK: Observation registration (docs/05-authority-kernel.md §14.4)

    /// Registers one invalidation continuation and returns its token and
    /// stream. docs/05-authority-kernel.md §14.4; docs/04-coherence.md §5
    /// step 1 (registration precedes the first authoritative query — the
    /// WS12 ordering rule).
    ///
    /// Registration is a synchronous actor operation. Cancellation of the
    /// returned stream fires the publisher's termination callback, which
    /// hops back onto the Authority and removes the token (§14.4:
    /// "Cancellation removes the token"); the weak hop avoids a
    /// publisher→continuation→actor retain cycle. The termination callback is
    /// synchronous and cannot await an actor hop, so this short-lived Task owns
    /// exactly one idempotent dictionary removal; there is no result or longer
    /// operation that a parent task would need to join. Step 7's
    /// `SQLiteHistory.observe` loop is the caller.
    internal func registerInvalidationSubscriber() -> (
        subscription: HistoryInvalidationSubscription,
        stream: HistoryInvalidationPublisher.Stream
    ) {
        invalidationPublisher.subscribe { [weak self] subscription in
            guard let self else { return }
            _ = Task { await self.unregisterInvalidationSubscriber(subscription) }
        }
    }

    /// Removes one subscription and finishes its stream (§14.4). Idempotent
    /// — a termination-triggered removal that races an explicit removal is
    /// a no-op.
    internal func unregisterInvalidationSubscriber(
        _ subscription: HistoryInvalidationSubscription
    ) {
        invalidationPublisher.unsubscribe(subscription)
    }

    // MARK: Roadmap-owned test seams (docs/roadmap/03-historystorage.md step 5)

    /// Installs (or clears) the suspension handler the deterministic
    /// concurrency harness drives. Test seam — `nil` in production, compiled
    /// in always, set via @testable; see `AuthoritySuspensionPoint`.
    internal func setSuspensionHandler(
        _ handler: (@Sendable (AuthoritySuspensionPoint) async -> Void)?
    ) {
        suspensionHandler = handler
    }

    /// Arms (or clears) one one-shot transaction failure. Test seam —
    /// disarmed in production, compiled in always, set via @testable; WS13
    /// uses `.beforeSingletonUpdate`, while direct defensive-guard proofs use
    /// the matching guard-specific cases. See `InjectedTransactionFailure`.
    internal func setTransactionFailureInjection(
        _ injection: InjectedTransactionFailure?
    ) {
        injectedTransactionFailure = injection
    }

    /// Consumes one armed injection only at its matching production guard.
    /// A guard-specific case therefore cannot accidentally fall through to
    /// WS13's later generic failure point and create a false-positive test.
    internal func consumeTransactionFailureInjection(
        _ expected: InjectedTransactionFailure
    ) -> Bool {
        guard injectedTransactionFailure == expected else { return false }
        injectedTransactionFailure = nil
        return true
    }

    /// Suspends at `point` when the harness has installed a handler; a no-op
    /// otherwise and always in production. Callers place points only where
    /// an `await` is legal (§5).
    internal func suspendIfRequested(_ point: AuthoritySuspensionPoint) async {
        await suspensionHandler?(point)
    }

}
