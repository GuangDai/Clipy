import Foundation
import HistoryCore
import Testing
@testable import PresentationUI

@Suite("Localized retention input")
struct RetentionLocalizedInputTests {
    @Test("Arabic-Indic control inputs submit exact policy units and retain ASCII compatibility")
    func arabicControlInputs() throws {
        var draft = RetentionSettingsDraft(locale: Locale(identifier: "ar_EG"))
        draft.setMaximumUnpinnedText("٤٢")
        draft.setAgeEnabled(true)
        draft.setAgeDaysText("٣١")
        draft.setStorageEnabled(true)
        draft.setStorageMiBText("١٬٠٢٤")
        draft.setRevisionCountEnabled(true)
        draft.setRevisionCountText("٣")
        draft.setRevisionBytesEnabled(true)
        draft.setRevisionMiBText("٦٥")

        #expect(draft.countSubmission()?.maximumUnpinnedItems == 42)
        let arabic = try #require(draft.submission())
        #expect(arabic.policies.age?.maxAge == 2_678_400)
        #expect(arabic.policies.storage?.maxTotalBytes == 1_073_741_824)
        #expect(arabic.policies.revisions?.maxRevisionsPerItem == 3)
        #expect(arabic.policies.revisions?.maxRevisionBytesPerItem == 68_157_440)

        // ASCII remains accepted even when the display uses another digit set.
        draft.setMaximumUnpinnedText("00042")
        draft.setAgeDaysText("31")
        draft.setStorageMiBText("1024")
        draft.setRevisionCountText("3")
        draft.setRevisionMiBText("65")
        #expect(draft.countSubmission()?.maximumUnpinnedItems == 42)
        #expect(try #require(draft.submission()).policies == arabic.policies)
    }

    @Test("each enabled control rejects Arabic fractions, wrong grouping and overflow",
          arguments: ["١٫٥", "١٬٥", "٥٬٠٠", "٩٢٢٣٣٧٢٠٣٦٨٥٤٧٧٥٨٠٨"])
    func invalidArabicControlInputs(_ text: String) {
        let locale = Locale(identifier: "ar_EG")
        // The full machine range distinguishes overflow rejection from a
        // merely out-of-policy result such as a silently saturated Int.max.
        #expect(validatedSettingsWholeNumber(text, in: Int.min...Int.max, locale: locale) == nil)

        var draft = RetentionSettingsDraft(locale: locale)
        draft.setMaximumUnpinnedText(text)
        #expect(draft.countSubmission() == nil)
        #expect(draft.submission() != nil)

        draft.setAgeEnabled(true)
        draft.setAgeDaysText(text)
        #expect(!draft.ageInputIsValid)
        #expect(draft.submission() == nil)
        draft.setAgeEnabled(false)
        #expect(draft.submission() != nil)

        draft.setStorageEnabled(true)
        draft.setStorageMiBText(text)
        #expect(!draft.storageInputIsValid)
        #expect(draft.submission() == nil)
        draft.setStorageEnabled(false)
        #expect(draft.submission() != nil)

        draft.setRevisionCountEnabled(true)
        draft.setRevisionCountText(text)
        #expect(!draft.revisionCountInputIsValid)
        #expect(draft.submission() == nil)
        draft.setRevisionCountEnabled(false)
        #expect(draft.submission() != nil)

        draft.setRevisionBytesEnabled(true)
        draft.setRevisionMiBText(text)
        #expect(!draft.revisionBytesInputIsValid)
        #expect(draft.submission() == nil)
        draft.setRevisionBytesEnabled(false)
        #expect(draft.submission() != nil)
    }

    @Test("ordinary Chinese locale accepts its displayed digits without assuming width folding")
    func chineseDigitContract() {
        let locale = Locale(identifier: "zh_Hans_CN")
        #expect(LocalizedCountPresentation.number(123, locale: locale) == "123")
        #expect(validatedSettingsWholeNumber("123", in: 1...5_000, locale: locale) == 123)
        // Fullwidth digits are not the numbering system of this locale.
        // The field accepts its actual integer format, not arbitrary width
        // normalization that might also alter decimal/grouping punctuation.
        for text in ["１２３", "１．５", "１，５", "９２２３３７２０３６８５４７７５８０８"] {
            #expect(validatedSettingsWholeNumber(text, in: 1...5_000, locale: locale) == nil)
        }
    }

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
