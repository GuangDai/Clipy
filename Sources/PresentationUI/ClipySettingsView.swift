/// ClipySettingsView.swift — the Settings scene body (⌘,): a General tab
/// (the v1 maximum-unpinned count policy, the optional Launch-at-Login
/// toggle, and the Danger Zone clears) and a Retention tab (the unified
/// V2-02 group; the first release is M1 + V2-02, so this is the ONLY V2
/// settings surface — V2-07 §5 intro, §6.3).
/// Owning spec: docs/01-architecture.md §2 (PresentationUI responsibilities)
/// and §8 (target confinement); count policy: docs/03a-instruction-set.md
/// §5 (`setRetentionPolicy`, `clear`/`ClearScope`) with receipts per §6;
/// failure rendering: docs/03b-instruction-set.md §10 via
/// `FailurePresentation`; bounds: docs/06-cross-cutting.md §2
/// (`userMaximumUnpinnedRange` 1–5,000, default 200); retention:
/// docs/v2/V2-02-retention.md §3.1 (both-nil revision normalization),
/// §8.1 (action + receipt), §8.3 (admission ranges), §12 (receipt feedback);
/// UX: docs/v2/V2-07-ux.md §5.2, §6.3, §9 (accessibility).
/// SwiftUI over HistoryCore DTOs only — no AppKit, no SwiftData, and no
/// ServiceManagement (the login binding is wired by the ClipyApp
/// composition root, which owns SMAppService).
import Foundation
import HistoryCore
import SwiftUI

/// The Settings window content: a fixed 480×320 `TabView` with a General
/// and a Retention tab (step-9 design contract §4.4).
///
/// Both tabs open from the authoritative configured-policy read
/// (`V2-07` §6.3 — Apply is gated on it, audit SPEC-IMPL-003) and mutate
/// History through `HistoryViewState`, reporting the outcome inline —
/// success text derived from the action's
/// `HistoryCommitOutcome` (03a §6), failures mapped by
/// `FailurePresentation.message(for:)` (03b §10) or by the retention
/// recovery guidance (V2-07 §5.2). Nothing here reads SwiftData, Domain
/// state, or fingerprints; only immutable `Sendable` HistoryCore values
/// cross the view-state boundary (01 §6).
public struct ClipySettingsView: View {

    /// The shared panel view state (step-9 design contract §3); settings
    /// mutations ride the same `ClipboardHistory` seam and its observation
    /// loop refreshes the panel after every commit.
    private let viewState: HistoryViewState

    /// Neutral immutable state plus narrow intents from the ClipyApp-owned
    /// ServiceManagement controller. This target never imports that framework.
    private let launchAtLogin: LaunchAtLoginSettings?

    /// Non-`nil` only when the composition root owns a floating panel whose
    /// placement the user can configure (the geometry lives in ClipyApp —
    /// PresentationUI carries the mode value only).
    private let popupPosition: Binding<PopupPositionMode>?

    /// - Parameters:
    ///   - viewState: the shared interaction-state object (contract §3).
    ///   - launchAtLogin: when non-`nil`, the General tab shows the
    ///     "Launch at Login" state and controls; `nil` (previews, hosted
    ///     tests) omits the toggle entirely.
    ///   - popupPosition: when non-`nil`, the General tab shows the panel
    ///     position picker bound to it; `nil` omits the picker entirely.
    public init(
        viewState: HistoryViewState,
        launchAtLogin: LaunchAtLoginSettings? = nil,
        popupPosition: Binding<PopupPositionMode>? = nil
    ) {
        self.viewState = viewState
        self.launchAtLogin = launchAtLogin
        self.popupPosition = popupPosition
    }

