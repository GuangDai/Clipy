/// Real-storage hosted support for the X.7 App Intents tracer bullets.
/// The framework dependency registry is standalone, so tests never mutate the
/// process-global registry and never substitute a second Gateway/Authority.
import AppIntents
import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import ClipyApp

struct AppIntentTestSupport {
    let history: SwiftDataHistory
    let ingress: AppIntentHistoryIngress
    let manager: AppDependencyManager
    let itemID: HistoryItemID

    static func make(
        grants: [ExternalCapability] = [],
        revisedText: String? = nil
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

        if let revisedText {
            let reviseReceipt = try await history.perform(.revise(
                RevisionRequest(
                    itemID: reference.id,
                    expected: reference.contentVersion,
                    intent: .replace(RevisionDraft(decisions: [
                        RevisionDecision(
                            typeIdentifier: "public.utf8-plain-text",
                            action: .replace(bytes: Data(revisedText.utf8))
                        ),
                    ]))
                )
            ))
            guard case .committed = reviseReceipt else {
                throw AppIntentTestSetupFailure.revisionDidNotCommit
            }
        }

        let connection = try #require(try await history.connections().first)
        for capability in grants {
            try await history.grantCapability(capability, to: connection.id)
        }

        let facade = history.makeAppIntentsHistoryFacade()
        let ingress = AppIntentHistoryIngress(
            facade: facade,
            onCommittedRemoval: { _ in }
        )
        let manager = AppDependencyManager()
        manager.add(dependency: ingress)
        return Self(
            history: history,
            ingress: ingress,
            manager: manager,
            itemID: reference.id
        )
    }

    func lastAuditOperation() async throws -> ExternalOperationKind? {
        try await history.auditLog(since: 1).last?.operationKind
    }

    func appIntentsConnectionID() async throws -> ExternalConnectionID {
        try #require(try await history.connections().first).id
    }
}

private enum AppIntentTestSetupFailure: Error {
    case captureDidNotInsert
    case revisionDidNotCommit
}
