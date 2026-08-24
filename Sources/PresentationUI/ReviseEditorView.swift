/// ReviseEditorView — the revision-authoring sheet for one item: one
/// decision (Keep Current / Use Original / Hide / Replace) per Canonical
/// representation, then one `HistoryAction.revise` through the view state.
/// The draft is built against
/// the Content Version the editor was opened on; storage enforces optimistic
/// concurrency (03a §5 `RevisionRequest.expected`), so an edit based on a
/// superseded state fails typed as `.staleContent` (03b §10), which this
/// view surfaces without dismissing or replacing the user's draft.
/// Owning spec: docs/03a-instruction-set.md §5 (`RevisionDraft`,
/// `RevisionDecision`, `.incoherentRevisionDraft`); detail DTOs
/// docs/03b-instruction-set.md §9; Main-actor UI docs/01-architecture.md §6;
/// roadmap: docs/roadmap/05-presentationui.md (step 9).
import ClipboardFormats
import Foundation
import HistoryCore
import SwiftUI

package enum ReviseEditorPresentation {
    /// Product decision 3D: Save never claims to redact Canonical Content or
    /// previously committed revisions.
    package static let revisionDisclosure =
        "Save appends an immutable revision. Previous and original content "
        + "may remain in this item's revision history."
}

/// The "Edit Content…" sheet (contract §4.3): 520×440, one decision row per
/// Canonical representation, and a footer with the coherence hint, Cancel,
/// and Save Revision. Saving maps every row onto one `RevisionDecision` and
/// submits a single `.replace(RevisionDraft(decisions:))` intent.
public struct ReviseEditorView: View {

    /// Alerts distinguish save and reload failures so a typed read failure is
    /// never mislabeled as a failed revision (03b §10; review Card 3B).
    private enum EditorAlert {
        case stale
        case saveFailure(String)
        case reloadFailure(String)
        case discardDraft

        var presentation: (title: String, message: String) {
            switch self {
            case .stale:
                return (
                    "Revision Not Saved",
                    "Edited content changed — your draft is intact. "
                        + "Reload Latest updates the base while keeping your "
                        + "edits for formats that are still editable."
                )
            case .saveFailure(let message):
                return ("Couldn't Save Revision", message)
            case .reloadFailure(let message):
                return ("Couldn't Reload Latest", message)
            case .discardDraft:
                return (
                    "Discard Changes?",
                    "Your unsaved changes will be lost."
                )
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    private let viewState: HistoryViewState

    /// Pure current-vs-canonical draft owner.  The view never translates
    /// "Keep Current" into HistoryCore actions itself.
    @State private var draft: ReviseEditorDraft

    @State private var isSaving = false
    @State private var isReloading = false
    @State private var reloadNotice: String?
    @State private var activeAlert: EditorAlert?

    public init(viewState: HistoryViewState, details: HistoryDetails) {
        self.viewState = viewState

        _draft = State(initialValue: ReviseEditorDraft(details: details))
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(
                        draft.canonicalRepresentations,
                        id: \.typeIdentifier
                    ) {
                        representation in
                        decisionRow(for: representation)
                    }
                }
                .padding(16)
            }
            Divider()
            revisionDisclosure
            reloadStatus
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
            alertActions
        } message: {
            Text(alertMessage)
        }
    }

    @ViewBuilder
    private var alertActions: some View {
        switch activeAlert {
        case .discardDraft:
            Button("Keep Editing", role: .cancel) {
                activeAlert = nil
            }
            Button("Discard Changes", role: .destructive) {
                activeAlert = nil
                dismiss()
            }
        case .stale:
            Button("Keep Editing", role: .cancel) {
                activeAlert = nil
            }
            Button("Reload Latest") {
                activeAlert = nil
                Task { await reloadLatest() }
            }
        case .reloadFailure:
            Button("Keep Editing", role: .cancel) {
                activeAlert = nil
            }
            Button("Retry Reload") {
                activeAlert = nil
                Task { await reloadLatest() }
            }
        case .saveFailure:
            Button("OK") {
                activeAlert = nil
            }
        case nil:
            EmptyView()
        }
    }

    /// Empty strings are observed only while the alert binding is false.
    private var alertPresentation: (title: String, message: String) {
        activeAlert?.presentation ?? ("", "")
    }

    private var alertTitle: String {
        alertPresentation.title
    }

    private var alertMessage: String {
        alertPresentation.message
    }

    // MARK: Footer

