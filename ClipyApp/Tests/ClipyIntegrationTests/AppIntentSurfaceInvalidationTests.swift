import AppIntents
import Foundation
import HistoryCore
@testable import HistoryStorage
import LocalAutomation
import PasteboardAdapter
import Testing
@testable import ClipyApp

struct AppIntentSurfaceInvalidationTests {
    enum RemovalEntry: CaseIterable {
        case appIntent
        case localAutomation
    }

    @Test(arguments: RemovalEntry.allCases) @MainActor
    func externalRemovalRetiresOlderPagesOnBothSurfaces(entry: RemovalEntry) async throws {
        let base = try await ComposedSupport.openMemoryHistory()
        let targetTitle = "external-remove-target"
        let survivorTitle = "unrelated-survivor"
        let time = Date(timeIntervalSinceReferenceDate: 930_000_000)
        _ = try await base.perform(.capture(ComposedSupport.textCapture(targetTitle, observedAt: time)))
        _ = try await base.perform(.capture(ComposedSupport.textCapture(
            survivorTitle, observedAt: time.addingTimeInterval(1)
        )))
        let browse = HistoryBrowseRequest(kind: .recent, limit: 10)
        let initial = try await base.browse(browse)
        let target = try #require(initial.rows.first { $0.title == targetTitle }?.item)
        let survivor = try #require(initial.rows.first { $0.title == survivorTitle }?.item)

        let delivery = RemovalObservationDelivery()
        let observedHistory = PostInitialObservationSuspendingHistory(base: base) {
            await delivery.stream()
        }
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let composition = AppComposition.makeForTesting(
            history: observedHistory,
            appIntentsHistoryFacade: base.makeAppIntentsHistoryFacade(),
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        let panel = composition.viewState
        let workspace = composition.historyWorkspaceViewState
        let preview = PreviewPaneState()
        let panelSurface = HistoryPanelSurfaceState(viewState: panel, previewState: preview)
        composition.installPanelSurface(panelSurface)
        defer {
            composition.stop()
            Task { await delivery.finish() }
        }
        panel.activate()
        workspace.activate()
        try await delivery.deliver(initial)
        try #require(panel.rows == initial.rows && workspace.rows == initial.rows)
        preview.togglePreview(for: target)
        try #require(preview.previewedItem == target)

        _ = try await base.perform(.placePinned(survivor.id, at: .first))
        let stale = try await base.browse(browse)
        try #require(stale.position > initial.position)
        try #require(stale.rows.contains { $0.item.id == target.id })

        switch entry {
        case .appIntent:
            let connections = try await base.connections()
            let connection = try #require(connections.first { $0.enrollKind == .appIntents })
            try await base.grantCapability(.manage, to: connection.id)
            let ingress = try #require(composition.appIntentHistoryIngress)
            let result = try await RemoveItemIntent(
                itemID: target.id.description,
                history: ingress,
                dependencyManager: AppDependencyManager()
            ).perform()
            try #require(result.value == true)
        case .localAutomation:
            let relay = PanelSurfacePurgeRelay(viewState: panel)
            relay.install(panelSurface)
            try await removeThroughSocket(targetTitle, history: base, relay: relay)
        }

        let committed = try await base.browse(browse)
        try #require(committed.position > stale.position)
        try #require(committed.rows.map(\.item.id) == [survivor.id])
        #expect(panel.rows.map(\.item.id) == [survivor.id])
        #expect(workspace.rows.map(\.item.id) == [survivor.id])
        #expect(preview.previewedItem == nil)
        #expect(panel.sourceCompletionPosition == committed.position)
        #expect(workspace.sourceCompletionPosition == committed.position)

        // Both consumers ask for another page after handling the delayed one.
        // If either admitted it, the deleted row would still be visible here.
        try await delivery.deliver(stale)
        #expect(panel.rows.map(\.item.id) == [survivor.id])
        #expect(workspace.rows.map(\.item.id) == [survivor.id])
        #expect(preview.previewedItem == nil)

        try await delivery.deliver(committed)
        #expect(panel.rows == committed.rows)
        #expect(workspace.rows == committed.rows)
    }

    @MainActor
    private func removeThroughSocket(
        _ title: String, history: SQLiteHistory, relay: PanelSurfacePurgeRelay
    ) async throws {
        let directory = URL(fileURLWithPath: "/tmp/clipy-remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = directory.appendingPathComponent("automation.sock")
        let clientDirectory = directory.appendingPathComponent("client")
        let ingress = LocalAutomationIngress(
            authority: history.authority,
            gateway: history.externalGateway,
            credentialStore: CredentialStore(directoryURL: directory.appendingPathComponent("server")),
            onCommittedRemoval: { itemID, position in
                await relay.acceptCommittedExternalRemoval(itemID, position: position)
            }
        )
        let controller = LocalAutomationController(
            ingress: ingress, endpointURL: endpoint, clientDirectory: clientDirectory
        )
        do {
            _ = try await controller.settings.enable()
            _ = try await controller.settings.setCapability(.browsePreview, true)
            _ = try await controller.settings.setCapability(.deleteItem, true)
            let credential = try Data(contentsOf: clientDirectory.appendingPathComponent("local-automation.credential"))
            let page = try await socketResult(
                "browsePreview", arguments: ["limit": 10], endpoint: endpoint, credential: credential
            )
            let rows = try #require(page["items"] as? [[String: Any]])
            let row = try #require(rows.first { $0["title"] as? String == title })
            let locator = try #require(row["locator"] as? String)
            let result = try await socketResult(
                "delete", arguments: ["locator": locator], endpoint: endpoint, credential: credential
            )
            try #require(result["changed"] as? Bool == true)
            #expect(Set(result.keys) == ["changed"])
        } catch {
            await controller.stop()
            throw error
        }
        await controller.stop()
    }

    @MainActor
    private func socketResult(
        _ operation: String, arguments: [String: Any], endpoint: URL, credential: Data
    ) async throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: [
            "protocolVersion": 1, "requestID": UUID().uuidString.lowercased(),
            "operation": operation, "arguments": arguments,
        ])
        let client = try await LocalAutomationClient.connect(endpointURL: endpoint)
        let output = await client.request(request, credential: credential)
        try #require(output.exitCode == 0)
        let envelope = try #require(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
        return try #require(envelope["result"] as? [String: Any])
    }
}

private actor RemovalObservationDelivery {
    private var waiting: [CheckedContinuation<HistoryPage?, Never>] = []
    private var finished = false

    func stream() -> AsyncThrowingStream<HistoryPage, Error> {
        AsyncThrowingStream(unfolding: { await self.next() })
    }

    private func next() async -> HistoryPage? {
        guard !finished, !Task.isCancelled else { return nil }
        return await withCheckedContinuation { waiting.append($0) }
    }

    func deliver(_ page: HistoryPage) async throws {
        try await waitForBothConsumers()
        let consumers = waiting
        waiting.removeAll()
        for consumer in consumers {
            consumer.resume(returning: page)
        }
        try await waitForBothConsumers()
    }

    func finish() {
        finished = true
        for consumer in waiting {
            consumer.resume(returning: nil)
        }
        waiting.removeAll()
    }

    private func waitForBothConsumers() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while waiting.count < 2 && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(waiting.count == 2)
    }
}
