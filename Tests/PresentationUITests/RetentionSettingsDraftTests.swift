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
        #expect(draft.acceptLoaded(policies, requestedAt: request))
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
        #expect(!draft.acceptLoaded(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 90_001),
                storage: StorageRetention(maxTotalBytes: 20_971_520),
                revisions: nil
            ),
            requestedAt: loadRequest
        ))

        let policies = try #require(draft.submission()?.policies)
        #expect(draft.storageEnabled)
        #expect(draft.storageMiBText == "15")
        #expect(draft.storageValueIsDirty)
        #expect(policies.storage?.maxTotalBytes == 15_728_640)
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

        #expect(!draft.acceptApplied(staleSubmission, successMessage: "Done."))
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
        #expect(!draft.acceptApplied(staleSubmission, successMessage: "Done."))

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

        #expect(draft.acceptApplied(submission, successMessage: "Done."))
        #expect(draft.acceptedSuccessMessage == "Done.")
        #expect(!draft.ageValueIsDirty)

        draft.setAgeDaysText("4")

        #expect(draft.acceptedSuccessMessage == nil)
        #expect(draft.ageValueIsDirty)
        #expect(draft.ageDaysText == "4")
    }

    @Test("binary storage fields identify their units as MiB")
    func binaryStorageUnitLabelIsMiB() {
        #expect(RetentionSettingsDraft.mebibyteUnitLabel == "MiB")
    }
}
