/// RetentionSettingsCopy.swift — every user-facing string of the unified
/// Retention Settings surface (V2-07 §5.2/§6.3), resolved through the
/// package String Catalog `Resources/RetentionSettings.xcstrings` (source
/// language English; V2-07 §10 UI localization, §10.4 plural-aware
/// receipt feedback).
///
/// Build-lane boundary: xcodebuild (the ClipyApp lanes) compiles the
/// catalog into the package resource bundle via xcstringstool, but
/// SwiftPM's native build system copies `.xcstrings` verbatim — its
/// resource manifest builder issues copy commands only — so `swift test`
/// bundles carry the raw catalog JSON and no compiled
/// `RetentionSettings.strings` table. Every lookup therefore passes the
/// English copy as the `value:` default: the native lane renders the
/// embedded English while the app lane resolves the compiled catalog
/// entry. `RetentionSettingsCopyTests` pins both halves: resolved copy
/// equals the pinned English and never the raw key, and the raw catalog
/// (present verbatim in the native-lane bundle) carries an `en` entry for
/// every key.
///
/// Coexistence boundary: the pre-existing search result-count keys stay
/// in `en.lproj/Localizable.strings[dict]` — already compiled-format
/// tables the native build serves directly (PR #50). Moving them into a
/// `Localizable.xcstrings` would break `resultCountText` under
/// `swift test`, and a catalog's compiled output collides with a
/// same-named legacy table at one bundle path under xcodebuild.
import Foundation

/// The Retention surface's copy keys (V2-07 §10). Internal (not private)
/// so the SwiftPM suites pin resolution and catalog parity directly
/// through `@testable`, like `clearStatusFeedback`.
internal enum RetentionSettingsCopy {

    /// The catalog compiles to `RetentionSettings.strings[dict]`; a
    /// surface-specific table name keeps the compiled output clear of the
    /// legacy `Localizable` tables in the same resource bundle.
    internal static let tableName = "RetentionSettings"

    /// The package resource bundle the copy resolves from — internal so
    /// the catalog-parity test can read the verbatim-copied catalog in
    /// the native lane (test targets carry no `Bundle.module` of their
    /// own).
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

    /// The invalid-input caption shared by every Retention value field
    /// (admission ranges: `V2-02` §8.3; count range: 06 §2). The key
    /// carries the two `%lld` substitutions — String Catalog format
    /// entries keep their substitutions in the key; the English value
    /// positions them.
    internal static func rangeHint(from lowerBound: Int, to upperBound: Int) -> String {
        formatted(
            "Enter a whole number from %lld to %lld.",
            "Enter a whole number from %1$lld to %2$lld.",
            lowerBound,
            upperBound
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

    /// The applied-policies summary joins the two plural phrases as one
    /// sentence (`V2-02` §12 transparent data-minimization feedback). Same
    /// catalog shape as `rangeHint`: substitutions live in the key.
    internal static func appliedSummary(
        retiredPhrase: String,
        prunedPhrase: String
    ) -> String {
        formatted(
            "Done. %@, %@.",
            "Done. %1$@, %2$@.",
            retiredPhrase,
            prunedPhrase
        )
    }

    /// "Removed N items." for one Danger Zone clear (03a §6).
    internal static func clearedItemsRemoved(_ removed: Int) -> String {
        plural(
            "Removed %lld items.",
            one: "Removed %lld item.",
            other: "Removed %lld items.",
            count: removed
        )
    }

    /// "Done. N items removed." for one item-count apply (V2-07 §5.2).
    internal static func countLimitItemsRemoved(_ removed: Int) -> String {
        plural(
            "Done. %lld items removed.",
            one: "Done. %lld item removed.",
            other: "Done. %lld items removed.",
            count: removed
        )
    }

    /// The retired-items phrase of the applied-policies summary (`V2-02`
    /// §12).
    internal static func itemsRetired(_ retired: Int) -> String {
        plural(
            "%lld items retired",
            one: "%lld item retired",
            other: "%lld items retired",
            count: retired
        )
    }

    /// The pruned-revisions phrase of the applied-policies summary
    /// (`V2-02` §12).
    internal static func revisionsPruned(_ pruned: Int) -> String {
        plural(
            "%lld revisions pruned",
            one: "%lld revision pruned",
            other: "%lld revisions pruned",
            count: pruned
        )
    }

    // MARK: Lookup plumbing

    /// Resolves one non-substituted key from the catalog. The embedded
    /// English is the `value:` default, so a lane whose bundle carries no
    /// compiled table (native `swift test`; see the file header) renders
    /// the same copy and a missing entry can never surface a raw key.
    internal static func plain(_ key: String, _ englishDefault: String) -> String {
        bundle.localizedString(
            forKey: key,
            value: englishDefault,
            table: tableName
        )
    }

    /// Resolves one format pattern (`%1$lld`-style) the same way and
    /// formats it without locale grouping, matching the direct
    /// interpolation the fields used before.
    private static func formatted(
        _ key: String,
        _ englishDefault: String,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: plain(key, englishDefault),
            arguments: arguments
        )
    }

    /// Resolves one plural-varied key (V2-07 §10.4). The compiled catalog
    /// answers with the stringsdict `%#@…@` pattern and
    /// `localizedStringWithFormat` picks the locale's plural category.
    /// The native lane's verbatim catalog copy cannot vary by count, so
    /// the embedded default carries the correct English one/other form —
    /// keeping the two lanes byte-identical for English.
    private static func plural(
        _ key: String,
        one englishOne: String,
        other englishOther: String,
        count: Int
    ) -> String {
        let format = bundle.localizedString(
            forKey: key,
            value: count == 1 ? englishOne : englishOther,
            table: tableName
        )
        return String.localizedStringWithFormat(format, count)
    }
}
