/// Real-storage hosted support for the X.7 App Intents tracer bullets.
/// The framework dependency registry is standalone, so tests never mutate the
/// process-global registry and never substitute a second Gateway/Authority.
import AppIntents
import Foundation
import HistoryCore
import HistoryStorage
import Testing

struct AppIntentTestSupport {
    let history: SwiftDataHistory
    let facade: ExternalHistoryFacade
    let manager: AppDependencyManager
    let itemID: HistoryItemID

    static func make(
        grants: [ExternalCapability] = []
    ) async throws -> Self {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("intent-seed".utf8)
            )],
            origin: CopyOriginObservation(
                sourceApplication: "ClipyIntegrationTests",
                lineageHint: nil
            ),
            observedAt: Date(timeIntervalSinceReferenceDate: 920_000_000)
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let reference) = commit.outcome
        else {
            throw AppIntentTestSetupFailure.captureDidNotInsert
        }

        let connection = try #require(try await history.connections().first)
        for capability in grants {
            try await history.grantCapability(capability, to: connection.id)
        }

        let facade = history.makeAppIntentsHistoryFacade()
        let manager = AppDependencyManager()
        manager.add(dependency: facade)
        return Self(
            history: history,
            facade: facade,
            manager: manager,
            itemID: reference.id
        )
    }

    func lastAuditOperation() async throws -> ExternalOperationKind? {
        try await history.auditLog(since: 0).last?.operationKind
    }

    func appIntentsConnectionID() async throws -> ExternalConnectionID {
        try #require(try await history.connections().first).id
    }
}

private enum AppIntentTestSetupFailure: Error {
    case captureDidNotInsert
}
