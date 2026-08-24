/// A test-only, exact publication counter for one `HistoryAuthority`
/// operation. It reuses the real invalidation subscription rather than
/// adding a production hook or a second notification path.
///
/// The shared §11 commit tail contains exactly one synchronous `publish`
/// call, and an Authority operation can execute that tail at most once.
/// Therefore a fresh subscription installed immediately before one operation
/// has a structural upper bound of one publication. Closing and draining it
/// before any later operation makes `.bufferingNewest(1)` non-coalescing for
/// this probe: its exact count can only be zero or one.
///
/// Owning contracts: docs/04-coherence.md §4; docs/05-authority-kernel.md
/// §10–§11; docs/06-cross-cutting.md §8 WS13.
@testable import HistoryStorage

struct SingleOperationInvalidationPublicationProbe {
    private let subscription: HistoryInvalidationSubscription
    private let stream: HistoryInvalidationPublisher.Stream

    static func begin(
        on authority: HistoryAuthority
    ) async -> SingleOperationInvalidationPublicationProbe {
        let registration = await authority.registerInvalidationSubscriber()
        return SingleOperationInvalidationPublicationProbe(
            subscription: registration.subscription,
            stream: registration.stream
        )
    }

    /// Ends the operation-local window before any later Authority operation
    /// can publish, then returns the exact publications observed in it.
    func finish(
        on authority: HistoryAuthority
    ) async throws -> [HistoryInvalidation] {
        await authority.unregisterInvalidationSubscriber(subscription)
        var publications: [HistoryInvalidation] = []
        for try await publication in stream {
            publications.append(publication)
        }
        return publications
    }
}
