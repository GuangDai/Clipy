import Foundation
import HistoryCore
import SwiftUI

// MARK: Retention

/// Retention tab — the unified count + V2-02 group (V2-07 §5.2/§6.3;
/// DC-23). The count remains its separate v1 `.setRetentionPolicy` action,
/// while age/storage/revision apply together through
/// `HistoryViewState.applyRetentionPolicies` (`.setRetentionPolicies`,
/// `V2-02` §8.1 — a set replaces the whole policy value).
///
/// Field bounds mirror the HistoryStorage admission ranges (`V2-02` §8.3)
/// one-for-one so Apply never sends a value storage will reject; disabling
/// a dimension sends `nil` for it (DC-23). Every control opens at the
/// persisted configured policy loaded on appear (`V2-07` §6.3's panel-open
/// read; audit SPEC-IMPL-003), and Apply stays disabled until that read
/// lands — an unexamined Apply against the neutral prefill could otherwise
/// silently wipe a real persisted policy. Retained counts and logical
/// content size load separately on opening or explicit refresh, and after
/// applying a policy; they do not start another observation subscription.
struct RetentionSettingsTab: View {

    private let viewState: HistoryViewState

    /// Exact configured values plus whole-unit display text and edit
    /// generations. Keeping this as one value prevents one field from being
    /// rounded merely because another field was edited.
    @Binding private var draft: RetentionSettingsDraft
    private let hasLoadedRetentionConfiguration: Bool
    private let retentionConfigurationFailure: String?
    private let retryRetentionConfiguration: () -> Void
    @State private var countStatus: SettingStatus?
    @State private var policyStatus: SettingStatus?
    @State private var usageRefreshGeneration = 0
    @State private var usage: HistoryUsage?
    @State private var usageFailed = false
    @State private var isWorking = false
    @State private var applyTask: Task<Void, Never>?
    @State private var isCancelling = false
    @State private var pendingCountSubmission:
        RetentionSettingsDraft.CountSubmission?
    @State private var isConfirmingCountTightening = false
    @State private var pendingSubmission: RetentionSettingsDraft.Submission?
    @State private var isConfirmingTightening = false

    init(
        viewState: HistoryViewState,
        draft: Binding<RetentionSettingsDraft>,
        hasLoadedRetentionConfiguration: Bool,
        retentionConfigurationFailure: String?,
        retryRetentionConfiguration: @escaping () -> Void
    ) {
        self.viewState = viewState
        _draft = draft
        self.hasLoadedRetentionConfiguration = hasLoadedRetentionConfiguration
        self.retentionConfigurationFailure = retentionConfigurationFailure
        self.retryRetentionConfiguration = retryRetentionConfiguration
    }

