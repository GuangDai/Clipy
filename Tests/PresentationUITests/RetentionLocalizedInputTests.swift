import Foundation
import HistoryCore
import Testing
@testable import PresentationUI

@Suite("Localized retention input")
struct RetentionLocalizedInputTests {
    @Test("grouped and ungrouped integers use the field locale")
    func localizedIntegers() {
        let cases: [(String, String, Int)] = [
            ("en_US", "5,000", 5_000),
            ("de_DE", "5.000", 5_000),
            ("fr_FR", "5\u{202F}000", 5_000),
            ("ar_EG", "٥٬٠٠٠", 5_000),
            ("ar_EG", "٥٠٠٠", 5_000),
            ("en_US", " 005000 ", 5_000),
            ("de_DE", "5000", 5_000),
        ]
        for (identifier, text, expected) in cases {
            #expect(validatedSettingsWholeNumber(
                text, in: 1...5_000, locale: Locale(identifier: identifier)
            ) == expected)
        }
    }

    @Test("fractions, incorrect grouping, trailing text and overflow never become policy values")
    func invalidIntegers() {
        let cases: [(String, [String])] = [
            ("en_US", ["1.5", "1.0", "1,5", "50,00", "5,,000", "5,000x", "1e3"]),
            ("de_DE", ["1,5", "1,0", "1.5", "50.00", "5..000", "5.000x"]),
            ("ar_EG", ["١٫٥", "١٬٥", "٥٬٠٠"]),
        ]
        for (identifier, inputs) in cases {
            for text in inputs {
                #expect(validatedSettingsWholeNumber(
                    text, in: 1...Int.max, locale: Locale(identifier: identifier)
                ) == nil)
            }
        }
        for text in ["", "0", "5001", "9223372036854775808", "9,223,372,036,854,775,808"] {
            #expect(validatedSettingsWholeNumber(
                text, in: 1...5_000, locale: Locale(identifier: "en_US")
            ) == nil)
        }
    }

    @Test("loaded values round trip without changing exact policies",
          arguments: ["en_US", "de_DE", "fr_FR", "ar_EG"])
    func loadedDraftRoundTrip(_ identifier: String) throws {
        let locale = Locale(identifier: identifier)
        var draft = RetentionSettingsDraft(locale: locale)
        let policies = HistoryRetentionPolicies(
            age: AgeRetention(maxAge: 1_999 * 86_400 + 1),
            storage: StorageRetention(maxTotalBytes: 4_999 * 1_048_576 + 1),
            revisions: RevisionRetention(maxRevisionsPerItem: 20, maxRevisionBytesPerItem: 64 * 1_048_576)
        )
        draft.acceptLoaded(
            HistoryRetentionConfiguration(maximumUnpinnedItems: 5_000, policies: policies),
            requestedAt: draft.beginLoadRequest()
        )
        #expect(draft.maximumUnpinnedText == LocalizedCountPresentation.number(5_000, locale: locale))
        #expect(draft.ageDaysText == LocalizedCountPresentation.number(2_000, locale: locale))
        #expect(draft.storageMiBText == LocalizedCountPresentation.number(5_000, locale: locale))
        #expect(draft.inputIsValid)
        #expect(draft.maximumUnpinnedInputIsValid)
        #expect(!draft.hasCountChanges)
        #expect(!draft.hasPolicyChanges)
        #expect(draft.countSubmission()?.maximumUnpinnedItems == 5_000)
        #expect(try #require(draft.submission()).policies == policies)

        draft.setMaximumUnpinnedText(LocalizedCountPresentation.number(4_000, locale: locale))
        #expect(draft.maximumUnpinnedStepperValue == 4_000)
        draft.maximumUnpinnedStepperValue += 1
        #expect(draft.maximumUnpinnedText == LocalizedCountPresentation.number(4_001, locale: locale))
        #expect(draft.countSubmission()?.maximumUnpinnedItems == 4_001)
    }
}
