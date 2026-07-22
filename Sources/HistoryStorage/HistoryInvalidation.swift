/// HistoryInvalidation, HistoryInvalidationSubscription, and
/// HistoryInvalidationPublisher — the process-local invalidation signal that
/// wakes observers after a History Commit.
/// Owning spec: docs/04-coherence.md §4 (internal invalidation, not a public
/// ChangeFeed) and §5 (race-free observation; WS12 in
/// docs/06-cross-cutting.md §8); mechanics: docs/05-authority-kernel.md
/// §11 (post-commit order step 2) and §14.4 (observation registration).
///
/// The publisher is a value type stored inside `HistoryAuthority`:
/// registration, unregistration, and the post-commit yield are synchronous
/// actor operations (§14.4), so the §11 post-commit order — durable
/// transaction, then Signature Index delta, then one synchronous
/// invalidation yield, still without suspension — is expressible directly.
/// It is constructed empty at `open`; there is no replay after process
/// restart (§4).
import Foundation
import HistoryCore

// MARK: - The signal (docs/04-coherence.md §4)

/// One process-local invalidation: a content-free wake-up signal carrying
/// only the latest durable Change Position. docs/04-coherence.md §4
///
/// Semantics (all §4):
///
/// - one invalidation is synchronously yielded after each successful History
///   Commit (docs/05 §11 step 2);
/// - no invalidation is yielded for a no-op or a failed transaction;
/// - buffering may keep only the newest value — it is a wake-up signal, not
///   a delta, and there is no requirement that every position be delivered;
/// - it has no replay after process restart;
/// - it contains no content, before/after state, or audit identity;
/// - it is not public and is not a durable History Change Record (a
///   post-v1 concept v1 explicitly excludes).
///
/// Consumers never apply an invalidation to local state:
/// `ClipboardHistory.observe` consumes it internally and re-reads
/// authoritative state (§4, §5).
internal struct HistoryInvalidation: Sendable, Hashable {
    /// The durable Change Position of the History Commit that produced this
    /// invalidation (§4: "coalesce to newest ChangePosition").
    internal let latestPosition: ChangePosition

    internal init(latestPosition: ChangePosition) {
        self.latestPosition = latestPosition
    }
}

// MARK: - Subscription token (docs/05-authority-kernel.md §14.4)

/// Internal key of one registered invalidation continuation.
/// docs/05-authority-kernel.md §14.4 ("continuations keyed by an internal
/// subscription token"). Opaque to its holder; compared only for identity.
/// Minted by the publisher as a UUID, so no counter arithmetic is involved
/// and tokens never collide across registrations within one process.
internal struct HistoryInvalidationSubscription: Sendable, Hashable {
    internal let rawValue: UUID

    internal init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

// MARK: - Publisher (docs/04-coherence.md §4–§5, docs/05 §11, §14.4)

/// The process-local invalidation publisher stored inside
/// `HistoryAuthority`. docs/04-coherence.md §4; docs/05-authority-kernel.md
/// §14.4.
///
/// `HistoryAuthority` calls `publish(_:)` synchronously once per successful
/// History Commit — after the durable transaction and the nonthrowing
/// Signature Index delta, before constructing the committed receipt (§11) —
/// and never for a no-op or failed transaction (§4). Each subscriber's
/// stream buffers only the newest invalidation
/// (`.bufferingNewest(1)`), which is exactly §4's coalesce-to-newest
/// permission: a slow observer wakes to the latest position, and missed
/// intermediate positions carry no information a re-read would need.
///
/// Observation-race ordering (§5, WS12): `SwiftDataHistory.observe`
/// registers via `subscribe(onTermination:)` *before* its first
/// authoritative query. Registration is a synchronous actor operation, so a
/// commit that lands between registration and the first query is already
/// recorded in the stream's newest-value buffer; the §5 algorithm then
/// discards any page whose position is behind a buffered invalidation and
/// queries again. Cancellation of the returned stream fires the
/// continuation's termination handler, which removes the token through the
/// `onTermination` callback the Authority supplied at registration (§14.4:
/// "Cancellation removes the token").
internal struct HistoryInvalidationPublisher: Sendable {
    /// The subscriber-facing stream type. §14.4 names `AsyncThrowingStream`
    /// continuations; v1 never finishes a stream with an error, but the
    /// throwing shape lets the step-7 read side forward one failure type
    /// end-to-end without a second stream kind.
    internal typealias Stream = AsyncThrowingStream<HistoryInvalidation, Error>

    /// Live continuations keyed by subscription token (§14.4).
    private var continuations: [HistoryInvalidationSubscription: Stream.Continuation] = [:]

    internal init() {}

    /// The number of registered subscriptions. Diagnostic surface for the
    /// WS12 harness and Authority assertions; not used by the signal path.
    internal var subscriptionCount: Int {
        continuations.count
    }

    /// Registers a new subscriber and returns its token and stream.
    /// docs/04-coherence.md §5 step 1 (register before the first query);
    /// docs/05-authority-kernel.md §14.4.
    ///
    /// `onTermination` is invoked (off-actor, on the terminating task) when
    /// the returned stream is cancelled or otherwise terminates; the
    /// Authority uses it to hop back onto itself and call
    /// `unsubscribe(_:)`, so cancellation removes the token (§14.4). The
    /// callback must therefore be a Sendable hop, never actor state captured
    /// mutably.
    internal mutating func subscribe(
        onTermination: @escaping @Sendable (HistoryInvalidationSubscription) -> Void
    ) -> (subscription: HistoryInvalidationSubscription, stream: Stream) {
        let subscription = HistoryInvalidationSubscription(rawValue: UUID())
        let (stream, continuation) = Stream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { @Sendable _ in
            onTermination(subscription)
        }
        continuations[subscription] = continuation
        return (subscription: subscription, stream: stream)
    }

    /// Synchronously yields one invalidation to every registered
    /// continuation. docs/05-authority-kernel.md §11 step 2;
    /// docs/04-coherence.md §4.
    ///
    /// Yields never suspend and never fail: each stream keeps only its
    /// newest buffered value, so a subscriber that has not consumed yet
    /// receives exactly this value next — the coalesced wake-up §4 permits.
    /// With zero subscribers the yield is a no-op, which is correct: an
    /// observation created later registers first and reads current state as
    /// its first page (§5: "An observation created after restart gets
    /// current state as its first page; it does not replay past commits").
    internal func publish(_ invalidation: HistoryInvalidation) {
        for continuation in continuations.values {
            continuation.yield(invalidation)
        }
    }

    /// Removes one subscription and finishes its stream. Idempotent: a
    /// termination-triggered removal that races an explicit removal is a
    /// no-op (§14.4: "Cancellation removes the token").
    internal mutating func unsubscribe(
        _ subscription: HistoryInvalidationSubscription
    ) {
        continuations.removeValue(forKey: subscription)?.finish()
    }

    /// Finishes every stream and removes every token. Used when the
    /// Authority itself is torn down; process teardown needs no replay
    /// handling because the signal has no post-restart replay by design
    /// (§4).
    internal mutating func finishAll() {
        let remaining = continuations
        continuations.removeAll()
        for continuation in remaining.values {
            continuation.finish()
        }
    }
}
