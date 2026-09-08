import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import ClipyApp

struct ExternalRevisionSurfaceTests {
    @Test(arguments: [false, true]) @MainActor
    func realRevisionCommitPurgesBeforeReplacementObservation(prunesRevision: Bool) async throws {
        let base = try await ComposedSupport.openMemoryHistory()
        let target = try await insert("revision-surface-original", into: base, at: 1)
        let survivor = try await insert("revision-surface-survivor", into: base, at: 2)
        let first = try await revise(target, text: "revision-surface-current", in: base)
        guard case .revised(let displayed) = first.outcome else {
            Issue.record("Expected the first committed revision")
            return
        }
        if prunesRevision {
            _ = try await base.perform(.setRetentionPolicies(HistoryRetentionPolicies(
                age: nil, storage: nil,
                revisions: RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
            )))
        }
        let observed = PostInitialObservationSuspendingHistory(base: base)
        let viewState = HistoryViewState(history: observed)
        let preview = PreviewPaneState()
        let surface = HistoryPanelSurfaceState(viewState: viewState, previewState: preview)
        let relay = PanelSurfacePurgeRelay(viewState: viewState)
        relay.install(surface)
        defer {
            viewState.deactivate()
            Task { await observed.releasePostInitialObservation() }
        }
        viewState.activate()
        try #require(await ComposedSupport.waitFor { viewState.rows.count == 2 })
        preview.togglePreview(for: displayed)

        let commit = try await revise(displayed, text: "revision-surface-new", in: base)
        // Pass the actual storage receipt unchanged, including its internal
        // retention effect. This is the same relay used by the app ingress.
        relay.acceptCommittedExternalRevision(from: displayed, commit: commit)
        await observed.waitUntilPostInitialObservationIsHeld()
        #expect(surface.appliedPurgeGeneration == 1)
        guard case .revised(let new) = commit.outcome else {
            Issue.record("Expected the second committed revision")
            return
        }
        if prunesRevision {
            #expect(viewState.rows.isEmpty)
            #expect(!preview.isOpen)
            #expect(preview.previewedItem == nil)
        } else {
            #expect(viewState.rows.map(\.item) == [survivor])
            #expect(preview.isOpen)
            #expect(preview.previewedItem == new)
        }
        await observed.releasePostInitialObservation()
        try #require(await ComposedSupport.waitFor {
            viewState.rows.contains { $0.item == new }
        })
    }

    @Test @MainActor
    func lateRevisionCallbackKeepsAnAlreadyNewerReference() async throws {
        let base = try await ComposedSupport.openMemoryHistory()
        let old = try await insert("late-revision-original", into: base, at: 1)
        let earlierCommit = try await revise(old, text: "late-revision-second", in: base)
        guard case .revised(let second) = earlierCommit.outcome else {
            Issue.record("Expected the second content version")
            return
        }
        let latestCommit = try await revise(second, text: "late-revision-third", in: base)
        guard case .revised(let latest) = latestCommit.outcome else {
            Issue.record("Expected the third content version")
            return
        }
        let viewState = HistoryViewState(history: base)
        let preview = PreviewPaneState()
        let surface = HistoryPanelSurfaceState(viewState: viewState, previewState: preview)
        let relay = PanelSurfacePurgeRelay(viewState: viewState)
        relay.install(surface)
        defer { viewState.deactivate() }
        viewState.activate()
        try #require(await ComposedSupport.waitFor { viewState.rows.first?.item == latest })
        preview.togglePreview(for: latest)

        relay.acceptCommittedExternalRevision(from: old, commit: earlierCommit)

        #expect(viewState.rows.map(\.item) == [latest])
        #expect(preview.isOpen)
        #expect(preview.previewedItem == latest)
        #expect(surface.appliedPurgeGeneration == 1)
    }

    private func insert(_ text: String, into history: SQLiteHistory, at time: TimeInterval) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ComposedSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: time)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw FixtureFailure.unexpectedReceipt
        }
        return item
    }

    private func revise(
        _ item: HistoryItemReference, text: String, in history: SQLiteHistory
    ) async throws -> HistoryCommit {
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: item.id, expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data(text.utf8))
            )]))
        )))
        guard case .committed(let commit) = receipt else { throw FixtureFailure.unexpectedReceipt }
        return commit
    }

    private enum FixtureFailure: Error { case unexpectedReceipt }
}
