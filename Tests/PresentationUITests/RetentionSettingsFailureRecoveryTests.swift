import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import PresentationUI

@Suite("Retention settings failure recovery")
struct RetentionSettingsFailureRecoveryTests {
    @Test("an unpinned active revision gets revision-specific recovery and the edited limit can retry")
    @MainActor
    func oversizedActiveRevisionPreservesTheDraftAndRecoversWithAHigherLimit() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let capture = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: "com.example.payload", bytes: Data([1]))],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_093_000)
        )))
        guard case .committed(let insertion) = capture,
              case .inserted(let original) = insertion.outcome else {
            Issue.record("Expected one unpinned item")
            return
        }
        _ = try await history.perform(.revise(RevisionRequest(
            itemID: original.id, expected: original.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: "com.example.payload",
                action: .replace(bytes: Data(repeating: 2, count: 1_048_577))
            )]))
        )))
        let state = HistoryViewState(history: history)
        let configuration = try await state.retentionConfiguration()
        let before = try await history.usage()
        #expect(before.pinnedItemCount == 0)
        #expect(before.revisionBytes == 1_048_577)
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        let read = draft.beginLoadRequest()
        draft.acceptLoaded(configuration, requestedAt: read)
        draft.setRevisionBytesEnabled(true)
        draft.setRevisionMiBText("1")
        let rejected = try #require(draft.submission())

        do {
            _ = try await state.applyRetentionPolicies(rejected.policies)
            Issue.record("An active revision cannot be pruned below its own byte size")
        } catch let failure as HistoryFailure {
            #expect(failure == .invalidInput(.invalidRetentionPolicy))
            #expect(RetentionSettingsCopy.failureMessage(for: failure, policies: rejected.policies)
                == "An active revision exceeds this limit. Increase the revision storage limit.")
        }
        #expect(try await history.usage() == before)
        #expect(try await state.retentionConfiguration() == configuration)
        #expect(draft.revisionMiBText == "1")
        #expect(draft.hasPolicyChanges)
        #expect(draft.acceptedSuccessMessage == nil)

        draft.setRevisionMiBText("2")
        let retry = try #require(draft.submission())
        let receipt = try await state.applyRetentionPolicies(retry.policies)
        guard case .success(let message) = retentionPoliciesStatusFeedback(receipt) else {
            Issue.record("The larger revision limit must apply")
            return
        }
        draft.acceptApplied(retry, successMessage: message)
        #expect(!draft.hasPolicyChanges)
        #expect(draft.acceptedSuccessMessage != nil)
        #expect(try await state.retentionConfiguration().policies == retry.policies)
        let after = try await history.usage()
        #expect(after.itemCount == 1)
        #expect(after.revisionBytes == before.revisionBytes)
        #expect(after.position.rawValue == before.position.rawValue + 1)
    }

    @Test("mixed storage and revision limits report both possible causes")
    func ambiguousAndStorageOnlyFailuresKeepTheirOwnGuidance() {
        let failure = HistoryFailure.invalidInput(.invalidRetentionPolicy)
        let storage = StorageRetention(maxTotalBytes: 1_048_576)
        let revisions = RevisionRetention(maxRevisionsPerItem: nil, maxRevisionBytesPerItem: 1_048_576)
        #expect(RetentionSettingsCopy.failureMessage(
            for: failure, policies: HistoryRetentionPolicies(age: nil, storage: storage, revisions: revisions)
        ) == "Pinned items may exceed the storage budget, or an active revision may exceed its limit. "
            + "Raise the limits, or unpin items to reduce protected storage.")
        #expect(RetentionSettingsCopy.failureMessage(
            for: failure, policies: HistoryRetentionPolicies(age: nil, storage: storage, revisions: nil)
        ) == "Pinned items exceed this budget. Unpin items or raise the budget.")

        let noByteLimit = HistoryRetentionPolicies(
            age: nil, storage: nil,
            revisions: RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
        )
        #expect(RetentionSettingsCopy.failureMessage(for: failure, policies: noByteLimit)
            == FailurePresentation.message(for: failure))
        let persistence = HistoryFailure.persistence(.openStore)
        #expect(RetentionSettingsCopy.failureMessage(for: persistence, policies: noByteLimit)
            == FailurePresentation.message(for: persistence))
    }
}