    var body: some View {
        Form {
            if let retentionConfigurationFailure {
                Section {
                    SettingStatusView(status: .failure(retentionConfigurationFailure))
                        .accessibilityIdentifier(
                            "clipy.settings.retention.configuration-failure"
                        )
                    Button(SettingsCopy.text("Retry"), action: retryRetentionConfiguration)
                        .accessibilityIdentifier(
                            "clipy.settings.retention.retry-configuration"
                        )
                }
            }
            HistoryUsageView(
                usage: usage,
                failed: usageFailed,
                onRefresh: { usageRefreshGeneration += 1 }
            )
            if hasLoadedRetentionConfiguration {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(RetentionLayoutCopy.countSummary(draft.configuredRetentionConfiguration))
                            .font(.headline)
                        Text(RetentionLayoutCopy.policySummary(draft.configuredRetentionConfiguration))
                            .foregroundStyle(.secondary)
                        if draft.hasCountChanges || draft.hasPolicyChanges {
                            Label(RetentionLayoutCopy.pendingChanges, systemImage: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("clipy.settings.retention.current-policy")
                } header: {
                    Text(RetentionLayoutCopy.currentPolicy)
                }
            }
            Section {
                // One grouped Form row owns this setting. Separate Form
                // children each receive native row padding, which formerly
                // left blank-looking rows between the checkbox and its value.
                VStack(alignment: .leading, spacing: 10) {
                    SettingsFieldLayout {
                        Toggle(RetentionSettingsCopy.countToggle, isOn: countEnabled)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("clipy.settings.retention.count-enabled")
                        if draft.countEnabled {
                            HStack(spacing: 8) {
                                Text(RetentionSettingsCopy.itemsKeepAtMost)
                                TextField("", text: maximumUnpinnedText)
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .frame(width: 88)
                                    .multilineTextAlignment(.trailing)
                                    .accessibilityLabel(RetentionSettingsCopy.maximumUnpinnedAccessibilityLabel)
                                    .accessibilityIdentifier("clipy.settings.retention.maximum-unpinned")
                                Stepper("", value: maximumUnpinnedStepperValue,
                                    in: HistoryLimits.standard.userMaximumUnpinnedRange)
                                    .labelsHidden()
                                    .accessibilityLabel(RetentionSettingsCopy.maximumUnpinnedAccessibilityLabel)
                                Text(RetentionSettingsCopy.unpinnedItemsUnit)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text(RetentionSettingsCopy.noLimit)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isWorking || !hasLoadedRetentionConfiguration)
                    if draft.countEnabled && !draft.maximumUnpinnedInputIsValid {
                        Text(RetentionSettingsCopy.countInputHint)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button(RetentionSettingsCopy.applyItemLimit) {
                        requestMaximumUnpinnedApply()
                    }
                    .accessibilityIdentifier(
                        "clipy.settings.retention.apply-item-limit"
                    )
                    .disabled(
                        !draft.maximumUnpinnedInputIsValid
                            || !draft.hasCountChanges
                            || isWorking
                            || !hasLoadedRetentionConfiguration
                    )
                    .confirmationDialog(
                        RetentionSettingsCopy.confirmItemLimitTitle,
                        isPresented: $isConfirmingCountTightening,
                        titleVisibility: .visible
                    ) {
                        Button(
                            RetentionSettingsCopy.confirmItemLimitApply,
                            role: .destructive
                        ) {
                            guard let submission = pendingCountSubmission else {
                                return
                            }
                            startApply { await applyMaximumUnpinned(submission) }
                        }
                        Button(RetentionSettingsCopy.confirmCancel, role: .cancel) {
                            pendingCountSubmission = nil
                        }
                    } message: {
                        Text(RetentionSettingsCopy.confirmItemLimitMessage)
                    }
                    // The status sits on its own row below the button so a
                    // long receipt or failure message can never squeeze the
                    // Apply button (V2-07 §9 inline feedback).
                    if let successMessage = draft.acceptedCountSuccessMessage {
                        SettingStatusView(status: .success(successMessage))
                            .accessibilityIdentifier(
                                "clipy.settings.retention.item-limit-status"
                            )
                    } else if let countStatus {
                        SettingStatusView(status: countStatus)
                            .accessibilityIdentifier(
                                "clipy.settings.retention.item-limit-status"
                            )
                    }
                    DisclosureGroup(RetentionLayoutCopy.countDetails) {
                        Text(RetentionSettingsCopy.countEnforcementNote)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disclosureGroupStyle(AppDisclosureGroupStyle(identifier: "clipy.settings.retention.count-details"))
                }
            } header: {
                Text(RetentionSettingsCopy.itemsSection)
            }
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        RetentionLimitField(
                            toggleLabel: RetentionSettingsCopy.ageToggle,
                            toggleHint: RetentionSettingsCopy.ageToggleHint,
                            toggleIdentifier: "clipy.settings.retention.age-enabled",
                            isEnabled: ageEnabled,
                            label: RetentionSettingsCopy.ageFieldLabel,
                            unit: RetentionSettingsCopy.ageUnit,
                            accessibilityIdentifier: "clipy.settings.retention.age-days",
                            text: ageDaysText,
                            isValid: draft.ageInputIsValid,
                            range: RetentionSettingsDraft.ageDaysRange
                        )
                        RetentionLimitField(
                            toggleLabel: RetentionSettingsCopy.storageToggle,
                            toggleHint: RetentionSettingsCopy.storageToggleHint,
                            toggleIdentifier: "clipy.settings.retention.storage-enabled",
                            isEnabled: storageEnabled,
                            label: RetentionSettingsCopy.storageFieldLabel,
                            unit: RetentionSettingsDraft.mebibyteUnitLabel,
                            accessibilityIdentifier: "clipy.settings.retention.storage-mib",
                            text: storageMiBText,
                            isValid: draft.storageInputIsValid,
                            range: RetentionSettingsDraft.storageMiBRange
                        )
                    }
                    .disabled(isWorking || !hasLoadedRetentionConfiguration)
                    VStack(alignment: .leading, spacing: 12) {
                        Divider()
                        Text(RetentionSettingsCopy.revisionsSection)
                            .font(.subheadline.weight(.medium))
                        RetentionLimitField(
                            toggleLabel: RetentionSettingsCopy.revisionCountFieldLabel,
                            toggleHint: RetentionSettingsCopy.revisionCountToggleHint,
                            toggleIdentifier: "clipy.settings.retention.revision-count-enabled",
                            isEnabled: revisionCountEnabled,
                            label: RetentionSettingsCopy.revisionCountFieldLabel,
                            unit: RetentionSettingsCopy.revisionCountUnit,
                            accessibilityIdentifier: "clipy.settings.retention.revision-count",
                            text: revisionCountText,
                            isValid: draft.revisionCountInputIsValid,
                            range: RetentionSettingsDraft.revisionCountRange
                        )
                        RetentionLimitField(
                            toggleLabel: RetentionSettingsCopy.revisionBytesToggle,
                            toggleHint: RetentionSettingsCopy.revisionBytesToggleHint,
                            toggleIdentifier: "clipy.settings.retention.revision-bytes-enabled",
                            isEnabled: revisionBytesEnabled,
                            label: RetentionSettingsCopy.revisionBytesFieldLabel,
                            unit: RetentionSettingsDraft.mebibyteUnitLabel,
                            accessibilityIdentifier: "clipy.settings.retention.revision-mib",
                            text: revisionMiBText,
                            isValid: draft.revisionBytesInputIsValid,
                            range: RetentionSettingsDraft.revisionMiBRange
                        )
                    }
                    .disabled(isWorking || !hasLoadedRetentionConfiguration)
                    VStack(alignment: .leading, spacing: 10) {
                        Button(RetentionSettingsCopy.applyPolicies) {
                            requestApply()
                        }
                        .accessibilityIdentifier("clipy.settings.retention.apply")
                        .disabled(
                            !draft.inputIsValid || !draft.hasPolicyChanges || isWorking
                                || !hasLoadedRetentionConfiguration
                        )
                        .confirmationDialog(
                            RetentionSettingsCopy.confirmPoliciesTitle,
                            isPresented: $isConfirmingTightening,
                            titleVisibility: .visible
                        ) {
                            Button(
                                RetentionSettingsCopy.confirmPoliciesApply,
                                role: .destructive
                            ) {
                                guard let submission = pendingSubmission else { return }
                                startApply { await applyRetention(submission) }
                            }
                            Button(RetentionSettingsCopy.confirmCancel, role: .cancel) {
                                pendingSubmission = nil
                            }
                        } message: {
                            // Deep review `04` Red 10D: only a strict local
                            // tightening is destructive-confirmed; equal or
                            // looser policy values apply directly.
                            Text(RetentionSettingsCopy.confirmPoliciesMessage)
                        }
                        // Same own-row treatment as the item-limit status above:
                        // a long receipt or failure message must not squeeze the
                        // Apply button.
                        if let successMessage = draft.acceptedSuccessMessage {
                            SettingStatusView(status: .success(successMessage))
                                .accessibilityIdentifier(
                                    "clipy.settings.retention.policy-status"
                                )
                        } else if let policyStatus {
                            SettingStatusView(status: policyStatus)
                                .accessibilityIdentifier(
                                    "clipy.settings.retention.policy-status"
                                )
                        }
                        DisclosureGroup(RetentionLayoutCopy.policyDetails) {
                            VStack(alignment: .leading, spacing: 8) {
                                if draft.ageEnabled {
                                    Text(RetentionSettingsDraft.ageEnforcementExplanation)
                                        .accessibilityIdentifier("clipy.settings.retention.age-enforcement")
                                }
                                Text(RetentionSettingsCopy.applyNote)
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .disclosureGroupStyle(AppDisclosureGroupStyle(identifier: "clipy.settings.retention.cleanup-details"))
                    }
                }
            } header: {
                Text(RetentionLayoutCopy.automaticPolicies)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isWorking {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(isCancelling ? RetentionSettingsCopy.cancelling : RetentionSettingsCopy.applying)
                        .font(.callout)
                    Spacer()
                    Button(RetentionSettingsCopy.confirmCancel) {
                        cancelApply()
                    }
                    .disabled(isCancelling)
                    .accessibilityIdentifier("clipy.settings.retention.cancel-apply")
                }
                .padding(12)
                .background(.bar)
                .accessibilityIdentifier("clipy.settings.retention.pending")
            }
        }
        // The tab owns this task, so scrolling the usage section offscreen
        // cannot start another read. Refresh and successful policy changes
        // replace the task; tab/window disappearance cancels it.
        .task(id: usageRefreshGeneration) {
            await refreshUsage()
        }
        // Clear can finish after the user has already returned from General.
        // The existing receipt-confirmed purge also covers destructive Apply
        // and external removals, without another History subscription.
        .onChange(of: viewState.surfacePurge?.generation) { _, _ in
            usageRefreshGeneration += 1
        }
        .onDisappear {
            cancelApply()
            usageRefreshGeneration += 1
            usage = nil
            usageFailed = false
        }
    }

    /// Set pending synchronously with the click, before the task can suspend.
    /// Cancellation requests rollback; only the actual result decides whether
    /// to report cancellation or accept an already committed receipt.
    private func startApply(_ operation: @escaping @MainActor () async -> Void) {
        guard !isWorking, hasLoadedRetentionConfiguration else { return }
        isWorking = true
        isCancelling = false
        applyTask = Task {
            defer {
                isWorking = false
                isCancelling = false
                applyTask = nil
            }
            await operation()
        }
    }

    private func cancelApply() {
        guard isWorking else { return }
        isCancelling = true
        applyTask?.cancel()
    }

    private func refreshUsage() async {
        guard !Task.isCancelled else { return }
        let requestGeneration = usageRefreshGeneration
        usage = nil
        usageFailed = false
        do {
            let result = try await viewState.history.usage()
            guard !Task.isCancelled, requestGeneration == usageRefreshGeneration else { return }
            usage = result
        } catch {
            guard !Task.isCancelled, requestGeneration == usageRefreshGeneration else { return }
            usageFailed = true
        }
    }

    private func refreshUsageAfterApply(_ receipt: HistoryReceipt) {
        // Destructive retention already publishes the purge observed above.
        // Only non-destructive/no-op Apply needs its own refresh request.
        if case .committed(let commit) = receipt,
           commit.hasDestructiveRetentionEffects {
            return
        }
        usageRefreshGeneration += 1
    }

    private var countEnabled: Binding<Bool> {
        Binding(
            get: { draft.countEnabled },
            set: {
                draft.setCountEnabled($0)
                countStatus = nil
            }
        )
    }

    private var maximumUnpinnedText: Binding<String> {
        Binding(
            get: { draft.maximumUnpinnedText },
            set: {
                draft.setMaximumUnpinnedText($0)
                countStatus = nil
            }
        )
    }

    /// The draft owns localized input parsing and the §2 stepper range.
    private var maximumUnpinnedStepperValue: Binding<Int> {
        Binding<Int>(
            get: { draft.maximumUnpinnedStepperValue },
            set: {
                draft.maximumUnpinnedStepperValue = $0
                countStatus = nil
            }
        )
    }

    /// Count is part of the same destructive-retention family as the V2
    /// thresholds: lowering the configured value requires confirmation;
    /// equal or looser values apply directly (`04` Red 10D).
    private func requestMaximumUnpinnedApply() {
        guard !isWorking, hasLoadedRetentionConfiguration, draft.hasCountChanges,
              let submission = draft.countSubmission() else { return }
        if draft.maximumUnpinnedRequiresTightening(for: submission) {
            pendingCountSubmission = submission
            isConfirmingCountTightening = true
        } else {
            startApply { await applyMaximumUnpinned(submission) }
        }
    }

    /// Applies the count policy and reports the receipt inline
    /// (`.retentionPolicySet(removedCount:)`, 03a §6; V2-07 §5.2). Every
    /// receipt state maps to deliberate feedback in
    /// `maximumUnpinnedStatusFeedback` — no blanket "Done." catch-all
    /// (deep review Card 10).
    private func applyMaximumUnpinned(
        _ submission: RetentionSettingsDraft.CountSubmission
    ) async {
        guard draft.isCurrent(submission) else { return }
        pendingCountSubmission = nil
        do {
            let receipt = try await viewState.applyMaximumUnpinnedItems(
                submission.maximumUnpinnedItems
            )
            switch maximumUnpinnedStatusFeedback(receipt) {
            case .success(let successMessage):
                refreshUsageAfterApply(receipt)
                guard draft.acceptApplied(
                    submission,
                    successMessage: successMessage
                ) else { return }
                countStatus = nil
            case .failure(let message), .cancelled(let message):
                // A committed receipt without `.retentionPolicySet` cannot
                // confirm this submission; the configured comparison
                // baseline stays put so the next Apply still compares
                // against the last known configuration.
                guard draft.isCurrent(submission) else { return }
                countStatus = .failure(message)
            }
        } catch is CancellationError {
            guard draft.isCurrent(submission) else { return }
            countStatus = .cancelled(RetentionSettingsCopy.countApplyCancelled)
        } catch let failure as HistoryFailure {
            guard draft.isCurrent(submission) else { return }
            countStatus = .failure(RetentionSettingsCopy.countFailureMessage(for: failure))
        } catch {
            guard draft.isCurrent(submission) else { return }
            countStatus = .failure(RetentionSettingsCopy.countSaveFailure)
        }
    }

    private var ageEnabled: Binding<Bool> {
        Binding(
            get: { draft.ageEnabled },
            set: {
                draft.setAgeEnabled($0)
                policyStatus = nil
            }
        )
    }

    private var ageDaysText: Binding<String> {
        Binding(
            get: { draft.ageDaysText },
            set: {
                draft.setAgeDaysText($0)
                policyStatus = nil
            }
        )
    }

    private var storageEnabled: Binding<Bool> {
        Binding(
            get: { draft.storageEnabled },
            set: {
                draft.setStorageEnabled($0)
                policyStatus = nil
            }
        )
    }

    private var storageMiBText: Binding<String> {
        Binding(
            get: { draft.storageMiBText },
            set: {
                draft.setStorageMiBText($0)
                policyStatus = nil
            }
        )
    }

    private var revisionCountEnabled: Binding<Bool> {
        Binding(
            get: { draft.revisionCountEnabled },
            set: {
                draft.setRevisionCountEnabled($0)
                policyStatus = nil
            }
        )
    }

    private var revisionCountText: Binding<String> {
        Binding(
            get: { draft.revisionCountText },
            set: {
                draft.setRevisionCountText($0)
                policyStatus = nil
            }
        )
    }

    private var revisionBytesEnabled: Binding<Bool> {
        Binding(
            get: { draft.revisionBytesEnabled },
            set: {
                draft.setRevisionBytesEnabled($0)
                policyStatus = nil
            }
        )
    }

    private var revisionMiBText: Binding<String> {
        Binding(
            get: { draft.revisionMiBText },
            set: {
                draft.setRevisionMiBText($0)
                policyStatus = nil
            }
        )
    }

    private func requestApply() {
        guard !isWorking, hasLoadedRetentionConfiguration, draft.hasPolicyChanges,
              let submission = draft.submission() else { return }
        if draft.requiresTighteningConfirmation(for: submission.policies) {
            pendingSubmission = submission
            isConfirmingTightening = true
        } else {
            startApply { await applyRetention(submission) }
        }
    }

    /// Applies all dimensions as one policy value and reports the receipt
    /// inline (`.retentionPoliciesSet(retiredItems:prunedRevisions:)`,
    /// 03a §6 / `V2-02` §8.1; feedback per V2-07 §5.2). Every receipt state
    /// maps to deliberate feedback in `retentionPoliciesStatusFeedback` —
    /// no blanket "Done." catch-all (deep review Card 10).
    private func applyRetention(
        _ submission: RetentionSettingsDraft.Submission
    ) async {
        guard draft.isCurrent(submission) else { return }
        pendingSubmission = nil
        do {
            let receipt = try await viewState.applyRetentionPolicies(submission.policies)
            switch retentionPoliciesStatusFeedback(receipt) {
            case .success(let successMessage):
                refreshUsageAfterApply(receipt)
                guard draft.acceptApplied(
                    submission,
                    successMessage: successMessage
                ) else { return }
                policyStatus = nil
            case .failure(let message), .cancelled(let message):
                // A committed receipt without `.retentionPoliciesSet`
                // cannot confirm this submission; the configured
                // comparison baseline stays put so the next Apply still
                // compares against the last known configuration.
                guard draft.isCurrent(submission) else { return }
                policyStatus = .failure(message)
            }
        } catch is CancellationError {
            guard draft.isCurrent(submission) else { return }
            policyStatus = .cancelled(RetentionSettingsCopy.policyApplyCancelled)
        } catch let failure as HistoryFailure {
            guard draft.isCurrent(submission) else { return }
            policyStatus = .failure(RetentionSettingsCopy.failureMessage(
                for: failure, policies: submission.policies
            ))
        } catch {
            guard draft.isCurrent(submission) else { return }
            policyStatus = .failure(RetentionSettingsCopy.policiesSaveFailure)
        }
    }
}

/// A checkbox and its optional value are one native form row. The adaptive
/// layout moves these same controls vertically when space is constrained;
/// resizing never creates a second TextField or discards an in-progress edit.
private struct RetentionLimitField: View {
    let toggleLabel: String
    let toggleHint: String
    let toggleIdentifier: String
    @Binding var isEnabled: Bool
    let label: String
    let unit: String
    let accessibilityIdentifier: String
    @Binding var text: String
    let isValid: Bool
    let range: ClosedRange<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsFieldLayout {
                Toggle(toggleLabel, isOn: $isEnabled)
                    .toggleStyle(.checkbox)
                    .accessibilityHint(toggleHint)
                    .accessibilityIdentifier(toggleIdentifier)
                if isEnabled {
                    HStack(spacing: 8) {
                        TextField("", text: $text)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 88)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel(label)
                            .accessibilityIdentifier(accessibilityIdentifier)
                        Text(unit)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(RetentionSettingsCopy.noLimit)
                        .foregroundStyle(.secondary)
                }
            }
            if isEnabled && !isValid {
                Text(RetentionSettingsCopy.rangeHint(from: range.lowerBound, to: range.upperBound))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
