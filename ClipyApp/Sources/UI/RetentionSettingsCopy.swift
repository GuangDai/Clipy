/// User-facing copy for unified Retention Settings (V2-07 §5.2/§10).
/// Native .strings/.stringsdict resources give SwiftPM and Xcode the same
/// translations and plural rules without a separate catalog compilation step.
import Foundation
import HistoryCore

/// The Retention surface's localized copy.
internal enum RetentionSettingsCopy {

    internal static let tableName = "RetentionSettings"
    internal static var bundle: Bundle { AppLocalization.bundle }

    // MARK: Tab and Items section

    internal static var tabTitle: String { plain(
        "settings.retention.tab-title",
        "Retention"
    ) }
    internal static var itemsSection: String { plain(
        "settings.retention.items.section",
        "Items"
    ) }
    internal static var countToggle: String { plain(
        "settings.retention.items.toggle",
        "Limit unpinned item count"
    ) }
    internal static var countInputHint: String { plain(
        "settings.retention.items.input-hint",
        "Enter a positive whole number."
    ) }
    internal static var countEnforcementNote: String { plain(
        "settings.retention.items.enforcement-note",
        "Turn off to keep unpinned items without a count limit. Age, storage and revision limits "
            + "still apply when enabled. Pinned items are not removed by the count limit."
    ) }
    internal static var itemsKeepAtMost: String { plain(
        "settings.retention.items.keep-at-most",
        "Keep at most"
    ) }
    internal static var maximumUnpinnedAccessibilityLabel: String { plain(
        "settings.retention.items.field-accessibility-label",
        "Maximum unpinned items"
    ) }
    internal static var unpinnedItemsUnit: String { plain(
        "settings.retention.items.unit",
        "unpinned items"
    ) }
    internal static var applyItemLimit: String { plain(
        "settings.retention.items.apply",
        "Apply Item Limit"
    ) }
    internal static var confirmItemLimitTitle: String { plain(
        "settings.retention.items.confirm-title",
        "Apply a stricter item limit?"
    ) }
    internal static var confirmItemLimitApply: String { plain(
        "settings.retention.items.confirm-apply",
        "Apply Stricter Limit"
    ) }
    internal static var confirmItemLimitMessage: String { plain(
        "settings.retention.items.confirm-message",
        "A stricter limit can immediately remove unpinned items, and they can't be recovered."
    ) }

    // MARK: Item age section

    internal static var ageSection: String { plain(
        "settings.retention.age.section",
        "Item age"
    ) }
    internal static var ageToggle: String { plain(
        "settings.retention.age.toggle",
        "Limit item age"
    ) }
    internal static var ageToggleHint: String { plain(
        "settings.retention.age.toggle-hint",
        "Retire items whose last copy is older than the entered age."
    ) }
    internal static var ageFieldLabel: String { plain(
        "settings.retention.age.field-label",
        "Maximum item age"
    ) }
    internal static var ageUnit: String { plain(
        "settings.retention.age.unit",
        "days"
    ) }

    /// R1 runs on capture and `.setRetentionPolicies`; it has no
    /// wall-clock worker or background reaper (`V2-02` §2.2/§7; review
    /// Card 10B). The copy must not imply a time-driven sweep.
    internal static var ageEnforcementNote: String { plain(
        "settings.retention.age.enforcement-note",
        "Age limits are checked when Clipy captures a clipboard change or "
            + "you apply retention settings. Time passing alone doesn't remove items."
    ) }

    // MARK: Storage section

    internal static var storageSection: String { plain(
        "settings.retention.storage.section",
        "Storage"
    ) }
    internal static var storageToggle: String { plain(
        "settings.retention.storage.toggle",
        "Limit storage budget"
    ) }
    internal static var storageToggleHint: String { plain(
        "settings.retention.storage.toggle-hint",
        "Retire the oldest unpinned items until history fits the budget."
    ) }
    internal static var storageFieldLabel: String { plain(
        "settings.retention.storage.field-label",
        "Storage budget"
    ) }

    // MARK: Revision limits section

    internal static var revisionsSection: String { plain(
        "settings.retention.revisions.section",
        "Revision limits"
    ) }
    internal static var revisionCountKeepAtMost: String { plain(
        "settings.retention.revisions.keep-at-most",
        "Keep at most"
    ) }
    internal static var revisionCountToggleHint: String { plain(
        "settings.retention.revisions.count-toggle-hint",
        "Prune the oldest inactive revisions beyond this count."
    ) }
    internal static var revisionCountFieldLabel: String { plain(
        "settings.retention.revisions.count-field-label",
        "Revisions per item"
    ) }
    internal static var revisionCountUnit: String { plain(
        "settings.retention.revisions.count-unit",
        "revisions"
    ) }
    internal static var revisionBytesToggle: String { plain(
        "settings.retention.revisions.bytes-toggle",
        "Limit revision storage"
    ) }
    internal static var revisionBytesToggleHint: String { plain(
        "settings.retention.revisions.bytes-toggle-hint",
        "Prune the oldest inactive revisions until they fit this budget."
    ) }
    internal static var revisionBytesFieldLabel: String { plain(
        "settings.retention.revisions.bytes-field-label",
        "Revision storage per item"
    ) }

    // MARK: Policy Apply and destructive confirmation

