import Foundation
import SwiftUI

/// Visual steps and editable rule text are two presentations of the existing
/// tree. Text stays a separate draft until a complete parse can replace it.
/// Owning semantics: docs/v2/V2-13-workflow-rule-syntax.md.
struct WorkflowStepsWorkspaceEditor: View {
    let workflowID: UUID
    @Binding var steps: [BuiltInAutomationStep]
    let state: WorkflowStepsEditorState
    let bundle: Bundle

    var body: some View {
        Group {
            if let draft = state.draft(for: workflowID) {
                WorkflowStepsDraftEditor(steps: $steps, draft: draft, bundle: bundle)
                    .id(workflowID)
            } else {
                ProgressView()
            }
        }
        .onChange(of: workflowID, initial: true) { _, id in state.prepare(id, steps: steps) }
        .onChange(of: steps) { _, value in state.prepare(workflowID, steps: value) }
    }
}

private struct WorkflowStepsDraftEditor: View {
    @Binding var steps: [BuiltInAutomationStep]
    let draft: WorkflowStepsEditorDraft
    let bundle: Bundle
    @State private var confirmsReload = false
    @State private var confirmsReplacingVisualSteps = false
    @State private var showsReference = false
    @State private var applyRequest = 0
    @State private var requestedSelection: NSRange?
    @State private var selectionRequestID: UUID?

    private func text(_ key: String) -> String { WorkflowSyntaxCopy.text(key, bundle: bundle) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(text("Step editing mode"), selection: Binding(get: { draft.mode }, set: { draft.setMode($0) })) {
                Text(text("Visual steps")).tag(WorkflowStepsDisplayMode.visual)
                    .accessibilityIdentifier("clipy.workflow.steps.visual")
                Text(text("Rule text")).tag(WorkflowStepsDisplayMode.syntax)
                    .accessibilityIdentifier("clipy.workflow.steps.syntax")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)
            .disabled(draft.isProcessing)
            .accessibilityIdentifier("clipy.workflow.steps.mode")

            if draft.mode == .visual {
                if draft.hasUnappliedChanges {
                    Label(text("Rule text has unapplied changes. Return to Rule text to apply or discard them before saving."),
                          systemImage: "pencil.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("clipy.workflow.syntax.pending")
                }
                BuiltInAutomationStepsEditor(steps: $steps, bundle: bundle)
            } else {
                syntaxEditor
            }
        }
        .task(id: draft.renderRequest) { await draft.prepareSourceIfNeeded() }
        .task(id: applyRequest) {
            guard applyRequest > 0 else { return }
            let priorSteps = steps
            if let parsed = await draft.parseSource(), steps == priorSteps {
                steps = parsed
                draft.acceptApplied(parsed)
            }
        }
        .confirmationDialog(text("Reload rule text from visual steps?"), isPresented: $confirmsReload) {
            Button(text("Discard rule text and reload"), role: .destructive) { draft.requestReload() }
            Button(text("Cancel"), role: .cancel) {}
        } message: {
            Text(text("This replaces the unapplied rule text for this workflow. Its visual steps stay unchanged."))
        }
        .confirmationDialog(text("Replace the changed visual steps?"), isPresented: $confirmsReplacingVisualSteps) {
            Button(text("Apply rule text")) { applyRequest += 1 }
            Button(text("Cancel"), role: .cancel) {}
        } message: {
            Text(text("Visual steps changed after this rule draft was created. Applying valid rule text replaces those visual edits."))
        }
    }

