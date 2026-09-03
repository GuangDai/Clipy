/// RetentionSettingsCopyTests.swift — the Retention Settings copy contract
/// (V2-07 §10). Two halves:
///
/// 1. Resolution: every key the surface resolves must render its pinned
///    English, never the raw key (the fallback-to-key regression). In this
///    native `swift test` lane the package resource bundle carries only the
///    verbatim-copied catalog JSON (SwiftPM's native build never invokes
///    xcstringstool — see RetentionSettingsCopy.swift's header), so the
///    resolved values come from each lookup's embedded `value:` default;
///    the xcodebuild lanes resolve the compiled `RetentionSettings.strings`
///    table instead. Both lanes must render identical English.
/// 2. Catalog parity: because the catalog is present verbatim in the
///    native-lane bundle, the test parses it and requires an `en` entry
///    matching every pinned string — the catalog and the embedded defaults
///    must move together until the native build compiles catalogs.
import Foundation
import Testing
@testable import PresentationUI

@Suite("Retention settings copy")
struct RetentionSettingsCopyTests {

    /// (catalog key, pinned English, resolved value) for every plain
    /// property the Retention surface renders.
    private static let plainExpectations:
        [(key: String, english: String, resolved: String)] = [
            (
                "settings.retention.tab-title",
                "Retention",
                RetentionSettingsCopy.tabTitle
            ),
            (
                "settings.retention.items.section",
                "Items",
                RetentionSettingsCopy.itemsSection
            ),
            (
                "settings.retention.items.keep-at-most",
                "Keep at most",
                RetentionSettingsCopy.itemsKeepAtMost
            ),
            (
                "settings.retention.items.field-accessibility-label",
                "Maximum unpinned items",
                RetentionSettingsCopy.maximumUnpinnedAccessibilityLabel
            ),
            (
                "settings.retention.items.unit",
                "unpinned items",
                RetentionSettingsCopy.unpinnedItemsUnit
            ),
            (
                "settings.retention.items.apply",
                "Apply Item Limit",
                RetentionSettingsCopy.applyItemLimit
            ),
            (
                "settings.retention.items.confirm-title",
                "Apply a stricter item limit?",
                RetentionSettingsCopy.confirmItemLimitTitle
            ),
            (
                "settings.retention.items.confirm-apply",
                "Apply Stricter Limit",
                RetentionSettingsCopy.confirmItemLimitApply
            ),
            (
                "settings.retention.items.confirm-message",
                "A stricter limit can immediately remove unpinned items, and they can't be recovered.",
                RetentionSettingsCopy.confirmItemLimitMessage
            ),
            (
                "settings.retention.age.section",
                "Item age",
                RetentionSettingsCopy.ageSection
            ),
            (
                "settings.retention.age.toggle",
                "Limit item age",
                RetentionSettingsCopy.ageToggle
            ),
            (
                "settings.retention.age.toggle-hint",
                "Retire items whose last copy is older than the entered age.",
                RetentionSettingsCopy.ageToggleHint
            ),
            (
                "settings.retention.age.field-label",
                "Maximum item age",
                RetentionSettingsCopy.ageFieldLabel
            ),
            (
                "settings.retention.age.unit",
                "days",
                RetentionSettingsCopy.ageUnit
            ),
            (
                "settings.retention.age.enforcement-note",
                "Age limits are checked when Clipy captures a clipboard change or "
                    + "you apply retention settings. Time passing alone doesn't remove items.",
                RetentionSettingsCopy.ageEnforcementNote
            ),
            (
                "settings.retention.storage.section",
                "Storage",
                RetentionSettingsCopy.storageSection
            ),
            (
                "settings.retention.storage.toggle",
                "Limit storage budget",
                RetentionSettingsCopy.storageToggle
            ),
            (
                "settings.retention.storage.toggle-hint",
                "Retire the oldest unpinned items until history fits the budget.",
                RetentionSettingsCopy.storageToggleHint
            ),
            (
                "settings.retention.storage.field-label",
                "Storage budget",
                RetentionSettingsCopy.storageFieldLabel
            ),
            (
                "settings.retention.revisions.section",
                "Revision limits",
                RetentionSettingsCopy.revisionsSection
            ),
            (
                "settings.retention.revisions.keep-at-most",
                "Keep at most",
                RetentionSettingsCopy.revisionCountKeepAtMost
            ),
            (
                "settings.retention.revisions.count-toggle-hint",
                "Prune the oldest inactive revisions beyond this count.",
                RetentionSettingsCopy.revisionCountToggleHint
            ),
            (
                "settings.retention.revisions.count-field-label",
                "Revisions per item",
                RetentionSettingsCopy.revisionCountFieldLabel
            ),
            (
                "settings.retention.revisions.count-unit",
                "revisions",
                RetentionSettingsCopy.revisionCountUnit
            ),
            (
                "settings.retention.revisions.bytes-toggle",
                "Limit revision storage",
                RetentionSettingsCopy.revisionBytesToggle
            ),
            (
                "settings.retention.revisions.bytes-toggle-hint",
                "Prune the oldest inactive revisions until they fit this budget.",
                RetentionSettingsCopy.revisionBytesToggleHint
            ),
            (
                "settings.retention.revisions.bytes-field-label",
                "Revision storage per item",
                RetentionSettingsCopy.revisionBytesFieldLabel
            ),
            (
                "settings.retention.apply",
                "Apply",
                RetentionSettingsCopy.applyPolicies
            ),
            (
                "settings.retention.confirm-title",
                "Apply stricter retention limits?",
                RetentionSettingsCopy.confirmPoliciesTitle
            ),
            (
                "settings.retention.confirm-apply",
                "Apply Stricter Limits",
                RetentionSettingsCopy.confirmPoliciesApply
            ),
            (
                "settings.retention.confirm-message",
                "Stricter limits can permanently remove items or revisions.",
                RetentionSettingsCopy.confirmPoliciesMessage
            ),
            (
                "settings.retention.confirm-cancel",
                "Cancel",
                RetentionSettingsCopy.confirmCancel
            ),
            (
                "settings.retention.apply-note",
                "Changes apply to new and existing items at once.",
                RetentionSettingsCopy.applyNote
            ),
            (
                "settings.retention.read-failure",
                "The current retention settings could not be read.",
                RetentionSettingsCopy.readFailure
            ),
            (
                "settings.retention.count-save-failure",
                "The setting could not be saved.",
                RetentionSettingsCopy.countSaveFailure
            ),
            (
                "settings.retention.policies-save-failure",
                "The policies could not be saved.",
                RetentionSettingsCopy.policiesSaveFailure
            ),
            (
                "settings.retention.pinned-over-budget",
                "Pinned items exceed this budget. Unpin items or raise the budget.",
                RetentionSettingsCopy.pinnedOverBudget
            ),
            (
                "settings.retention.budget-unsatisfiable",
                "This budget can't be satisfied with the current history.",
                RetentionSettingsCopy.budgetUnsatisfiable
            ),
            (
                "settings.retention.feedback.done",
                "Done.",
                RetentionSettingsCopy.feedbackDone
            ),
            (
                "settings.retention.feedback.nothing-to-clear",
                "Nothing to clear.",
                RetentionSettingsCopy.feedbackNothingToClear
            ),
            (
                "settings.retention.feedback.no-change",
                "No change.",
                RetentionSettingsCopy.feedbackNoChange
            ),
            (
                "settings.retention.feedback.clear-failure",
                "The history could not be cleared.",
                RetentionSettingsCopy.clearFailure
            ),
        ]