    /// Editing Effective Content is append-only: the captured Canonical
    /// Content and prior revisions are not erased by Save. This warning stays
    /// visible before submission so the editor cannot imply destructive
    /// redaction of sensitive clipboard bytes (review Card 3D).
    private var revisionDisclosure: some View {
        Label(
            ReviseEditorPresentation.revisionDisclosure,
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .accessibilityIdentifier("clipy.editor.revision-disclosure")
    }

    @ViewBuilder
    private var reloadStatus: some View {
        if draft.isAwaitingLatestContent {
            HStack(spacing: 12) {
                Label(
                    "Reload latest content before saving again.",
                    systemImage: "arrow.clockwise"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(isReloading ? "Reloading…" : "Reload Latest") {
                    Task { await reloadLatest() }
                }
                .disabled(isReloading)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        } else if let reloadNotice {
            Label(reloadNotice, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let validationMessage {
                Label(
                    validationMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    "Validation hint: \(validationMessage)"
                )
            }
            Spacer(minLength: 8)
            Button("Cancel") {
                requestDismissal()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityHint(
                draft.isDirty
                    ? "Asks before discarding unsaved changes."
                    : "Closes the editor without changing the item."
            )
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
            .disabled(!canSave || isSaving || isReloading)
            .accessibilityLabel(isSaving ? "Saving revision" : "Save Revision")
            .accessibilityHint(
                "Applies these decisions as a new revision of the item."
            )
        }
        .padding(12)
    }

    /// The draft must leave at least one representation effective. An
    /// unchanged Save remains a supported `.unchanged` History receipt;
    /// storage rejects an all-hidden draft as
    /// `.invalidInput(.incoherentRevisionDraft)` (03a §5).
    private var allRepresentationsHidden: Bool {
        draft.allRepresentationsHidden
    }

    private var canSave: Bool {
        draft.canSubmit
    }

    private var validationMessage: String? {
        if allRepresentationsHidden {
            return "Hiding every representation is not allowed"
        }
        if draft.hasEmptyReplacement {
            return "Replacement text cannot be empty"
        }
        return nil
    }

    /// Cancel and the `.cancelAction` keyboard shortcut share this intent so
    /// neither path can bypass dirty-draft confirmation (review Card 3C).
    private func requestDismissal() {
        switch draft.dismissalDecision {
        case .dismiss:
            dismiss()
        case .confirmDiscard:
            activeAlert = .discardDraft
        }
    }

    // MARK: Rows

    private func decisionRow(
        for representation: HistoryRepresentation
    ) -> some View {
        let typeIdentifier = representation.typeIdentifier
        let replacementIsAvailable = draft.canReplace(representation)
        let replacementAccessibilityHint = replacementIsAvailable
            ? " Replace substitutes literal UTF-8 plain text."
            : " Replace is unavailable because Clipy cannot safely decode"
                + " and re-encode this format yet."
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
                    if replacementIsAvailable {
                        // The first encoder-backed editing route is exact
                        // Exact UTF-8 plain text only (review TYPE-2).
                        Text("Replace").tag(ReviseEditorDraft.Choice.replace)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Editing decision for \(typeIdentifier)")
                .accessibilityIdentifier(
                    "clipy.editor.decision.\(typeIdentifier)"
                )
                .accessibilityHint(
                    "Keep Current preserves the bytes currently used for"
                        + " pasting. Use Original restores the captured bytes."
                        + " Hide omits this type from pasting."
                        + replacementAccessibilityHint
                )
            }
            if !replacementIsAvailable {
                Label(
                    "Replace unavailable: Clipy cannot safely decode and "
                        + "re-encode this format yet. Keep Current preserves "
                        + "its exact bytes.",
                    systemImage: "lock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    .accessibilityIdentifier(
                        "clipy.editor.replacement.\(typeIdentifier)"
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

    /// Saves the draft as one `.replace` revision. `.staleContent` leaves the
    /// sheet and byte-exact draft intact, then blocks another save until the
    /// user explicitly reloads. Success dismisses and observation refreshes
    /// the row list (03b §10; 04 §5; review Card 3B).
    @MainActor
    private func save() async {
        guard !isSaving, draft.canSubmit else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await viewState.revise(draft.revisionRequest())
            dismiss()
        } catch let failure as HistoryFailure {
            if case .staleContent = failure {
                draft.markStale()
                reloadNotice = nil
                activeAlert = .stale
            } else {
                activeAlert = .saveFailure(
                    FailurePresentation.message(for: failure)
                )
            }
        } catch {
            guard error is CancellationError else {
                activeAlert = .saveFailure(
                    "Clipy couldn't save this revision."
                )
                return
            }
        }
    }

    /// Fetches current details only after explicit user intent, then rebases
    /// the pure draft. It never auto-merges or submits. A typed read failure
    /// leaves the stale gate and all draft bytes untouched so Retry is safe.
    @MainActor
    private func reloadLatest() async {
        guard !isReloading, draft.isAwaitingLatestContent else { return }
        isReloading = true
        defer { isReloading = false }
        do {
            let latest = try await viewState.details(for: draft.itemID)
            guard draft.reloadLatest(details: latest) else {
                activeAlert = .reloadFailure(
                    "Latest content can't be safely rebased onto this draft. "
                        + "Your edits are intact; keep editing or try again "
                        + "after the item changes."
                )
                return
            }
            reloadNotice = "Latest content loaded. Your draft was kept for "
                + "formats that remain editable."
        } catch let failure as HistoryFailure {
            activeAlert = .reloadFailure(
                FailurePresentation.message(for: failure)
            )
        } catch {
            guard error is CancellationError else {
                activeAlert = .reloadFailure(
                    "Clipy couldn't load the latest content."
                )
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
                typeIdentifier: ClipboardFormatIdentifier.utf8PlainText.rawValue,
                bytes: Data("Meeting notes — first line\nSecond line".utf8)
            ),
            HistoryRepresentation(
                typeIdentifier: ClipboardFormatIdentifier.html.rawValue,
                bytes: Data("<p>Meeting notes</p>".utf8)
            ),
        ],
        effective: [
            HistoryRepresentation(
                typeIdentifier: ClipboardFormatIdentifier.utf8PlainText.rawValue,
                bytes: Data("Meeting notes — first line".utf8)
            ),
        ],
        revisions: [
            RevisionSummary(
                id: RevisionID(rawValue: UUID()),
                createdAt: Date(timeIntervalSinceNow: -3_600),
                isActive: true,
                title: "Meeting notes — first line",
                typeIdentifiers: [
                    ClipboardFormatIdentifier.utf8PlainText.rawValue,
                ],
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
