/// Card 9B's external-ingress tracer: a real granted Gateway removal must
/// reach the existing panel surface owner before the App Intent returns,
/// even while the post-commit observation snapshot is deliberately held.
import AppIntents
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import PresentationUI
import Testing
@testable import ClipyApp

@Suite("App Intent surface invalidation (Card 9B)")
struct AppIntentSurfaceInvalidationTests {
    @Test @MainActor
    func removePurgesExactSurfaceBeforeHeldObservationCatchesUp() async throws {
        let base = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let receipt = try await base.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("external-remove-target".utf8)
            )],
            origin: CopyOriginObservation(
                sourceApplication: "ClipyIntegrationTests",
                lineageHint: nil
            ),
            observedAt: Date(timeIntervalSinceReferenceDate: 930_000_000)
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let target) = commit.outcome
        else {
            Issue.record("expected inserted external-remove target")
            return
        }
        let survivorReceipt = try await base.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("unrelated-survivor".utf8)
            )],
            origin: CopyOriginObservation(
                sourceApplication: "ClipyIntegrationTests",
                lineageHint: nil
            ),
            observedAt: Date(timeIntervalSinceReferenceDate: 930_000_001)
        )))
        guard case .committed(let survivorCommit) = survivorReceipt,
              case .inserted(let survivor) = survivorCommit.outcome
        else {
            Issue.record("expected inserted unrelated survivor")
            return
        }
        let connection = try #require(try await base.connections().first)
        try await base.grantCapability(.manage, to: connection.id)

        let observedHistory = PostInitialObservationSuspendingHistory(base: base)
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let composition = AppComposition.makeForTesting(
            history: observedHistory,
            appIntentsHistoryFacade: base.makeAppIntentsHistoryFacade(),
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        let panelSurface = HistoryPanelSurfaceState(
            viewState: composition.viewState,
            previewState: PreviewPaneState()
        )
        composition.installPanelSurface(panelSurface)
        defer {
            Task { await observedHistory.releasePostInitialObservation() }
            composition.stop()
        }
        composition.viewState.activate()
        try #require(await ComposedSupport.waitFor {
            composition.viewState.rows.map(\.item.id)
                == [survivor.id, target.id]
        })

        let ingress = try #require(composition.appIntentHistoryIngress)
        let manager = AppDependencyManager()
        let intent = RemoveItemIntent(
            itemID: target.id.description,
            history: ingress,
            dependencyManager: manager
        )

        let result = try await intent.perform()

        #expect(result.value == true)
        await observedHistory.waitUntilPostInitialObservationIsHeld()
        #expect(composition.viewState.rows.map(\.item.id) == [survivor.id])
        #expect(panelSurface.appliedPurgeGeneration == 1)

        // An already-unpinned survivor produces the Gateway's real
        // `.unchanged` shape. It must not disturb the exact removal result.
        let unchanged = try await UnpinItemIntent(
            itemID: survivor.id.description,
            history: ingress,
            dependencyManager: manager
        ).perform()
        #expect(unchanged.value == false)
        #expect(composition.viewState.rows.map(\.item.id) == [survivor.id])
        #expect(panelSurface.appliedPurgeGeneration == 1)

        await observedHistory.releasePostInitialObservation()
        try #require(await ComposedSupport.waitFor {
            composition.viewState.rows.map(\.item.id) == [survivor.id]
        })
    }
}
