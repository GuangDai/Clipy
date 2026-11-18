/// RetentionSettingsDraftTests.swift — pure Presentation-state proofs for the
/// unified retention editor (`V2-07` §5.2/§6.3). Expected values are literal
/// policy facts, never values recomputed through the draft's conversion code.
import Foundation
@testable import HistoryCore
import Testing
@testable import ClipyApp

@Suite("Retention settings draft")
struct RetentionSettingsDraftTests {
    @Test(arguments: [true, false])
    func reopeningReadRacingACompletedApplyRequiresOneFreshConfiguration(appliesCount: Bool) throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        load(HistoryRetentionConfiguration(
            maximumUnpinnedItems: 200,
            policies: HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil)
        ), into: &draft)
        let reopeningRead: RetentionSettingsDraft.LoadRequest
        let refreshedConfiguration: HistoryRetentionConfiguration
        if appliesCount {
            draft.setMaximumUnpinnedText("500")
            let submission = try #require(draft.countSubmission())
            reopeningRead = draft.beginLoadRequest()
            let acceptedApply = draft.acceptApplied(submission, successMessage: "count saved")
            #expect(acceptedApply)
            let acceptedRead = draft.acceptLoaded(HistoryRetentionConfiguration(
                maximumUnpinnedItems: 200,
                policies: HistoryRetentionPolicies(age: AgeRetention(maxAge: 90_001), storage: nil, revisions: nil)
            ), requestedAt: reopeningRead)
            #expect(!acceptedRead)
            #expect(draft.maximumUnpinnedText == "500")
            #expect(draft.countSubmission()?.maximumUnpinnedItems == 500)
            #expect(!draft.hasCountChanges)
            #expect(draft.acceptedCountSuccessMessage == "count saved")
            refreshedConfiguration = HistoryRetentionConfiguration(
                maximumUnpinnedItems: 500,
                policies: HistoryRetentionPolicies(age: AgeRetention(maxAge: 90_001), storage: nil, revisions: nil)
            )
        } else {
            draft.setAgeEnabled(true)
            draft.setAgeDaysText("4")
            let submission = try #require(draft.submission())
            reopeningRead = draft.beginLoadRequest()
            let acceptedApply = draft.acceptApplied(submission, successMessage: "policies saved")
            #expect(acceptedApply)
            let acceptedRead = draft.acceptLoaded(HistoryRetentionConfiguration(
                maximumUnpinnedItems: 37,
                policies: HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil)
            ), requestedAt: reopeningRead)
            #expect(!acceptedRead)
            #expect(draft.ageEnabled)
            #expect(draft.ageDaysText == "4")
            #expect(try #require(draft.submission()).policies == submission.policies)
            #expect(!draft.hasPolicyChanges)
            #expect(draft.acceptedSuccessMessage == "policies saved")
            refreshedConfiguration = HistoryRetentionConfiguration(
                maximumUnpinnedItems: 37, policies: submission.policies
            )
        }
        #expect(!draft.isCurrent(reopeningRead))
        #expect(draft.requiresReloadAfterApply(reopeningRead))
        let refresh = draft.beginLoadRequest()
        #expect(!draft.requiresReloadAfterApply(reopeningRead), "The retired request must not schedule another read")
        // Unsaved text remains protected when the one fresh read arrives.
        draft.setRevisionCountText("unsaved draft")
        _ = draft.acceptLoaded(refreshedConfiguration, requestedAt: refresh)
        #expect(draft.isCurrent(refresh))
        #expect(!draft.requiresReloadAfterApply(refresh))
        #expect(draft.configuredRetentionConfiguration == refreshedConfiguration)
        #expect(!draft.hasCountChanges)
        #expect(!draft.hasPolicyChanges)
        #expect(draft.revisionCountText == "unsaved draft")
    }

    @Test("an earlier settings load cannot overwrite a newer load without intervening edits")
    func newerLoadOwnsTheExactBaseline() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        let earlier = draft.beginLoadRequest()
        let newer = draft.beginLoadRequest()
        let current = HistoryRetentionConfiguration(
            maximumUnpinnedItems: 42,
            policies: HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 90_001),
                storage: StorageRetention(maxTotalBytes: 1_048_577), revisions: nil
            )
        )
        let acceptedNewer = draft.acceptLoaded(current, requestedAt: newer)
        #expect(acceptedNewer)
        #expect(!draft.isCurrent(earlier))
        let acceptedEarlier = draft.acceptLoaded(
            HistoryRetentionConfiguration(
                maximumUnpinnedItems: 7,
                policies: HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil)
            ), requestedAt: earlier
        )
        #expect(!acceptedEarlier)
        #expect(draft.countSubmission()?.maximumUnpinnedItems == 42)
        #expect(try #require(draft.submission()).policies == current.policies)
        #expect(!draft.hasCountChanges)
        #expect(!draft.hasPolicyChanges)
    }

    @Test("disappearing settings invalidate reads without clearing user edits or their baseline")
    func invalidatedLoadCannotEraseUserDraft() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        load(HistoryRetentionConfiguration(
            maximumUnpinnedItems: 37,
            policies: HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 90_001),
                storage: StorageRetention(maxTotalBytes: 1_048_577), revisions: nil
            )
        ), into: &draft)
        let request = draft.beginLoadRequest()
        draft.setMaximumUnpinnedText("31")
        draft.setStorageMiBText("15")
        draft.invalidateLoadRequest()
        #expect(!draft.isCurrent(request))
        let acceptedInvalidated = draft.acceptLoaded(
            HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil),
            requestedAt: request
        )
        #expect(!acceptedInvalidated)
        #expect(draft.maximumUnpinnedText == "31")
        #expect(draft.storageMiBText == "15")
        #expect(draft.maximumUnpinnedValueIsDirty)
        #expect(draft.storageValueIsDirty)
        let submission = try #require(draft.submission())
        #expect(submission.policies.age?.maxAge == 90_001)
        #expect(submission.policies.storage?.maxTotalBytes == 15_728_640)
        let count = try #require(draft.countSubmission())
        #expect(draft.requiresCountRemovalConfirmation(for: count))

        // Reopening starts after these edits. It must preserve them just as
        // a read that started before the edits does, while updating untouched
        // fields and the authoritative configured values.
        let reopened = draft.beginLoadRequest()
        let acceptedReopened = draft.acceptLoaded(HistoryRetentionConfiguration(
            maximumUnpinnedItems: 20,
            policies: HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 180_001),
                storage: StorageRetention(maxTotalBytes: 2_097_153), revisions: nil
            )
        ), requestedAt: reopened)
        #expect(acceptedReopened)
        #expect(draft.maximumUnpinnedText == "31")
        #expect(draft.storageMiBText == "15")
        #expect(draft.maximumUnpinnedValueIsDirty)
        #expect(draft.storageValueIsDirty)
        #expect(draft.ageDaysText == "3")
        #expect(try #require(draft.submission()).policies.age?.maxAge == 180_001)
        #expect(try #require(draft.submission()).policies.storage?.maxTotalBytes == 15_728_640)
        #expect(draft.configuredRetentionConfiguration.maximumUnpinnedItems == 20)
        #expect(draft.countSubmission()?.maximumUnpinnedItems == 31)
    }

    @Test("reload preserves unsaved toggles and all V2 value fields")
    func reloadedConfigurationDoesNotDiscardExistingPolicyEdits() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        draft.setAgeEnabled(true)
        draft.setAgeDaysText("4")
        draft.setStorageEnabled(true)
        draft.setStorageMiBText("2")
        draft.setRevisionCountEnabled(true)
        draft.setRevisionCountText("3")
        draft.setRevisionBytesEnabled(true)
        draft.setRevisionMiBText("5")
        let request = draft.beginLoadRequest()
        let accepted = draft.acceptLoaded(
            HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil),
            requestedAt: request
        )
        #expect(accepted)
        let policies = try #require(draft.submission()).policies
        #expect(policies.age?.maxAge == 345_600)
        #expect(policies.storage?.maxTotalBytes == 2_097_152)
        #expect(policies.revisions?.maxRevisionsPerItem == 3)
        #expect(policies.revisions?.maxRevisionBytesPerItem == 5_242_880)
        #expect(draft.hasPolicyChanges)
    }

    @Test("a fresh configuration read clears old success feedback without changing edited values")
    func reloadingRetiresPriorSuccessFeedback() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        draft.setMaximumUnpinnedText("37")
        draft.setAgeEnabled(true)
        let policies = try #require(draft.submission())
        let acceptedPolicies = draft.acceptApplied(policies, successMessage: "policies saved")
        #expect(acceptedPolicies)
        let count = try #require(draft.countSubmission())
        let acceptedCount = draft.acceptApplied(count, successMessage: "count saved")
        #expect(acceptedCount)
        #expect(draft.acceptedSuccessMessage == "policies saved")
        #expect(draft.acceptedCountSuccessMessage == "count saved")
        let before = try #require(draft.submission()).policies
        _ = draft.beginLoadRequest()
        #expect(draft.acceptedSuccessMessage == nil)
        #expect(draft.acceptedCountSuccessMessage == nil)
        #expect(draft.maximumUnpinnedText == "37")
        #expect(try #require(draft.submission()).policies == before)
    }

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
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
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
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
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
        #expect(!draft.requiresCountRemovalConfirmation(for: submission))

        draft.setMaximumUnpinnedText("36")
        let tightened = try #require(draft.countSubmission())
        #expect(draft.requiresCountRemovalConfirmation(for: tightened))
    }

    @Test("count Apply is enabled only when the validated value differs from configuration")
    func countChangesCompareTheCandidateToTheExactBaseline() {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
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
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
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
        var countDraft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
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
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
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
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
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
        #expect(draft.requiresRemovalConfirmation(for: policies))
    }

    @Test("unedited rounded fields submit the exact configured policy values")
    func uneditedRoundedFieldsPreserveExactConfiguredValues() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
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
        #expect(!draft.requiresRemovalConfirmation(for: policies))
    }

    @Test("editing one rounded field converts only that field to whole units")
    func editingOneFieldDoesNotRoundUntouchedPolicyValues() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
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
        #expect(draft.requiresRemovalConfirmation(for: policies))
    }

    @Test("enabling or lowering any threshold requires confirmation")
    func activeLimitsThatCanRemoveContentRequireConfirmation() throws {
        let enableEdits: [(inout RetentionSettingsDraft) -> Void] = [
            { $0.setAgeEnabled(true) },
            { $0.setStorageEnabled(true) },
            { $0.setRevisionCountEnabled(true) },
            { $0.setRevisionBytesEnabled(true) },
        ]
        for enable in enableEdits {
            var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
            enable(&draft)
            let policies = try #require(draft.submission()?.policies)
            #expect(draft.requiresRemovalConfirmation(for: policies))
        }

        let lowerEdits: [(inout RetentionSettingsDraft) -> Void] = [
            { $0.setStorageMiBText("1") },
            { $0.setRevisionCountText("19") },
            { $0.setRevisionMiBText("1") },
        ]
        for lower in lowerEdits {
            var draft = configuredDraft(age: nil)
            lower(&draft)
            let policies = try #require(draft.submission()?.policies)
            #expect(draft.requiresRemovalConfirmation(for: policies))
        }
    }

    @Test("an active age limit can retire items even when no limit tightens")
    func ageRemainsADeletionRiskWhenRelaxingLimits() throws {
        let edits: [(inout RetentionSettingsDraft) -> Void] = [
            { $0.setAgeDaysText("3") },
            { $0.setStorageMiBText("3") },
            { $0.setRevisionCountEnabled(false) },
        ]
        for edit in edits {
            var draft = configuredDraft(age: AgeRetention(maxAge: 172_800))
            edit(&draft)
            #expect(draft.hasPolicyChanges)
            let policies = try #require(draft.submission()?.policies)
            #expect(draft.requiresRemovalConfirmation(for: policies))
        }
    }

    @Test("turning off age alone needs no confirmation")
    func disablingAgeIsADirectApply() throws {
        var draft = configuredDraft(age: AgeRetention(maxAge: 172_800))
        draft.setAgeEnabled(false)
        #expect(draft.hasPolicyChanges)
        let policies = try #require(draft.submission()?.policies)
        #expect(policies.age == nil)
        #expect(!draft.requiresRemovalConfirmation(for: policies))
    }

    @Test("tightening storage still needs confirmation when age is turned off")
    func disablingAgeDoesNotHideOtherRemovalRisk() throws {
        var draft = configuredDraft(age: AgeRetention(maxAge: 172_800))
        draft.setAgeEnabled(false)
        draft.setStorageMiBText("1")
        let policies = try #require(draft.submission()?.policies)
        #expect(draft.requiresRemovalConfirmation(for: policies))
    }

    private func configuredDraft(age: AgeRetention?) -> RetentionSettingsDraft {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        load(HistoryRetentionPolicies(
            age: age,
            storage: StorageRetention(maxTotalBytes: 2_097_152),
            revisions: RevisionRetention(
                maxRevisionsPerItem: 20,
                maxRevisionBytesPerItem: 2_097_152
            )
        ), into: &draft)
        return draft
    }

    @Test("late apply completion cannot overwrite a newer edit")
    func lateApplyCompletionIsRejectedByEditGeneration() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
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
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
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
        #expect(draft.requiresRemovalConfirmation(for: newerPolicies))
    }

    @Test("count completion clears saved count edits after a policy edit")
    func countCompletionWithNewPolicyEditAllowsFreshCountReadback() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        draft.setMaximumUnpinnedText("38")
        let submission = try #require(draft.countSubmission())
        draft.setAgeEnabled(true)
        draft.setAgeDaysText("4")

        let accepted = draft.acceptApplied(submission, successMessage: "Done.")
        #expect(!accepted)
        #expect(draft.acceptedCountSuccessMessage == nil)
        #expect(!draft.maximumUnpinnedValueIsDirty)
        #expect(draft.ageToggleIsDirty)
        #expect(draft.ageValueIsDirty)

        load(HistoryRetentionConfiguration(
            maximumUnpinnedItems: 42,
            policies: HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil)
        ), into: &draft)
        #expect(draft.countSubmission()?.maximumUnpinnedItems == 42)
        #expect(!draft.hasCountChanges)
        #expect(draft.submission()?.policies.age?.maxAge == 345_600)
        #expect(draft.hasPolicyChanges)
    }

    @Test("policy completion clears saved policy edits after a count edit")
    func policyCompletionWithNewCountEditAllowsFreshPolicyReadback() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        draft.setAgeEnabled(true)
        draft.setAgeDaysText("4")
        let submission = try #require(draft.submission())
        draft.setMaximumUnpinnedText("38")

        let accepted = draft.acceptApplied(submission, successMessage: "Done.")
        #expect(!accepted)
        #expect(draft.acceptedSuccessMessage == nil)
        #expect(!draft.ageToggleIsDirty)
        #expect(!draft.ageValueIsDirty)
        #expect(draft.maximumUnpinnedValueIsDirty)

        load(HistoryRetentionConfiguration(
            maximumUnpinnedItems: 42,
            policies: HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 90_001), storage: nil, revisions: nil
            )
        ), into: &draft)
        #expect(draft.countSubmission()?.maximumUnpinnedItems == 38)
        #expect(draft.hasCountChanges)
        #expect(draft.ageDaysText == "2")
        #expect(draft.submission()?.policies.age?.maxAge == 90_001)
        #expect(!draft.hasPolicyChanges)
    }

    @Test("policy completion preserves newer text in a disabled field")
    func policyCompletionDoesNotDiscardAnUnsubmittedDisabledFieldEdit() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        draft.setStorageEnabled(true)
        let submission = try #require(draft.submission())
        draft.setAgeDaysText("4")

        // The policies are equal because age is disabled, but its new text
        // remains an unsaved edit and must survive the next configured read.
        #expect(draft.submission()?.policies == submission.policies)
        let accepted = draft.acceptApplied(submission, successMessage: "Done.")
        #expect(!accepted)
        #expect(draft.ageValueIsDirty)

        load(HistoryRetentionPolicies(
            age: AgeRetention(maxAge: 90_001),
            storage: StorageRetention(maxTotalBytes: 524_288_000),
            revisions: nil
        ), into: &draft)
        #expect(draft.ageDaysText == "4")
        #expect(draft.submission()?.policies.age?.maxAge == 345_600)
    }

    @Test("policy completion cleans saved fields while preserving a newer sibling field")
    func completedPolicyFieldsCanRefreshAfterAnotherPolicyFieldWasEdited() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        draft.setAgeEnabled(true)
        draft.setAgeDaysText("4")
        draft.setStorageEnabled(true)
        draft.setStorageMiBText("3")
        draft.setRevisionCountEnabled(true)
        draft.setRevisionCountText("12")
        draft.setRevisionBytesEnabled(true)
        draft.setRevisionMiBText("5")
        let submission = try #require(draft.submission())
        draft.setStorageMiBText("2")

        let accepted = draft.acceptApplied(submission, successMessage: "Done.")
        #expect(!accepted)
        #expect(draft.acceptedSuccessMessage == nil)
        #expect(!draft.ageValueIsDirty)
        #expect(draft.storageValueIsDirty)
        #expect(!draft.revisionCountValueIsDirty)
        #expect(!draft.revisionBytesValueIsDirty)
        #expect(!draft.ageToggleIsDirty)
        #expect(!draft.storageToggleIsDirty)
        #expect(!draft.revisionCountToggleIsDirty)
        #expect(!draft.revisionBytesToggleIsDirty)

        load(HistoryRetentionPolicies(
            age: AgeRetention(maxAge: 90_001),
            storage: StorageRetention(maxTotalBytes: 3_145_729),
            revisions: RevisionRetention(
                maxRevisionsPerItem: 19, maxRevisionBytesPerItem: 1_048_577
            )
        ), into: &draft)
        let proposed = try #require(draft.submission()).policies
        #expect(draft.ageDaysText == "2")
        #expect(draft.storageMiBText == "2")
        #expect(draft.revisionCountText == "19")
        #expect(draft.revisionMiBText == "2")
        #expect(proposed.age?.maxAge == 90_001)
        #expect(proposed.storage?.maxTotalBytes == 2_097_152)
        #expect(proposed.revisions?.maxRevisionsPerItem == 19)
        #expect(proposed.revisions?.maxRevisionBytesPerItem == 1_048_577)
    }

    @Test("policy completion preserves a newer toggle without retaining saved sibling toggles")
    func completedPolicyTogglesCanRefreshAfterAnotherToggleWasEdited() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        draft.setAgeEnabled(true)
        draft.setStorageEnabled(true)
        draft.setStorageMiBText("3")
        let submission = try #require(draft.submission())
        draft.setStorageEnabled(false)

        let accepted = draft.acceptApplied(submission, successMessage: "Done.")
        #expect(!accepted)
        #expect(!draft.ageToggleIsDirty)
        #expect(draft.storageToggleIsDirty)
        #expect(!draft.storageValueIsDirty)

        load(HistoryRetentionPolicies(
            age: nil,
            storage: StorageRetention(maxTotalBytes: 1_048_577),
            revisions: nil
        ), into: &draft)
        #expect(!draft.ageEnabled)
        #expect(!draft.storageEnabled)
        #expect(draft.storageMiBText == "2")
        #expect(draft.submission()?.policies.age == nil)
        #expect(draft.submission()?.policies.storage == nil)
        #expect(draft.hasPolicyChanges)
    }

    @Test("policy completion preserves an explicit whole-unit edit returning to rounded display")
    func completedPolicyDoesNotRestoreRawValuesOverNewWholeUnitIntent() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        load(HistoryRetentionPolicies(
            age: AgeRetention(maxAge: 90_001),
            storage: StorageRetention(maxTotalBytes: 1_048_577),
            revisions: RevisionRetention(
                maxRevisionsPerItem: 20, maxRevisionBytesPerItem: 1_048_577
            )
        ), into: &draft)
        draft.setRevisionCountText("19")
        let submission = try #require(draft.submission())

        draft.setAgeDaysText("3")
        draft.setAgeDaysText("2")
        draft.setStorageMiBText("3")
        draft.setStorageMiBText("2")
        draft.setRevisionMiBText("3")
        draft.setRevisionMiBText("2")
        let accepted = draft.acceptApplied(submission, successMessage: "Done.")
        #expect(!accepted)
        #expect(draft.ageValueIsDirty)
        #expect(draft.storageValueIsDirty)
        #expect(draft.revisionBytesValueIsDirty)
        #expect(!draft.revisionCountValueIsDirty)
        let proposed = try #require(draft.submission()).policies
        #expect(proposed.age?.maxAge == 172_800)
        #expect(proposed.storage?.maxTotalBytes == 2_097_152)
        #expect(proposed.revisions?.maxRevisionBytesPerItem == 2_097_152)
        #expect(draft.hasPolicyChanges)
    }

    @Test("a new edit clears the accepted Done generation")
    func newEditClearsAcceptedApplyState() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
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
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
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

    @Test("a freshly loaded draft offers no write on either Apply")
    func uneditedConfigurationHasNoPendingWrite() {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        load(
            HistoryRetentionConfiguration(
                maximumUnpinnedItems: 37,
                policies: HistoryRetentionPolicies(
                    age: AgeRetention(maxAge: 90_001),
                    storage: StorageRetention(maxTotalBytes: 1_048_577),
                    revisions: RevisionRetention(
                        maxRevisionsPerItem: 19,
                        maxRevisionBytesPerItem: 1_048_577
                    )
                )
            ),
            into: &draft
        )

        // Equal to the persisted configuration: no field is dirty, neither
        // Apply enables, and nothing would be written (Card 10D/10E).
        #expect(!draft.maximumUnpinnedValueIsDirty)
        #expect(!draft.ageValueIsDirty)
        #expect(!draft.storageValueIsDirty)
        #expect(!draft.revisionCountValueIsDirty)
        #expect(!draft.revisionBytesValueIsDirty)
        #expect(!draft.ageToggleIsDirty)
        #expect(!draft.storageToggleIsDirty)
        #expect(!draft.revisionCountToggleIsDirty)
        #expect(!draft.revisionBytesToggleIsDirty)
        #expect(!draft.hasCountChanges)
        #expect(!draft.hasPolicyChanges)
    }

    @Test("each control dirties only its own edit state")
    func fieldEditsAreIndependentlyDirty() {
        // A count edit never dirties the policy dimensions (Card 10A).
        var countDraft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        countDraft.setMaximumUnpinnedText("31")
        #expect(countDraft.maximumUnpinnedValueIsDirty)
        #expect(countDraft.hasCountChanges)
        #expect(!countDraft.ageValueIsDirty)
        #expect(!countDraft.storageValueIsDirty)
        #expect(!countDraft.revisionCountValueIsDirty)
        #expect(!countDraft.revisionBytesValueIsDirty)
        #expect(!countDraft.ageToggleIsDirty)
        #expect(!countDraft.storageToggleIsDirty)
        #expect(!countDraft.revisionCountToggleIsDirty)
        #expect(!countDraft.revisionBytesToggleIsDirty)
        #expect(!countDraft.hasPolicyChanges)

        // A toggle dirties its own toggle state only, never its value.
        var toggleDraft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        toggleDraft.setStorageEnabled(true)
        #expect(toggleDraft.storageToggleIsDirty)
        #expect(!toggleDraft.storageValueIsDirty)
        #expect(!toggleDraft.ageToggleIsDirty)
        #expect(!toggleDraft.revisionCountToggleIsDirty)
        #expect(!toggleDraft.revisionBytesToggleIsDirty)
        #expect(toggleDraft.hasPolicyChanges)

        // Text in a disabled dimension dirties its value only; with the
        // toggle off, the proposed bundle still matches the all-disabled
        // baseline, so there is nothing to write.
        var valueDraft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        valueDraft.setRevisionCountText("7")
        #expect(valueDraft.revisionCountValueIsDirty)
        #expect(!valueDraft.revisionCountToggleIsDirty)
        #expect(!valueDraft.revisionBytesValueIsDirty)
        #expect(!valueDraft.ageValueIsDirty)
        #expect(!valueDraft.storageValueIsDirty)
        #expect(!valueDraft.hasPolicyChanges)
        #expect(!valueDraft.hasCountChanges)
    }

    @Test("raising the count can still remove unpinned items")
    func raisedCountRequiresRemovalConfirmation() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
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

        draft.setMaximumUnpinnedText("38")
        let submission = try #require(draft.countSubmission())
        #expect(draft.hasCountChanges)
        #expect(draft.requiresCountRemovalConfirmation(for: submission))
    }

    @Test("loosening or disabling non-age thresholds applies directly with age off")
    func nonAgeRelaxationDoesNotRequireConfirmation() throws {
        let edits: [(inout RetentionSettingsDraft) -> Void] = [
            { $0.setStorageMiBText("3") },
            { $0.setRevisionCountText("21") },
            { $0.setRevisionMiBText("3") },
            { $0.setStorageEnabled(false) },
            { $0.setRevisionCountEnabled(false) },
            { $0.setRevisionBytesEnabled(false) },
        ]
        for edit in edits {
            var draft = configuredDraft(age: nil)
            edit(&draft)
            #expect(draft.hasPolicyChanges)
            let submission = try #require(draft.submission())
            #expect(!draft.requiresRemovalConfirmation(for: submission.policies))
        }
    }
}
