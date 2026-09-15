import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import Testing
@testable import ClipyApp

/// Real observer startup and capture commits feed the automatic workflow owner.
/// Only notification delivery is substituted; no second History writer is used.
@Suite("Conditional workflow capture integration", .serialized)
@MainActor
struct BuiltInAutomationCaptureHostedTests {
    @Test func startupIsInertButNewCopiesAndRepeatCopiesMatch() async throws {
        let suite = "WorkflowCaptureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workflow = BuiltInAutomationWorkflow(name: "TODO detected", steps: [
            .init(operation: .containsText, find: "TODO"), .init(operation: .notify)
        ], trigger: .newCopies)
        try BuiltInAutomationLibrary(defaults: defaults).save(workflow)
        let notifications = CapturedWorkflowNotifications()
        let runner = BuiltInAutomationAutomaticRunner(defaults: defaults) { await notifications.record($0) }
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let pasteboard = NSPasteboard(name: .init(suite))
        defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.setString("TODO already present at startup", forType: .string))
        let composition = AppComposition.makeForTesting(
            history: history, adapter: PasteboardAdapter(pasteboard: pasteboard),
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: { .allowed }, workflowRunner: runner
        )
        defer { composition.stop() }
        try await settleCapture(composition)
        let initial = try await history.browse(.init(kind: .recent, limit: 10))
        #expect(initial.rows.count == 1)
        #expect(await notifications.names.isEmpty)

        let capture = ClipboardCapture(
            representations: [.init(typeIdentifier: "public.utf8-plain-text", bytes: Data("TODO new".utf8))],
            origin: .init(sourceApplication: "com.clipy.tests.workflow", lineageHint: nil), observedAt: Date()
        )
        composition.submitCaptureForTesting(capture)
        try await settleCapture(composition)
        #expect(await notifications.names == ["TODO detected"])
        composition.submitCaptureForTesting(capture)
        try await settleCapture(composition)
        #expect(await notifications.names == ["TODO detected", "TODO detected"])
        #expect(try await history.browse(.init(kind: .recent, limit: 10)).rows.count == 2)

        composition.submitCaptureForTesting(.init(
            representations: capture.representations, origin: capture.origin,
            observedAt: Date(), isConcealed: true
        ))
        try await settleCapture(composition)
        #expect(await notifications.names.count == 2, "Concealed captures must never enter workflows")
        composition.pauseCapture()
        composition.submitCaptureForTesting(capture)
        try await settleCapture(composition)
        #expect(await notifications.names.count == 2)
    }

    private func settleCapture(_ composition: AppComposition) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while composition.captureHealth.activeCommitCount != 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(composition.captureHealth.activeCommitCount == 0)
        await composition.workflowRunner.waitForPendingWorkForTesting()
    }
}

private actor CapturedWorkflowNotifications {
    private(set) var names: [String] = []
    func record(_ name: String) { names.append(name) }
}
