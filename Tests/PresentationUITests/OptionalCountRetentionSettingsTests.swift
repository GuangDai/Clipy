import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import PresentationUI

struct OptionalCountRetentionSettingsTests {
    @Test func disabledCountLoadsWithoutInventingAThresholdOrChangingOtherPolicies() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        let policies = HistoryRetentionPolicies(
            age: AgeRetention(maxAge: 90_001),
            storage: StorageRetention(maxTotalBytes: 1_048_577),
            revisions: RevisionRetention(maxRevisionsPerItem: 7, maxRevisionBytesPerItem: 2_097_153)
        )
        let load = draft.beginLoadRequest()
        draft.acceptLoaded(.init(maximumUnpinnedItems: nil, policies: policies), requestedAt: load)
        #expect(!draft.countEnabled)
        #expect(!draft.hasCountChanges)
        #expect(draft.maximumUnpinnedInputIsValid)
        let unchanged = try #require(draft.countSubmission())
        #expect(unchanged.maximumUnpinnedItems == nil)
        #expect(!draft.maximumUnpinnedRequiresTightening(for: unchanged))
        #expect(try #require(draft.submission()).policies == policies)
        #expect(!draft.hasPolicyChanges)

        // A disabled field cannot block saving the independent off state.
        draft.setMaximumUnpinnedText("unfinished")
        #expect(draft.maximumUnpinnedInputIsValid)
        #expect(!draft.hasCountChanges)
        #expect(try #require(draft.countSubmission()).maximumUnpinnedItems == nil)
        draft.setCountEnabled(true)
        #expect(!draft.maximumUnpinnedInputIsValid)
        #expect(draft.countSubmission() == nil)
        draft.setMaximumUnpinnedText("1,000,000")
        let enabled = try #require(draft.countSubmission())
        #expect(enabled.maximumUnpinnedItems == 1_000_000)
        #expect(draft.hasCountChanges)
        #expect(draft.maximumUnpinnedRequiresTightening(for: enabled))
    }

    @Test func disablingCountIsNotDestructiveButReenablingItRequiresConfirmation() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        draft.setCountEnabled(false)
        let off = try #require(draft.countSubmission())
        #expect(off.maximumUnpinnedItems == nil)
        #expect(draft.hasCountChanges)
        #expect(!draft.maximumUnpinnedRequiresTightening(for: off))
        let accepted = draft.acceptApplied(off, successMessage: "Saved")
        #expect(accepted)
        #expect(!draft.countToggleIsDirty)
        #expect(!draft.hasCountChanges)
        draft.setCountEnabled(true)
        let on = try #require(draft.countSubmission())
        #expect(on.maximumUnpinnedItems == 200)
        #expect(draft.maximumUnpinnedRequiresTightening(for: on))
        draft.setCountEnabled(false)
        #expect(!draft.hasCountChanges)
    }

    @Test func newerOffChoiceSurvivesAReadAndAnOlderCountApply() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        draft.setMaximumUnpinnedText("1000000")
        let pending = try #require(draft.countSubmission())
        let load = draft.beginLoadRequest()
        draft.setCountEnabled(false)
        draft.acceptLoaded(.init(
            maximumUnpinnedItems: 500,
            policies: .init(age: nil, storage: nil, revisions: nil)
        ), requestedAt: load)
        #expect(!draft.countEnabled)
        #expect(draft.maximumUnpinnedText == "1000000")
        #expect(draft.countToggleIsDirty)
        let accepted = draft.acceptApplied(pending, successMessage: "Old success")
        #expect(!accepted)
        #expect(!draft.countEnabled)
        #expect(draft.countToggleIsDirty)
        #expect(draft.acceptedCountSuccessMessage == nil)
        #expect(draft.hasCountChanges)
        let latest = try #require(draft.countSubmission())
        #expect(latest.maximumUnpinnedItems == nil)
        #expect(!draft.maximumUnpinnedRequiresTightening(for: latest))
    }

    @Test(arguments: [("en_US", "1,000,000"), ("de_DE", "1.000.000"), ("ar_EG", "١٬٠٠٠٬٠٠٠")])
    func localizedMillionItemLimitHasNoProductCeiling(locale: String, text: String) throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: locale))
        draft.setMaximumUnpinnedText(text)
        #expect(draft.maximumUnpinnedInputIsValid)
        #expect(draft.maximumUnpinnedStepperValue == 1_000_000)
        let submission = try #require(draft.countSubmission())
        #expect(submission.maximumUnpinnedItems == 1_000_000)
        #expect(!draft.maximumUnpinnedRequiresTightening(for: submission))
    }

    @Test @MainActor
    func settingsIntentPersistsOffAndMillionCountChoices() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let state = HistoryViewState(history: history)
        _ = try await state.applyMaximumUnpinnedItems(nil)
        let disabled = try await history.retentionConfiguration()
        #expect(disabled.maximumUnpinnedItems == nil)
        _ = try await state.applyMaximumUnpinnedItems(1_000_000)
        let enabled = try await history.retentionConfiguration()
        #expect(enabled.maximumUnpinnedItems == 1_000_000)
        #expect(enabled.policies == disabled.policies)
    }
}
