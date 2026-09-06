/// RetentionSettingsDraft.swift — lossless editing state for the unified
/// V2-02 retention settings group (`V2-07` §5.2/§6.3).
///
/// The controls are intentionally whole-day / whole-MiB fields while the
/// configured History values are seconds / bytes. Loading therefore keeps the
/// exact configured count/policy beside each displayed ceiling-rounded value.
/// Until a field is actually edited, submission reuses that exact raw value
/// instead of silently loosening it through the display conversion. One edit
/// generation covers the count and all V2 dimensions, so a single panel-open
/// read can merge around newer edits and fence asynchronous Apply completion
/// (deep review `04` Red 10A/10D/10E).
import Foundation
import HistoryCore

internal struct RetentionSettingsDraft {
    internal struct LoadRequest: Sendable {
        fileprivate let editGeneration: UInt64
        fileprivate let loadGeneration: UInt64
    }

    internal struct Submission: Sendable {
        internal let policies: HistoryRetentionPolicies
        fileprivate let editGeneration: UInt64
    }

    internal struct CountSubmission: Sendable {
        internal let maximumUnpinnedItems: Int
        fileprivate let editGeneration: UInt64
    }

    internal static let ageDaysRange: ClosedRange<Int> = 1...3_650
    internal static let storageMiBRange: ClosedRange<Int> = 1...1_920_000
    internal static let revisionCountRange: ClosedRange<Int> = 1...100
    internal static let revisionMiBRange: ClosedRange<Int> = 1...256
    internal static let mebibyteUnitLabel = "MiB"

    /// R1 runs on capture and `.setRetentionPolicies`; it has no wall-clock
    /// worker or background reaper (`V2-02` §2.2/§7; review Card 10B). The
    /// copy resolves through the package localization resources
    /// (`RetentionSettingsCopy.ageEnforcementNote`; V2-07 §10).
    internal static let ageEnforcementExplanation =
        RetentionSettingsCopy.ageEnforcementNote

    internal private(set) var maximumUnpinnedText =
        String(HistoryLimits.standard.defaultMaximumUnpinnedItems)

    internal private(set) var ageEnabled = false
    internal private(set) var ageDaysText = "30"
    internal private(set) var storageEnabled = false
    internal private(set) var storageMiBText = "500"
    internal private(set) var revisionCountEnabled = false
    internal private(set) var revisionCountText = "20"
    internal private(set) var revisionBytesEnabled = false
    internal private(set) var revisionMiBText = "64"

    internal private(set) var maximumUnpinnedValueIsDirty = false
    internal private(set) var ageValueIsDirty = false
    internal private(set) var storageValueIsDirty = false
    internal private(set) var revisionCountValueIsDirty = false
    internal private(set) var revisionBytesValueIsDirty = false
    internal private(set) var ageToggleIsDirty = false
    internal private(set) var storageToggleIsDirty = false
    internal private(set) var revisionCountToggleIsDirty = false
    internal private(set) var revisionBytesToggleIsDirty = false

    private var configuredMaximumUnpinnedItems =
        HistoryLimits.standard.defaultMaximumUnpinnedItems
    private var configuredPolicies = HistoryRetentionPolicies(
        age: nil,
        storage: nil,
        revisions: nil
    )
    private var editGeneration: UInt64 = 0
    private var loadGeneration: UInt64 = 0
    private let locale: Locale
    internal private(set) var acceptedSuccessMessage: String?
    internal private(set) var acceptedCountSuccessMessage: String?

    internal init(locale: Locale = .current) {
        self.locale = locale
        maximumUnpinnedText = formatted(HistoryLimits.standard.defaultMaximumUnpinnedItems)
        ageDaysText = formatted(30)
        storageMiBText = formatted(500)
        revisionCountText = formatted(20)
        revisionMiBText = formatted(64)
    }

    /// The stepper and typed input share integer parsing; stepping an invalid
    /// field starts from the default, while valid out-of-range input clamps.
    internal var maximumUnpinnedStepperValue: Int {
        get {
            let typed = validatedSettingsWholeNumber(
                maximumUnpinnedText, in: Int.min...Int.max, locale: locale
            ) ?? HistoryLimits.standard.defaultMaximumUnpinnedItems
            let range = HistoryLimits.standard.userMaximumUnpinnedRange
            return min(max(typed, range.lowerBound), range.upperBound)
        }
        set { setMaximumUnpinnedText(formatted(newValue)) }
    }

    internal var inputIsValid: Bool {
        (!ageEnabled || ageInputIsValid)
            && (!storageEnabled || storageInputIsValid)
            && (!revisionCountEnabled || revisionCountInputIsValid)
            && (!revisionBytesEnabled || revisionBytesInputIsValid)
    }

