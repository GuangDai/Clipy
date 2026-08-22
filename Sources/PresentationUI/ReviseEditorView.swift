/// ReviseEditorView — the revision-authoring sheet for one item: one
/// decision (Keep Current / Use Original / Hide / Replace) per Canonical
/// representation, then one `HistoryAction.revise` through the view state.
/// The draft is built against
/// the Content Version the editor was opened on; storage enforces optimistic
/// concurrency (03a §5 `RevisionRequest.expected`), so an edit based on a
/// superseded state fails typed as `.staleContent` (03b §10), which this
/// view surfaces as an alert and a dismissal.
/// Owning spec: docs/03a-instruction-set.md §5 (`RevisionDraft`,
/// `RevisionDecision`, `.incoherentRevisionDraft`); detail DTOs
/// docs/03b-instruction-set.md §9; Main-actor UI docs/01-architecture.md §6;
/// roadmap: docs/roadmap/05-presentationui.md (step 9).
import Foundation
import HistoryCore
import SwiftUI

/// The "Edit Content…" sheet (contract §4.3): 520×440, one decision row per
/// Canonical representation, and a footer with the coherence hint, Cancel,
/// and Save Revision. Saving maps every row onto one `RevisionDecision` and
/// submits a single `.replace(RevisionDraft(decisions:))` intent.
public struct ReviseEditorView: View {

    /// The single alert this sheet can raise: a stale base version or a
    /// typed failure message (03b §10).
    private enum EditorAlert {
        case stale
        case failure(String)
    }

    @Environment(\.dismiss) private var dismiss

    private let viewState: HistoryViewState
    private let details: HistoryDetails

    /// Pure current-vs-canonical draft owner.  The view never translates
    /// "Keep Current" into HistoryCore actions itself.
    @State private var draft: ReviseEditorDraft

    @State private var isSaving = false
    @State private var activeAlert: EditorAlert?

    public init(viewState: HistoryViewState, details: HistoryDetails) {
        self.viewState = viewState
        self.details = details

        _draft = State(initialValue: ReviseEditorDraft(details: details))
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(details.canonical, id: \.typeIdentifier) {
                        representation in
                        decisionRow(for: representation)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 440)
        .alert(
            alertTitle,
            isPresented: Binding(
                get: { activeAlert != nil },
                set: { if !$0 { activeAlert = nil } }
            )
        ) {
            Button("OK") {
                if case .stale? = activeAlert {
                    dismiss()
                }
                activeAlert = nil
            }
        } message: {
            Text(alertMessage)
        }
    }

    /// The alert title for the current alert state (03b §10 mapping).
    private var alertTitle: String {
        switch activeAlert {
        case .stale:
            return "Revision Not Saved"
        case .failure:
            return "Couldn't Save Revision"
        case nil:
            return ""
        }
    }

