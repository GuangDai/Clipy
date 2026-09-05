/// SettingsReceiptFeedbackTests.swift — Card 10 exact-feedback proofs for
/// the Settings mutation surfaces. Every `HistoryReceipt` state maps to its
/// own deliberate message: a committed receipt reports its outcome-derived
/// counts (03a §6; `V2-02` §12), `.unchanged` reports the no-op exactly
/// (02 §8/§12; `V2-02` §4.4/§5.6), and a commit carrying another action's
/// outcome renders as a failure — never a blanket "Done.".
/// These tests own receipt selection and count forwarding; literal translations
/// and plural forms are exercised by RetentionSettingsCopyTests.
import Foundation
import HistoryCore
import Testing
@testable import PresentationUI

@Suite("Settings receipt feedback")
struct SettingsReceiptFeedbackTests {
    /// One committed receipt at a fixed position carrying `outcome`.
    private func committedReceipt(
        _ outcome: HistoryCommitOutcome
    ) -> HistoryReceipt {
        .committed(HistoryCommit(
            position: ChangePosition(rawValue: 1),
            outcome: outcome
        ))
    }

    @Test("clear feedback distinguishes removal counts from the nothing-matched no-op")
    func clearFeedbackIsExactPerReceiptState() {
        #expect(
            clearStatusFeedback(committedReceipt(.cleared(count: 3)))
                == .success(RetentionSettingsCopy.clearedItemsRemoved(3))
        )
        #expect(
            clearStatusFeedback(committedReceipt(.cleared(count: 1)))
                == .success(RetentionSettingsCopy.clearedItemsRemoved(1))
        )
        #expect(
            clearStatusFeedback(committedReceipt(.cleared(count: 0)))
                == .success(RetentionSettingsCopy.feedbackDone)
        )
        // An empty affected set never commits (02 §8) — the feedback says
        // nothing matched instead of implying a removal.
        #expect(
            clearStatusFeedback(.unchanged)
                == .success(RetentionSettingsCopy.feedbackNothingToClear)
        )
        // A clear commit never carries another action's outcome; the
        // boundary violation is a failure, not a blanket success.
        #expect(
            clearStatusFeedback(committedReceipt(.removed(count: 1)))
                == .failure(RetentionSettingsCopy.clearFailure)
        )
    }

    @Test("count apply feedback distinguishes removals from the no-change no-op")
    func maximumUnpinnedFeedbackIsExactPerReceiptState() {
        #expect(
            maximumUnpinnedStatusFeedback(
                committedReceipt(.retentionPolicySet(removedCount: 2))
            ) == .success(RetentionSettingsCopy.countLimitItemsRemoved(2))
        )
        #expect(
            maximumUnpinnedStatusFeedback(
                committedReceipt(.retentionPolicySet(removedCount: 1))
            ) == .success(RetentionSettingsCopy.countLimitItemsRemoved(1))
        )
        #expect(
            maximumUnpinnedStatusFeedback(
                committedReceipt(.retentionPolicySet(removedCount: 0))
            ) == .success(RetentionSettingsCopy.feedbackDone)
        )
        // The submitted count already equals the persisted value (02 §8/§12).
        #expect(
            maximumUnpinnedStatusFeedback(.unchanged)
                == .success(RetentionSettingsCopy.feedbackNoChange)
        )
        #expect(
            maximumUnpinnedStatusFeedback(
                committedReceipt(.cleared(count: 1))
            ) == .failure(RetentionSettingsCopy.countSaveFailure)
        )
    }

    @Test("policy apply feedback reports retired items and pruned revisions separately")
    func retentionPoliciesFeedbackIsExactPerReceiptState() {
        #expect(
            retentionPoliciesStatusFeedback(
                committedReceipt(.retentionPoliciesSet(
                    retiredItems: 1,
                    prunedRevisions: 0
                ))
            ) == .success(RetentionSettingsCopy.appliedSummary(
                retiredPhrase: RetentionSettingsCopy.itemsRetired(1),
                prunedPhrase: RetentionSettingsCopy.revisionsPruned(0)
            ))
        )
        #expect(
            retentionPoliciesStatusFeedback(
                committedReceipt(.retentionPoliciesSet(
                    retiredItems: 2,
                    prunedRevisions: 3
                ))
            ) == .success(RetentionSettingsCopy.appliedSummary(
                retiredPhrase: RetentionSettingsCopy.itemsRetired(2),
                prunedPhrase: RetentionSettingsCopy.revisionsPruned(3)
            ))
        )
        #expect(
            retentionPoliciesStatusFeedback(
                committedReceipt(.retentionPoliciesSet(
                    retiredItems: 0,
                    prunedRevisions: 1
                ))
            ) == .success(RetentionSettingsCopy.appliedSummary(
                retiredPhrase: RetentionSettingsCopy.itemsRetired(0),
                prunedPhrase: RetentionSettingsCopy.revisionsPruned(1)
            ))
        )
        // A nothing-happened set reports plain "Done." (`V2-02` §12).
        #expect(
            retentionPoliciesStatusFeedback(
                committedReceipt(.retentionPoliciesSet(
                    retiredItems: 0,
                    prunedRevisions: 0
                ))
            ) == .success(RetentionSettingsCopy.feedbackDone)
        )
        // The submitted bundle already equals the persisted policy
        // (`V2-02` §4.4/§5.6).
        #expect(
            retentionPoliciesStatusFeedback(.unchanged)
                == .success(RetentionSettingsCopy.feedbackNoChange)
        )
        #expect(
            retentionPoliciesStatusFeedback(
                committedReceipt(.cleared(count: 2))
            ) == .failure(RetentionSettingsCopy.policiesSaveFailure)
        )
    }
}
