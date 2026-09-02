/// SettingsReceiptFeedbackTests.swift — Card 10 exact-feedback proofs for
/// the Settings mutation surfaces. Every `HistoryReceipt` state maps to its
/// own deliberate message: a committed receipt reports its outcome-derived
/// counts (03a §6; `V2-02` §12), `.unchanged` reports the no-op exactly
/// (02 §8/§12; `V2-02` §4.4/§5.6), and a commit carrying another action's
/// outcome renders as a failure — never a blanket "Done.".
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
                == .success("Removed 3 items.")
        )
        #expect(
            clearStatusFeedback(committedReceipt(.cleared(count: 1)))
                == .success("Removed 1 item.")
        )
        #expect(
            clearStatusFeedback(committedReceipt(.cleared(count: 0)))
                == .success("Done.")
        )
        // An empty affected set never commits (02 §8) — the feedback says
        // nothing matched instead of implying a removal.
        #expect(
            clearStatusFeedback(.unchanged) == .success("Nothing to clear.")
        )
        // A clear commit never carries another action's outcome; the
        // boundary violation is a failure, not a blanket success.
        #expect(
            clearStatusFeedback(committedReceipt(.removed(count: 1)))
                == .failure("The history could not be cleared.")
        )
    }

    @Test("count apply feedback distinguishes removals from the no-change no-op")
    func maximumUnpinnedFeedbackIsExactPerReceiptState() {
        #expect(
            maximumUnpinnedStatusFeedback(
                committedReceipt(.retentionPolicySet(removedCount: 2))
            ) == .success("Done. 2 items removed.")
        )
        #expect(
            maximumUnpinnedStatusFeedback(
                committedReceipt(.retentionPolicySet(removedCount: 1))
            ) == .success("Done. 1 item removed.")
        )
        #expect(
            maximumUnpinnedStatusFeedback(
                committedReceipt(.retentionPolicySet(removedCount: 0))
            ) == .success("Done.")
        )
        // The submitted count already equals the persisted value (02 §8/§12).
        #expect(
            maximumUnpinnedStatusFeedback(.unchanged) == .success("No change.")
        )
        #expect(
            maximumUnpinnedStatusFeedback(
                committedReceipt(.cleared(count: 1))
            ) == .failure("The setting could not be saved.")
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
            ) == .success("Done. 1 item retired, 0 revisions pruned.")
        )
        #expect(
            retentionPoliciesStatusFeedback(
                committedReceipt(.retentionPoliciesSet(
                    retiredItems: 2,
                    prunedRevisions: 3
                ))
            ) == .success("Done. 2 items retired, 3 revisions pruned.")
        )
        #expect(
            retentionPoliciesStatusFeedback(
                committedReceipt(.retentionPoliciesSet(
                    retiredItems: 0,
                    prunedRevisions: 1
                ))
            ) == .success("Done. 0 items retired, 1 revision pruned.")
        )
        // A nothing-happened set reports plain "Done." (`V2-02` §12).
        #expect(
            retentionPoliciesStatusFeedback(
                committedReceipt(.retentionPoliciesSet(
                    retiredItems: 0,
                    prunedRevisions: 0
                ))
            ) == .success("Done.")
        )
        // The submitted bundle already equals the persisted policy
        // (`V2-02` §4.4/§5.6).
        #expect(
            retentionPoliciesStatusFeedback(.unchanged) == .success("No change.")
        )
        #expect(
            retentionPoliciesStatusFeedback(
                committedReceipt(.cleared(count: 2))
            ) == .failure("The policies could not be saved.")
        )
    }
}
