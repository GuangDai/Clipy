/// Out-of-package X.6 proof for the public HistoryStorage facade and factory.
/// This hosted target uses normal imports; no AppIntents composition belongs
/// to this publication leaf (`X-COMPILE-2`).
import Foundation
import HistoryCore
import HistoryStorage
import Testing

@Suite("External History facade public surface (X.6)")
struct ExternalHistoryFacadePublicTests {
    private func requirePublicExternalHistory<T: ExternalHistory>(
        _ value: T
    ) -> T {
        value
    }

    @Test("normal package import constructs and calls the bound facade")
    func publicFactoryAndFacadeAreCallable() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let facade: ExternalHistoryFacade = requirePublicExternalHistory(
            history.makeAppIntentsHistoryFacade()
        )

        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("out-of-package-external-facade".utf8)
            )],
            origin: CopyOriginObservation(
                sourceApplication: "ClipyIntegrationTests",
                lineageHint: nil
            ),
            observedAt: Date(timeIntervalSinceReferenceDate: 911_000_100)
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let reference) = commit.outcome else {
            Issue.record("expected inserted reference")
            return
        }

        let connections = try await history.connections()
        let appIntents = try #require(connections.first)
        try await history.grantCapability(.browse, to: appIntents.id)

        guard case .page(let page) = try await facade.read(
            .recent(limit: 1)
        ) else {
            Issue.record("expected recent page")
            return
        }
        #expect(page.rows.map(\.item.id) == [reference.id])
    }
}