    /// The alert message for the current alert state — the contract string
    /// for a stale base version, `FailurePresentation` otherwise.
    private var alertMessage: String {
        switch activeAlert {
        case .stale:
            return "Edited content changed — your edit was not saved."
        case .failure(let message):
            return message
        case nil:
            return ""
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if allRepresentationsHidden {
                Label(
                    "Hiding every representation is not allowed",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    "Validation hint: hiding every representation is not"
                        + " allowed"
                )
            }
            Spacer(minLength: 8)
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityHint("Closes the editor without changing the item.")
            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    Label("Saving…", systemImage: "hourglass")
                } else {
                    Label("Save Revision", systemImage: "checkmark")
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!canSave || isSaving)
            .accessibilityLabel(isSaving ? "Saving revision" : "Save Revision")
            .accessibilityHint(
                "Applies these decisions as a new revision of the item."
            )
        }
        .padding(12)
    }

    /// The draft must leave at least one representation effective: storage
    /// rejects an all-hidden draft as `.invalidInput(.incoherentRevisionDraft)`
    /// (03a §5), so Save is disabled and the hint shows in exactly that
    /// state.
    private var allRepresentationsHidden: Bool {
        draft.allRepresentationsHidden
    }

    private var canSave: Bool {
        !allRepresentationsHidden
    }

    // MARK: Rows

    private func decisionRow(
        for representation: HistoryRepresentation
    ) -> some View {
        let typeIdentifier = representation.typeIdentifier
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(typeIdentifier)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(
                        EditorFormat.bytes.string(
                            fromByteCount: Int64(representation.bytes.count)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker(
                    "Decision",
                    selection: choiceBinding(for: typeIdentifier)
                ) {
                    Text("Keep Current").tag(ReviseEditorDraft.Choice.keepCurrent)
                    Text("Use Original").tag(ReviseEditorDraft.Choice.useOriginal)
                    Text("Hide").tag(ReviseEditorDraft.Choice.hide)
                    if draft.canReplace(representation) {
                        // Replace is text-only: the editor's payload is one
                        // UTF-8 string per type (03a §5 `.replace(bytes:)`).
                        Text("Replace").tag(ReviseEditorDraft.Choice.replace)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Editing decision for \(typeIdentifier)")
                .accessibilityHint(
                    "Keep Current preserves the bytes currently used for"
                        + " pasting. Use Original restores the captured bytes."
                        + " Hide omits this type from pasting."
                        + " Replace substitutes edited text."
                )
            }
            if draft.choice(for: typeIdentifier) == .replace {
                TextEditor(text: textBinding(for: typeIdentifier))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 96)
                    .padding(4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.15))
                    }
                    .accessibilityLabel(
                        "Replacement text for \(typeIdentifier)"
                    )
            }
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func choiceBinding(
        for typeIdentifier: String
    ) -> Binding<ReviseEditorDraft.Choice> {
        Binding(
            get: { draft.choice(for: typeIdentifier) },
            set: { draft.setChoice($0, for: typeIdentifier) }
        )
    }

    private func textBinding(for typeIdentifier: String) -> Binding<String> {
        Binding(
            get: { draft.replacementText(for: typeIdentifier) },
            set: { draft.setReplacementText($0, for: typeIdentifier) }
        )
    }

    // MARK: Save

    /// Saves the draft as one `.replace` revision. `.staleContent` alerts
    /// and dismisses (the base version is gone); any other typed failure
    /// shows its `FailurePresentation` message (03b §10); success dismisses
    /// — the observation loop refreshes the row list (04 §5).
    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await viewState.revise(draft.revisionRequest())
            dismiss()
        } catch let failure as HistoryFailure {
            if case .staleContent = failure {
                activeAlert = .stale
            } else {
                activeAlert = .failure(
                    FailurePresentation.message(for: failure)
                )
            }
        } catch {
            guard error is CancellationError else {
                activeAlert = .failure("Clipy couldn't save this revision.")
                return
            }
        }
    }
}

// MARK: - Private helpers (file-scoped)

/// Main-actor-cached byte formatter (Foundation formatters are not Sendable;
/// they stay confined to the UI actor, 01 §6).
@MainActor
private enum EditorFormat {
    static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

#if DEBUG
// Preview builds DTOs through the package-visible inits (03a §3
// scripted-preview allowance); the view state stub performs no writes.
#Preview {
    ReviseEditorView(
        viewState: HistoryViewState(history: PreviewClipboardHistory.empty),
        details: editorPreviewDetails()
    )
}

private func editorPreviewDetails() -> HistoryDetails {
    HistoryDetails(
        item: HistoryItemReference(
            id: HistoryItemID(rawValue: UUID()),
            contentVersion: ContentVersion(rawValue: 2)
        ),
        canonical: [
            HistoryRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("Meeting notes — first line\nSecond line".utf8)
            ),
            HistoryRepresentation(
                typeIdentifier: "public.html",
                bytes: Data("<p>Meeting notes</p>".utf8)
            ),
        ],
        effective: [
            HistoryRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("Meeting notes — first line".utf8)
            ),
        ],
        revisions: [
            RevisionSummary(
                id: RevisionID(rawValue: UUID()),
                createdAt: Date(timeIntervalSinceNow: -3_600),
                isActive: true,
                title: "Meeting notes — first line",
                typeIdentifiers: ["public.utf8-plain-text"],
                byteCount: 27
            ),
        ],
        occurrence: CopyOccurrenceSummary(
            firstCopiedAt: Date(timeIntervalSinceNow: -3_600),
            lastCopiedAt: Date(timeIntervalSinceNow: -600),
            count: 2,
            firstSource: "com.apple.Notes",
            lastSource: "com.apple.Notes"
        ),
        pinnedPosition: nil
    )
}
#endif
