/// X.6 public connection-bound facade behavior through the real in-memory
/// History store. Owning spec: `V2-05` §5.1–§5.2/§6.5 and roadmap X.6.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite("External History facade (X.6)")
struct ExternalHistoryFacadeTests {
    private func requireExternalHistory<T: ExternalHistory>(_ value: T) -> T {
        value
    }

    private func requireSendable<T: Sendable>(_ value: T) -> T {
        value
    }

    @Test("factory publishes one bound Sendable facade with real positive paths")
    func publicFactoryRunsTheApprovedJourney() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        // A plain no-argument call proves this is a synchronous value accessor.
        let facade = requireSendable(
            requireExternalHistory(history.makeAppIntentsHistoryFacade())
        )
        let secondValue = history.makeAppIntentsHistoryFacade()

        let captureReceipt = try await history.perform(.capture(
            ClipboardCapture(
                representations: [CapturedRepresentation(
                    typeIdentifier: "public.utf8-plain-text",
                    bytes: Data("external-facade-journey".utf8)
                )],
                origin: CopyOriginObservation(
                    sourceApplication: "ExternalHistoryFacadeTests",
                    lineageHint: nil
                ),
                observedAt: Date(timeIntervalSinceReferenceDate: 911_000_000)
            )
        ))
        guard case .committed(let captureCommit) = captureReceipt,
              case .inserted(let reference) = captureCommit.outcome else {
            Issue.record("expected inserted reference")
            return
        }

        let connections = try await history.connections()
        let connection = try #require(connections.first)
        #expect(connections.count == 1)
        try await history.grantCapability(.browse, to: connection.id)
        try await history.grantCapability(.readContent, to: connection.id)
        try await history.grantCapability(.manage, to: connection.id)

        guard case .page(let recent) = try await facade.read(
            .recent(limit: 10)
        ) else {
            Issue.record("expected recent page")
            return
        }
        #expect(recent.rows.map(\.item.id) == [reference.id])

        guard case .page(let search) = try await secondValue.read(
            .search(text: "facade", mode: .exact, limit: 10)
        ) else {
            Issue.record("expected search page")
            return
        }
        #expect(search.rows.map(\.item.id) == [reference.id])

        guard case .details(let details) = try await facade.read(
            .details(reference.id)
        ) else {
            Issue.record("expected details")
            return
        }
        #expect(details.item == reference)
        #expect(
            details.effective.first?.bytes
                == Data("external-facade-journey".utf8)
        )

        guard case .pastePayload(let payload) = try await facade.read(
            .pastePayload(reference.id)
        ) else {
            Issue.record("expected paste payload")
            return
        }
        #expect(payload.item == reference)
        #expect(payload.lineageHint == reference.id)

        guard case .pin(let pinnedID) = try await facade.perform(
            .pin(reference.id)
        ) else {
            Issue.record("expected pin response")
            return
        }
        #expect(pinnedID == reference.id)

        guard case .unchanged = try await facade.perform(
            .pin(reference.id)
        ) else {
            Issue.record("expected repeated pin to be unchanged")
            return
        }

        guard case .unpin(let unpinnedID) = try await facade.perform(
            .unpin(reference.id)
        ) else {
            Issue.record("expected unpin response")
            return
        }
        #expect(unpinnedID == reference.id)

        guard case .removed(let count) = try await facade.perform(
            .remove(reference.id)
        ) else {
            Issue.record("expected remove response")
            return
        }
        #expect(count == 1)

        guard case .page(let empty) = try await secondValue.read(
            .recent(limit: 10)
        ) else {
            Issue.record("expected final recent page")
            return
        }
        #expect(empty.rows.isEmpty)
    }
}