    internal var maximumUnpinnedInputIsValid: Bool {
        maximumUnpinnedItems != nil
    }

    /// Apply availability follows the proposed value, not edit history: a
    /// user who changes a field and then restores the configured count has no
    /// pending write (`V2-07` §6.3; deep review Card 10A).
    internal var hasCountChanges: Bool {
        guard let maximumUnpinnedItems else { return false }
        return maximumUnpinnedItems != configuredMaximumUnpinnedItems
    }

    /// Exact policy comparison preserves the raw seconds/bytes baseline kept
    /// for rounded controls. Dirty flags protect asynchronous editing; they do
    /// not by themselves mean that Apply has work to perform.
    internal var hasPolicyChanges: Bool {
        guard inputIsValid else { return false }
        return HistoryRetentionPolicies(
            age: proposedAgePolicy,
            storage: proposedStoragePolicy,
            revisions: proposedRevisionPolicy
        ) != configuredPolicies
    }

    internal var ageInputIsValid: Bool { ageDays != nil }
    internal var storageInputIsValid: Bool { storageMiB != nil }
    internal var revisionCountInputIsValid: Bool { revisionCount != nil }
    internal var revisionBytesInputIsValid: Bool { revisionMiB != nil }

    internal mutating func beginLoadRequest() -> LoadRequest {
        loadGeneration += 1
        acceptedSuccessMessage = nil
        acceptedCountSuccessMessage = nil
        return LoadRequest(editGeneration: editGeneration, loadGeneration: loadGeneration)
    }

    /// A disappeared Settings surface cannot accept a pending read. Retire
    /// only that read's ownership; user text and per-field edits survive.
    internal mutating func invalidateLoadRequest() {
        loadGeneration += 1
    }

    internal func isCurrent(_ request: LoadRequest) -> Bool {
        request.loadGeneration == loadGeneration
    }

    /// Accepts the complete configured snapshot used by both Settings tabs.
    /// A current read refreshes the count baseline but preserves an unsaved
    /// count edit, then applies the same per-field merge to the V2 bundle.
    /// This is one History read and one edit generation, so count and policy
    /// controls cannot render values from different persisted snapshots.
    @discardableResult
    internal mutating func acceptLoaded(
        _ configuration: HistoryRetentionConfiguration,
        requestedAt request: LoadRequest
    ) -> Bool {
        guard isCurrent(request) else { return false }
        configuredMaximumUnpinnedItems = configuration.maximumUnpinnedItems
        if !maximumUnpinnedValueIsDirty {
            maximumUnpinnedText = formatted(configuration.maximumUnpinnedItems)
        }
        return acceptLoaded(
            configuration.policies,
            requestedAt: request
        )
    }

    /// Accepts a configured-policy read against the edit generation at which
    /// it started (`04` Red 10A). A late read always refreshes the hidden
    /// authoritative comparison baseline and reflects each untouched control,
    /// while preserving dirty toggles/fields, including edits made before a
    /// reload began. Opening Settings again must not discard unsaved text.
    /// Untouched fields still adopt the newest exact stored policy values.
    @discardableResult
    internal mutating func acceptLoaded(
        _ policies: HistoryRetentionPolicies,
        requestedAt request: LoadRequest
    ) -> Bool {
        guard isCurrent(request) else { return false }
        let generationIsCurrent = request.editGeneration == editGeneration
        configuredPolicies = policies
        if !ageToggleIsDirty {
            ageEnabled = policies.age != nil
        }
        if let age = policies.age,
           !ageValueIsDirty {
            ageDaysText = formatted(Self.ceilingDays(age.maxAge))
        }
        if !storageToggleIsDirty {
            storageEnabled = policies.storage != nil
        }
        if let storage = policies.storage,
           !storageValueIsDirty {
            storageMiBText = formatted(Self.ceilingMiB(
                storage.maxTotalBytes,
                range: Self.storageMiBRange
            ))
        }
        if !revisionCountToggleIsDirty {
            revisionCountEnabled = policies.revisions?.maxRevisionsPerItem != nil
        }
        if let count = policies.revisions?.maxRevisionsPerItem,
           !revisionCountValueIsDirty {
            revisionCountText = formatted(count)
        }
        if !revisionBytesToggleIsDirty {
            revisionBytesEnabled = policies.revisions?.maxRevisionBytesPerItem != nil
        }
        if let bytes = policies.revisions?.maxRevisionBytesPerItem,
           !revisionBytesValueIsDirty {
            revisionMiBText = formatted(Self.ceilingMiB(
                bytes,
                range: Self.revisionMiBRange
            ))
        }
        guard generationIsCurrent else { return false }
        acceptedSuccessMessage = nil
        acceptedCountSuccessMessage = nil
        return true
    }

