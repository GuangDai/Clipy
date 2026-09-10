/// HistoryDetailsView — the item-detail surface pushed inside the panel's
/// NavigationStack: full content lineage (Effective vs Canonical), revision
/// history with revert, copy-occurrence facts, and the per-item actions
/// (copy, pin toggle, revise, remove). All data flows through
/// `HistoryViewState` (the only state holder) against `HistoryCore` DTOs;
/// nothing here sees SwiftData, Domain state, or fingerprints.
/// Owning spec: docs/01-architecture.md §6 (Main-actor UI) and §5.4 (detail
/// flow); detail DTOs docs/03b-instruction-set.md §9; revise semantics
/// docs/03a-instruction-set.md §5; thumbnail discipline
/// docs/01-architecture.md §5.7 / docs/04-coherence.md §9; roadmap:
/// docs/roadmap/05-presentationui.md (step 9).
import ClipboardFormats
import ContentPreview
import Foundation
import HistoryCore
import SwiftUI

/// Monotonic ownership for one details view's async read. A destructive or
/// old-content purge invalidates the token synchronously, so a non-cooperative
/// read completion cannot republish sensitive `HistoryDetails` afterward
/// (review Card 9B).
struct HistoryDetailsLoadFence {
    private(set) var generation = 0
    private(set) var isPurged = false
    private(set) var observedSurfacePurgeGeneration: Int

    /// A newly constructed details surface starts after the purge currently
    /// retained by its owner. That historical value is a baseline, not an
    /// event to replay against an item created or navigated to later.
    init(baselinePurgeGeneration: Int = 0) {
        observedSurfacePurgeGeneration = baselinePurgeGeneration
    }

    mutating func begin() -> Int? {
        guard !isPurged else { return nil }
        generation += 1
        return generation
    }

    mutating func purge(
        _ scope: HistorySurfacePurge.Scope,
        item: HistoryItemReference
    ) -> Bool {
        let affectsItem: Bool
        switch scope {
        case .all:
            affectsItem = true
        case .unpinned:
            // Pin state is authoritative only after the restarted observation.
            // This owner fails closed; a retained pinned row can reopen it.
            affectsItem = true
        case .item(let id):
            affectsItem = id == item.id
        case .revision(let old, _):
            affectsItem = old == item
        }
        guard affectsItem else { return false }
        isPurged = true
        generation += 1
        return true
    }

    /// Reconciles directly with the panel owner's latest purge rather than
    /// relying on SwiftUI child callback delivery. One missed generation can
    /// be evaluated precisely; a larger gap has lost an intermediate scope,
    /// so this details surface must retire as a whole.
    mutating func reconcile(
        _ purge: HistorySurfacePurge?,
        item: HistoryItemReference
    ) -> HistorySurfacePurge.Scope? {
        guard !isPurged, let purge else { return nil }
        guard purge.generation > observedSurfacePurgeGeneration else {
            return nil
        }
        let previousGeneration = observedSurfacePurgeGeneration
        observedSurfacePurgeGeneration = purge.generation
        if purge.generation > previousGeneration + 1 {
            _ = self.purge(.all, item: item)
            return .all
        }

        guard self.purge(purge.scope, item: item) else { return nil }
        return purge.scope
    }

    func owns(_ token: Int) -> Bool {
        token == generation
    }

    func accepts(
        _ token: Int,
        returned: HistoryItemReference,
        expected: HistoryItemReference,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && owns(token) && returned == expected
    }

    /// An editor may advance this Details owner only with an authoritative
    /// reference returned by a successful details read or committed revision.
    /// Advancing invalidates any load begun for the older exact reference;
    /// it never revives a surface already retired by a purge.
    mutating func advanceReference(
        from current: HistoryItemReference,
        to latest: HistoryItemReference
    ) -> Bool {
        guard !isPurged,
              latest.id == current.id,
              latest.contentVersion >= current.contentVersion
        else { return false }
        if latest != current {
            generation += 1
        }
        return true
    }
}

