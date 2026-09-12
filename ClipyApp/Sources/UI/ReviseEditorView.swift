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

enum ReviseEditorPresentation {
    /// Product decision 3D: Save never claims to redact Canonical Content or
    /// previously committed revisions.
    static func revisionDisclosure(bundle: Bundle = .main) -> String {
        PanelActionsCopy.revisionDisclosure(bundle: bundle)
    }

    static func formatIndependenceDisclosure(bundle: Bundle = .main) -> String {
        PanelActionsCopy.text(
            "Editing one format leaves other kept formats unchanged. The destination app may use those formats instead.",
            bundle: bundle
        )
    }
}

/// The "Edit Content…" surface (contract §4.3) fills its host, with an ideal
/// standalone size and a text area that grows with the available height. It
/// renders one decision row per Canonical representation and a footer with
/// the coherence hint, Cancel, and Save Revision. Saving maps every row onto
/// one `RevisionDecision` and submits one `.replace` intent.
struct ReviseEditorView: View {
    private enum Layout: Equatable {
        case standaloneSheet
        case embeddedInDetails
    }

    /// Alerts distinguish save and reload failures so a typed read failure is
    /// never mislabeled as a failed revision (03b §10; review Card 3B).
    private enum EditorAlert {
        case stale
        case saveFailure(HistoryFailure?)
        case reloadFailure(HistoryFailure?)
        case incompatibleReload
        case discardDraft