    public var body: some View {
        TabView {
            GeneralSettingsTab(
                viewState: viewState,
                launchAtLogin: launchAtLogin,
                popupPosition: popupPosition
            )
                .tabItem { Label("General", systemImage: "gear") }
            RetentionSettingsTab(viewState: viewState)
                .tabItem { Label("Retention", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 480, height: 320)
    }
}

// MARK: General

/// General tab (contract §4.4): the v1 count policy, the optional
/// Launch-at-Login toggle, and the Danger Zone clears.
///
/// The count control stays on the v1 `.setRetentionPolicy` action — the
/// count dimension deliberately did not move to V2-02 (`V2-02` §1;
/// `V2-07` §5.2) — bounded by `HistoryLimits.standard
/// .userMaximumUnpinnedRange` (06 §2). The field opens at the persisted
/// configured count loaded on appear (`V2-07` §6.3's panel-open read;
/// audit SPEC-IMPL-003) — the §2 default (200) is only the pre-read
/// placeholder — and Apply stays disabled until that read lands, so a
/// failed load can never overwrite a real persisted policy with the
/// placeholder. Apply always sends the complete value.
private struct GeneralSettingsTab: View {

    private let viewState: HistoryViewState
    private let launchAtLogin: LaunchAtLoginSettings?
    private let popupPosition: Binding<PopupPositionMode>?

    /// Text backing the count field; parsed and range-checked on every use
    /// (Apply is disabled while invalid — contract §4.4 "numeric
    /// TextField + Stepper"). Opens at the §2 default as a placeholder;
    /// `loadConfiguredCount()` replaces it with the persisted value.
    @State private var maximumUnpinnedText: String =
        String(HistoryLimits.standard.defaultMaximumUnpinnedItems)

    /// False until the authoritative configured-policy read has landed on
    /// this tab; gates Apply (SPEC-IMPL-003).
    @State private var hasLoadedConfiguration = false

    @State private var status: SettingStatus?
    @State private var isWorking = false
    @State private var isConfirmingClearUnpinned = false
    @State private var isConfirmingClearAll = false

    init(
        viewState: HistoryViewState,
        launchAtLogin: LaunchAtLoginSettings?,
        popupPosition: Binding<PopupPositionMode>?
    ) {
        self.viewState = viewState
        self.launchAtLogin = launchAtLogin
        self.popupPosition = popupPosition
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Keep at most") {
                    HStack {
                        TextField("200", text: $maximumUnpinnedText)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Maximum unpinned items")
                        Stepper(
                            "",
                            value: maximumUnpinnedStepperValue,
                            in: HistoryLimits.standard.userMaximumUnpinnedRange
                        )
                        .labelsHidden()
                        .accessibilityLabel("Maximum unpinned items")
                        Text("unpinned items")
                    }
                }
                if maximumUnpinnedValue == nil {
                    Text(unpinnedRangeHint)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Apply") {
                        Task { await applyMaximumUnpinned() }
                    }
                    .disabled(
                        maximumUnpinnedValue == nil || isWorking
                            || !hasLoadedConfiguration
                    )
                    if let status {
                        SettingStatusView(status: status)
                    }
                }
                if let launchAtLogin {
                    launchAtLoginControl(launchAtLogin)
                }
                if let popupPosition {
                    Picker("Panel position", selection: popupPosition) {
                        ForEach(PopupPositionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
            }
            GroupBox("Danger Zone") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Clear Unpinned Items…") {
                        isConfirmingClearUnpinned = true
                    }
                    .disabled(isWorking)
                    .confirmationDialog(
                        "Remove all unpinned items?",
                        isPresented: $isConfirmingClearUnpinned,
                        titleVisibility: .visible
                    ) {
                        Button("Clear Unpinned Items", role: .destructive) {
                            Task { await performClear(.unpinned) }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                    Button("Clear All History…") {
                        isConfirmingClearAll = true
                    }
                    .disabled(isWorking)
                    .confirmationDialog(
                        "Remove every item, including pinned items?",
                        isPresented: $isConfirmingClearAll,
                        titleVisibility: .visible
                    ) {
                        Button("Clear All History", role: .destructive) {
                            Task { await performClear(.all) }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin?.refresh() }
        .task { await loadConfiguredCount() }
    }

    @ViewBuilder
    private func launchAtLoginControl(
        _ settings: LaunchAtLoginSettings
    ) -> some View {
        Toggle(
            "Launch at Login",
            isOn: Binding(
                get: { settings.isOn },
                set: { settings.setEnabled($0) }
            )
        )
        .disabled(!settings.canToggle)

        switch settings.state {
        case .off, .on:
            EmptyView()
        case .requiresApproval:
            HStack {
                Label(
                    "Approval is required in System Settings.",
                    systemImage: "person.badge.clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Open Login Items Settings") {
                    settings.openSystemSettings()
                }
            }
        case .unavailable:
            Label(
                "Launch at Login is unavailable for this app.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if settings.operationFailed {
            Label(
                "The Launch at Login setting couldn't be changed.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.red)
        }
    }

    /// The parsed count, or `nil` when the text is not a whole number
    /// inside `userMaximumUnpinnedRange` (06 §2).
    private var maximumUnpinnedValue: Int? {
        validatedWholeNumber(
            maximumUnpinnedText,
            in: HistoryLimits.standard.userMaximumUnpinnedRange
        )
    }

    /// Stepper binding: reads the typed value clamped into the §2 range
    /// (an out-of-range or unparseable field steps from the nearest legal
    /// state instead of refusing), writes back plain decimal text.
    private var maximumUnpinnedStepperValue: Binding<Int> {
        Binding<Int>(
            get: {
                guard let typed = Int(
                    maximumUnpinnedText.trimmingCharacters(in: .whitespaces)
                ) else {
                    return HistoryLimits.standard.defaultMaximumUnpinnedItems
                }
                let range = HistoryLimits.standard.userMaximumUnpinnedRange
                return min(max(typed, range.lowerBound), range.upperBound)
            },
            set: { maximumUnpinnedText = String($0) }
        )
    }

    private var unpinnedRangeHint: String {
        let range = HistoryLimits.standard.userMaximumUnpinnedRange
        return "Enter a whole number from \(range.lowerBound) to \(range.upperBound)."
    }

    /// Loads the persisted configured count so the field opens at the
    /// authoritative value (`V2-07` §6.3's panel-open one-shot read; audit
    /// SPEC-IMPL-003). Until the read lands, Apply stays disabled: a failed
    /// read leaves the placeholder visible but can never be applied over a
    /// real persisted policy. The V2-02 dimensions ride the same read but
    /// belong to the Retention tab (`V2-02` §1's count/expansion split).
    private func loadConfiguredCount() async {
        do {
            let configuration = try await viewState.retentionConfiguration()
            maximumUnpinnedText = String(configuration.maximumUnpinnedItems)
            hasLoadedConfiguration = true
        } catch let failure as HistoryFailure {
            status = .failure(FailurePresentation.message(for: failure))
        } catch {
            status = .failure("The current setting could not be read.")
        }
    }

    /// Applies the count policy and reports the receipt inline
    /// (`.retentionPolicySet(removedCount:)`, 03a §6; V2-07 §5.2).
    private func applyMaximumUnpinned() async {
        guard let count = maximumUnpinnedValue else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let receipt = try await viewState.applyMaximumUnpinnedItems(count)
            if case .committed(let commit) = receipt,
               case .retentionPolicySet(removedCount: let removed) = commit.outcome {
                status = .success(Self.maximumUnpinnedFeedback(removed))
            } else {
                status = .success("Done.")
            }
        } catch let failure as HistoryFailure {
            status = .failure(FailurePresentation.message(for: failure))
        } catch {
            status = .failure("The setting could not be saved.")
        }
    }

    /// Performs one Danger Zone clear (03a §5 `clear`/`ClearScope`).
    ///
    /// The awaitable view-state intent preserves the receipt needed for the
    /// mandated "Removed N items." feedback while keeping receipt-confirmed
    /// Card 9B surface purge publication at the shared mutation owner.
    private func performClear(_ scope: ClearScope) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let receipt = try await viewState.clearAwaitingReceipt(scope)
            if case .committed(let commit) = receipt,
               case .cleared(count: let removed) = commit.outcome {
                status = .success(Self.clearFeedback(removed))
            } else {
                status = .success("Done.")
            }
        } catch let failure as HistoryFailure {
            status = .failure(FailurePresentation.message(for: failure))
        } catch {
            status = .failure("The history could not be cleared.")
        }
    }

    /// "Done. N items removed." / "Done." — plural-aware (contract §4.4).
    private static func maximumUnpinnedFeedback(_ removedCount: Int) -> String {
        switch removedCount {
        case 0:
            return "Done."
        case 1:
            return "Done. 1 item removed."
        default:
            return "Done. \(removedCount) items removed."
        }
    }

    /// "Removed N items." — plural-aware; a no-op clear reports "Done."
    /// (contract §4.4).
    private static func clearFeedback(_ removedCount: Int) -> String {
        switch removedCount {
        case 0:
            return "Done."
        case 1:
            return "Removed 1 item."
        default:
            return "Removed \(removedCount) items."
        }
    }
}

// MARK: Retention

/// Retention tab — the unified V2-02 group (V2-07 §5.2/§6.3; DC-23): one
/// enable toggle + value field per dimension, all applied together via
/// `HistoryViewState.applyRetentionPolicies` (`.setRetentionPolicies`,
/// `V2-02` §8.1 — a set replaces the whole policy value).
///
/// Field bounds mirror the HistoryStorage admission ranges (`V2-02` §8.3)
/// one-for-one so Apply never sends a value storage will reject; disabling
/// a dimension sends `nil` for it (DC-23). Every control opens at the
/// persisted configured policy loaded on appear (`V2-07` §6.3's panel-open
/// read; audit SPEC-IMPL-003), and Apply stays disabled until that read
/// lands — an unexamined Apply against the neutral prefill could otherwise
/// silently wipe a real persisted policy. The read is the configured
/// policy only: no live usage readout exists on the public surface (the
/// OPEN-2 exclusion — V2-07 §5.2 "live storage indicator not available").
private struct RetentionSettingsTab: View {

    private let viewState: HistoryViewState

    /// Exact configured values plus whole-unit display text and edit
    /// generations. Keeping this as one value prevents one field from being
    /// rounded merely because another field was edited.
    @State private var draft = RetentionSettingsDraft()
    @State private var hasLoadedConfiguration = false
    @State private var status: SettingStatus?
    @State private var isWorking = false
    @State private var pendingSubmission: RetentionSettingsDraft.Submission?
    @State private var isConfirmingTightening = false

    init(viewState: HistoryViewState) {
        self.viewState = viewState
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Item age") {
                    Toggle("Limit item age", isOn: ageEnabled)
                        .accessibilityHint("Retire items whose last copy is older than the entered age.")
                    ValueFieldRow(
                        label: "Maximum item age",
                        unit: "days",
                        text: ageDaysText,
                        isEnabled: draft.ageEnabled,
                        isValid: draft.ageInputIsValid,
                        range: RetentionSettingsDraft.ageDaysRange
                    )
                }
                Section("Storage") {
                    Toggle("Limit storage budget", isOn: storageEnabled)
                        .accessibilityHint("Retire the oldest unpinned items until history fits the budget.")
                    ValueFieldRow(
                        label: "Storage budget",
                        unit: RetentionSettingsDraft.mebibyteUnitLabel,
                        text: storageMiBText,
                        isEnabled: draft.storageEnabled,
                        isValid: draft.storageInputIsValid,
                        range: RetentionSettingsDraft.storageMiBRange
                    )
                }
                Section("Revision limits") {
                    Toggle("Keep at most", isOn: revisionCountEnabled)
                        .accessibilityHint("Prune the oldest inactive revisions beyond this count.")
                    ValueFieldRow(
                        label: "Revisions per item",
                        unit: "revisions",
                        text: revisionCountText,
                        isEnabled: draft.revisionCountEnabled,
                        isValid: draft.revisionCountInputIsValid,
                        range: RetentionSettingsDraft.revisionCountRange
                    )
                    Toggle("Limit revision storage", isOn: revisionBytesEnabled)
                        .accessibilityHint("Prune the oldest inactive revisions until they fit this budget.")
                    ValueFieldRow(
                        label: "Revision storage per item",
                        unit: RetentionSettingsDraft.mebibyteUnitLabel,
                        text: revisionMiBText,
                        isEnabled: draft.revisionBytesEnabled,
                        isValid: draft.revisionBytesInputIsValid,
                        range: RetentionSettingsDraft.revisionMiBRange
                    )
                }
                Section {
                    HStack {
                        Button("Apply") {
                            requestApply()
                        }
                        .disabled(
                            !draft.inputIsValid || isWorking
                                || !hasLoadedConfiguration
                        )
                        .confirmationDialog(
                            "Apply stricter retention limits?",
                            isPresented: $isConfirmingTightening,
                            titleVisibility: .visible
                        ) {
                            Button("Apply Stricter Limits", role: .destructive) {
                                guard let submission = pendingSubmission else { return }
                                Task { await applyRetention(submission) }
                            }
                            Button("Cancel", role: .cancel) {
                                pendingSubmission = nil
                            }
                        } message: {
                            Text("Stricter limits can permanently remove items or revisions.")
                        }
                        if let status {
                            SettingStatusView(status: status)
                        }
                    }
                    Text("Changes apply to new and existing items at once.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding([.horizontal, .bottom])
        }
        .task { await loadConfiguredPolicies() }
    }

    private var ageEnabled: Binding<Bool> {
        Binding(
            get: { draft.ageEnabled },
            set: {
                draft.setAgeEnabled($0)
                status = nil
            }
        )
    }

    private var ageDaysText: Binding<String> {
        Binding(
            get: { draft.ageDaysText },
            set: {
                draft.setAgeDaysText($0)
                status = nil
            }
        )
    }

    private var storageEnabled: Binding<Bool> {
        Binding(
            get: { draft.storageEnabled },
            set: {
                draft.setStorageEnabled($0)
                status = nil
            }
        )
    }

    private var storageMiBText: Binding<String> {
        Binding(
            get: { draft.storageMiBText },
            set: {
                draft.setStorageMiBText($0)
                status = nil
            }
        )
    }

    private var revisionCountEnabled: Binding<Bool> {
        Binding(
            get: { draft.revisionCountEnabled },
            set: {
                draft.setRevisionCountEnabled($0)
                status = nil
            }
        )
    }

    private var revisionCountText: Binding<String> {
        Binding(
            get: { draft.revisionCountText },
            set: {
                draft.setRevisionCountText($0)
                status = nil
            }
        )
    }

    private var revisionBytesEnabled: Binding<Bool> {
        Binding(
            get: { draft.revisionBytesEnabled },
            set: {
                draft.setRevisionBytesEnabled($0)
                status = nil
            }
        )
    }

    private var revisionMiBText: Binding<String> {
        Binding(
            get: { draft.revisionMiBText },
            set: {
                draft.setRevisionMiBText($0)
                status = nil
            }
        )
    }

    /// Loads the persisted configured policies so every control opens at
    /// its authoritative value (`V2-07` §6.3's panel-open one-shot read;
    /// audit SPEC-IMPL-003). Until the read lands, Apply stays disabled: a
    /// set replaces the WHOLE policy value (`V2-02` §8.1), so applying the
    /// neutral prefill would silently disable every persisted dimension.
    private func loadConfiguredPolicies() async {
        do {
            let configuration = try await viewState.retentionConfiguration()
            draft.load(configuration.policies)
            hasLoadedConfiguration = true
        } catch let failure as HistoryFailure {
            status = .failure(Self.retentionFailureMessage(failure))
        } catch {
            status = .failure("The current policies could not be read.")
        }
    }

    private func requestApply() {
        guard let submission = draft.submission() else { return }
        if draft.requiresTighteningConfirmation(for: submission.policies) {
            pendingSubmission = submission
            isConfirmingTightening = true
        } else {
            Task { await applyRetention(submission) }
        }
    }

    /// Applies all dimensions as one policy value and reports the receipt
    /// inline (`.retentionPoliciesSet(retiredItems:prunedRevisions:)`,
    /// 03a §6 / `V2-02` §8.1; feedback per V2-07 §5.2).
    private func applyRetention(
        _ submission: RetentionSettingsDraft.Submission
    ) async {
        guard draft.isCurrent(submission) else { return }
        pendingSubmission = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let receipt = try await viewState.applyRetentionPolicies(submission.policies)
            guard draft.acceptApplied(submission) else { return }
            if case .committed(let commit) = receipt,
               case .retentionPoliciesSet(
                   retiredItems: let retired,
                   prunedRevisions: let pruned
               ) = commit.outcome {
                status = .success(
                    Self.retentionFeedback(retiredItems: retired, prunedRevisions: pruned)
                )
            } else {
                status = .success("Done.")
            }
        } catch let failure as HistoryFailure {
            guard draft.isCurrent(submission) else { return }
            status = .failure(Self.retentionFailureMessage(failure))
        } catch {
            guard draft.isCurrent(submission) else { return }
            status = .failure("The policies could not be saved.")
        }
    }

    /// "Done. N items retired, M revisions pruned." — plural-aware; a
    /// nothing-happened set reports plain "Done." (contract §4.4;
    /// transparent data-minimization feedback, `V2-02` §12).
    private static func retentionFeedback(retiredItems: Int, prunedRevisions: Int) -> String {
        if retiredItems == 0 && prunedRevisions == 0 {
            return "Done."
        }
        let retiredPhrase = retiredItems == 1 ? "1 item retired" : "\(retiredItems) items retired"
        let prunedPhrase = prunedRevisions == 1
            ? "1 revision pruned"
            : "\(prunedRevisions) revisions pruned"
        return "Done. \(retiredPhrase), \(prunedPhrase)."
    }

    /// Retention-specific recovery guidance (V2-07 §5.2): the set-time
    /// pinned-over-budget rejection and the unsatisfiable R2 budget carry
    /// their own text; every other failure falls through to the shared
    /// `FailurePresentation` mapping (03b §10).
    private static func retentionFailureMessage(_ failure: HistoryFailure) -> String {
        switch failure {
        case .invalidInput(.invalidRetentionPolicy):
            return "Pinned items exceed this budget. Unpin items or raise the budget."
        case .capacityExceeded(.storageBytes):
            return "This budget can't be satisfied with the current history."
        default:
            return FailurePresentation.message(for: failure)
        }
    }
}

// MARK: Shared helpers

/// One enable-gated numeric value row for the Retention tab: labeled
/// field + unit, disabled while its dimension is off, with the range hint
/// shown only while the enabled field's text is invalid (V2-07 §9 — the
/// field carries its own accessibility label; the caption is the
/// invalid-input state, never the only cue).
private struct ValueFieldRow: View {

    let label: String
    let unit: String
    @Binding var text: String
    let isEnabled: Bool
    let isValid: Bool
    let range: ClosedRange<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer(minLength: 12)
                TextField("", text: $text)
                    .frame(width: 88)
                    .multilineTextAlignment(.trailing)
                    .disabled(!isEnabled)
                    .accessibilityLabel(label)
                Text(unit)
                    .foregroundStyle(.secondary)
            }
            if isEnabled && !isValid {
                Text("Enter a whole number from \(range.lowerBound) to \(range.upperBound).")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// Inline outcome of one settings mutation: success carries receipt-derived
/// text, failure carries the already-mapped user-facing message.
private enum SettingStatus {
    case success(String)
    case failure(String)
}

/// One-line status rendering; the icon pairs with the text so the outcome
/// is never conveyed by color alone (V2-07 §9 point 3).
private struct SettingStatusView: View {

    let status: SettingStatus

    var body: some View {
        switch status {
        case .success(let message):
            Label(message, systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}

/// Parses a whole-number field, returning the value only when it lies
/// inside `range`. Strict `Int` parsing: decimals, empty text, and
/// out-of-range values return `nil`, which disables Apply and shows the
/// row's range hint (contract §4.4 validation).
private func validatedWholeNumber(_ text: String, in range: ClosedRange<Int>) -> Int? {
    guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else { return nil }
    return range.contains(value) ? value : nil
}

#Preview("Settings") {
    ClipySettingsView(
        viewState: HistoryViewState(history: PreviewClipboardHistory.populated),
        launchAtLogin: LaunchAtLoginSettings(state: .on)
    )
}