    /// Format patterns keep their substitutions in the key (the catalog
    /// shape for substituted strings); the English value positions them.
    private static let formatExpectations: [(key: String, english: String)] = [
        (
            "Enter a whole number from %lld to %lld.",
            "Enter a whole number from %1$lld to %2$lld."
        ),
        (
            "Done. %@, %@.",
            "Done. %1$@, %2$@."
        ),
    ]

    /// Plural receipt phrases keep English-pattern keys (the `%lld results`
    /// idiom from PR #50) because String Catalog plural variations bind to
    /// a `%lld` substitution in the key (V2-07 §10.4).
    private static let pluralExpectations:
        [(key: String, one: String, other: String)] = [
            (
                "Removed %lld items.",
                one: "Removed %lld item.",
                other: "Removed %lld items."
            ),
            (
                "Done. %lld items removed.",
                one: "Done. %lld item removed.",
                other: "Done. %lld items removed."
            ),
            (
                "%lld items retired",
                one: "%lld item retired",
                other: "%lld items retired"
            ),
            (
                "%lld revisions pruned",
                one: "%lld revision pruned",
                other: "%lld revisions pruned"
            ),
        ]

    @Test("every retention key resolves to its pinned English, never the raw key")
    func plainKeysResolveToPinnedEnglish() {
        for expectation in Self.plainExpectations {
            #expect(
                expectation.resolved == expectation.english,
                "\(expectation.key) must resolve to its pinned English"
            )
            #expect(
                expectation.resolved != expectation.key,
                "\(expectation.key) fell back to the raw key"
            )
        }
    }

    @Test("plural receipt helpers render the one and other forms exactly")
    func pluralHelpersRenderExactEnglish() {
        #expect(RetentionSettingsCopy.clearedItemsRemoved(1) == "Removed 1 item.")
        #expect(RetentionSettingsCopy.clearedItemsRemoved(3) == "Removed 3 items.")
        #expect(
            RetentionSettingsCopy.countLimitItemsRemoved(1)
                == "Done. 1 item removed."
        )
        #expect(
            RetentionSettingsCopy.countLimitItemsRemoved(2)
                == "Done. 2 items removed."
        )
        #expect(RetentionSettingsCopy.itemsRetired(1) == "1 item retired")
        #expect(RetentionSettingsCopy.itemsRetired(0) == "0 items retired")
        #expect(RetentionSettingsCopy.revisionsPruned(1) == "1 revision pruned")
        #expect(RetentionSettingsCopy.revisionsPruned(0) == "0 revisions pruned")
    }

    @Test("format helpers interpolate their arguments")
    func formatHelpersInterpolate() {
        #expect(
            RetentionSettingsCopy.rangeHint(from: 1, to: 5_000)
                == "Enter a whole number from 1 to 5000."
        )
        #expect(
            RetentionSettingsCopy.appliedSummary(
                retiredPhrase: "1 item retired",
                prunedPhrase: "2 revisions pruned"
            ) == "Done. 1 item retired, 2 revisions pruned."
        )
    }

    @Test("the String Catalog carries an en entry matching every pinned string")
    func catalogCarriesEveryKeyWithMatchingEnglish() throws {
        let strings = try Self.catalogStrings()
        let expectedKeys = Set(
            Self.plainExpectations.map { $0.key }
                + Self.formatExpectations.map { $0.key }
                + Self.pluralExpectations.map { $0.key }
        )
        #expect(Set(strings.keys) == expectedKeys)
        for expectation in Self.plainExpectations {
            #expect(
                Self.plainValue(strings, key: expectation.key)
                    == expectation.english,
                "catalog entry \(expectation.key) must match the pinned English"
            )
        }
        for expectation in Self.formatExpectations {
            #expect(
                Self.plainValue(strings, key: expectation.key)
                    == expectation.english,
                "catalog entry \(expectation.key) must match the pinned format"
            )
        }
        for expectation in Self.pluralExpectations {
            #expect(
                Self.pluralValue(strings, key: expectation.key, category: "one")
                    == expectation.one,
                "catalog entry \(expectation.key) needs its one form"
            )
            #expect(
                Self.pluralValue(strings, key: expectation.key, category: "other")
                    == expectation.other,
                "catalog entry \(expectation.key) needs its other form"
            )
        }
    }

    // MARK: Catalog decoding

    /// Reads the verbatim-copied catalog out of the package resource bundle
    /// (present in the native lane precisely because that lane cannot
    /// compile it). Test targets own no `Bundle.module`, so the bundle
    /// comes from the copy namespace.
    private static func catalogStrings() throws -> [String: Any] {
        let url = try #require(
            RetentionSettingsCopy.bundle.url(
                forResource: "RetentionSettings",
                withExtension: "xcstrings"
            ),
            "RetentionSettings.xcstrings must be in the package resource bundle"
        )
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try #require(object as? [String: Any])
        #expect(root["sourceLanguage"] as? String == "en")
        return try #require(root["strings"] as? [String: Any])
    }

    private static func plainValue(
        _ strings: [String: Any],
        key: String
    ) -> String? {
        let entry = strings[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]
        let english = localizations?["en"] as? [String: Any]
        let unit = english?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    private static func pluralValue(
        _ strings: [String: Any],
        key: String,
        category: String
    ) -> String? {
        let entry = strings[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]
        let english = localizations?["en"] as? [String: Any]
        let variations = english?["variations"] as? [String: Any]
        let plural = variations?["plural"] as? [String: Any]
        let variant = plural?[category] as? [String: Any]
        let unit = variant?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }
}
