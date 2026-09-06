/// User-facing copy for unified Retention Settings (V2-07 §5.2/§10).
/// Native .strings/.stringsdict resources give SwiftPM and Xcode the same
/// translations and plural rules without a separate catalog compilation step.
import Foundation

/// The Retention surface's localized copy.
internal enum RetentionSettingsCopy {

    internal static let tableName = "RetentionSettings"
    internal static var bundle: Bundle { .module }

    // MARK: Tab and Items section

    internal static let tabTitle = plain(
        "settings.retention.tab-title",
        "Retention"
    )
    internal static let itemsSection = plain(
        "settings.retention.items.section",
        "Items"
    )
    internal static let itemsKeepAtMost = plain(
        "settings.retention.items.keep-at-most",
        "Keep at most"
    )
    internal static let maximumUnpinnedAccessibilityLabel = plain(
        "settings.retention.items.field-accessibility-label",
        "Maximum unpinned items"
    )
    internal static let unpinnedItemsUnit = plain(
        "settings.retention.items.unit",
        "unpinned items"
    )
    internal static let applyItemLimit = plain(
        "settings.retention.items.apply",
        "Apply Item Limit"
    )
    internal static let confirmItemLimitTitle = plain(
        "settings.retention.items.confirm-title",
        "Apply a stricter item limit?"
    )
    internal static let confirmItemLimitApply = plain(
        "settings.retention.items.confirm-apply",
        "Apply Stricter Limit"
    )
    internal static let confirmItemLimitMessage = plain(
        "settings.retention.items.confirm-message",
        "A stricter limit can immediately remove unpinned items, and they can't be recovered."
    )

    // MARK: Item age section

    internal static let ageSection = plain(
        "settings.retention.age.section",
        "Item age"
    )
    internal static let ageToggle = plain(
        "settings.retention.age.toggle",
        "Limit item age"
    )
    internal static let ageToggleHint = plain(
        "settings.retention.age.toggle-hint",
        "Retire items whose last copy is older than the entered age."
    )
    internal static let ageFieldLabel = plain(
        "settings.retention.age.field-label",
        "Maximum item age"
    )
    internal static let ageUnit = plain(
        "settings.retention.age.unit",
        "days"
    )

    /// R1 runs on capture and `.setRetentionPolicies`; it has no
    /// wall-clock worker or background reaper (`V2-02` §2.2/§7; review
    /// Card 10B). The copy must not imply a time-driven sweep.
    internal static let ageEnforcementNote = plain(
        "settings.retention.age.enforcement-note",
        "Age limits are checked when Clipy captures a clipboard change or "
            + "you apply retention settings. Time passing alone doesn't remove items."
    )

    // MARK: Storage section

    internal static let storageSection = plain(
        "settings.retention.storage.section",
        "Storage"
    )
    internal static let storageToggle = plain(
        "settings.retention.storage.toggle",
        "Limit storage budget"
    )
    internal static let storageToggleHint = plain(
        "settings.retention.storage.toggle-hint",
        "Retire the oldest unpinned items until history fits the budget."
    )
    internal static let storageFieldLabel = plain(
        "settings.retention.storage.field-label",
        "Storage budget"
    )

    // MARK: Revision limits section

    internal static let revisionsSection = plain(
        "settings.retention.revisions.section",
        "Revision limits"
    )
    internal static let revisionCountKeepAtMost = plain(
        "settings.retention.revisions.keep-at-most",
        "Keep at most"
    )
    internal static let revisionCountToggleHint = plain(
        "settings.retention.revisions.count-toggle-hint",
        "Prune the oldest inactive revisions beyond this count."
    )
    internal static let revisionCountFieldLabel = plain(
        "settings.retention.revisions.count-field-label",
        "Revisions per item"
    )
    internal static let revisionCountUnit = plain(
        "settings.retention.revisions.count-unit",
        "revisions"
    )
    internal static let revisionBytesToggle = plain(
        "settings.retention.revisions.bytes-toggle",
        "Limit revision storage"
    )
    internal static let revisionBytesToggleHint = plain(
        "settings.retention.revisions.bytes-toggle-hint",
        "Prune the oldest inactive revisions until they fit this budget."
    )
    internal static let revisionBytesFieldLabel = plain(
        "settings.retention.revisions.bytes-field-label",
        "Revision storage per item"
    )

    // MARK: Policy Apply and destructive confirmation

    internal static let applyPolicies = plain(
        "settings.retention.apply",
        "Apply"
    )
    internal static let confirmPoliciesTitle = plain(
        "settings.retention.confirm-title",
        "Apply stricter retention limits?"
    )
    internal static let confirmPoliciesApply = plain(
        "settings.retention.confirm-apply",
        "Apply Stricter Limits"
    )
    internal static let confirmPoliciesMessage = plain(
        "settings.retention.confirm-message",
        "Stricter limits can permanently remove items or revisions."
    )
    internal static let confirmCancel = plain(
        "settings.retention.confirm-cancel",
        "Cancel"
    )
    internal static let applyNote = plain(
        "settings.retention.apply-note",
        "Changes apply to new and existing items at once."
    )

