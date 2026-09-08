import Foundation
@testable import HistoryCore
import Testing
@testable import ClipyApp

struct RetentionAppliedSummaryTests {
    @Test func summaryKeepsAppliedValuesWhileFieldsContainUnsubmittedChanges() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "en_US"))
        let loaded = HistoryRetentionConfiguration(maximumUnpinnedItems: 200, policies: .init(
            age: .init(maxAge: 90_001), storage: .init(maxTotalBytes: 1_048_577), revisions: nil
        ))
        let read = draft.beginLoadRequest()
        let acceptedRead = draft.acceptLoaded(loaded, requestedAt: read)
        #expect(acceptedRead)
        draft.setMaximumUnpinnedText("20")
        draft.setAgeEnabled(false)
        #expect(draft.configuredRetentionConfiguration == loaded)
        #expect(draft.hasCountChanges && draft.hasPolicyChanges)

        let submission = try #require(draft.countSubmission())
        draft.setMaximumUnpinnedText("30")
        // A real receipt for an older edit still advances the applied
        // summary; the newer field value remains pending, not misreported.
        let acceptedOldEdit = draft.acceptApplied(submission, successMessage: "Saved")
        #expect(!acceptedOldEdit)
        #expect(draft.configuredRetentionConfiguration.maximumUnpinnedItems == 20)
        #expect(draft.maximumUnpinnedText == "30" && draft.hasCountChanges)
        #expect(draft.configuredRetentionConfiguration.policies == loaded.policies)
    }

    @Test func summaryDistinguishesNoCountLimitFromOtherEnabledPolicies() throws {
        let root = try #require(Bundle.main.resourceURL)
        let localization = try #require(Bundle.main.localizations.first {
            $0.caseInsensitiveCompare("zh-Hans") == .orderedSame
        })
        let chinese = try #require(Bundle(url: root.appendingPathComponent("\(localization).lproj")))
        let configuration = HistoryRetentionConfiguration(maximumUnpinnedItems: nil, policies: .init(
            age: .init(maxAge: 86_400), storage: nil,
            revisions: .init(maxRevisionsPerItem: 2, maxRevisionBytesPerItem: nil)
        ))
        #expect(RetentionLayoutCopy.countSummary(configuration, bundle: chinese) == "不限制项目数量")
        #expect(RetentionLayoutCopy.policySummary(configuration, bundle: chinese) == "清理限制：时间 · 修订版本")
        let noPolicies = HistoryRetentionConfiguration(maximumUnpinnedItems: 1_000_000,
            policies: .init(age: nil, storage: nil, revisions: nil))
        #expect(RetentionLayoutCopy.countSummary(noPolicies, bundle: chinese,
            locale: Locale(identifier: "zh_Hans")) == "最多保留 1,000,000 个未置顶项目")
        #expect(RetentionLayoutCopy.policySummary(noPolicies, bundle: chinese) == "时间、存储量和修订版本限制均已关闭。")
    }
}