    internal mutating func setAgeEnabled(_ enabled: Bool) {
        guard ageEnabled != enabled else { return }
        ageEnabled = enabled
        ageToggleIsDirty = true
        recordEdit()
    }

    internal mutating func setMaximumUnpinnedText(_ text: String) {
        guard maximumUnpinnedText != text else { return }
        maximumUnpinnedText = text
        maximumUnpinnedValueIsDirty = true
        recordEdit()
    }

    internal mutating func setAgeDaysText(_ text: String) {
        guard ageDaysText != text else { return }
        ageDaysText = text
        ageValueIsDirty = true
        recordEdit()
    }

    internal mutating func setStorageEnabled(_ enabled: Bool) {
        guard storageEnabled != enabled else { return }
        storageEnabled = enabled
        storageToggleIsDirty = true
        recordEdit()
    }

    internal mutating func setStorageMiBText(_ text: String) {
        guard storageMiBText != text else { return }
        storageMiBText = text
        storageValueIsDirty = true
        recordEdit()
    }

    internal mutating func setRevisionCountEnabled(_ enabled: Bool) {
        guard revisionCountEnabled != enabled else { return }
        revisionCountEnabled = enabled
        revisionCountToggleIsDirty = true
        recordEdit()
    }

    internal mutating func setRevisionCountText(_ text: String) {
        guard revisionCountText != text else { return }
        revisionCountText = text
        revisionCountValueIsDirty = true
        recordEdit()
    }

    internal mutating func setRevisionBytesEnabled(_ enabled: Bool) {
        guard revisionBytesEnabled != enabled else { return }
        revisionBytesEnabled = enabled
        revisionBytesToggleIsDirty = true
        recordEdit()
    }

    internal mutating func setRevisionMiBText(_ text: String) {
        guard revisionMiBText != text else { return }
        revisionMiBText = text
        revisionBytesValueIsDirty = true
        recordEdit()
    }

    internal func submission() -> Submission? {
        guard inputIsValid else { return nil }
        return Submission(
            policies: HistoryRetentionPolicies(
                age: proposedAgePolicy,
                storage: proposedStoragePolicy,
                revisions: proposedRevisionPolicy
            ),
            editGeneration: editGeneration
        )
    }

    internal func countSubmission() -> CountSubmission? {
        guard let maximumUnpinnedItems else { return nil }
        return CountSubmission(
            maximumUnpinnedItems: maximumUnpinnedItems,
            editGeneration: editGeneration
        )
    }

    internal func isCurrent(_ submission: Submission) -> Bool {
        submission.editGeneration == editGeneration
    }

    internal func isCurrent(_ submission: CountSubmission) -> Bool {
        submission.editGeneration == editGeneration
    }

    internal func maximumUnpinnedRequiresTightening(
        for submission: CountSubmission
    ) -> Bool {
        submission.maximumUnpinnedItems < configuredMaximumUnpinnedItems
    }

    /// Returns true when any enabled candidate threshold is stricter than
    /// the exact configured threshold. Enabling a previously absent threshold
    /// is tightening; disabling or increasing one is not. Mixed edits still
    /// confirm when at least one dimension can delete more history.
    internal func requiresTighteningConfirmation(
        for candidate: HistoryRetentionPolicies
    ) -> Bool {
        Self.tightens(candidate.age?.maxAge, from: configuredPolicies.age?.maxAge)
            || Self.tightens(
                candidate.storage?.maxTotalBytes,
                from: configuredPolicies.storage?.maxTotalBytes
            )
            || Self.tightens(
                candidate.revisions?.maxRevisionsPerItem,
                from: configuredPolicies.revisions?.maxRevisionsPerItem
            )
            || Self.tightens(
                candidate.revisions?.maxRevisionBytesPerItem,
                from: configuredPolicies.revisions?.maxRevisionBytesPerItem
            )
    }

    /// Accepts an Apply result only for the edit generation that produced
    /// it. A successful current submission becomes the new exact baseline;
    /// an intervening edit leaves both its text and dirty state untouched.
    /// The configured comparison baseline still advances after a stale-UI
    /// success because that submission did commit to History; otherwise the
    /// next draft could compare strictness against policy state that no longer
    /// exists (`04` Red 10D/10E).
    @discardableResult
    internal mutating func acceptApplied(
        _ submission: Submission,
        successMessage: String
    ) -> Bool {
        configuredPolicies = submission.policies
        guard isCurrent(submission) else { return false }
        ageValueIsDirty = false
        storageValueIsDirty = false
        revisionCountValueIsDirty = false
        revisionBytesValueIsDirty = false
        ageToggleIsDirty = false
        storageToggleIsDirty = false
        revisionCountToggleIsDirty = false
        revisionBytesToggleIsDirty = false
        acceptedSuccessMessage = successMessage
        return true
    }