    // MARK: Range hint and failures

    /// V2-07 §10.3: ranges use the same locale-aware digits and grouping
    /// as counts in receipt feedback.
    internal static func rangeHint(
        from lowerBound: Int,
        to upperBound: Int,
        bundle: Bundle = .module,
        locale: Locale = .current
    ) -> String {
        formatted(
            "settings.retention.range-hint",
            "Enter a whole number from %1$@ to %2$@.",
            bundle: bundle,
            locale: locale,
            LocalizedCountPresentation.number(lowerBound, locale: locale),
            LocalizedCountPresentation.number(upperBound, locale: locale)
        )
    }

    internal static let readFailure = plain(
        "settings.retention.read-failure",
        "The current retention settings could not be read."
    )
    internal static let countSaveFailure = plain(
        "settings.retention.count-save-failure",
        "The setting could not be saved."
    )
    internal static let policiesSaveFailure = plain(
        "settings.retention.policies-save-failure",
        "The policies could not be saved."
    )

    /// Retention-specific recovery guidance (V2-07 §5.2): the set-time
    /// pinned-over-budget rejection and the unsatisfiable R2 budget carry
    /// their own text.
    internal static let pinnedOverBudget = plain(
        "settings.retention.pinned-over-budget",
        "Pinned items exceed this budget. Unpin items or raise the budget."
    )
    internal static let budgetUnsatisfiable = plain(
        "settings.retention.budget-unsatisfiable",
        "This budget can't be satisfied with the current history."
    )

    // MARK: Receipt feedback (03a §6; V2-02 §12; deep review Card 10)

    internal static let feedbackDone = plain(
        "settings.retention.feedback.done",
        "Done."
    )
    internal static let feedbackNothingToClear = plain(
        "settings.retention.feedback.nothing-to-clear",
        "Nothing to clear."
    )
    internal static let feedbackNoChange = plain(
        "settings.retention.feedback.no-change",
        "No change."
    )
    internal static let clearFailure = plain(
        "settings.retention.feedback.clear-failure",
        "The history could not be cleared."
    )

    /// Translators own the summary order and punctuation (V2-02 §12).
    internal static func appliedSummary(
        retiredPhrase: String,
        prunedPhrase: String,
        bundle: Bundle = .module,
        locale: Locale = .current
    ) -> String {
        formatted(
            "Done. %@, %@.",
            "Done. %1$@, %2$@.",
            bundle: bundle,
            locale: locale,
            retiredPhrase,
            prunedPhrase
        )
    }

    internal static func clearedItemsRemoved(
        _ removed: Int,
        bundle: Bundle = .module,
        locale: Locale = .current
    ) -> String {
        plural(
            "Removed %lld items.",
            one: "Removed %2$@ item.",
            other: "Removed %2$@ items.",
            count: removed,
            bundle: bundle,
            locale: locale
        )
    }

    internal static func countLimitItemsRemoved(
        _ removed: Int,
        bundle: Bundle = .module,
        locale: Locale = .current
    ) -> String {
        plural(
            "Done. %lld items removed.",
            one: "Done. %2$@ item removed.",
            other: "Done. %2$@ items removed.",
            count: removed,
            bundle: bundle,
            locale: locale
        )
    }

    internal static func itemsRetired(
        _ retired: Int,
        bundle: Bundle = .module,
        locale: Locale = .current
    ) -> String {
        plural(
            "%lld items retired",
            one: "%2$@ item retired",
            other: "%2$@ items retired",
            count: retired,
            bundle: bundle,
            locale: locale
        )
    }

    internal static func revisionsPruned(
        _ pruned: Int,
        bundle: Bundle = .module,
        locale: Locale = .current
    ) -> String {
        plural(
            "%lld revisions pruned",
            one: "%2$@ revision pruned",
            other: "%2$@ revisions pruned",
            count: pruned,
            bundle: bundle,
            locale: locale
        )
    }

    // MARK: Resource lookup

    internal static func plain(
        _ key: String,
        _ englishDefault: String,
        bundle: Bundle = .module
    ) -> String {
        bundle.localizedString(
            forKey: key,
            value: englishDefault,
            table: tableName
        )
    }

    private static func formatted(
        _ key: String,
        _ englishDefault: String,
        bundle: Bundle,
        locale: Locale,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: plain(key, englishDefault, bundle: bundle),
            locale: locale,
            arguments: arguments
        )
    }

    /// The numeric first argument selects the language's plural rule;
    /// the second carries FormatStyle's localized grouping and digits.
    private static func plural(
        _ key: String,
        one englishOne: String,
        other englishOther: String,
        count: Int,
        bundle: Bundle,
        locale: Locale
    ) -> String {
        formatted(
            key,
            count == 1 ? englishOne : englishOther,
            bundle: bundle,
            locale: locale,
            count,
            LocalizedCountPresentation.number(count, locale: locale)
        )
    }
}
