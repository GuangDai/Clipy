/// Position singleton access (§3.2), invalidation registration (§14.4), and the roadmap step-5 test seams.
/// Split out of HistoryAuthority.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

extension HistoryAuthority {
    // MARK: Singleton access (docs/05-authority-kernel.md §3.2, §10)

    /// Fetches the one position/retention singleton row.
    /// docs/05-authority-kernel.md §3.2, §10 (`fetchExactlyOnePositionRow`)
    ///
    /// The fetch is bounded (`fetchLimit = 2`): exactly one row is valid;
    /// zero or duplicates are durable-state corruption
    /// (`.persistence(.invariantViolation)`). A framework fetch failure
    /// outside the transaction closure means the fact cannot be proven
    /// (`.temporarilyUnavailable(.factProof)`, §16); inside the closure the
    /// executor remaps it with every other closure failure to
    /// `.persistence(.transaction)`.
    internal static func fetchExactlyOnePositionRow(
        in context: ModelContext
    ) throws -> LastChangePositionRow {
        let key = positionSingletonKey
        var descriptor = FetchDescriptor<LastChangePositionRow>(
            predicate: #Predicate { row in row.key == key }
        )
        descriptor.fetchLimit = 2
        let rows: [LastChangePositionRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }
        guard rows.count == 1, let row = rows.first else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return row
    }

    /// Decodes the singleton's scalar values: the current Change Position
    /// and the authoritative retention policy (§3.2). A stored policy
    /// outside the fixed Part VI user range is a corrupt stored value (§16,
    /// D19).
    internal static func decodePositionRow(
        _ row: LastChangePositionRow,
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

    /// The loaded Content Version of one item in the capture facts, checking
    /// the lineage hint first (it need not be a signature candidate,
    /// §7.1 step 4). Returns `nil` when the ID is absent — a planner
    /// contract violation for a chosen winner, never data.
    internal static func loadedContentVersion(
        of itemID: HistoryItemID,
        in facts: IngestFacts
    ) -> ContentVersion? {
        if facts.hintedItem?.id == itemID {
            return facts.hintedItem?.contentVersion
        }
        return facts.candidates.items.first { $0.id == itemID }?.contentVersion
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
    /// `SwiftDataHistory.observe` loop is the caller.
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
