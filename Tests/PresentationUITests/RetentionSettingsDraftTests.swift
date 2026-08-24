/// RetentionSettingsDraftTests.swift — pure Presentation-state proofs for the
/// unified retention editor (`V2-07` §5.2/§6.3). Expected values are literal
/// policy facts, never values recomputed through the draft's conversion code.
import Foundation
import HistoryCore
import Testing
@testable import PresentationUI

@Suite("Retention settings draft")
struct RetentionSettingsDraftTests {
    private func load(
        _ policies: HistoryRetentionPolicies,
        into draft: inout RetentionSettingsDraft
    ) {
        let request = draft.beginLoadRequest()
        let accepted = draft.acceptLoaded(policies, requestedAt: request)
        #expect(accepted)
    }

    private func load(
        _ configuration: HistoryRetentionConfiguration,
        into draft: inout RetentionSettingsDraft
    ) {
        let request = draft.beginLoadRequest()
        let accepted = draft.acceptLoaded(configuration, requestedAt: request)
        #expect(accepted)
    }

    @Test("one configured snapshot preserves a newer count edit and loads untouched policies")
    func lateUnifiedReadMergesCountAndPoliciesPerField() throws {
        var draft = RetentionSettingsDraft()
        let request = draft.beginLoadRequest()
        draft.setMaximumUnpinnedText("31")

        let accepted = draft.acceptLoaded(
            HistoryRetentionConfiguration(
                maximumUnpinnedItems: 42,
                policies: HistoryRetentionPolicies(
                    age: AgeRetention(maxAge: 90_001),
                    storage: StorageRetention(maxTotalBytes: 1_048_577),
                    revisions: RevisionRetention(
                        maxRevisionsPerItem: 19,
                        maxRevisionBytesPerItem: 1_048_577
                    )
                )
            ),
            requestedAt: request
        )

        #expect(!accepted)
        #expect(draft.maximumUnpinnedText == "31")
        #expect(draft.maximumUnpinnedValueIsDirty)
        #expect(draft.countSubmission()?.maximumUnpinnedItems == 31)
        #expect(draft.ageDaysText == "2")
        #expect(draft.storageMiBText == "2")
        #expect(draft.revisionCountText == "19")
        #expect(draft.revisionMiBText == "2")
        let policies = try #require(draft.submission()?.policies)
        #expect(policies.age?.maxAge == 90_001)
        #expect(policies.storage?.maxTotalBytes == 1_048_577)
        #expect(policies.revisions?.maxRevisionBytesPerItem == 1_048_577)
    }

    @Test("unedited count readback submits exact configured value")
    func uneditedCountUsesTheUnifiedConfiguredSnapshot() throws {
        var draft = RetentionSettingsDraft()
        load(
            HistoryRetentionConfiguration(
                maximumUnpinnedItems: 37,
                policies: HistoryRetentionPolicies(
                    age: nil,
                    storage: nil,
                    revisions: nil
                )
            ),
            into: &draft
        )

        let submission = try #require(draft.countSubmission())
        #expect(submission.maximumUnpinnedItems == 37)
        #expect(!draft.maximumUnpinnedValueIsDirty)
        #expect(!draft.maximumUnpinnedRequiresTightening(for: submission))

        draft.setMaximumUnpinnedText("36")
        let tightened = try #require(draft.countSubmission())
        #expect(draft.maximumUnpinnedRequiresTightening(for: tightened))
    }

    @Test("count Apply is enabled only when the validated value differs from configuration")
    func countChangesCompareTheCandidateToTheExactBaseline() {
        var draft = RetentionSettingsDraft()
        load(
            HistoryRetentionConfiguration(
                maximumUnpinnedItems: 37,
                policies: HistoryRetentionPolicies(
                    age: nil,
                    storage: nil,
                    revisions: nil
                )
            ),
            into: &draft
        )

        #expect(!draft.hasCountChanges)

        draft.setMaximumUnpinnedText("36")
        #expect(draft.hasCountChanges)

        // Dirty history is not a semantic change: returning to the exact
        // configured value must disable Apply again.
        draft.setMaximumUnpinnedText("37")
        #expect(!draft.hasCountChanges)
    }

