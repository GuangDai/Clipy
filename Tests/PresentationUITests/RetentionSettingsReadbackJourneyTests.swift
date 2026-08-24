/// Card 10A consumer proof — one authoritative configuration read enters the
/// panel-owned draft, a single revision-count edit preserves awkward raw age
/// and byte values, and the resulting action crosses the production
/// `HistoryViewState` intent seam. Storage durability and `.unchanged`
/// semantics remain covered by `RetentionConfigurationReadTests` using the
/// real `SwiftDataHistory`; this suite owns Presentation consumption only.
import HistoryCore
import Testing
@testable import PresentationUI

@Suite("Retention settings readback journey")
struct RetentionSettingsReadbackJourneyTests {
    @Test @MainActor
    func oneReadAndOneRevisionEditPreserveEveryUntouchedRawValue() async throws {
        let history = ScriptedHistory(
            performReceipt: .committed(HistoryCommit(
                position: ChangePosition(rawValue: 1),
                outcome: .retentionPoliciesSet(
                    retiredItems: 0,
                    prunedRevisions: 0
                )
            )),
            scriptedRetentionConfiguration: HistoryRetentionConfiguration(
                maximumUnpinnedItems: 37,
                policies: HistoryRetentionPolicies(
                    age: AgeRetention(maxAge: 90_001),
                    storage: StorageRetention(maxTotalBytes: 1_048_577),
                    revisions: RevisionRetention(
                        maxRevisionsPerItem: 19,
                        maxRevisionBytesPerItem: 1_048_577
                    )
                )
            )
        )
        let viewState = HistoryViewState(history: history)
        var draft = RetentionSettingsDraft()
        let loadRequest = draft.beginLoadRequest()

        let configuration = try await viewState.retentionConfiguration()
        let acceptedLoad = draft.acceptLoaded(
            configuration,
            requestedAt: loadRequest
        )
        #expect(acceptedLoad)
        draft.setRevisionCountText("18")

        let submission = try #require(draft.submission())
        let receipt = try await viewState.applyRetentionPolicies(
            submission.policies
        )
        guard case let .committed(commit) = receipt,
              case let .retentionPoliciesSet(retired, pruned) = commit.outcome else {
            Issue.record("Card 10A: changed policy must return a committed receipt")
            return
        }
        #expect(commit.position.rawValue == 1)
        #expect(retired == 0)
        #expect(pruned == 0)

        #expect(await history.retentionConfigurationRequestCount == 1)
        let actions = await history.performActions
        #expect(actions.count == 1)
        guard let action = actions.first,
              case let .setRetentionPolicies(policies) = action else {
            Issue.record("Card 10A: expected one setRetentionPolicies action")
            return
        }
        #expect(policies.age?.maxAge == 90_001)
        #expect(policies.storage?.maxTotalBytes == 1_048_577)
        #expect(policies.revisions?.maxRevisionsPerItem == 18)
        #expect(policies.revisions?.maxRevisionBytesPerItem == 1_048_577)
    }
}