    private var syntaxEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text("Clipy rules use indentation and if/else blocks. This is not Python: only the actions and conditions listed below are accepted."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if draft.hasPreparedSource {
                BuiltInAutomationSourceEditor(
                    text: Binding(get: { draft.source }, set: { draft.updateSource($0) }),
                    accessibilityLabel: text("Workflow rule text"),
                    isEditable: !draft.isProcessing,
                    accessibilityIdentifier: "clipy.workflow.syntax.source",
                    requestedSelection: requestedSelection,
                    selectionRequestID: selectionRequestID,
                    usesRuleIndentation: true
                )
                .frame(minHeight: 220, idealHeight: 320)
            }
            if draft.isProcessing {
                ProgressView(text("Checking rule text…"))
                    .controlSize(.small)
            }
            if let diagnostic = draft.diagnostic {
                HStack(alignment: .top, spacing: 8) {
                    Label(draft.diagnosticIsInSource
                        ? String(format: text("Line %lld, column %lld: %@"), Int64(diagnostic.line),
                            Int64(diagnostic.column), BuiltInAutomationCopy.text(diagnostic.message, bundle: bundle))
                        : BuiltInAutomationCopy.text(diagnostic.message, bundle: bundle),
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("clipy.workflow.syntax.error")
                    if draft.hasPreparedSource && draft.diagnosticIsInSource {
                        Button(text("Go to error")) {
                            requestedSelection = WorkflowSyntaxLocation.selection(in: draft.source,
                                line: diagnostic.line, column: diagnostic.column)
                            selectionRequestID = UUID()
                        }
                        .accessibilityIdentifier("clipy.workflow.syntax.go-to-error")
                    }
                }
            }
            if let message = draft.failureMessage {
                Label(text(message), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
            }
            if draft.hasVisualConflict {
                Label(text("Visual steps changed while this rule text was pending. Applying it will replace those visual edits."),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button(text("Apply rule text")) {
                    if draft.hasVisualConflict { confirmsReplacingVisualSteps = true }
                    else { applyRequest += 1 }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.hasUnappliedChanges || draft.isProcessing)
                .accessibilityIdentifier("clipy.workflow.syntax.apply")
                Button(text("Reload from visual steps")) {
                    if draft.hasUnappliedChanges { confirmsReload = true }
                    else { draft.requestReload() }
                }
                .disabled(draft.isProcessing)
                .accessibilityIdentifier("clipy.workflow.syntax.reload")
                Spacer(minLength: 0)
                if draft.didApplySource {
                    Label(text("Applied to visual steps"), systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("clipy.workflow.syntax.applied")
                } else if draft.hasUnappliedChanges {
                    Text(text("Unapplied rule text")).font(.caption).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup(text("Rule syntax reference"), isExpanded: $showsReference) {
                syntaxReference.padding(.top, 6)
            }
            .disclosureGroupStyle(AppDisclosureGroupStyle(identifier: "clipy.workflow.syntax.reference"))
        }
    }

    private var syntaxReference: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("Use four spaces per indentation level. Tab inserts four spaces, and Return continues the current indentation."))
            Text(verbatim: "if is_text() and contains(\"TODO\"):\n    replace(\"TODO\", \"Done\")\nelse:\n    trim()")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text(text("Conditions can combine is_text(), is_image(), contains(\"text\") and matches(\"pattern\") with and, or, not and parentheses."))
            Text(text("Actions use stable English names, even when Clipy’s interface language changes. Wrap steps in a disabled: block to keep them without running them; use pass for an empty branch."))
            Text(verbatim: "trim() · trim_lines() · remove_empty_lines() · unique_lines() · sort_lines()\nuppercase() · lowercase() · pretty_json() · compact_json()\nreplace(\"find\", \"replacement\") · regex_replace(\"pattern\", \"replacement\")\nregex_extract(\"pattern\") · recognize_text() · notify()")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(text("A require_text(), require_image(), require_contains(\"text\") or require_matches(\"pattern\") guard stops the workflow when it does not match. Use an if block to choose between branches instead."))
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

enum WorkflowSyntaxCopy {
    static func text(_ english: String, bundle: Bundle = AppLocalization.bundle) -> String {
        bundle.localizedString(forKey: english, value: english, table: "WorkflowSyntax")
    }
}
