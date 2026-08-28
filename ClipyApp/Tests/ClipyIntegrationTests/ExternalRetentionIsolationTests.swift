/// Task 47-4 adjudication guard: retention-policy configuration has no
/// external ingress. V2-05 §2.2/§3.2 freeze the external face at the closed
/// `ExternalRequest`/`ExternalOperationKind` vocabulary (no retention
/// spelling exists), and V2-02 §9 keeps the local Settings path through the
/// v1 `ClipboardHistory` seam as the sole retention owner. This hosted proof
/// makes that closed face red/green observable; it adds no Gateway operation.
import Foundation
import HistoryCore
import HistoryStorage
import Testing

@Suite("External retention isolation (47-4 adjudication)")
struct ExternalRetentionIsolationTests {
    @Test func externalGatewayOperationsCannotReachRetentionConfiguration() async throws {
        let base = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )

        // One real retained item, so pin/unpin/remove cross the committed
        // Gateway paths instead of notFound denials.
        let receipt = try await base.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("external-retention-isolation-target".utf8)
            )],
            origin: CopyOriginObservation(
                sourceApplication: "ClipyIntegrationTests",
                lineageHint: nil
            ),
            // Future-dated relative to the wall-clock sweep reference, so
            // the policy-set below retires nobody (maxAge 3600 s).
            observedAt: Date(timeIntervalSinceReferenceDate: 930_000_000)
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let target) = commit.outcome
        else {
            Issue.record("expected inserted external-retention target")
            return
        }

        // Bake a NON-default internal policy — the value an external
        // ingress must not be able to move. The internal seam publishes no
        // OperationRecord at all (V2-02 §9).
        _ = try await base.perform(.setRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 3600),
                storage: nil,
                revisions: nil
            )
        ))
        let before = try await base.retentionConfiguration()
        #expect(
            before.policies == HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 3600),
                storage: nil,
                revisions: nil
            )
        )

        let connection = try #require(try await base.connections().first)
        try await base.grantCapability(.manage, to: connection.id)
        let facade = base.makeAppIntentsHistoryFacade()

        // Exercise EVERY constructible ExternalRequest case (the closed
        // three-case set) plus one read through the granted
        // connection-bound facade — the entire external write face.
        _ = try await facade.perform(.pin(target.id))
        _ = try await facade.perform(.unpin(target.id))
        _ = try await facade.perform(.remove(target.id))
        _ = try await facade.read(.recent(limit: 1))

        // (a) The persisted configuration is bit-identical: `Hashable`
        // full-field equality on the DEC-RET-READ oracle.
        #expect(try await base.retentionConfiguration() == before)

        // (b) The audit trail admits only the closed external/admin
        // vocabulary: no retention-spelling ExternalOperationKind exists,
        // and the internal policy-set commit published no OperationRecord.
        // `connections()` and `grantCapability` are in-app admin
        // operations that audit themselves, so their kinds are part of the
        // expected setup prefix. `since: 1` is the first readable sequence
        // (the bootstrap writes compactionFloor 1 and sequences start at 1;
        // `since: 0` is below the floor and throws compacted-before).
        let kinds = Set(
            try await base.auditLog(since: 1).map(\.operationKind)
        )
        #expect(kinds.isSubset(of: [
            .adminReadConnections,
            .adminGrant,
            .readRecent,
            .managePin,
            .manageUnpin,
            .manageRemove,
        ]))
    }
}