/// Detail screen for one retained item (roadmap 05). Loads `HistoryDetails`
/// via the view state, renders the Effective/Canonical content with
/// per-representation previews, offers revision revert, and the per-item
/// action set. A `.staleContent` typed failure from any revise/revert (03b
/// §10) reloads the details and surfaces an inline notice instead of
/// discarding the user's place.
struct HistoryDetailsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.displayMemoryPressure) private var memoryPressure
    @Environment(\.displayMemoryPressureGeneration) private var memoryPressureGeneration
    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }
    private let viewState: HistoryViewState
    private let onReferenceAdvance:
        (@MainActor (HistoryItemReference, HistoryItemReference) -> Bool)?
    @State private var currentItem: HistoryItemReference

    /// Reference-exact thumbnail cache (01 §5.7; 04 §9): keyed by
    /// `HistoryItemReference`, so a revised item never shows stale pixels.
    /// 128 px ≈ 2× the 64 pt header cell, keeping the header sharp on
    /// retina displays (the row list keeps the 112 px default).
    @State private var thumbnails: ThumbnailStore

    @State private var phase: DetailsPhase = .loading
    @State private var basis: ContentBasis = .effective
    @State private var showsStaleNotice = false
    @State private var needsRevisionConflictReload = false
    @State private var failureNotice: String?
    @State private var showsEditor = false
    @State private var showsRemoveConfirmation = false
    @State private var isTogglingPin = false
    @State private var isRemoving = false
    @State private var isRevising = false
    @State private var isExporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var representationTask: Task<Void, Never>?
    @State private var previewRequest: HistoryRepresentationRequest?
    @State private var representationPreview: DetailsRepresentationPresentation?
    @State private var representationFailure: String?
    @State private var representationRenderer = ContentPreview()
    @State private var loadFence = HistoryDetailsLoadFence()

    init(viewState: HistoryViewState, item: HistoryItemReference) {
        self.viewState = viewState
        self.onReferenceAdvance = nil
        self._currentItem = State(initialValue: item)
        self._loadFence = State(
            initialValue: HistoryDetailsLoadFence(
                baselinePurgeGeneration: viewState.surfacePurge?.generation ?? 0
            )
        )
        self._thumbnails = State(
            initialValue: ThumbnailStore(
                history: viewState.history,
                pixels: PixelSize(width: 128, height: 128)
            )
        )
    }

    init(
        viewState: HistoryViewState,
        item: HistoryItemReference,
        onReferenceAdvance: @escaping @MainActor (
            HistoryItemReference,
            HistoryItemReference
        ) -> Bool
    ) {
        self.viewState = viewState
        self.onReferenceAdvance = onReferenceAdvance
        self._currentItem = State(initialValue: item)
        self._loadFence = State(
            initialValue: HistoryDetailsLoadFence(
                baselinePurgeGeneration:
                    viewState.surfacePurge?.generation ?? 0
            )
        )
        self._thumbnails = State(
            initialValue: ThumbnailStore(
                history: viewState.history,
                pixels: PixelSize(width: 128, height: 128)
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsEditor, case .loaded(let details, _) = phase {
                ReviseEditorView(
                    viewState: viewState,
                    details: details,
                    onDismiss: closeEditor,
                    onReferenceAdvance: advanceDetailsReference
                )
            } else {
                switch phase {
                case .loading:
                    ProgressView(PanelActionsCopy.text("Loading…", bundle: copyBundle))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .removed:
                    ContentUnavailableView(
                        PanelActionsCopy.text("Item Removed", bundle: copyBundle),
                        systemImage: "trash",
                        description: Text(
                            PanelActionsCopy.text("This item is no longer in your clipboard history.", bundle: copyBundle)
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label(
                            PanelActionsCopy.text("Couldn't Load Item", bundle: copyBundle),
                            systemImage: "exclamationmark.triangle"
                        )
                    } description: {
                        Text(message)
                    } actions: {
                        Button(PanelActionsCopy.text("Retry", bundle: copyBundle)) {
                            Task { await load() }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let details, let content):
                    loadedLayout(for: details, content: content)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.details.root")
        .navigationTitle(PanelActionsCopy.text("Details", bundle: copyBundle))
        .navigationBarBackButtonHidden(showsEditor)
        .overlay { detailsEscapeShortcut }
        .task { await load() }
        .confirmationDialog(
            PanelActionsCopy.text("Remove this item from your clipboard history?", bundle: copyBundle),
            isPresented: $showsRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(PanelActionsCopy.text("Remove", bundle: copyBundle), role: .destructive) {
                Task { await remove() }
            }
            .accessibilityIdentifier("clipy.details.confirm-remove")
            Button(PanelActionsCopy.text("Cancel", bundle: copyBundle), role: .cancel) {}
        }
        .onDisappear {
            cancelExport()
            cancelRepresentationPreview()
        }
        .onChange(of: basis) { _, _ in
            cancelExport()
            cancelRepresentationPreview()
        }
        .onChange(of: showsEditor) { _, opened in
            if opened {
                cancelExport()
                cancelRepresentationPreview()
            }
        }
        .onChange(of: viewState.surfacePurge, initial: true) { _, _ in
            _ = reconcileSurfacePurge(viewState.surfacePurge)
        }
        .onChange(of: memoryPressureGeneration, initial: true) { _, _ in
            thumbnails.respondToMemoryPressure(memoryPressure)
            if memoryPressure == .critical { cancelRepresentationPreview() }
        }

    }

    /// Details owns settled Esc as a navigation dismissal. While its inline
    /// editor or remove confirmation is visible, that child/modal's own
    /// `.cancelAction` remains the only Esc owner so a dirty draft or pending
    /// destructive choice cannot be bypassed (review UI-7 / Card 3C / 14A).
    @ViewBuilder
    private var detailsEscapeShortcut: some View {
        if !showsEditor, !showsRemoveConfirmation {
            Button(PanelActionsCopy.text("Back to History", bundle: copyBundle)) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    /// The floating nonactivating panel's attached SwiftUI sheet is exposed
    /// by macOS as an empty public AX Dialog. Keeping the same editor View in
    /// this Details-owned content switch gives keyboard and accessibility
    /// clients the real controls while preserving one editor at a time. A
    /// saved revision still joins the same explicit authoritative reload.
    @MainActor
    private func closeEditor() {
        showsEditor = false
        Task { await load(presentingTransition: false) }
    }

    /// Explicit revision recovery and committed Save/Revert are the sources
    /// allowed to retarget this already-open Details surface. All values cross
    /// History's authoritative read/receipt boundary. External mismatches on
    /// ordinary `load()` remain rejected by the unchanged exact fence.
    @MainActor
    private func advanceDetailsReference(_ latest: HistoryItemReference) {
        let previous = currentItem
        guard !loadFence.isPurged,
              latest.id == previous.id,
              latest.contentVersion >= previous.contentVersion
        else { return }
        if let onReferenceAdvance,
           !onReferenceAdvance(previous, latest) {
            return
        }
        guard loadFence.advanceReference(from: previous, to: latest) else {
            return
        }
        if latest != previous {
            cancelExport()
            cancelRepresentationPreview()
        }
        currentItem = latest
        if latest != previous {
            thumbnails.purge(.revision(old: previous, new: latest))
        }
    }

    // MARK: Loaded layout

    @ViewBuilder
    private func loadedLayout(
        for details: HistoryDetails,
        content: DetailsContentPresentation
    ) -> some View {
        VStack(spacing: 0) {
            if showsStaleNotice {
                noticeBanner(
                    text: PanelActionsCopy.text(
                        "This item changed while you were viewing it. Details reloaded.",
                        bundle: copyBundle
                    ),
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    showsStaleNotice = false
                }
            }
            if let failureNotice {
                noticeBanner(
                    text: failureNotice,
                    systemImage: "exclamationmark.triangle"
                ) {
                    self.failureNotice = nil
                }
            }
            DetailsBody(
                details: details,
                content: content,
                thumbnails: thumbnails,
                basis: $basis,
                onRevise: { intent in
                    Task {
                        await revise(
                            intent: intent,
                            expected: details.item.contentVersion
                        )
                    }
                },
                onExport: startExport,
                isExporting: isExporting,
                onPreview: startRepresentationPreview,
                previewRequest: previewRequest,
                representationPreview: representationPreview,
                isLoadingRepresentation: representationTask != nil,
                representationFailure: representationFailure
            )
            .disabled(isRevising)
            Divider()
            actionBar(isPinned: details.pinnedPosition != nil)
                .disabled(isRevising)
        }
    }

    /// The per-item action set (contract §4.2 "toolbar"): rendered as a
    /// persistent bottom bar because the floating NSPanel has no window
    /// toolbar surface for `.toolbar` items — the four actions are identical.
    /// Copy remains prominent; compact secondary actions retain explicit
    /// accessibility labels and help within the narrowest browsing column.
    private func actionBar(isPinned: Bool) -> some View {
        HStack(spacing: PanelTheme.spacingSmall) {
            Button {
                // The only History→pasteboard hand-off (01 §5.6); the view
                // state routes it to the composition root's paste closure.
                viewState.requestPaste(currentItem)
            } label: {
                Label(DetailsPresentationCopy.text("Copy", bundle: copyBundle), systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(PanelActionsCopy.text("Copy to Clipboard", bundle: copyBundle))
            Spacer(minLength: PanelTheme.spacingSmall)
            Button {
                Task { await togglePin(isPinned: isPinned) }
            } label: {
                if isTogglingPin {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(
                        isPinned ? PanelActionsCopy.text("Unpin", bundle: copyBundle) : PanelActionsCopy.text("Pin", bundle: copyBundle),
                        systemImage: isPinned ? "pin.slash" : "pin"
                    )
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .labelStyle(.iconOnly)
            .help(isPinned ? PanelActionsCopy.text("Unpin", bundle: copyBundle) : PanelActionsCopy.text("Pin", bundle: copyBundle))
            .accessibilityLabel(isPinned ? PanelActionsCopy.text("Unpin", bundle: copyBundle) : PanelActionsCopy.text("Pin", bundle: copyBundle))
            .accessibilityHint(
                PanelActionsCopy.text("Pinned items stay at the top of the list and are exempt from unpinned retention limits.", bundle: copyBundle)
            )
            .accessibilityIdentifier("clipy.details.pin-toggle")
            .disabled(isTogglingPin)
            Button {
                showsEditor = true
            } label: {
                Label(PanelActionsCopy.text("Edit Content", bundle: copyBundle), systemImage: "square.and.pencil")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(PanelActionsCopy.text("Edit Content…", bundle: copyBundle))
            .accessibilityLabel(PanelActionsCopy.text("Edit Content", bundle: copyBundle))
            .accessibilityHint(PanelActionsCopy.text("Opens the revision editor for this item.", bundle: copyBundle))
            Button {
                showsRemoveConfirmation = true
            } label: {
                Label(PanelActionsCopy.text("Remove", bundle: copyBundle), systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .labelStyle(.iconOnly)
            .help(PanelActionsCopy.text("Remove", bundle: copyBundle))
            .accessibilityLabel(PanelActionsCopy.text("Remove", bundle: copyBundle))
            .accessibilityHint(
                PanelActionsCopy.text("Removes this item from your clipboard history.", bundle: copyBundle)
            )
            .accessibilityIdentifier("clipy.details.remove")
            .disabled(isRemoving)
        }
        .padding(.horizontal, PanelTheme.spacingLarge)
        .padding(.vertical, PanelTheme.spacingSmall)
        .background(.bar)
    }

    /// Inline dismissible notice row (stale reload / typed failure).
    private func noticeBanner(
        text: String,
        systemImage: String,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: PanelTheme.spacingSmall) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PanelTheme.spacingSmall)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel(PanelActionsCopy.text("Dismiss", bundle: copyBundle))
        }
        .padding(.horizontal, PanelTheme.spacingLarge)
        .padding(.vertical, PanelTheme.spacingXSmall)
        .background(Color.primary.opacity(0.05))
    }

    // MARK: Data flow

    /// Export the selected immutable snapshot, including opaque/empty bytes.
    /// Cancellation leaves the surface untouched; a write failure is shown
    /// here independently of History's mutation failures (V2-07 §4.1.1).
    @MainActor
    private func startExport(_ request: HistoryRepresentationRequest) {
        guard !isExporting, !showsEditor else { return }
        guard request.item == currentItem else { return }
        guard reconcileSurfacePurge(viewState.surfacePurge) else { return }
        let reference = currentItem
        let generation = loadFence.generation
        isExporting = true
        failureNotice = nil
        exportTask = Task {
            do {
                guard !Task.isCancelled else { return }
                let representation = try await viewState.history.representation(request)
                guard !showsEditor else { cancelExport(); return }
                guard !Task.isCancelled, reconcileSurfacePurge(viewState.surfacePurge),
                      loadFence.accepts(generation, returned: request.item, expected: currentItem, isCancelled: Task.isCancelled)
                else { return }
                let result = await viewState.onExportRepresentation(representation)
                guard !Task.isCancelled else { return }
                exportTask = nil
                isExporting = false
                // A closed/purged or retargeted Details surface cannot accept a
                // late export result, even if an app callback ignores cancellation.
                guard reconcileSurfacePurge(viewState.surfacePurge),
                      loadFence.accepts(
                        generation, returned: reference, expected: currentItem,
                        isCancelled: Task.isCancelled
                      ) else { return }
                switch result {
                case .success:
                    break
                case .failure(let failure):
                    switch failure {
                    case .unavailable:
                        failureNotice = PanelActionsCopy.text("The Save dialog is unavailable. Try again.", bundle: copyBundle)
                    case .writeFailed:
                        failureNotice = PanelActionsCopy.text("Clipy couldn't save this file. Choose another location and try again.", bundle: copyBundle)
                    }
                }
            } catch {
                guard !Task.isCancelled, reconcileSurfacePurge(viewState.surfacePurge),
                      loadFence.owns(generation) else { return }
                exportTask = nil
                isExporting = false
                failureNotice = (error as? HistoryFailure).map {
                    FailurePresentation.message(for: $0, bundle: copyBundle)
                } ?? PanelActionsCopy.text("Clipy couldn't load this item.", bundle: copyBundle)
            }
        }
    }

    @MainActor
    private func startRepresentationPreview(_ request: HistoryRepresentationRequest) {
        if previewRequest == request, representationPreview != nil || representationTask != nil {
            cancelRepresentationPreview()
            return
        }
        cancelRepresentationPreview()
        guard request.item == currentItem, reconcileSurfacePurge(viewState.surfacePurge),
              case .loaded(let details, _) = phase else { return }
        let representations = request.basis == .canonical ? details.canonical : details.effective
        guard let metadata = representations.first(where: {
            $0.typeIdentifier == request.typeIdentifier && $0.pasteboardItemIndex == request.pasteboardItemIndex
        }) else { return }
        previewRequest = request
        let generation = loadFence.generation
        representationTask = Task {
            do {
                let presentation = try await DetailsRepresentationPresentation.load(
                    request, metadata: metadata, history: viewState.history,
                    renderer: representationRenderer
                )
                guard !Task.isCancelled, previewRequest == request,
                      reconcileSurfacePurge(viewState.surfacePurge),
                      loadFence.accepts(generation, returned: request.item, expected: currentItem, isCancelled: Task.isCancelled)
                else { return }
                representationTask = nil
                representationPreview = presentation
            } catch {
                guard !Task.isCancelled, previewRequest == request,
                      reconcileSurfacePurge(viewState.surfacePurge), loadFence.owns(generation) else { return }
                representationTask = nil
                representationFailure = (error as? HistoryFailure).map {
                    FailurePresentation.message(for: $0, bundle: copyBundle)
                } ?? PanelActionsCopy.text("Clipy couldn't load this item.", bundle: copyBundle)
            }
        }
    }

    @MainActor
    private func cancelRepresentationPreview() {
        representationTask?.cancel()
        representationTask = nil
        previewRequest = nil
        representationPreview = nil
        representationFailure = nil
    }

    @MainActor
    private func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        isExporting = false
    }

    /// Loads (or reloads) the detail snapshot. `.notFound` maps to the
    /// removed placeholder; every other typed failure maps to the
    /// user-facing `FailurePresentation` message (03b §10).
    @MainActor
    private func load(presentingTransition: Bool = true) async {
        cancelRepresentationPreview()
        cancelExport()
        guard reconcileSurfacePurge(viewState.surfacePurge) else { return }
        guard var generation = loadFence.begin() else {
            phase = .removed
            return
        }
        if presentingTransition {
            phase = .loading
        }
        do {
            let details = try await viewState.details(for: currentItem.id)
            guard reconcileSurfacePurge(viewState.surfacePurge) else { return }
            // A failed explicit Revert reloads the authoritative latest base
            // (03b §10). Ordinary reads still require the displayed reference.
            // Keep this intent across a transient read failure so Retry can
            // still recover the newer base instead of reporting it removed.
            if needsRevisionConflictReload,
               !Task.isCancelled,
               loadFence.owns(generation) {
                advanceDetailsReference(details.item)
                generation = loadFence.generation
                if details.item == currentItem {
                    needsRevisionConflictReload = false
                }
            }
            guard loadFence.accepts(
                generation,
                returned: details.item,
                expected: currentItem,
                isCancelled: Task.isCancelled
            ) else {
                if !Task.isCancelled,
                   loadFence.owns(generation),
                   details.item != currentItem {
                    phase = .removed
                }
                return
            }
            // The overview prepares only scalar metadata. Representation bytes
            // are read only by explicit preview, replacement or Save As actions.
            let content = try DetailsContentPresentation(details: details)
            guard reconcileSurfacePurge(viewState.surfacePurge) else { return }
            guard loadFence.accepts(
                generation,
                returned: details.item,
                expected: currentItem,
                isCancelled: Task.isCancelled
            ) else { return }
            phase = .loaded(details, content)
        } catch let failure as HistoryFailure {
            guard reconcileSurfacePurge(viewState.surfacePurge) else { return }
            guard !Task.isCancelled, loadFence.owns(generation) else { return }
            switch failure {
            case .notFound:
                phase = .removed
            default:
                phase = .failed(
                    message: FailurePresentation.message(for: failure, bundle: copyBundle)
                )
            }
        } catch {
            guard reconcileSurfacePurge(viewState.surfacePurge) else { return }
            guard !Task.isCancelled, loadFence.owns(generation) else { return }
            guard error is CancellationError else {
                phase = .failed(message: PanelActionsCopy.text("Clipy couldn't load this item.", bundle: copyBundle))
                return
            }
        }
    }

    /// Applies the panel owner's current purge synchronously. This is called
    /// both by SwiftUI observation and by the load's begin/completion path,
    /// so navigation teardown ordering cannot admit a late details payload.
    @MainActor @discardableResult
    private func reconcileSurfacePurge(
        _ purge: HistorySurfacePurge?
    ) -> Bool {
        if let scope = loadFence.reconcile(purge, item: currentItem) {
            cancelExport()
            cancelRepresentationPreview()
            thumbnails.purge(scope)
            showsEditor = false
            phase = .removed
        }
        return !loadFence.isPurged
    }

    /// Pin state is re-read only after the write receipt. A typed write
    /// failure leaves the currently loaded details in place and uses the
    /// existing inline failure presentation.
    @MainActor
    private func togglePin(isPinned: Bool) async {
        guard !isTogglingPin else { return }
        isTogglingPin = true
        defer { isTogglingPin = false }
        do {
            if isPinned {
                _ = try await viewState.unpinAwaitingReceipt(currentItem.id)
            } else {
                _ = try await viewState.pinAwaitingReceipt(currentItem.id)
            }
            await load(presentingTransition: false)
        } catch let failure as HistoryFailure {
            failureNotice = FailurePresentation.message(for: failure, bundle: copyBundle)
        } catch {
            guard error is CancellationError else {
                failureNotice = PanelActionsCopy.text("Clipy couldn't update this item.", bundle: copyBundle)
                return
            }
        }
    }

    /// Performs one revise/revert against the version the screen loaded,
    /// then reloads. `.staleContent` reloads plus the inline notice (03b §10);
    /// other typed failures surface their message inline.
    @MainActor
    private func revise(intent: RevisionIntent, expected: ContentVersion) async {
        guard !isRevising else { return }
        isRevising = true
        defer { isRevising = false }
        do {
            _ = try await viewState.reviseKeepingDetails(
                RevisionRequest(
                    itemID: currentItem.id,
                    expected: expected,
                    intent: intent
                ),
                onCommittedReference: advanceDetailsReference
            )
            await load(presentingTransition: false)
        } catch let failure as HistoryFailure {
            if case .staleContent = failure {
                showsStaleNotice = true
                needsRevisionConflictReload = true
                await load(presentingTransition: false)
            } else {
                failureNotice = FailurePresentation.message(for: failure, bundle: copyBundle)
            }
        } catch {
            guard error is CancellationError else {
                failureNotice = PanelActionsCopy.text("Clipy couldn't update this item.", bundle: copyBundle)
                return
            }
        }
    }

    /// Sequences the destructive mutation before its readback (review UI-2 /
    /// Card 9B). A typed failure leaves the loaded details in place and is
    /// presented inline. The panel owner consumes the receipt-confirmed purge
    /// and removes this navigation path for a committed Remove.
    @MainActor
    private func remove() async {
        guard !isRemoving else { return }
        isRemoving = true
        defer { isRemoving = false }
        do {
            _ = try await viewState.removeAwaitingReceipt(currentItem.id)
            // The receipt-confirmed surface purge owns dismissal. Do not
            // issue a guaranteed-notFound read after a successful Remove.
        } catch let failure as HistoryFailure {
            failureNotice = FailurePresentation.message(for: failure, bundle: copyBundle)
        } catch {
            guard error is CancellationError else {
                failureNotice = PanelActionsCopy.text("Clipy couldn't remove this item.", bundle: copyBundle)
                return
            }
        }
    }
}

// MARK: - Loaded body (private, previewable with canned DTOs)

/// Content takes the available width and scrolls as one surface. Occurrence
/// and format metadata use disclosure controls instead of a permanent
/// inspector column; immutable revision actions remain independently usable.
private struct DetailsBody: View {

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }

    @State private var showsRevisions = true

    let details: HistoryDetails
    let content: DetailsContentPresentation
    let thumbnails: ThumbnailStore
    @Binding var basis: ContentBasis
    let onRevise: (RevisionIntent) -> Void
    var onExport: (HistoryRepresentationRequest) -> Void = { _ in }
    var isExporting = false
    var onPreview: (HistoryRepresentationRequest) -> Void = { _ in }
    var previewRequest: HistoryRepresentationRequest?
    var representationPreview: DetailsRepresentationPresentation?
    var isLoadingRepresentation = false
    var representationFailure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                contentSection
                Divider()
                infoSection
                revisionsSection
            }
            .padding(PanelTheme.spacingXLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: PanelTheme.spacingSmall) {
            HStack(alignment: .top, spacing: PanelTheme.spacingLarge) {
                thumbnail
                    .frame(width: 64, height: 64)
                VStack(
                    alignment: .leading,
                    spacing: PanelTheme.spacingXXSmall
                ) {
                    Text(content.title ?? PanelActionsCopy.text("Clipboard Item", bundle: copyBundle))
                        .font(.title2.weight(.semibold))
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("clipy.details.title")
                    pinBadge
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, PanelTheme.spacingXXSmall)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let raster = thumbnails.raster(for: details.item),
           let image = PreviewRasterDisplay.image(
               raster,
               scale: 2,
               label: Text(PanelActionsCopy.text("Item thumbnail", bundle: copyBundle))
           ) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: PanelTheme.cornerRadiusMedium
                    )
                )
                .accessibilityLabel(PanelActionsCopy.text("Item thumbnail", bundle: copyBundle))
        } else {
            Image(systemName: content.symbolName)
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
            .frame(width: 64, height: 64)
            .background(
                Color.primary.opacity(0.06),
                in: RoundedRectangle(
                    cornerRadius: PanelTheme.cornerRadiusMedium
                )
            )
            .accessibilityLabel(PanelActionsCopy.text("Content type icon", bundle: copyBundle))
        }
    }

    @ViewBuilder
    private var pinBadge: some View {
        if let position = details.pinnedPosition {
            // `pinnedPosition` is 0-based (03b §8); display is 1-based.
            Label(PanelActionsCopy.pinnedPosition(position + 1, compact: true, bundle: copyBundle, locale: locale), systemImage: "pin.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, PanelTheme.spacingXSmall)
                .padding(.vertical, PanelTheme.spacingXXXSmall)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: Capsule()
                )
                .accessibilityLabel(PanelActionsCopy.pinnedPosition(position + 1, bundle: copyBundle, locale: locale))
                .accessibilityIdentifier("clipy.details.pin-status")
        } else {
            Text(PanelActionsCopy.text("Unpinned", bundle: copyBundle))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, PanelTheme.spacingXSmall)
                .padding(.vertical, PanelTheme.spacingXXXSmall)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .accessibilityIdentifier("clipy.details.pin-status")
        }
    }

    private var infoSection: some View {
        DisclosureGroup(PanelActionsCopy.text("Info", bundle: copyBundle)) {
            LabeledContent(
                PanelActionsCopy.text("First Copied", bundle: copyBundle),
                value: DetailsFormat.dateTime(
                    details.occurrence.firstCopiedAt, locale: locale, timeZone: timeZone
                )
            )
            LabeledContent(
                PanelActionsCopy.text("Last Copied", bundle: copyBundle),
                value: DetailsFormat.dateTime(
                    details.occurrence.lastCopiedAt, locale: locale, timeZone: timeZone
                )
            )
            LabeledContent(
                PanelActionsCopy.text("Copy Count", bundle: copyBundle),
                value: DetailsFormat.count(details.occurrence.count, locale: locale)
            )
            LabeledContent(
                PanelActionsCopy.text("Source", bundle: copyBundle),
                value: details.occurrence.lastSource.map {
                    ($0 as NSString).lastPathComponent
                } ?? PanelActionsCopy.text("Unknown", bundle: copyBundle)
            )
            LabeledContent(
                PanelActionsCopy.text("Content Version", bundle: copyBundle),
                value: DetailsFormat.count(details.item.contentVersion.rawValue, locale: locale)
            )
        }
        .disclosureGroupStyle(AppDisclosureGroupStyle(identifier: "clipy.details.info"))
    }

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: PanelTheme.spacingXLarge) {
            Picker(PanelActionsCopy.text("Content", bundle: copyBundle), selection: $basis) {
                Text(PanelActionsCopy.text("Effective", bundle: copyBundle)).tag(ContentBasis.effective)
                Text(PanelActionsCopy.text("Canonical", bundle: copyBundle)).tag(ContentBasis.canonical)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(PanelActionsCopy.text("Content view", bundle: copyBundle))
            .accessibilityHint(
                PanelActionsCopy.text("Effective lists what pasting produces now; Canonical lists every retained original type.", bundle: copyBundle)
            )

            ForEach(representations, id: \.identity) { representation in
                let request = basis.representation(typeIdentifier: representation.typeIdentifier, in: details, pasteboardItemIndex: representation.pasteboardItemIndex)
                let selected = previewRequest == request
                RepresentationRow(
                    representation: representation,
                    // "Hidden" is a Canonical-lane fact: a retained canonical
                    // type that no longer flows into Effective (03a §5
                    // `.hide`).
                    isHiddenFromEffective: basis == .canonical
                        && !effectiveTypeIdentifiers.contains(
                            representation.identity
                        ),
                    isExporting: isExporting,
                    preview: selected ? representationPreview : nil,
                    isLoading: selected && isLoadingRepresentation,
                    failure: selected ? representationFailure : nil,
                    onPreview: { if let request { onPreview(request) } },
                    onExport: {
                        if let raw = basis.representation(
                            typeIdentifier: representation.typeIdentifier,
                            in: details,
                            pasteboardItemIndex: representation.pasteboardItemIndex
                        ) {
                            onExport(raw)
                        }
                    }
                )
            }
        }
    }

    private var revisionsSection: some View {
        DisclosureGroup(isExpanded: $showsRevisions) {
            Button {
                onRevise(.revert(to: .canonical))
            } label: {
                Label(
                    PanelActionsCopy.text("Revert to Original", bundle: copyBundle),
                    systemImage: "arrow.uturn.backward"
                )
            }
            .controlSize(.small)
            // A canonical revert whose proposed Effective Content is
            // byte-identical to the current Effective Content commits an
            // `.unchanged` no-op (docs/02-domain.md §11 step 5; WS7 (b)),
            // so the action is disabled exactly in that state.
            .disabled(!canRevertToOriginal)
            .accessibilityLabel(PanelActionsCopy.text("Revert to Original", bundle: copyBundle))
            .accessibilityHint(
                PanelActionsCopy.text("Restores the canonical content as this item's current content.", bundle: copyBundle)
            )
            if details.revisions.isEmpty {
                Text(PanelActionsCopy.text("No revisions", bundle: copyBundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(details.revisions, id: \.id) { revision in
                RevisionRow(revision: revision) {
                    onRevise(.revert(to: .revision(revision.id)))
                }
            }
        } label: {
            Text(PanelActionsCopy.text("Revisions", bundle: copyBundle))
        }
        .disclosureGroupStyle(AppDisclosureGroupStyle(identifier: "clipy.details.revisions"))
    }

    /// Whether Revert to Original would change the item: at least one
    /// revision exists AND the current Effective Content differs from the
    /// Canonical original. With no revisions, Effective is canonical by
    /// construction; storage's no-op rule (02 §11 step 5) compares proposed
    /// content byte-for-byte, mirrored here by the representation lists.
    private var canRevertToOriginal: Bool {
        !details.revisions.isEmpty && !content.effectiveMatchesCanonical
    }

    private var representations: [DetailsContentPresentation.Representation] {
        basis == .effective ? content.effective : content.canonical
    }

    private var effectiveTypeIdentifiers: Set<RepresentationIdentity> {
        Set(details.effective.map(\.representationIdentity))
    }
}

// MARK: - Rows (private)

/// One representation row in the Content section: monospaced type identifier,
/// byte size, "Hidden" badge (canonical-but-not-effective types), and the
/// bounded preview — ≤500 characters for exact UTF-8/UTF-16 plain text.
/// Image rows show their own type and byte metadata, never the item-level
/// thumbnail: that payload names neither its selected representation nor its
/// basis, so it cannot describe each Canonical/Effective row (04 §9).
private struct RepresentationRow: View {

    @Environment(\.locale) private var locale
    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }

    let representation: DetailsContentPresentation.Representation
    let isHiddenFromEffective: Bool
    let isExporting: Bool
    let preview: DetailsRepresentationPresentation?
    let isLoading: Bool
    let failure: String?
    let onPreview: () -> Void
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.spacingXSmall) {
            HStack(alignment: .firstTextBaseline) {
                if representation.isImage {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                if representation.pasteboardItemIndex > 0 {
                    Text("\(representation.pasteboardItemIndex + 1) ·")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: DetailsPresentationCopy.formatName(representation.typeIdentifier, bundle: copyBundle))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: PanelTheme.spacingSmall)
                if isHiddenFromEffective {
                    Label(PanelActionsCopy.text("Hidden", bundle: copyBundle), systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, PanelTheme.spacingXSmall)
                        .padding(.vertical, PanelTheme.spacingXXXSmall)
                        .background(
                            Color.primary.opacity(0.06),
                            in: Capsule()
                        )
                        .accessibilityLabel(PanelActionsCopy.text("Hidden from effective content", bundle: copyBundle))
                }
            }
            HStack(spacing: PanelTheme.spacingLarge) {
                Button(action: onExport) {
                    Label(PanelActionsCopy.text("Save As…", bundle: copyBundle), systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
                .disabled(isExporting)
                .accessibilityIdentifier("clipy.details.save-as." + representation.identity.accessibilitySuffix)
                .accessibilityLabel(PanelActionsCopy.format("Save %@ As…", representation.identity.accessibilityLabel, bundle: copyBundle))
                .accessibilityHint(PanelActionsCopy.text("Saves the complete bytes of this displayed representation to a file you choose.", bundle: copyBundle))
                Button(action: onPreview) {
                    Label(PanelActionsCopy.text(isLoading ? "Cancel" : (preview == nil ? "Show Preview" : "Hide Preview"), bundle: copyBundle),
                          systemImage: isLoading ? "xmark.circle" : "eye")
                }
                .accessibilityIdentifier("clipy.details.show-preview." + representation.identity.accessibilitySuffix)
                .accessibilityLabel(PanelActionsCopy.text(isLoading ? "Cancel" : (preview == nil ? "Show Preview" : "Hide Preview"), bundle: copyBundle)
                    + ": " + representation.identity.accessibilityLabel)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            if isLoading { ProgressView().controlSize(.small) }
            if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
            if case .some(.plainText(let preview, let wasTruncated)) = preview {
                Text(verbatim: preview)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 840, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, PanelTheme.spacingMedium)
                    .accessibilityIdentifier("clipy.details.text-preview." + representation.identity.accessibilitySuffix)
                    .accessibilityLabel(
                        PanelActionsCopy.format("Text preview of %@", representation.identity.accessibilityLabel, bundle: copyBundle)
                    )
                if wasTruncated {
                    Text(PreviewCopy.text(
                        "Preview truncated. Copying the item keeps its complete content.",
                        bundle: copyBundle
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clipy.details.truncation-notice." + representation.identity.accessibilitySuffix)
                }
            }
            if let raster = preview?.raster,
               let image = PreviewRasterDisplay.image(raster, scale: 1,
                   label: Text(PanelActionsCopy.format("Preview of %@", representation.identity.accessibilityLabel, bundle: copyBundle))) {
                image.resizable().scaledToFit().frame(maxWidth: .infinity)
                    .accessibilityIdentifier("clipy.details.image-preview." + representation.identity.accessibilitySuffix)
            }
            if case .some(.pdf(let pdf)) = preview {
                Text(PreviewCopy.pdfPageDisclosure(
                    pageNumber: pdf.pageNumber, pageCount: pdf.pageCount,
                    bundle: copyBundle, locale: locale
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("clipy.details.pdf-page-notice." + representation.identity.accessibilitySuffix)
            }
            if case .some(.image(let raster)) = preview, raster.sourceImageCount > 1 {
                Text(PreviewCopy.multiImageDisclosure(bundle: copyBundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clipy.details.multi-image-notice." + representation.identity.accessibilitySuffix)
            }
            if case .some(.reference(let reference)) = preview {
                // The same inert address/path presentation as the large pane;
                // Details does not request a file load or open a destination.
                ReferencePreviewView(reference: reference)
                    .containerRelativeFrame(.vertical) { length, _ in length * 0.6 }
                    .accessibilityIdentifier("clipy.details.reference-preview." + representation.identity.accessibilitySuffix)
            }
            if preview == .metadataOnly {
                Label(PanelActionsCopy.text("Preview unavailable", bundle: copyBundle), systemImage: "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        PanelActionsCopy.format("Preview unavailable for %@", representation.typeIdentifier, bundle: copyBundle)
                    )
            }
            DisclosureGroup(DetailsPresentationCopy.text("Format Details", bundle: copyBundle)) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: representation.typeIdentifier)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer(minLength: PanelTheme.spacingSmall)
                    Text(DetailsFormat.bytes(representation.byteCount, locale: locale))
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .disclosureGroupStyle(AppDisclosureGroupStyle(
                identifier: "clipy.details.format-details." + representation.identity.accessibilitySuffix,
                accessibilityLabel: DetailsPresentationCopy.text("Format Details", bundle: copyBundle) + ": " + representation.identity.accessibilityLabel
            ))
            .font(.caption)
        }
        .padding(.vertical, PanelTheme.spacingSmall)
    }
}

/// One revision row: title, creation date, byte count, the Active badge, and
/// the revert action (03b §9 `RevisionSummary`). Reverting to the already
/// active revision is a no-op state, so its button is disabled.
private struct RevisionRow: View {

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }

    let revision: RevisionSummary
    let onRevert: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: PanelTheme.spacingXXXSmall) {
                Text(revision.title)
                    .font(
                        .subheadline.weight(
                            revision.isActive ? .semibold : .regular
                        )
                    )
                    .lineLimit(1)
                Text(
                    DetailsFormat.dateTime(
                        revision.createdAt, locale: locale, timeZone: timeZone
                    )
                        + " · "
                        + DetailsFormat.bytes(revision.byteCount, locale: locale)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: PanelTheme.spacingSmall)
            if revision.isActive {
                Label(PanelActionsCopy.text("Active", bundle: copyBundle), systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(PanelActionsCopy.text("Active revision", bundle: copyBundle))
            }
            Button(PanelActionsCopy.text("Revert", bundle: copyBundle), action: onRevert)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(revision.isActive)
                .accessibilityLabel(PanelActionsCopy.format("Revert to %@", revision.title, bundle: copyBundle))
                .accessibilityHint(
                    PanelActionsCopy.text("Restores this revision as the item's current content.", bundle: copyBundle)
                )
        }
        .padding(.vertical, PanelTheme.spacingXXXSmall)
    }
}

// MARK: - Private helpers (file-scoped)

/// The lifecycle of one detail load (03b §10 typed failures mapped).
private enum DetailsPhase {
    case loading
    case loaded(HistoryDetails, DetailsContentPresentation)
    case removed
    case failed(message: String)
}

/// Which content lineage the Content section lists (03b §9).
internal enum ContentBasis: String, Hashable {
    case effective
    case canonical

    /// The user exports the displayed basis, never the bounded preview or a
    /// later History read. Canonical includes representations hidden by edits.
    func representation(
        typeIdentifier: String, in details: HistoryDetails, pasteboardItemIndex: Int = 0
    ) -> HistoryRepresentationRequest? {
        let values = self == .effective ? details.effective : details.canonical
        guard values.contains(where: { $0.typeIdentifier == typeIdentifier && $0.pasteboardItemIndex == pasteboardItemIndex }) else { return nil }
        return HistoryRepresentationRequest(item: details.item,
            basis: self == .effective ? .effective : .canonical, typeIdentifier: typeIdentifier,
            pasteboardItemIndex: pasteboardItemIndex)
    }
}

/// Details' bounded preview for one explicitly selected representation.
/// Exact UTF-8/UTF-16 text keeps the editor's strict codec; rich text, images,
/// PDF and inert references retain ContentPreview's artifacts and disclosure
/// facts. Other identifiers never acquire semantics merely from UTF-8-looking
/// bytes. Each row addresses its own Canonical/Effective source (V2-09 §5;
/// review TYPE-2), independently of sibling formats and the item's thumbnail.
enum DetailsRepresentationPresentation: Equatable, Sendable {
    case plainText(String, wasTruncated: Bool = false)
    case image(PreviewRaster)
    case pdf(PreviewPDF)
    case reference(PreviewReference)
    case metadataOnly

    var raster: PreviewRaster? {
        switch self {
        case .image(let raster): raster
        case .pdf(let pdf): pdf.raster
        case .plainText, .reference, .metadataOnly: nil
        }
    }

    /// One explicit row preview uses the renderer's existing metadata limits
    /// before reading bytes (V2-09 §5). Opaque and over-budget representations
    /// stay metadata-only; Save As continues to read their complete bytes.
    static func load(
        _ request: HistoryRepresentationRequest,
        metadata: HistoryRepresentationMetadata,
        history: any ClipboardHistory,
        renderer: ContentPreview
    ) async throws -> DetailsRepresentationPresentation {
        try Task.checkCancellation()
        guard let source = ContentPreview.prepareHistoryPane([
            PreviewRepresentationMetadata(
                typeIdentifier: metadata.typeIdentifier, byteCount: metadata.byteCount
            )
        ]).first, source.preflightFailure == nil else { return .metadataOnly }
        let raw = try await history.representation(request)
        try Task.checkCancellation()
        let type = ClipboardFormatIdentifier(rawValue: raw.typeIdentifier)
        if type == .utf8PlainText || type == .utf16PlainText || type == .utf16ExternalPlainText {
            let decoding = Task.detached {
                guard !Task.isCancelled else { return DetailsRepresentationPresentation.metadataOnly }
                return resolve(raw)
            }
            let presentation = await withTaskCancellationHandler {
                await decoding.value
            } onCancel: { decoding.cancel() }
            try Task.checkCancellation()
            return presentation
        }
        let outcome = await renderer.renderSelectedHistoryPane(source, representation: PreviewRepresentation(
            typeIdentifier: raw.typeIdentifier, bytes: raw.bytes
        ))
        try Task.checkCancellation()
        switch outcome {
        case .content(.text(let text)): return excerpt(text.text, wasTruncated: text.wasTruncated)
        case .content(.raster(let raster)): return .image(raster)
        case .content(.pdf(let pdf)): return .pdf(pdf)
        case .content(.reference(let reference)): return .reference(reference)
        default: return .metadataOnly
        }
    }

    static func resolve(
        _ representation: HistoryRepresentation
    ) -> DetailsRepresentationPresentation {
        // Both surfaces admit the same three exact plain-text encodings.
        // Share strict byte decoding with the editor so Details cannot strip
        // UTF-8 U+FEFF or interpret a second UTF-16 marker as encoding metadata.
        // The excerpt/empty-text policy remains owned by Details (roadmap 05).
        guard let text = EditorTextCodec.decode(representation)?.text, !text.isEmpty
        else {
            return .metadataOnly
        }
        return excerpt(text)
    }

    /// Keep truncation separate from selectable text. A renderer may already
    /// have truncated rich text before Details applies its shorter excerpt.
    private static func excerpt(_ text: String, wasTruncated: Bool = false) -> Self {
        let end = text.index(text.startIndex, offsetBy: 500, limitedBy: text.endIndex) ?? text.endIndex
        return .plainText(String(text[..<end]), wasTruncated: wasTruncated || end != text.endIndex)
    }
}

/// The initial Details overview contains only scalar metadata. Opening it
/// neither validates nor retains representation bytes; explicit selection owns
/// the separate, bounded preview artifact.
struct DetailsContentPresentation: Sendable {
    struct Representation: Sendable {
        let typeIdentifier: String
        let pasteboardItemIndex: Int
        var identity: RepresentationIdentity {
            RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)
        }
        let byteCount: Int
        let presentation: DetailsRepresentationPresentation
        let isImage: Bool

    }

    let canonical: [Representation]
    let effective: [Representation]
    let effectiveMatchesCanonical: Bool
    let symbolName: String
    /// Literal active-revision or first text title; the view localizes only
    /// its absent-title fallback, not user content or durable revision titles.
    let title: String?

    init(details: HistoryDetails) throws {
        canonical = try Self.prepare(details.canonical)
        try Task.checkCancellation()
        effectiveMatchesCanonical = details.effectiveMatchesCanonical
        effective = try Self.prepare(details.effective)
        symbolName = typeSymbol(for: details.effective.map(\.typeIdentifier))
        title = details.title
        try Task.checkCancellation()
    }

    private static func prepare(
        _ representations: [HistoryRepresentationMetadata]
    ) throws -> [Representation] {
        try representations.map { representation in
            try Task.checkCancellation()
            return Representation(
                typeIdentifier: representation.typeIdentifier,
                pasteboardItemIndex: representation.pasteboardItemIndex,
                byteCount: representation.byteCount,
                presentation: .metadataOnly,
                isImage: isImageType(representation.typeIdentifier)
            )
        }
    }
}

/// Locale-sensitive display of immutable Details facts; static UI copy stays
/// in PanelActions. Callers pass the view's environment, not system defaults.
internal enum DetailsFormat {
    static func count(_ value: UInt64, locale: Locale) -> String {
        value.formatted(.number.locale(locale))
    }

    static func bytes(_ value: Int, locale: Locale) -> String {
        value.formatted(ByteCountFormatStyle(style: .file, locale: locale))
    }

    /// Native abbreviated-date and standard-time styles follow the view's
    /// locale and time zone.
    /// Foundation caches the value format style's formatter internally, so
    /// a revision list does not allocate one DateFormatter per displayed row.
    static func dateTime(_ value: Date, locale: Locale, timeZone: TimeZone) -> String {
        value.formatted(Date.FormatStyle(
            date: .abbreviated, time: .standard,
            locale: locale, timeZone: timeZone
        ))
    }
}

/// Text-like icon classification only. This set is not a decoding contract:
/// `DetailsRepresentationPresentation` owns exact preview admission (review
/// TYPE-2).
private let textualTypeIdentifiers: Set<String> = [
    ClipboardFormatIdentifier.plainText.rawValue,
    ClipboardFormatIdentifier.utf8PlainText.rawValue,
    ClipboardFormatIdentifier.utf16PlainText.rawValue,
    ClipboardFormatIdentifier.utf16ExternalPlainText.rawValue,
    ClipboardFormatIdentifier.text.rawValue,
    ClipboardFormatIdentifier.rtf.rawValue,
    ClipboardFormatIdentifier.html.rawValue,
]

/// Exact image family for Details presentation, including the abstract image
/// identifier. This is a display classification, not a decoder contract.
private let imageTypeIdentifiers: Set<String> = [
    ClipboardFormatIdentifier.image.rawValue,
    ClipboardFormatIdentifier.png.rawValue,
    ClipboardFormatIdentifier.jpeg.rawValue,
    ClipboardFormatIdentifier.tiff.rawValue,
    ClipboardFormatIdentifier.heic.rawValue,
    ClipboardFormatIdentifier.heif.rawValue,
    ClipboardFormatIdentifier.gif.rawValue,
    ClipboardFormatIdentifier.bmp.rawValue,
]

/// A similar prefix does not establish that an unknown representation is an
/// image; opaque formats retain their unavailable-preview label (01 §2).
private func isImageType(_ typeIdentifier: String) -> Bool {
    imageTypeIdentifiers.contains(typeIdentifier)
}

/// SF Symbol fallback by dominant representation type.
private func typeSymbol(for typeIdentifiers: [String]) -> String {
    if typeIdentifiers.contains(where: isImageType) {
        return "photo"
    }
    if typeIdentifiers.contains(ClipboardFormatIdentifier.url.rawValue)
        || typeIdentifiers.contains(ClipboardFormatIdentifier.fileURL.rawValue) {
        return "link"
    }
    if typeIdentifiers.contains(where: textualTypeIdentifiers.contains) {
        return "doc.text"
    }
    return "doc.on.clipboard"
}

#if DEBUG
// Previews build DTOs through the package-visible inits (03a §3
// scripted-preview allowance). PreviewClipboardHistory.details throws
// .notFound, so the live-view preview shows the removed placeholder; the
// content preview exercises the private loaded body with canned DTOs.
#Preview("Removed") {
    NavigationStack {
        HistoryDetailsView(
            viewState: HistoryViewState(history: PreviewClipboardHistory.empty),
            item: HistoryItemReference(
                id: HistoryItemID(rawValue: UUID()),
                contentVersion: ContentVersion(rawValue: 1)
            )
        )
    }
    .frame(width: 400, height: 560)
}

#Preview("Content") {
    let details = detailsPreviewDetails()
    if let content = try? DetailsContentPresentation(details: details) {
        DetailsBody(
            details: details,
            content: content,
            thumbnails: ThumbnailStore(history: PreviewClipboardHistory.empty),
            basis: .constant(.effective),
            onRevise: { _ in }
        )
        .frame(width: 400, height: 560)
    }
}

#Preview("Content (Wide)") {
    let details = detailsPreviewDetails()
    if let content = try? DetailsContentPresentation(details: details) {
        DetailsBody(
            details: details,
            content: content,
            thumbnails: ThumbnailStore(history: PreviewClipboardHistory.empty),
            basis: .constant(.effective),
            onRevise: { _ in }
        )
        .frame(width: 720, height: 560)
    }
}

private func detailsPreviewDetails() -> HistoryDetails {
    HistoryDetails(
        item: HistoryItemReference(
            id: HistoryItemID(rawValue: UUID()),
            contentVersion: ContentVersion(rawValue: 3)
        ),
        title: "Meeting notes — Clipy design review",
        canonical: [
            HistoryRepresentationMetadata(typeIdentifier: ClipboardFormatIdentifier.html.rawValue, byteCount: 20),
            HistoryRepresentationMetadata(typeIdentifier: ClipboardFormatIdentifier.utf8PlainText.rawValue, byteCount: 71),
        ],
        effective: [HistoryRepresentationMetadata(typeIdentifier: ClipboardFormatIdentifier.utf8PlainText.rawValue, byteCount: 71)],
        effectiveMatchesCanonical: false,
        revisions: [
            RevisionSummary(
                id: RevisionID(rawValue: UUID()),
                createdAt: Date(timeIntervalSinceNow: -3_600),
                isActive: true,
                title: "Meeting notes — Clipy design review",
                typeIdentifiers: [
                    ClipboardFormatIdentifier.utf8PlainText.rawValue,
                ],
                byteCount: 64
            ),
            RevisionSummary(
                id: RevisionID(rawValue: UUID()),
                createdAt: Date(timeIntervalSinceNow: -86_400),
                isActive: false,
                title: "Meeting notes",
                typeIdentifiers: [
                    ClipboardFormatIdentifier.html.rawValue,
                    ClipboardFormatIdentifier.utf8PlainText.rawValue,
                ],
                byteCount: 96
            ),
        ],
        occurrence: CopyOccurrenceSummary(
            firstCopiedAt: Date(timeIntervalSinceNow: -86_400),
            lastCopiedAt: Date(timeIntervalSinceNow: -600),
            count: 4,
            firstSource: "com.apple.Safari",
            lastSource: "com.apple.Notes"
        ),
        pinnedPosition: 1
    )
}
#endif
