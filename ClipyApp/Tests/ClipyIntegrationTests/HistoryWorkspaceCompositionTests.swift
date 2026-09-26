import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import Testing
@testable import ClipyApp

/// Settings and the floating panel share History and one pasteboard writer,
/// while browse intent, copy feedback and session cancellation stay local.
@MainActor
struct HistoryWorkspaceCompositionTests {
    @Test
    func workspaceCopiesCurrentContentWithoutFloatingPanelCallbacks() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()
        let original = try await Self.capture("workspace original", in: history)
        let revisedText = "工作区复制\ne\u{301} — current content"
        let receipt = try await history.perform(.revise(Self.replacement(
            for: original, text: revisedText
        )))
        let revised = try #require(
            ComposedSupport.revisedReference(from: receipt, "workspace revision")
        )
        let pasteboard = ComposedSupport.makePasteboard()
        let composition = AppComposition.makeForTesting(
            history: history, adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        defer { composition.stop() }
        var completionCount = 0
        var failures: [ClipyPasteFailure] = []
        composition.onPasteCompleted = { completionCount += 1 }
        composition.onPasteFailed = { failures.append($0) }

        // Current-by-ID resolution also applies to the persistent workspace.
        composition.historyWorkspaceViewState.requestPaste(original)
        #expect(composition.historyWorkspaceCopyState.isCopying)
        #expect(composition.historyWorkspaceCopyState.status == nil)
        let pending = try #require(composition.pendingPasteForTesting)
        await pending.value

        let written = try #require(pasteboard.pasteboardItems?.first)
        #expect(written.data(forType: .string) == Data(revisedText.utf8))
        #expect(written.data(forType: NSPasteboard.PasteboardType("com.clipy.lineageHint"))
            == Data(revised.id.rawValue.uuidString.utf8))
        #expect(!composition.historyWorkspaceCopyState.isCopying)
        #expect(composition.historyWorkspaceCopyState.status
            == .success(SettingsCopy.text("Copied to Clipboard")))
        #expect(composition.pendingPasteForTesting == nil)
        #expect(completionCount == 0)
        #expect(failures.isEmpty)
    }

    @Test
    func missingWorkspaceItemReportsLocallyAndReleasesCopyForRetry() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()
        let removed = try await Self.capture("removed workspace item", in: history)
        let retained = try await Self.capture("retained workspace item", in: history)
        _ = try await history.perform(.remove(removed.id))
        let pasteboard = ComposedSupport.makePasteboard()
        ComposedSupport.setPasteboardContents("previous clipboard owner", on: pasteboard)
        let composition = AppComposition.makeForTesting(
            history: history, adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        defer { composition.stop() }
        var completionCount = 0
        var failures: [ClipyPasteFailure] = []
        composition.onPasteCompleted = { completionCount += 1 }
        composition.onPasteFailed = { failures.append($0) }
        let previousChangeCount = pasteboard.changeCount

        composition.historyWorkspaceViewState.requestPaste(removed)
        let failedCopy = try #require(composition.pendingPasteForTesting)
        await failedCopy.value

        #expect(composition.historyWorkspaceCopyState.status == .failure(
            PanelRootView.pasteFailureMessage(.history(.notFound(removed.id)))
        ))
        #expect(!composition.historyWorkspaceCopyState.isCopying)
        #expect(composition.pendingPasteForTesting == nil)
        #expect(pasteboard.changeCount == previousChangeCount)
        #expect(pasteboard.string(forType: .string) == "previous clipboard owner")
        #expect(completionCount == 0)
        #expect(failures.isEmpty)

        composition.historyWorkspaceViewState.requestPaste(retained)
        #expect(composition.historyWorkspaceCopyState.status == nil)
        let retry = try #require(composition.pendingPasteForTesting)
        await retry.value
        #expect(pasteboard.data(forType: .string) == Data("retained workspace item".utf8))
        #expect(composition.historyWorkspaceCopyState.status
            == .success(SettingsCopy.text("Copied to Clipboard")))
        #expect(completionCount == 0)
        #expect(failures.isEmpty)
    }

    @Test(arguments: [false, true])
    func removalPurgesBothSurfacesAndPreservesIndependentSearch(
        fromWorkspace: Bool
    ) async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()
        let shared = try await Self.capture("panel workspace shared", in: history)
        let panelOnly = try await Self.capture("panel exclusive", in: history)
        let workspaceOnly = try await Self.capture("workspace exclusive", in: history)
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: ComposedSupport.makePasteboard())
        )
        defer { composition.stop() }
        let panel = composition.viewState
        let workspace = composition.historyWorkspaceViewState
        try await Self.loadIndependentSearches(panel: panel, workspace: workspace)
        let origin = fromWorkspace ? workspace : panel

        _ = try await origin.removeAwaitingReceipt(shared.id)

        // Observation never publishes these receipt scopes. Both values prove
        // the direct composition handoff, even if an observed page wins the race.
        #expect(panel.surfacePurge?.scope == .item(shared.id))
        #expect(workspace.surfacePurge?.scope == .item(shared.id))
        #expect(!panel.rows.contains { $0.item.id == shared.id })
        #expect(!workspace.rows.contains { $0.item.id == shared.id })
        #expect(panel.searchText == "panel")
        #expect(workspace.searchText == "workspace")
        let refreshed = await ComposedSupport.waitFor {
            panel.rows.map(\.item) == [panelOnly]
                && workspace.rows.map(\.item) == [workspaceOnly]
        }
        #expect(refreshed)
    }

    @Test(arguments: [false, true])
    func revisionRetiresOldReferencesOnBothSurfacesWithoutSharingSearch(
        fromWorkspace: Bool
    ) async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()
        let original = try await Self.capture("panel workspace original", in: history)
        _ = try await Self.capture("panel exclusive", in: history)
        _ = try await Self.capture("workspace exclusive", in: history)
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: ComposedSupport.makePasteboard())
        )
        defer { composition.stop() }
        let panel = composition.viewState
        let workspace = composition.historyWorkspaceViewState
        try await Self.loadIndependentSearches(panel: panel, workspace: workspace)
        let origin = fromWorkspace ? workspace : panel

        let receipt = try await origin.revise(Self.replacement(
            for: original, text: "panel workspace revised"
        ))
        let revised = try #require(
            ComposedSupport.revisedReference(from: receipt, "cross-surface revision")
        )

        #expect(panel.surfacePurge?.scope == .revision(old: original, new: revised))
        #expect(workspace.surfacePurge?.scope == .revision(old: original, new: revised))
        #expect(!panel.rows.contains { $0.item == original })
        #expect(!workspace.rows.contains { $0.item == original })
        #expect(panel.searchText == "panel")
        #expect(workspace.searchText == "workspace")
        let refreshed = await ComposedSupport.waitFor {
            panel.rows.contains { $0.item == revised }
                && workspace.rows.contains { $0.item == revised }
        }
        #expect(refreshed)
    }

    @Test(arguments: [false, true])
    func bothSurfacesShareFirstAcceptedCopyAdmission(workspaceFirst: Bool) async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()
        let first = try await Self.capture("first accepted copy", in: history)
        let second = try await Self.capture("second refused copy", in: history)
        let pasteboard = ComposedSupport.makePasteboard()
        let composition = AppComposition.makeForTesting(
            history: history, adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        defer { composition.stop() }
        var completionCount = 0
        var failures: [ClipyPasteFailure] = []
        composition.onPasteCompleted = { completionCount += 1 }
        composition.onPasteFailed = { failures.append($0) }
        let firstSurface = workspaceFirst
            ? composition.historyWorkspaceViewState : composition.viewState
        let secondSurface = workspaceFirst
            ? composition.viewState : composition.historyWorkspaceViewState

        // Neither task can run before this MainActor turn yields. The second
        // surface must see the first surface's already-reserved writer slot.
        firstSurface.requestPaste(first)
        let acceptedCopy = try #require(composition.pendingPasteForTesting)
        secondSurface.requestPaste(second)
        if workspaceFirst {
            #expect(failures == [.busy])
            #expect(composition.historyWorkspaceCopyState.isCopying)
            #expect(composition.historyWorkspaceCopyState.status == nil)
        } else {
            #expect(failures.isEmpty)
            #expect(!composition.historyWorkspaceCopyState.isCopying)
            #expect(composition.historyWorkspaceCopyState.status == .failure(
                PanelRootView.pasteFailureMessage(.busy)
            ))
        }

        await acceptedCopy.value
        #expect(pasteboard.data(forType: .string) == Data("first accepted copy".utf8))
        #expect(composition.pendingPasteForTesting == nil)
        #expect(!composition.historyWorkspaceCopyState.isCopying)
        #expect(completionCount == (workspaceFirst ? 0 : 1))
        if workspaceFirst {
            #expect(failures == [.busy])
            #expect(composition.historyWorkspaceCopyState.status
                == .success(SettingsCopy.text("Copied to Clipboard")))
        } else {
            #expect(failures.isEmpty)
            #expect(composition.historyWorkspaceCopyState.status == .failure(
                PanelRootView.pasteFailureMessage(.busy)
            ))
        }
    }

    @Test
    func sessionCancellationAffectsOnlyItsOwnCopy() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()
        let workspaceItem = try await Self.capture("workspace copy survives panel close", in: history)
        let panelItem = try await Self.capture("panel copy survives workspace close", in: history)
        let pasteboard = ComposedSupport.makePasteboard()
        let composition = AppComposition.makeForTesting(
            history: history, adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        defer { composition.stop() }
        var completionCount = 0
        var failures: [ClipyPasteFailure] = []
        composition.onPasteCompleted = { completionCount += 1 }
        composition.onPasteFailed = { failures.append($0) }

        // Request and cancel happen in one MainActor turn, before the owned
        // task can read a payload or write to the private pasteboard.
        composition.historyWorkspaceViewState.requestPaste(workspaceItem)
        let workspaceCopy = try #require(composition.pendingPasteForTesting)
        composition.cancelPendingPaste()
        #expect(composition.pendingPasteForTesting != nil)
        #expect(composition.historyWorkspaceCopyState.isCopying)
        await workspaceCopy.value
        #expect(pasteboard.string(forType: .string) == "workspace copy survives panel close")
        #expect(completionCount == 0)

        composition.viewState.requestPaste(panelItem)
        let panelCopy = try #require(composition.pendingPasteForTesting)
        composition.historyWorkspaceCopyState.cancel()
        #expect(composition.pendingPasteForTesting != nil)
        await panelCopy.value
        #expect(pasteboard.string(forType: .string) == "panel copy survives workspace close")
        #expect(completionCount == 1)
        #expect(failures.isEmpty)

        let previousChangeCount = pasteboard.changeCount
        composition.historyWorkspaceViewState.requestPaste(workspaceItem)
        let cancelledCopy = try #require(composition.pendingPasteForTesting)
        composition.historyWorkspaceCopyState.cancel()
        #expect(composition.pendingPasteForTesting == nil)
        #expect(!composition.historyWorkspaceCopyState.isCopying)
        #expect(composition.historyWorkspaceCopyState.status == nil)
        await cancelledCopy.value
        #expect(pasteboard.changeCount == previousChangeCount)
        #expect(completionCount == 1)
        #expect(failures.isEmpty)
    }

    private static func capture(
        _ text: String, in history: SQLiteHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ComposedSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: 700_321_000)
        )))
        return try #require(ComposedSupport.insertedReference(from: receipt, "workspace arrange"))
    }

    private static func replacement(
        for item: HistoryItemReference, text: String
    ) -> RevisionRequest {
        RevisionRequest(
            itemID: item.id,
            expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(
                    typeIdentifier: ComposedSupport.plainTextTypeIdentifier,
                    action: .replace(bytes: Data(text.utf8))
                )
            ]))
        )
    }

    private static func loadIndependentSearches(
        panel: HistoryViewState, workspace: HistoryViewState
    ) async throws {
        panel.searchMode = .exact
        panel.searchText = "panel"
        workspace.searchMode = .exact
        workspace.searchText = "workspace"
        panel.activate()
        workspace.activate()
        let loaded = await ComposedSupport.waitFor {
            panel.hasAuthoritativeFirstPage && workspace.hasAuthoritativeFirstPage
                && panel.rows.count == 2 && workspace.rows.count == 2
        }
        try #require(loaded)
    }
}