    @discardableResult
    internal mutating func acceptApplied(
        _ submission: CountSubmission,
        successMessage: String
    ) -> Bool {
        configuredMaximumUnpinnedItems = submission.maximumUnpinnedItems
        guard isCurrent(submission) else { return false }
        maximumUnpinnedValueIsDirty = false
        acceptedCountSuccessMessage = successMessage
        return true
    }

    private var maximumUnpinnedItems: Int? {
        validatedSettingsWholeNumber(
            maximumUnpinnedText,
            in: HistoryLimits.standard.userMaximumUnpinnedRange,
            locale: locale
        )
    }

    private var ageDays: Int? {
        validatedSettingsWholeNumber(ageDaysText, in: Self.ageDaysRange, locale: locale)
    }

    private var storageMiB: Int? {
        validatedSettingsWholeNumber(storageMiBText, in: Self.storageMiBRange, locale: locale)
    }

    private var revisionCount: Int? {
        validatedSettingsWholeNumber(revisionCountText, in: Self.revisionCountRange, locale: locale)
    }

    private var revisionMiB: Int? {
        validatedSettingsWholeNumber(revisionMiBText, in: Self.revisionMiBRange, locale: locale)
    }

    private func formatted(_ value: Int) -> String {
        LocalizedCountPresentation.number(value, locale: locale)
    }

    private var proposedAgePolicy: AgeRetention? {
        guard ageEnabled else { return nil }
        if !ageValueIsDirty, let configured = configuredPolicies.age {
            return configured
        }
        return ageDays.map { AgeRetention(maxAge: TimeInterval($0 * 86_400)) }
    }

    private var proposedStoragePolicy: StorageRetention? {
        guard storageEnabled else { return nil }
        if !storageValueIsDirty, let configured = configuredPolicies.storage {
            return configured
        }
        return storageMiB.map {
            StorageRetention(maxTotalBytes: $0 * 1_048_576)
        }
    }

    private var proposedRevisionPolicy: RevisionRetention? {
        let count: Int?
        if revisionCountEnabled {
            if !revisionCountValueIsDirty,
               let configured = configuredPolicies.revisions?.maxRevisionsPerItem {
                count = configured
            } else {
                count = revisionCount
            }
        } else {
            count = nil
        }

        let bytes: Int?
        if revisionBytesEnabled {
            if !revisionBytesValueIsDirty,
               let configured = configuredPolicies.revisions?.maxRevisionBytesPerItem {
                bytes = configured
            } else {
                bytes = revisionMiB.map { $0 * 1_048_576 }
            }
        } else {
            bytes = nil
        }

        guard count != nil || bytes != nil else { return nil }
        return RevisionRetention(
            maxRevisionsPerItem: count,
            maxRevisionBytesPerItem: bytes
        )
    }

    private mutating func recordEdit() {
        editGeneration += 1
        acceptedSuccessMessage = nil
        acceptedCountSuccessMessage = nil
    }

    private static func tightens<T: Comparable>(
        _ candidate: T?,
        from configured: T?
    ) -> Bool {
        guard let candidate else { return false }
        guard let configured else { return true }
        return candidate < configured
    }

    private static func ceilingDays(_ seconds: TimeInterval) -> Int {
        let days = Int((seconds / 86_400).rounded(.up))
        return min(max(days, ageDaysRange.lowerBound), ageDaysRange.upperBound)
    }

    private static func ceilingMiB(
        _ bytes: Int,
        range: ClosedRange<Int>
    ) -> Int {
        let mib = (bytes + 1_048_575) / 1_048_576
        return min(max(mib, range.lowerBound), range.upperBound)
    }
}

/// V2-07 §10.3: accept localized integers as displayed, with optional grouping.
/// Comparing the parsed value's integer representations rejects decimal or
/// partially parsed input even if Foundation can recover a number from it.
internal func validatedSettingsWholeNumber(
    _ text: String,
    in range: ClosedRange<Int>,
    locale: Locale = .current
) -> Int? {
    let text = text.trimmingCharacters(in: .whitespaces)
    if let value = Int(text) {
        return range.contains(value) ? value : nil
    }
    let style = IntegerFormatStyle<Int>.number.locale(locale)
    guard let value = try? Int(text, format: style, lenient: false),
          range.contains(value),
          text == value.formatted(style)
            || text == value.formatted(style.grouping(.never)) else { return nil }
    return value
}