        func presentation(bundle copyBundle: Bundle) -> (title: String, message: String) {
            switch self {
            case .stale:
                return (
                    PanelActionsCopy.text("Revision Not Saved", bundle: copyBundle),
                    PanelActionsCopy.text("Edited content changed — your draft is intact. Reload Latest updates the base while keeping your edits for formats that are still editable.", bundle: copyBundle)
                )
            case .saveFailure(let failure):
                return (
                    PanelActionsCopy.text("Couldn't Save Revision", bundle: copyBundle),
                    failure.map { FailurePresentation.message(for: $0, bundle: copyBundle) }
                        ?? PanelActionsCopy.text("Clipy couldn't save this revision.", bundle: copyBundle)
                )
            case .reloadFailure(let failure):
                return (
                    PanelActionsCopy.text("Couldn't Reload Latest", bundle: copyBundle),
                    failure.map { FailurePresentation.message(for: $0, bundle: copyBundle) }
                        ?? PanelActionsCopy.text("Clipy couldn't load the latest content.", bundle: copyBundle)
                )
            case .incompatibleReload:
                return (
                    PanelActionsCopy.text("Couldn't Reload Latest", bundle: copyBundle),
                    PanelActionsCopy.text("Latest content can't be safely rebased onto this draft. Your edits are intact; keep editing or try again after the item changes.", bundle: copyBundle)
                )
            case .discardDraft:
                return (
                    PanelActionsCopy.text("Discard Changes?", bundle: copyBundle),
                    PanelActionsCopy.text("Your unsaved changes will be lost.", bundle: copyBundle)
                )
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }

    private let viewState: HistoryViewState
    private let onDismiss: (@MainActor () -> Void)?
    private let onReferenceAdvance:
        (@MainActor (HistoryItemReference) -> Void)?
    private let layout: Layout

    /// Pure current-vs-canonical draft owner.  The view never translates
    /// "Keep Current" into HistoryCore actions itself.
    @State private var draft: ReviseEditorDraft

    @State private var isSaving = false
    @State private var isReloading = false
    @State private var reloadTask: Task<Void, Never>?
    @State private var replacementTask: Task<Void, Never>?
    @State private var replacementFailure: String?
    @State private var replacementType: RepresentationIdentity?
    @State private var readFence: HistoryDetailsLoadFence
    /// A fixed product-copy key, localized at render time rather than
    /// retaining the language active when the reload completed.
    @State private var reloadNotice: String?
    @State private var activeAlert: EditorAlert?
    @FocusState private var focusedReplacement: RepresentationIdentity?

    init(viewState: HistoryViewState, details: HistoryDetails) {
        self.viewState = viewState
        self.onDismiss = nil
        self.onReferenceAdvance = nil
        self.layout = .standaloneSheet

        _draft = State(initialValue: ReviseEditorDraft(details: details))
        _readFence = State(initialValue: HistoryDetailsLoadFence(baselinePurgeGeneration: viewState.surfacePurge?.generation ?? 0))
    }

    /// The production floating panel's main column is user-resizable.
    /// Its editor fills the available
    /// Details surface without imposing the standalone sheet's ideal size.
    init(
        viewState: HistoryViewState,
        details: HistoryDetails,
        onDismiss: @escaping @MainActor () -> Void,
        onReferenceAdvance:
            @escaping @MainActor (HistoryItemReference) -> Void
    ) {
        self.viewState = viewState
        self.onDismiss = onDismiss
        self.onReferenceAdvance = onReferenceAdvance
        self.layout = .embeddedInDetails

        _draft = State(initialValue: ReviseEditorDraft(details: details))
        _readFence = State(initialValue: HistoryDetailsLoadFence(baselinePurgeGeneration: viewState.surfacePurge?.generation ?? 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: PanelTheme.spacingLarge) {
                    if draft.canonicalRepresentations.count > 1 {
                        DisclosureGroup(DetailsPresentationCopy.text("About Formats", bundle: copyBundle)) {
                            Text(
                                ReviseEditorPresentation.formatIndependenceDisclosure(bundle: copyBundle)
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("clipy.editor.format-independence-disclosure")
                        }
                        .disclosureGroupStyle(AppDisclosureGroupStyle(identifier: "clipy.editor.about-formats"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    ForEach(
                        draft.canonicalRepresentations,
                        id: \.representationIdentity
                    ) {
                        representation in
                        decisionRow(for: representation)
                    }
                }
                .padding(PanelTheme.spacingXLarge)
            }
            Divider()
            revisionDisclosure
            reloadStatus
            if replacementTask != nil {
                ProgressView(PanelActionsCopy.text("Loading…", bundle: copyBundle))
                    .padding(.horizontal)
            }
            if let replacementFailure {
                HStack {
                    Text(replacementFailure).font(.caption)
                    Button(PanelActionsCopy.text("Retry", bundle: copyBundle)) {
                        if let replacementType { loadReplacement(for: replacementType.typeIdentifier, pasteboardItemIndex: replacementType.pasteboardItemIndex) }
                    }
                }.padding(.horizontal)
            }
            footer
        }
        .frame(
            minWidth: layout == .standaloneSheet ? 360 : nil,
            idealWidth: layout == .standaloneSheet ? 640 : nil,
            maxWidth: .infinity,
            minHeight: layout == .standaloneSheet ? 360 : nil,
            idealHeight: layout == .standaloneSheet ? 520 : nil,
            maxHeight: .infinity
        )
        .interactiveDismissDisabled(draft.isDirty || isSaving)
        .onDisappear {
            cancelReplacementLoad()
            cancelReload()
        }
        .alert(
            alertTitle,
            isPresented: Binding(
                get: { activeAlert != nil },
                set: { if !$0 { activeAlert = nil } }
            )
        ) {
            alertActions
        } message: {
            Text(verbatim: alertMessage)
        }
    }

    @ViewBuilder
    private var alertActions: some View {
        switch activeAlert {
        case .discardDraft:
            Button(PanelActionsCopy.text("Keep Editing", bundle: copyBundle), role: .cancel) {
                activeAlert = nil
            }
            Button(PanelActionsCopy.text("Discard Changes", bundle: copyBundle), role: .destructive) {
                activeAlert = nil
                completeDismissal()
            }
            .accessibilityIdentifier("clipy.editor.confirm-discard")
        case .stale:
            Button(PanelActionsCopy.text("Keep Editing", bundle: copyBundle), role: .cancel) {
                activeAlert = nil
            }
            Button(PanelActionsCopy.text("Reload Latest", bundle: copyBundle)) {
                activeAlert = nil
                startReload()
            }
            .accessibilityIdentifier("clipy.editor.stale-reload")
        case .reloadFailure, .incompatibleReload:
            Button(PanelActionsCopy.text("Keep Editing", bundle: copyBundle), role: .cancel) {
                activeAlert = nil
            }
            Button(PanelActionsCopy.text("Retry Reload", bundle: copyBundle)) {
                activeAlert = nil
                startReload()
            }
            .accessibilityIdentifier("clipy.editor.retry-reload")
        case .saveFailure:
            Button(PanelActionsCopy.text("OK", bundle: copyBundle)) {
                activeAlert = nil
            }
        case nil:
            EmptyView()
        }
    }

    /// Empty strings are observed only while the alert binding is false.
    private var alertPresentation: (title: String, message: String) {
        activeAlert?.presentation(bundle: copyBundle) ?? ("", "")
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
        Text(ReviseEditorPresentation.revisionDisclosure(bundle: copyBundle))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PanelTheme.spacingLarge)
        .padding(.top, PanelTheme.spacingMedium)
        .accessibilityIdentifier("clipy.editor.revision-disclosure")
    }

    @ViewBuilder
    private var reloadStatus: some View {
        if draft.isAwaitingLatestContent {
            HStack(spacing: PanelTheme.spacingLarge) {
                Label(
                    PanelActionsCopy.text("Reload latest content before saving again.", bundle: copyBundle),
                    systemImage: "arrow.clockwise"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("clipy.editor.awaiting-reload")
                Spacer(minLength: PanelTheme.spacingSmall)
                Button(isReloading ? PanelActionsCopy.text("Reloading…", bundle: copyBundle) : PanelActionsCopy.text("Reload Latest", bundle: copyBundle)) {
                    startReload()
                }
                .disabled(isReloading)
                .accessibilityIdentifier("clipy.editor.reload-latest")
            }
            .padding(.horizontal, PanelTheme.spacingLarge)
            .padding(.top, PanelTheme.spacingMedium)
        } else if let reloadNotice {
            Label(PanelActionsCopy.text(reloadNotice, bundle: copyBundle), systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PanelTheme.spacingLarge)
                .padding(.top, PanelTheme.spacingMedium)
                .accessibilityIdentifier("clipy.editor.reload-notice")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: PanelTheme.spacingSmall) {
            if let validationMessage {
                Label(
                    validationMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    PanelActionsCopy.format("Validation hint: %@", validationMessage, bundle: copyBundle)
                )
            }
            HStack(spacing: PanelTheme.spacingLarge) {
                Spacer(minLength: PanelTheme.spacingSmall)
                Button(PanelActionsCopy.text("Cancel", bundle: copyBundle)) {
                    requestDismissal()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                .accessibilityIdentifier("clipy.editor.cancel")
                .accessibilityHint(
                    draft.isDirty
                        ? PanelActionsCopy.text("Asks before discarding unsaved changes.", bundle: copyBundle)
                        : PanelActionsCopy.text("Closes the editor without changing the item.", bundle: copyBundle)
                )
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        Label(PanelActionsCopy.text("Saving…", bundle: copyBundle), systemImage: "hourglass")
                    } else {
                        Label(PanelActionsCopy.text("Save Revision", bundle: copyBundle), systemImage: "checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave || isSaving || isReloading || replacementTask != nil)
                .accessibilityLabel(isSaving ? PanelActionsCopy.text("Saving revision", bundle: copyBundle) : PanelActionsCopy.text("Save Revision", bundle: copyBundle))
                .accessibilityIdentifier("clipy.editor.save")
                .accessibilityHint(
                    PanelActionsCopy.text("Applies these decisions as a new revision of the item.", bundle: copyBundle)
                )
            }
        }
        .padding(PanelTheme.spacingLarge)
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
            return PanelActionsCopy.text("Hiding every representation is not allowed", bundle: copyBundle)
        }
        if draft.hasEmptyPasteboardItem {
            return PanelActionsCopy.text("Each clipboard item must keep at least one format", bundle: copyBundle)
        }
        if draft.hasEmptyReplacement {
            return PanelActionsCopy.text("Replacement text cannot be empty", bundle: copyBundle)
        }
        return nil
    }

    /// Cancel and the `.cancelAction` keyboard shortcut share this intent so
    /// neither path can bypass dirty-draft confirmation (review Card 3C).
    private func requestDismissal() {
        guard !isSaving else { return }
        switch draft.dismissalDecision {
        case .dismiss:
            completeDismissal()
        case .confirmDiscard:
            activeAlert = .discardDraft
        }
    }

    // MARK: Rows

    private func decisionRow(
        for representation: HistoryRepresentationMetadata
    ) -> some View {
        let typeIdentifier = representation.typeIdentifier
        let pasteboardItemIndex = representation.pasteboardItemIndex
        let identity = representation.representationIdentity
        let replacementIsAvailable = draft.canReplace(representation)
        let replacementAccessibilityHint = replacementIsAvailable
            ? PanelActionsCopy.text(" Replace edits UTF-8 or UTF-16 plain text while preserving its encoding.", bundle: copyBundle)
            : PanelActionsCopy.text(" Replace requires a supported UTF-8 or UTF-16 plain-text format with valid content. Other formats can be preserved, restored, or hidden.", bundle: copyBundle)
        let formatTitle = VStack(
            alignment: .leading,
            spacing: PanelTheme.spacingXXXSmall
        ) {
            if Set(draft.canonicalRepresentations.map(\.pasteboardItemIndex)).count > 1 {
                Text("\(pasteboardItemIndex + 1)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: DetailsPresentationCopy.formatName(typeIdentifier, bundle: copyBundle))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        let decisionPicker = Picker(
            PanelActionsCopy.text("Decision", bundle: copyBundle),
            selection: choiceBinding(for: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)
        ) {
            Text(PanelActionsCopy.text("Keep Current", bundle: copyBundle)).tag(ReviseEditorDraft.Choice.keepCurrent)
            Text(PanelActionsCopy.text("Use Original", bundle: copyBundle)).tag(ReviseEditorDraft.Choice.useOriginal)
            Text(PanelActionsCopy.text("Hide", bundle: copyBundle)).tag(ReviseEditorDraft.Choice.hide)
            if replacementIsAvailable {
                // Metadata offers only exact declared encodings. The
                // selected source must load and validate before the
                // TextEditor or a replacement decision is installed.
                Text(PanelActionsCopy.text("Replace", bundle: copyBundle)).tag(ReviseEditorDraft.Choice.replace)
            }
        }
        .pickerStyle(.menu)
        .disabled(isSaving || isReloading || replacementTask != nil)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(PanelActionsCopy.format("Editing decision for %@", identity.accessibilityLabel, bundle: copyBundle))
        .accessibilityIdentifier(
            "clipy.editor.decision.\(identity.accessibilitySuffix)"
        )
        .accessibilityHint(
            PanelActionsCopy.text("Keep Current preserves the bytes currently used for pasting. Use Original restores the captured bytes. Hide omits this type from pasting.", bundle: copyBundle)
                + replacementAccessibilityHint
        )
        return VStack(alignment: .leading, spacing: PanelTheme.spacingXSmall) {
            SettingsFieldLayout {
                formatTitle
                decisionPicker
            }
            DisclosureGroup(DetailsPresentationCopy.text("Format Details", bundle: copyBundle)) {
                VStack(alignment: .leading, spacing: PanelTheme.spacingSmall) {
                    Text(verbatim: typeIdentifier)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text(verbatim: EditorFormat.bytes(representation.byteCount, locale: locale))
                    if !replacementIsAvailable {
                        Text(PanelActionsCopy.text(
                            "Replace supports valid UTF-8 and UTF-16 plain-text formats. Keep Current preserves exact bytes.",
                            bundle: copyBundle
                        ))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .disclosureGroupStyle(AppDisclosureGroupStyle(
                identifier: "clipy.editor.format-details." + identity.accessibilitySuffix,
                accessibilityLabel: DetailsPresentationCopy.text("Format Details", bundle: copyBundle) + ": " + identity.accessibilityLabel
            ))
            .font(.caption)
            if draft.choice(for: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex) == .replace {
                TextEditor(text: textBinding(for: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex))
                    .disabled(isSaving || isReloading || replacementTask != nil)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .focused($focusedReplacement, equals: identity)
                    .containerRelativeFrame(.vertical) { height, _ in height * 0.65 }
                    .frame(minHeight: 140)
                    .padding(PanelTheme.spacingSmall)
                    .background(.background, in: RoundedRectangle(cornerRadius: PanelTheme.cornerRadiusMedium))
                    .accessibilityLabel(
                        PanelActionsCopy.format("Replacement text for %@", identity.accessibilityLabel, bundle: copyBundle)
                    )
                    .accessibilityIdentifier(
                        "clipy.editor.replacement.\(identity.accessibilitySuffix)"
                    )
            }
        }
        .padding(.vertical, PanelTheme.spacingSmall)
    }

    private func choiceBinding(
        for typeIdentifier: String, pasteboardItemIndex: Int
    ) -> Binding<ReviseEditorDraft.Choice> {
        Binding(
            get: { draft.choice(for: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex) },
            set: {
                guard !isSaving, !isReloading, replacementTask == nil else { return }
                if $0 == .replace, !draft.hasReplacementSource(for: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex) {
                    loadReplacement(for: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)
                } else {
                    draft.setChoice($0, for: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)
                    focusedReplacement = $0 == .replace
                        ? RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)
                        : nil
                }
            }
        )
    }

    private func textBinding(for typeIdentifier: String, pasteboardItemIndex: Int) -> Binding<String> {
        Binding(
            get: { draft.replacementText(for: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex) },
            set: {
                guard !isSaving, !isReloading, replacementTask == nil else { return }
                draft.setReplacementText($0, for: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)
            }
        )
    }

    // MARK: Save

    @MainActor
    private func loadReplacement(for typeIdentifier: String, pasteboardItemIndex: Int) {
        guard replacementTask == nil, !isSaving, !isReloading,
              let request = draft.replacementRequest(for: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex) else { return }
        _ = readFence.reconcile(viewState.surfacePurge, item: request.item)
        guard !readFence.isPurged else { return }
        replacementFailure = nil
        replacementType = RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)
        let snapshot = draft
        replacementTask = Task {
            do {
                let source = try await viewState.history.representation(request)
                _ = readFence.reconcile(viewState.surfacePurge, item: request.item)
                guard !readFence.isPurged else { cancelReplacementLoad(); return }
                guard !Task.isCancelled, draft.itemReference == request.item else { return }
                let decoding = Task.detached {
                    var loaded = snapshot
                    guard !Task.isCancelled, loaded.installReplacementSource(source) else { return Optional<ReviseEditorDraft>.none }
                    return loaded
                }
                let loaded = await withTaskCancellationHandler {
                    await decoding.value
                } onCancel: { decoding.cancel() }
                _ = readFence.reconcile(viewState.surfacePurge, item: request.item)
                guard !readFence.isPurged else { cancelReplacementLoad(); return }
                guard !Task.isCancelled, draft.itemReference == request.item else { return }
                replacementTask = nil
                guard let loaded else {
                    replacementFailure = PanelActionsCopy.text("Replace requires valid UTF-8 or UTF-16 plain text.", bundle: copyBundle)
                    return
                }
                draft = loaded
                draft.setChoice(.replace, for: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)
                focusedReplacement = RepresentationIdentity(
                    typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex
                )
            } catch {
                guard !Task.isCancelled else { return }
                _ = readFence.reconcile(viewState.surfacePurge, item: request.item)
                guard !readFence.isPurged else { cancelReplacementLoad(); return }
                replacementTask = nil
                if let failure = error as? HistoryFailure, case .staleContent = failure {
                    draft.markStale()
                    activeAlert = .stale
                    return
                }
                replacementFailure = (error as? HistoryFailure).map {
                    FailurePresentation.message(for: $0, bundle: copyBundle)
                } ?? PanelActionsCopy.text("Clipy couldn't load this item.", bundle: copyBundle)
            }
        }
    }

    @MainActor
    private func cancelReplacementLoad() {
        replacementTask?.cancel()
        replacementTask = nil
    }

    /// Saves the draft as one `.replace` revision. `.staleContent` leaves the
    /// editor and byte-exact draft intact, then blocks another save until the
    /// user explicitly reloads. Success dismisses and observation refreshes
    /// the row list (03b §10; 04 §5; review Card 3B).
    @MainActor
    private func save() async {
        guard !isSaving, !isReloading, replacementTask == nil, draft.canSubmit else { return }
        // The submitted request is a snapshot. Keep its draft controls fixed
        // until it settles, so successful dismissal cannot discard later
        // input that was never included in the committed revision.
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await viewState.reviseKeepingDetails(
                draft.revisionRequest()
            ) { reference in
                onReferenceAdvance?(reference)
            }
            completeDismissal()
        } catch let failure as HistoryFailure {
            if case .staleContent = failure {
                draft.markStale()
                reloadNotice = nil
                activeAlert = .stale
            } else {
                activeAlert = .saveFailure(failure)
            }
        } catch {
            guard error is CancellationError else {
                activeAlert = .saveFailure(nil)
                return
            }
        }
    }

    @MainActor
    private func completeDismissal() {
        cancelReload()
        cancelReplacementLoad()
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    /// Reload is owned by this editor, including Cancel/Discard while its
    /// read is suspended. A closed editor must never advance its former
    /// Details owner when a non-cooperative read eventually returns (V2-09 §5).
    @MainActor
    private func startReload() {
        guard reloadTask == nil, draft.isAwaitingLatestContent else { return }
        reloadTask = Task {
            await reloadLatest()
            guard !Task.isCancelled else { return }
            reloadTask = nil
        }
    }

    @MainActor
    private func cancelReload() {
        reloadTask?.cancel()
        reloadTask = nil
        isReloading = false
    }

    /// Fetches current details only after explicit user intent, then rebases
    /// the pure draft. It never auto-merges or submits. A typed read failure
    /// leaves the stale gate and all draft bytes untouched so Retry is safe.
    @MainActor
    private func reloadLatest() async {
        guard !Task.isCancelled, !isReloading, draft.isAwaitingLatestContent else { return }
        let reference = draft.itemReference
        _ = readFence.reconcile(viewState.surfacePurge, item: reference)
        guard let generation = readFence.begin() else { return }
        cancelReplacementLoad()
        replacementFailure = nil
        isReloading = true
        defer {
            if !Task.isCancelled { isReloading = false }
        }
        do {
            let latest = try await viewState.details(for: reference.id)
            guard !Task.isCancelled else { return }
            _ = readFence.reconcile(viewState.surfacePurge, item: reference)
            guard !readFence.isPurged,
                  readFence.owns(generation), draft.itemReference == reference
            else { return }
            guard draft.reloadLatest(details: latest) else {
                activeAlert = .incompatibleReload
                return
            }
            onReferenceAdvance?(latest.item)
            reloadNotice = "Latest content loaded. Your draft was kept for formats that remain editable."
        } catch let failure as HistoryFailure {
            guard !Task.isCancelled else { return }
            _ = readFence.reconcile(viewState.surfacePurge, item: reference)
            guard !readFence.isPurged,
                  readFence.owns(generation) else { return }
            activeAlert = .reloadFailure(failure)
        } catch {
            guard !Task.isCancelled else { return }
            _ = readFence.reconcile(viewState.surfacePurge, item: reference)
            guard !readFence.isPurged,
                  readFence.owns(generation) else { return }
            guard error is CancellationError else {
                activeAlert = .reloadFailure(nil)
                return
            }
        }
    }
}

// MARK: - Editor size presentation

/// Value formatting follows this editor's environment, without a mutable
/// formatter retaining another view's language or regional settings.
internal enum EditorFormat {
    static func bytes(_ value: Int, locale: Locale) -> String {
        value.formatted(ByteCountFormatStyle(style: .file, locale: locale))
    }
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
        title: "Meeting notes — first line",
        canonical: [
            HistoryRepresentationMetadata(typeIdentifier: ClipboardFormatIdentifier.utf8PlainText.rawValue, byteCount: 39),
            HistoryRepresentationMetadata(typeIdentifier: ClipboardFormatIdentifier.html.rawValue, byteCount: 20),
        ],
        effective: [HistoryRepresentationMetadata(typeIdentifier: ClipboardFormatIdentifier.utf8PlainText.rawValue, byteCount: 27)],
        effectiveMatchesCanonical: false,
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