    internal static var applyPolicies: String { plain(
        "settings.retention.apply",
        "Apply"
    ) }
    internal static var confirmPoliciesTitle: String { plain(
        "settings.retention.confirm-title",
        "Apply stricter retention limits?"
    ) }
    internal static var confirmPoliciesApply: String { plain(
        "settings.retention.confirm-apply",
        "Apply Stricter Limits"
    ) }
    internal static var confirmPoliciesMessage: String { plain(
        "settings.retention.confirm-message",
        "Stricter limits can permanently remove items or revisions."
    ) }
    internal static var confirmCancel: String { plain(
        "settings.retention.confirm-cancel",
        "Cancel"
    ) }
    internal static var applyNote: String { plain(
        "settings.retention.apply-note",
        "Changes apply to new and existing items at once."
    ) }

    // MARK: Range hint and failures

    internal static var noLimit: String { plain("settings.retention.no-limit", "No limit") }
    internal static var applying: String { plain("settings.retention.applying", "Applying limits…") }
    internal static var cancelling: String { plain("settings.retention.cancelling", "Cancelling…") }
    internal static var countApplyCancelled: String { plain(
        "settings.retention.count-cancelled",
        "Cancelled. The item limit was not changed and no items were removed by this apply."
    ) }
    internal static var policyApplyCancelled: String { plain(
        "settings.retention.policies-cancelled",
        "Cancelled. These cleanup limits were not changed and no items or revisions were removed by this apply."
    ) }
    internal static var historyChanged: String { plain(
        "settings.retention.history-changed",
        "History changed while preparing cleanup. Nothing was applied. Try applying again."
    ) }

    internal static func countFailureMessage(for failure: HistoryFailure) -> String {
        if case .snapshotExpired = failure { return historyChanged }
        return FailurePresentation.message(for: failure)
    }

    /// V2-07 §10.3: ranges use the same locale-aware digits and grouping
    /// as counts in receipt feedback.
    internal static func rangeHint(
        from lowerBound: Int,
        to upperBound: Int,
        bundle: Bundle = AppLocalization.bundle,
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

    internal static var readFailure: String { plain(
        "settings.retention.read-failure",
        "The current retention settings could not be read."
    ) }
    internal static var countSaveFailure: String { plain(
        "settings.retention.count-save-failure",
        "The setting could not be saved."
    ) }
    internal static var policiesSaveFailure: String { plain(
        "settings.retention.policies-save-failure",
        "The policies could not be saved."
    ) }

    /// Retention-specific recovery guidance (V2-07 §5.2): the set-time
    /// pinned-over-budget rejection and the unsatisfiable R2 budget carry
    /// their own text.
    internal static var pinnedOverBudget: String { plain(
        "settings.retention.pinned-over-budget",
        "Pinned items exceed this budget. Unpin items or raise the budget."
    ) }
    internal static var budgetUnsatisfiable: String { plain(
        "settings.retention.budget-unsatisfiable",
        "This budget can't be satisfied with the current history."
    ) }
    internal static var activeRevisionOverBudget: String { plain(
        "settings.retention.active-revision-over-budget",
        "An active revision exceeds this limit. Increase the revision storage limit."
    ) }
    internal static var combinedBudgetUnsatisfiable: String { plain(
        "settings.retention.combined-budget-unsatisfiable",
        "Pinned items may exceed the storage budget, or an active revision may exceed its limit. "
            + "Raise the limits, or unpin items to reduce protected storage."
    ) }

    /// V2-02 §8.3 gives pinned R2 bytes and irreducible active R3 bytes the
    /// same failure. A validated Settings draft's dimensions can rule out a cause, but when
    /// both limits are enabled the UI must not pretend to know which failed.
    internal static func failureMessage(
        for failure: HistoryFailure,
        policies: HistoryRetentionPolicies
    ) -> String {
        switch failure {
        case .snapshotExpired:
            return historyChanged
        case .invalidInput(.invalidRetentionPolicy):
            switch (policies.storage != nil, policies.revisions?.maxRevisionBytesPerItem != nil) {
            case (true, true): return combinedBudgetUnsatisfiable
            case (true, false): return pinnedOverBudget
            case (false, true): return activeRevisionOverBudget
            case (false, false): return FailurePresentation.message(for: failure)
            }
        case .capacityExceeded(.storageBytes):
            return budgetUnsatisfiable
        default:
            return FailurePresentation.message(for: failure)
        }
    }

    // MARK: Receipt feedback (03a §6; V2-02 §12; deep review Card 10)

    internal static var feedbackDone: String { plain(
        "settings.retention.feedback.done",
        "Done."
    ) }
    internal static var feedbackNothingToClear: String { plain(
        "settings.retention.feedback.nothing-to-clear",
        "Nothing to clear."
    ) }
    internal static var feedbackNoChange: String { plain(
        "settings.retention.feedback.no-change",
        "No change."
    ) }
    internal static var clearFailure: String { plain(
        "settings.retention.feedback.clear-failure",
        "The history could not be cleared."
    ) }

    /// Translators own the summary order and punctuation (V2-02 §12).
    internal static func appliedSummary(
        retiredPhrase: String,
        prunedPhrase: String,
        bundle: Bundle = AppLocalization.bundle,
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
        bundle: Bundle = AppLocalization.bundle,
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
        bundle: Bundle = AppLocalization.bundle,
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
        bundle: Bundle = AppLocalization.bundle,
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
        bundle: Bundle = AppLocalization.bundle,
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
        bundle: Bundle = AppLocalization.bundle
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
