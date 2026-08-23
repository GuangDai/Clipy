/// RetentionSettingsDraft.swift — lossless editing state for the unified
/// V2-02 retention settings group (`V2-07` §5.2/§6.3).
///
/// The controls are intentionally whole-day / whole-MiB fields while the
/// configured History values are seconds / bytes. Loading therefore keeps the
/// exact configured policy beside each displayed ceiling-rounded value. Until
/// a field is actually edited, submission reuses that exact raw value instead
/// of silently loosening it through the display conversion. An edit generation
/// also fences asynchronous Apply completion from a newer draft (deep review
/// `04` Red 10A/10D/10E).
import Foundation
import HistoryCore

internal struct RetentionSettingsDraft {
    internal struct LoadRequest: Sendable {
        fileprivate let editGeneration: UInt64
    }

    internal struct Submission: Sendable {
        internal let policies: HistoryRetentionPolicies
        fileprivate let editGeneration: UInt64
    }

    internal static let ageDaysRange: ClosedRange<Int> = 1...3_650
    internal static let storageMiBRange: ClosedRange<Int> = 1...1_920_000
    internal static let revisionCountRange: ClosedRange<Int> = 1...100
    internal static let revisionMiBRange: ClosedRange<Int> = 1...256
    internal static let mebibyteUnitLabel = "MiB"

    internal private(set) var ageEnabled = false
    internal private(set) var ageDaysText = "30"
    internal private(set) var storageEnabled = false
    internal private(set) var storageMiBText = "500"
    internal private(set) var revisionCountEnabled = false
    internal private(set) var revisionCountText = "20"
    internal private(set) var revisionBytesEnabled = false
    internal private(set) var revisionMiBText = "64"

    internal private(set) var ageValueIsDirty = false
    internal private(set) var storageValueIsDirty = false
    internal private(set) var revisionCountValueIsDirty = false
    internal private(set) var revisionBytesValueIsDirty = false

    private var configuredPolicies = HistoryRetentionPolicies(
        age: nil,
        storage: nil,
        revisions: nil
    )
    private var editGeneration: UInt64 = 0
    internal private(set) var acceptedSuccessMessage: String?

    internal var inputIsValid: Bool {
        (!ageEnabled || ageInputIsValid)
            && (!storageEnabled || storageInputIsValid)
            && (!revisionCountEnabled || revisionCountInputIsValid)
            && (!revisionBytesEnabled || revisionBytesInputIsValid)
    }

    internal var ageInputIsValid: Bool { ageDays != nil }
    internal var storageInputIsValid: Bool { storageMiB != nil }
    internal var revisionCountInputIsValid: Bool { revisionCount != nil }
    internal var revisionBytesInputIsValid: Bool { revisionMiB != nil }

    internal func beginLoadRequest() -> LoadRequest {
        LoadRequest(editGeneration: editGeneration)
    }

    /// Accepts a configured-policy read against the edit generation at which
    /// it started (`04` Red 10A). A late read always refreshes the hidden
    /// authoritative comparison baseline, but it may reflect into controls
    /// only when no user edit happened while the request was suspended.
    @discardableResult
    internal mutating func acceptLoaded(
        _ policies: HistoryRetentionPolicies,
        requestedAt request: LoadRequest
    ) -> Bool {
        configuredPolicies = policies
        guard request.editGeneration == editGeneration else { return false }
        ageEnabled = policies.age != nil
        if let age = policies.age {
            ageDaysText = String(Self.ceilingDays(age.maxAge))
        }
        storageEnabled = policies.storage != nil
        if let storage = policies.storage {
            storageMiBText = String(Self.ceilingMiB(
                storage.maxTotalBytes,
                range: Self.storageMiBRange
            ))
        }
        revisionCountEnabled = policies.revisions?.maxRevisionsPerItem != nil
        if let count = policies.revisions?.maxRevisionsPerItem {
            revisionCountText = String(count)
        }
        revisionBytesEnabled = policies.revisions?.maxRevisionBytesPerItem != nil
        if let bytes = policies.revisions?.maxRevisionBytesPerItem {
            revisionMiBText = String(Self.ceilingMiB(
                bytes,
                range: Self.revisionMiBRange
            ))
        }
        ageValueIsDirty = false
        storageValueIsDirty = false
        revisionCountValueIsDirty = false
        revisionBytesValueIsDirty = false
        acceptedSuccessMessage = nil
        return true
    }

    internal mutating func setAgeEnabled(_ enabled: Bool) {
        guard ageEnabled != enabled else { return }
        ageEnabled = enabled
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

    internal func isCurrent(_ submission: Submission) -> Bool {
        submission.editGeneration == editGeneration
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
        acceptedSuccessMessage = successMessage
        return true
    }

    private var ageDays: Int? {
        validatedSettingsWholeNumber(ageDaysText, in: Self.ageDaysRange)
    }

    private var storageMiB: Int? {
        validatedSettingsWholeNumber(storageMiBText, in: Self.storageMiBRange)
    }

    private var revisionCount: Int? {
        validatedSettingsWholeNumber(revisionCountText, in: Self.revisionCountRange)
    }

    private var revisionMiB: Int? {
        validatedSettingsWholeNumber(revisionMiBText, in: Self.revisionMiBRange)
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

/// Shared strict integer parser for Settings numeric fields. A decimal,
/// empty, or out-of-range value is not a whole policy value (contract §4.4).
internal func validatedSettingsWholeNumber(
    _ text: String,
    in range: ClosedRange<Int>
) -> Int? {
    guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else {
        return nil
    }
    return range.contains(value) ? value : nil
}
