import Foundation
import HistoryCore
import SwiftUI

// MARK: Shared helpers

/// One adaptive numeric value row for the Retention tab: labeled field and
/// unit, with the range hint
/// shown only while the enabled field's text is invalid (V2-07 §9 — the
/// field carries its own accessibility label; the caption is the
/// invalid-input state, never the only cue).
struct ValueFieldRow: View {

    let label: String
    let unit: String
    let accessibilityIdentifier: String
    @Binding var text: String
    let isEnabled: Bool
    let isValid: Bool
    let range: ClosedRange<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsFieldLayout {
                Text(label)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("", text: $text)
                        .frame(minWidth: 96, idealWidth: 120, maxWidth: 180)
                        .multilineTextAlignment(.trailing)
                        .disabled(!isEnabled)
                        .accessibilityLabel(label)
                        .accessibilityIdentifier(accessibilityIdentifier)
                    Text(unit)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isEnabled && !isValid {
                Text(
                    RetentionSettingsCopy.rangeHint(
                        from: range.lowerBound,
                        to: range.upperBound
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// One label/control pair that stacks when its natural widths do not fit.
/// Both layouts use the same subviews, so resizing never replaces the live
/// TextField or its selection. No window-width breakpoint or duplicate field.
struct SettingsFieldLayout: Layout {
    private let columnSpacing: CGFloat = 20
    private let rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let values = measurements(proposal: proposal, subviews: subviews)
        return CGSize(width: values.width, height: values.stacked
            ? values.label.height + rowSpacing + values.control.height
            : max(values.label.height, values.control.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let values = measurements(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        if values.stacked {
            subviews[0].place(at: bounds.origin, anchor: .topLeading,
                proposal: ProposedViewSize(values.label))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + values.label.height + rowSpacing),
                anchor: .topLeading, proposal: ProposedViewSize(values.control))
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY - values.label.height / 2),
                anchor: .topLeading, proposal: ProposedViewSize(values.label))
            subviews[1].place(at: CGPoint(x: bounds.maxX - values.control.width, y: bounds.midY - values.control.height / 2),
                anchor: .topLeading, proposal: ProposedViewSize(values.control))
        }
    }

    private func measurements(proposal: ProposedViewSize, subviews: Subviews)
        -> (width: CGFloat, stacked: Bool, label: CGSize, control: CGSize) {
        let label = subviews[0].sizeThatFits(.unspecified)
        let control = subviews[1].sizeThatFits(.unspecified)
        let naturalWidth = label.width + columnSpacing + control.width
        let width = proposal.width ?? naturalWidth
        if naturalWidth <= width { return (width, false, label, control) }
        let stackedProposal = ProposedViewSize(width: width, height: nil)
        return (width, true, subviews[0].sizeThatFits(stackedProposal), subviews[1].sizeThatFits(stackedProposal))
    }
}

/// Inline outcome of one settings mutation: success carries receipt-derived
/// text, failure carries the already-mapped user-facing message. Internal
/// (not private) so the SwiftPM suites pin the receipt-feedback mapping
/// directly through `@testable`, like `validatedSettingsWholeNumber`.
internal enum SettingStatus: Equatable {
    case success(String)
    case failure(String)
}

/// One-line status rendering; the icon pairs with the text so the outcome
/// is never conveyed by color alone (V2-07 §9 point 3).
struct SettingStatusView: View {

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

// MARK: Receipt feedback

/// Exact per-receipt feedback for one Danger Zone clear (deep review Card
/// 10): a committed clear reports its removed count ("Removed N items." —
/// plural-aware, 03a §6); `.unchanged` means the scope matched nothing, so
/// no History Commit exists and no removal is implied (02 §8); a commit
/// carrying another action's outcome is a boundary violation, rendered as a
/// failure rather than a blanket success. Copy resolves through
/// `RetentionSettingsCopy` (V2-07 §10; the count phrase varies by plural in
/// the package String Catalog per §10.4).
internal func clearStatusFeedback(_ receipt: HistoryReceipt) -> SettingStatus {
    switch receipt {
    case .committed(let commit):
        guard case .cleared(count: let removed) = commit.outcome else {
            return .failure(RetentionSettingsCopy.clearFailure)
        }
        switch removed {
        case 0:
            return .success(RetentionSettingsCopy.feedbackDone)
        default:
            return .success(RetentionSettingsCopy.clearedItemsRemoved(removed))
        }
    case .unchanged:
        return .success(RetentionSettingsCopy.feedbackNothingToClear)
    }
}

/// Exact per-receipt feedback for one item-count apply (deep review Card
/// 10): a committed `.setRetentionPolicy` reports its removed count
/// ("Done. N items removed." — plural-aware, 03a §6; V2-07 §5.2);
/// `.unchanged` means the submitted count already equals the persisted
/// value and nothing was written (02 §8/§12); a commit carrying another
/// action's outcome is a boundary violation, rendered as a failure rather
/// than a blanket success. Copy resolves through `RetentionSettingsCopy`
/// (V2-07 §10; the count phrase varies by plural in the package String
/// Catalog per §10.4).
internal func maximumUnpinnedStatusFeedback(
    _ receipt: HistoryReceipt
) -> SettingStatus {
    switch receipt {
    case .committed(let commit):
        guard case .retentionPolicySet(removedCount: let removed)
                = commit.outcome else {
            return .failure(RetentionSettingsCopy.countSaveFailure)
        }
        switch removed {
        case 0:
            return .success(RetentionSettingsCopy.feedbackDone)
        default:
            return .success(RetentionSettingsCopy.countLimitItemsRemoved(removed))
        }
    case .unchanged:
        return .success(RetentionSettingsCopy.feedbackNoChange)
    }
}

/// Exact per-receipt feedback for one V2-02 policy apply (deep review Card
/// 10): a committed `.setRetentionPolicies` reports retired items and
/// pruned revisions separately ("Done. N items retired, M revisions
/// pruned." — plural-aware; transparent data-minimization feedback,
/// `V2-02` §12); `.unchanged` means the submitted bundle already equals
/// the persisted policy and nothing was written (`V2-02` §4.4/§5.6); a
/// commit carrying another action's outcome is a boundary violation,
/// rendered as a failure rather than a blanket success. Copy resolves
/// through `RetentionSettingsCopy` (V2-07 §10; both phrases vary by plural
/// in the package String Catalog per §10.4).
internal func retentionPoliciesStatusFeedback(
    _ receipt: HistoryReceipt
) -> SettingStatus {
    switch receipt {
    case .committed(let commit):
        guard case .retentionPoliciesSet(
            retiredItems: let retired,
            prunedRevisions: let pruned
        ) = commit.outcome else {
            return .failure(RetentionSettingsCopy.policiesSaveFailure)
        }
        if retired == 0 && pruned == 0 {
            return .success(RetentionSettingsCopy.feedbackDone)
        }
        return .success(RetentionSettingsCopy.appliedSummary(
            retiredPhrase: RetentionSettingsCopy.itemsRetired(retired),
            prunedPhrase: RetentionSettingsCopy.revisionsPruned(pruned)
        ))
    case .unchanged:
        return .success(RetentionSettingsCopy.feedbackNoChange)
    }
}

#Preview("Settings") {
    ClipySettingsView(
        viewState: HistoryViewState(history: PreviewClipboardHistory.populated),
        launchAtLogin: LaunchAtLoginSettings(state: .on),
        summonShortcut: SummonShortcutSettings(
            status: .current("⇧⌘C"),
            warning: .showColorsConflict
        ),
        popupPosition: .constant(.cursor)
    )
}