    @Test("policy Apply is enabled only when the exact candidate differs from configuration")
    func policyChangesCompareTheCandidateToTheExactBaseline() {
        var draft = RetentionSettingsDraft()
        load(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 90_001),
                storage: StorageRetention(maxTotalBytes: 1_048_577),
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 20,
                    maxRevisionBytesPerItem: 1_048_577
                )
            ),
            into: &draft
        )

        #expect(!draft.hasPolicyChanges)

        draft.setStorageMiBText("3")
        #expect(draft.hasPolicyChanges)

        // The configured raw value is not exactly representable by this whole-
        // MiB control. Returning to displayed "2" after an edit is explicit
        // intent for exactly 2 MiB, not permission to restore hidden bytes.
        draft.setStorageMiBText("2")
        #expect(draft.hasPolicyChanges)
        #expect(draft.submission()?.policies.storage?.maxTotalBytes == 2_097_152)

        draft.setAgeDaysText("3")
        #expect(draft.hasPolicyChanges)
        draft.setAgeDaysText("2")
        #expect(draft.hasPolicyChanges)
        #expect(draft.submission()?.policies.age?.maxAge == 172_800)

        draft.setRevisionMiBText("3")
        #expect(draft.hasPolicyChanges)
        draft.setRevisionMiBText("2")
        #expect(draft.hasPolicyChanges)
        #expect(
            draft.submission()?.policies.revisions?.maxRevisionBytesPerItem
                == 2_097_152
        )

        // Isolate the exact whole-number revision-count round trip from the
        // deliberately changed, non-representable fields above.
        var countDraft = RetentionSettingsDraft()
        load(
            HistoryRetentionPolicies(
                age: nil,
                storage: nil,
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 20,
                    maxRevisionBytesPerItem: nil
                )
            ),
            into: &countDraft
        )
        countDraft.setRevisionCountEnabled(false)
        #expect(countDraft.hasPolicyChanges)
        countDraft.setRevisionCountEnabled(true)
        #expect(!countDraft.hasPolicyChanges)
    }

    @Test("representable whole-unit fields disable Apply after edit and restore")
    func exactWholeUnitBaselinesCanBeRestoredAfterEditing() {
        var draft = RetentionSettingsDraft()
        load(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 172_800),
                storage: StorageRetention(maxTotalBytes: 2_097_152),
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 20,
                    maxRevisionBytesPerItem: 2_097_152
                )
            ),
            into: &draft
        )

        draft.setAgeDaysText("3")
        #expect(draft.hasPolicyChanges)
        draft.setAgeDaysText("2")
        #expect(!draft.hasPolicyChanges)

        draft.setStorageMiBText("3")
        #expect(draft.hasPolicyChanges)
        draft.setStorageMiBText("2")
        #expect(!draft.hasPolicyChanges)

        draft.setRevisionMiBText("3")
        #expect(draft.hasPolicyChanges)
        draft.setRevisionMiBText("2")
        #expect(!draft.hasPolicyChanges)
    }

    @Test("late configured-policy read preserves edits and advances strictness baseline")
    func lateConfigurationReadCannotOverwriteNewerDraft() throws {
        var draft = RetentionSettingsDraft()
        let loadRequest = draft.beginLoadRequest()

        // The panel is still awaiting its configured-policy read. The user
        // enables storage and enters 15 MiB against the neutral prefill.
        draft.setStorageEnabled(true)
        draft.setStorageMiBText("15")

        // The request then returns the authoritative 20 MiB configuration.
        // Its baseline is needed to identify 15 MiB as destructive tightening,
        // but its displayed 20 must not replace the newer dirty 15.
        let accepted = draft.acceptLoaded(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 90_001),
                storage: StorageRetention(maxTotalBytes: 20_971_520),
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 19,
                    maxRevisionBytesPerItem: 1_048_577
                )
            ),
            requestedAt: loadRequest
        )
        #expect(!accepted)

        let policies = try #require(draft.submission()?.policies)
        #expect(draft.storageEnabled)
        #expect(draft.storageMiBText == "15")
        #expect(draft.storageValueIsDirty)
        #expect(draft.ageEnabled)
        #expect(draft.ageDaysText == "2")
        #expect(draft.revisionCountEnabled)
        #expect(draft.revisionCountText == "19")
        #expect(draft.revisionBytesEnabled)
        #expect(draft.revisionMiBText == "2")
        #expect(policies.age?.maxAge == 90_001)
        #expect(policies.storage?.maxTotalBytes == 15_728_640)
        #expect(policies.revisions?.maxRevisionsPerItem == 19)
        #expect(policies.revisions?.maxRevisionBytesPerItem == 1_048_577)
        #expect(draft.requiresTighteningConfirmation(for: policies))
    }

    @Test("unedited rounded fields submit the exact configured policy values")
    func uneditedRoundedFieldsPreserveExactConfiguredValues() throws {
        var draft = RetentionSettingsDraft()
        load(HistoryRetentionPolicies(
            age: AgeRetention(maxAge: 90_001),
            storage: StorageRetention(maxTotalBytes: 1_048_577),
            revisions: RevisionRetention(
                maxRevisionsPerItem: 19,
                maxRevisionBytesPerItem: 1_048_577
            )
        ), into: &draft)

        // The whole-unit controls display the ceiling, but an untouched field
        // must not replace the authoritative sub-day/sub-MiB raw value.
        #expect(draft.ageDaysText == "2")
        #expect(draft.storageMiBText == "2")
        #expect(draft.revisionMiBText == "2")
        #expect(!draft.ageValueIsDirty)
        #expect(!draft.storageValueIsDirty)
        #expect(!draft.revisionBytesValueIsDirty)
        #expect(!draft.hasPolicyChanges)

        let policies = try #require(draft.submission()?.policies)
        #expect(policies.age?.maxAge == 90_001)
        #expect(policies.storage?.maxTotalBytes == 1_048_577)
        #expect(policies.revisions?.maxRevisionsPerItem == 19)
        #expect(policies.revisions?.maxRevisionBytesPerItem == 1_048_577)
        #expect(!draft.requiresTighteningConfirmation(for: policies))
    }

    @Test("editing one rounded field converts only that field to whole units")
    func editingOneFieldDoesNotRoundUntouchedPolicyValues() throws {
        var draft = RetentionSettingsDraft()
        load(HistoryRetentionPolicies(
            age: AgeRetention(maxAge: 90_001),
            storage: StorageRetention(maxTotalBytes: 1_048_577),
            revisions: RevisionRetention(
                maxRevisionsPerItem: nil,
                maxRevisionBytesPerItem: 1_048_577
            )
        ), into: &draft)

        draft.setStorageMiBText("1")

        let policies = try #require(draft.submission()?.policies)
        #expect(policies.age?.maxAge == 90_001)
        #expect(policies.storage?.maxTotalBytes == 1_048_576)
        #expect(policies.revisions?.maxRevisionBytesPerItem == 1_048_577)
        #expect(draft.storageValueIsDirty)
        #expect(draft.hasPolicyChanges)
        #expect(draft.requiresTighteningConfirmation(for: policies))
    }

    @Test("enabling or lowering any threshold requires destructive confirmation")
    func onlyStrictTighteningRequiresConfirmation() throws {
        var disabled = RetentionSettingsDraft()
        load(
            HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil),
            into: &disabled
        )
        disabled.setAgeEnabled(true)
        let enabledPolicies = try #require(disabled.submission()?.policies)
        #expect(disabled.requiresTighteningConfirmation(for: enabledPolicies))

        var configured = RetentionSettingsDraft()
        load(HistoryRetentionPolicies(
            age: AgeRetention(maxAge: 172_800),
            storage: StorageRetention(maxTotalBytes: 2_097_152),
            revisions: RevisionRetention(
                maxRevisionsPerItem: 20,
                maxRevisionBytesPerItem: 2_097_152
            )
        ), into: &configured)
        configured.setAgeDaysText("3")
        configured.setStorageMiBText("3")
        configured.setRevisionCountText("21")
        configured.setRevisionMiBText("3")
        let loosenedPolicies = try #require(configured.submission()?.policies)
        #expect(!configured.requiresTighteningConfirmation(for: loosenedPolicies))

        configured.setRevisionCountText("19")
        let tightenedPolicies = try #require(configured.submission()?.policies)
        #expect(configured.requiresTighteningConfirmation(for: tightenedPolicies))
    }

    @Test("late apply completion cannot overwrite a newer edit")
    func lateApplyCompletionIsRejectedByEditGeneration() throws {
        var draft = RetentionSettingsDraft()
        load(HistoryRetentionPolicies(
            age: nil,
            storage: StorageRetention(maxTotalBytes: 4_194_304),
            revisions: nil
        ), into: &draft)
        draft.setStorageMiBText("3")
        let staleSubmission = try #require(draft.submission())

        draft.setStorageMiBText("2")

        let accepted = draft.acceptApplied(
            staleSubmission,
            successMessage: "Done."
        )
        #expect(!accepted)
        #expect(draft.storageMiBText == "2")
        #expect(draft.storageValueIsDirty)
        #expect(draft.acceptedSuccessMessage == nil)
        #expect(draft.submission()?.policies.storage?.maxTotalBytes == 2_097_152)
    }

    @Test("stale success advances the strictness baseline without replacing newer text")
    func staleSuccessAdvancesOnlyTheConfiguredComparisonBaseline() throws {
        var draft = RetentionSettingsDraft()
        load(HistoryRetentionPolicies(
            age: nil,
            storage: StorageRetention(maxTotalBytes: 10_485_760),
            revisions: nil
        ), into: &draft)
        draft.setStorageMiBText("20")
        let staleSubmission = try #require(draft.submission())

        draft.setStorageMiBText("15")
        let accepted = draft.acceptApplied(
            staleSubmission,
            successMessage: "Done."
        )
        #expect(!accepted)

        let newerPolicies = try #require(draft.submission()?.policies)
        #expect(draft.storageMiBText == "15")
        #expect(draft.storageValueIsDirty)
        #expect(draft.acceptedSuccessMessage == nil)
        #expect(draft.requiresTighteningConfirmation(for: newerPolicies))
    }

    @Test("a new edit clears the accepted Done generation")
    func newEditClearsAcceptedApplyState() throws {
        var draft = RetentionSettingsDraft()
        load(HistoryRetentionPolicies(
            age: AgeRetention(maxAge: 172_800),
            storage: nil,
            revisions: nil
        ), into: &draft)
        draft.setAgeDaysText("3")
        let submission = try #require(draft.submission())

        let accepted = draft.acceptApplied(submission, successMessage: "Done.")
        #expect(accepted)
        #expect(draft.acceptedSuccessMessage == "Done.")
        #expect(!draft.ageValueIsDirty)
        #expect(!draft.hasPolicyChanges)

        draft.setAgeDaysText("4")

        #expect(draft.acceptedSuccessMessage == nil)
        #expect(draft.ageValueIsDirty)
        #expect(draft.ageDaysText == "4")
        #expect(draft.hasPolicyChanges)
    }

    @Test("an edit in either retention tab clears count Apply success")
    func crossTabEditClearsAcceptedCountSuccess() throws {
        var draft = RetentionSettingsDraft()
        load(
            HistoryRetentionConfiguration(
                maximumUnpinnedItems: 37,
                policies: HistoryRetentionPolicies(
                    age: nil,
                    storage: nil,
                    revisions: nil
                )
            ),
            into: &draft
        )
        let submission = try #require(draft.countSubmission())
        let accepted = draft.acceptApplied(
            submission,
            successMessage: "Done."
        )
        #expect(accepted)
        #expect(draft.acceptedCountSuccessMessage == "Done.")
        #expect(!draft.hasCountChanges)

        draft.setRevisionCountEnabled(true)

        #expect(draft.acceptedCountSuccessMessage == nil)
    }

    @Test("binary storage fields identify their units as MiB")
    func binaryStorageUnitLabelIsMiB() {
        #expect(RetentionSettingsDraft.mebibyteUnitLabel == "MiB")
    }

    @Test("age copy discloses event-triggered enforcement")
    func ageCopyDoesNotImplyAWallClockSweep() {
        #expect(
            RetentionSettingsDraft.ageEnforcementExplanation
                == "Age limits are checked when Clipy captures a clipboard "
                + "change or you apply retention settings. Time passing alone "
                + "doesn't remove items."
        )
    }
}
