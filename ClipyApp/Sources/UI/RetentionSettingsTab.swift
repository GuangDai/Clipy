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
                Toggle(RetentionSettingsCopy.countToggle, isOn: countEnabled)
                    .accessibilityIdentifier("clipy.settings.retention.count-enabled")
                if draft.countEnabled {
                    SettingsFieldLayout {
                        Text(RetentionSettingsCopy.itemsKeepAtMost)
                        HStack(spacing: 8) {
                            TextField("200", text: maximumUnpinnedText)
                                .frame(minWidth: 96, idealWidth: 140, maxWidth: 180)
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
                    }
                    if !draft.maximumUnpinnedInputIsValid {
                        Text(RetentionSettingsCopy.countInputHint)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
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
                        Task { await applyMaximumUnpinned(submission) }
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
            } header: {
                Text(RetentionSettingsCopy.itemsSection)
            }
            Section {
                Toggle(RetentionSettingsCopy.ageToggle, isOn: ageEnabled)
                    .accessibilityHint(RetentionSettingsCopy.ageToggleHint)
                    .accessibilityIdentifier("clipy.settings.retention.age-enabled")
                if draft.ageEnabled {
                    ValueFieldRow(
                        label: RetentionSettingsCopy.ageFieldLabel,
                        unit: RetentionSettingsCopy.ageUnit,
                        accessibilityIdentifier: "clipy.settings.retention.age-days",
                        text: ageDaysText,
                        isEnabled: draft.ageEnabled,
                        isValid: draft.ageInputIsValid,
                        range: RetentionSettingsDraft.ageDaysRange
                    )
                }
                Divider()
                Toggle(RetentionSettingsCopy.storageToggle, isOn: storageEnabled)
                    .accessibilityHint(RetentionSettingsCopy.storageToggleHint)
                    .accessibilityIdentifier("clipy.settings.retention.storage-enabled")
                if draft.storageEnabled {
                    ValueFieldRow(
                        label: RetentionSettingsCopy.storageFieldLabel,
                        unit: RetentionSettingsDraft.mebibyteUnitLabel,
                        accessibilityIdentifier: "clipy.settings.retention.storage-mib",
                        text: storageMiBText,
                        isEnabled: draft.storageEnabled,
                        isValid: draft.storageInputIsValid,
                        range: RetentionSettingsDraft.storageMiBRange
                    )
                }
                Divider()
                Text(RetentionSettingsCopy.revisionsSection)
                    .font(.subheadline.weight(.medium))
                Toggle(
                    RetentionSettingsCopy.revisionCountKeepAtMost,
                    isOn: revisionCountEnabled
                )
                    .accessibilityHint(
                        RetentionSettingsCopy.revisionCountToggleHint
                    )
                    .accessibilityIdentifier(
                        "clipy.settings.retention.revision-count-enabled"
                    )
                if draft.revisionCountEnabled {
                    ValueFieldRow(
                        label: RetentionSettingsCopy.revisionCountFieldLabel,
                        unit: RetentionSettingsCopy.revisionCountUnit,
                        accessibilityIdentifier: "clipy.settings.retention.revision-count",
                        text: revisionCountText,
                        isEnabled: draft.revisionCountEnabled,
                        isValid: draft.revisionCountInputIsValid,
                        range: RetentionSettingsDraft.revisionCountRange
                    )
                }
                Toggle(
                    RetentionSettingsCopy.revisionBytesToggle,
                    isOn: revisionBytesEnabled
                )
                    .accessibilityHint(
                        RetentionSettingsCopy.revisionBytesToggleHint
                    )
                    .accessibilityIdentifier(
                        "clipy.settings.retention.revision-bytes-enabled"
                    )
                if draft.revisionBytesEnabled {
                    ValueFieldRow(
                        label: RetentionSettingsCopy.revisionBytesFieldLabel,
                        unit: RetentionSettingsDraft.mebibyteUnitLabel,
                        accessibilityIdentifier: "clipy.settings.retention.revision-mib",
                        text: revisionMiBText,
                        isEnabled: draft.revisionBytesEnabled,
                        isValid: draft.revisionBytesInputIsValid,
                        range: RetentionSettingsDraft.revisionMiBRange
                    )
                }
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
                        Task { await applyRetention(submission) }
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
            } header: {
                Text(RetentionLayoutCopy.automaticPolicies)
            }
        }
        .formStyle(.grouped)
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
            usageRefreshGeneration += 1
            usage = nil
            usageFailed = false
        }
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
        guard draft.hasCountChanges,
              let submission = draft.countSubmission() else { return }
        if draft.maximumUnpinnedRequiresTightening(for: submission) {
            pendingCountSubmission = submission
            isConfirmingCountTightening = true
        } else {
            Task { await applyMaximumUnpinned(submission) }
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
        isWorking = true
        defer { isWorking = false }
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
            case .failure(let message):
                // A committed receipt without `.retentionPolicySet` cannot
                // confirm this submission; the configured comparison
                // baseline stays put so the next Apply still compares
                // against the last known configuration.
                guard draft.isCurrent(submission) else { return }
                countStatus = .failure(message)
            }
        } catch let failure as HistoryFailure {
            guard draft.isCurrent(submission) else { return }
            countStatus = .failure(FailurePresentation.message(for: failure))
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
        guard draft.hasPolicyChanges,
              let submission = draft.submission() else { return }
        if draft.requiresTighteningConfirmation(for: submission.policies) {
            pendingSubmission = submission
            isConfirmingTightening = true
        } else {
            Task { await applyRetention(submission) }
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
        isWorking = true
        defer { isWorking = false }
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
            case .failure(let message):
                // A committed receipt without `.retentionPoliciesSet`
                // cannot confirm this submission; the configured
                // comparison baseline stays put so the next Apply still
                // compares against the last known configuration.
                guard draft.isCurrent(submission) else { return }
                policyStatus = .failure(message)
            }
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
