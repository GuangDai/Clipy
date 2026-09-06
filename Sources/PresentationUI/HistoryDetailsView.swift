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
import Foundation
import HistoryCore
import SwiftUI

/// Monotonic ownership for one details view's async read. A destructive or
/// old-content purge invalidates the token synchronously, so a non-cooperative
/// read completion cannot republish sensitive `HistoryDetails` afterward
/// (review Card 9B).
package struct HistoryDetailsLoadFence {
    package private(set) var generation = 0
    package private(set) var isPurged = false
    package private(set) var observedSurfacePurgeGeneration: Int

    /// A newly constructed details surface starts after the purge currently
    /// retained by its owner. That historical value is a baseline, not an
    /// event to replay against an item created or navigated to later.
    package init(baselinePurgeGeneration: Int = 0) {
        observedSurfacePurgeGeneration = baselinePurgeGeneration
    }

    package mutating func begin() -> Int? {
        guard !isPurged else { return nil }
        generation += 1
        return generation
    }

    package mutating func purge(
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
    package mutating func reconcile(
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

    package func owns(_ token: Int) -> Bool {
        token == generation
    }

    package func accepts(
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
    package mutating func advanceReference(
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

/// The loaded Details presentation's pure width branch. The panel's browsing
/// column is user-resizable across `PanelGeometry`'s 360…720 points
/// (`minimumContentWidth`/`maximumContentWidth`), so the details surface's own
/// measured width decides between the original single-column Form and a
/// two-column metadata/content layout. The decision is pure presentation:
/// identical sections, data, actions, and reading order either way.
package enum DetailsLayout {
    /// Measured rendered width at which the two-column layout engages;
    /// anything below renders the unchanged single-column Form.
    package static let twoColumnMinimumWidth: CGFloat = 640

    /// True when `width` admits the two-column metadata/content layout.
    package static func usesTwoColumnLayout(width: CGFloat) -> Bool {
        width >= twoColumnMinimumWidth
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
    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }
    private let viewState: HistoryViewState
    private let onReferenceAdvance:
        (@MainActor (HistoryItemReference, HistoryItemReference) -> Bool)?
    @State private var currentItem: HistoryItemReference

    /// Reference-exact thumbnail cache (01 §5.7; 04 §9): keyed by
    /// `HistoryItemReference`, so a revised item never shows stale pixels.
    /// 128 px ≈ 2× the 64 pt header cell, keeping the header sharp on
    /// retina displays (the row list keeps the 72 px default).
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
    @State private var loadFence = HistoryDetailsLoadFence()

    /// The details surface's live measured width — the signal for
    /// `DetailsLayout`'s two-column branch. Zero before the first geometry
    /// report, which keeps the initial render on the single-column Form.
    @State private var detailsWidth: CGFloat = 0

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

    package init(
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
        .onChange(of: viewState.surfacePurge, initial: true) { _, _ in
            _ = reconcileSurfacePurge(viewState.surfacePurge)
        }
        // The browsing column's user resize (PanelGeometry 360…720) is this
        // view's live width signal; `onGeometryChange` reports it without
        // imposing a layout of its own — no GeometryReader.
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            detailsWidth = newSize.width
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
                usesTwoColumnLayout: DetailsLayout.usesTwoColumnLayout(
                    width: detailsWidth
                ),
                onRevise: { intent in
                    Task {
                        await revise(
                            intent: intent,
                            expected: details.item.contentVersion
                        )
                    }
                }
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
    /// The secondary actions wear their accessibility labels as visible text
    /// at the small control size so the bar still fits the resizable panel's
    /// narrowest (360-point) main column; only "Copy to Clipboard" stays
    /// prominent.
    private func actionBar(isPinned: Bool) -> some View {
        HStack(spacing: PanelTheme.spacingSmall) {
            Button {
                // The only History→pasteboard hand-off (01 §5.6); the view
                // state routes it to the composition root's paste closure.
                viewState.requestPaste(currentItem)
            } label: {
                Label(PanelActionsCopy.text("Copy to Clipboard", bundle: copyBundle), systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
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

    /// Loads (or reloads) the detail snapshot. `.notFound` maps to the
    /// removed placeholder; every other typed failure maps to the
    /// user-facing `FailurePresentation` message (03b §10).
    @MainActor
    private func load(presentingTransition: Bool = true) async {
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
            // Resolve all text rows once per immutable details snapshot,
            // away from MainActor body evaluation. Cancellation can retire
            // work between representations, not preempt a synchronous decode.
            let preparation = Task.detached(priority: .userInitiated) {
                try DetailsContentPresentation(details: details)
            }
            let content = try await withTaskCancellationHandler {
                try await preparation.value
            } onCancel: {
                preparation.cancel()
            }
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

/// The loaded-details layout: header, occurrence facts, the Effective/
/// Canonical content section, and the revision list. The presentation is a
/// pure width branch (`DetailsLayout`): below the two-column threshold the
/// original single-column Form renders unchanged; at or above it the same
/// sections split into a metadata column (left) and the content payload
/// (right).
private struct DetailsBody: View {

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }

    /// The fixed width of the two-column layout's metadata column; the
    /// content payload column flexes with the rest of the measured width.
    private static let metadataColumnWidth: CGFloat = 280

    let details: HistoryDetails
    let content: DetailsContentPresentation
    let thumbnails: ThumbnailStore
    @Binding var basis: ContentBasis
    let usesTwoColumnLayout: Bool
    let onRevise: (RevisionIntent) -> Void

    var body: some View {
        if usesTwoColumnLayout {
            twoColumnForm
        } else {
            singleColumnForm
        }
    }

    /// The original narrow presentation (measured width below the
    /// threshold): one grouped Form, unchanged.
    private var singleColumnForm: some View {
        Form {
            headerSection
            infoSection
            contentSection
            revisionsSection
        }
        .formStyle(.grouped)
    }

    /// The wide presentation (measured width at or above the threshold): the
    /// metadata sections in a fixed-width left Form, the content payload and
    /// its revision lineage in the flexible right Form. Both columns render
    /// the SAME section views as the single-column Form — identical data,
    /// actions, identifiers, and reading order (header → info → content →
    /// revisions); two Forms keep each column's grouped style and let a tall
    /// payload scroll without moving the metadata column.
    private var twoColumnForm: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                headerSection
                infoSection
            }
            .formStyle(.grouped)
            .frame(width: Self.metadataColumnWidth)
            Divider()
            Form {
                contentSection
                revisionsSection
            }
            .formStyle(.grouped)
        }
    }

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: PanelTheme.spacingLarge) {
                thumbnail
                    .frame(width: 64, height: 64)
                    .task(id: details.item) {
                        // Prefetch is gated by the same cheap UTI heuristic
                        // the row list uses (04 §9); the store applies a
                        // result only under the exact requesting reference.
                        if ThumbnailStore.likelyThumbnailable(
                            details.effective.map(\.typeIdentifier)
                        ) {
                            thumbnails.prefetch(details.item)
                        }
                    }
                VStack(
                    alignment: .leading,
                    spacing: PanelTheme.spacingXXSmall
                ) {
                    Text(content.title ?? PanelActionsCopy.text("Clipboard Item", bundle: copyBundle))
                        .font(.headline)
                        .lineLimit(2)
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
        Section(PanelActionsCopy.text("Info", bundle: copyBundle)) {
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
    }

    private var contentSection: some View {
        Section {
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

            ForEach(representations, id: \.typeIdentifier) { representation in
                RepresentationRow(
                    representation: representation,
                    // "Hidden" is a Canonical-lane fact: a retained canonical
                    // type that no longer flows into Effective (03a §5
                    // `.hide`).
                    isHiddenFromEffective: basis == .canonical
                        && !effectiveTypeIdentifiers.contains(
                            representation.typeIdentifier
                        )
                )
            }
        } header: {
            Text(PanelActionsCopy.text("Content", bundle: copyBundle))
        }
    }

    private var revisionsSection: some View {
        Section {
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
        } header: {
            HStack {
                Text(PanelActionsCopy.text("Revisions", bundle: copyBundle))
                Spacer()
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
            }
        }
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

    private var effectiveTypeIdentifiers: Set<String> {
        Set(details.effective.map(\.typeIdentifier))
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

    var body: some View {
        let presentation = representation.presentation
        VStack(alignment: .leading, spacing: PanelTheme.spacingXSmall) {
            HStack(alignment: .firstTextBaseline) {
                if representation.isImage {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(representation.typeIdentifier)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
                Text(
                    DetailsFormat.bytes(representation.byteCount, locale: locale)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if case .plainText(let preview) = presentation {
                ScrollView {
                    Text(preview)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "clipy.details.text-preview."
                                + representation.typeIdentifier
                        )
                }
                // The preview box tracks the resizable main column's width
                // (PanelGeometry 360…720); its height cap grew 120 → 160.
                .frame(
                    maxWidth: .infinity,
                    maxHeight: 160,
                    alignment: .leading
                )
                .padding(PanelTheme.spacingSmall)
                .background(
                    Color.primary.opacity(0.04),
                    in: RoundedRectangle(
                        cornerRadius: PanelTheme.cornerRadiusSmall
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: PanelTheme.cornerRadiusSmall
                    )
                    .strokeBorder(Color.primary.opacity(0.12))
                }
                .accessibilityLabel(
                    PanelActionsCopy.format("Text preview of %@", representation.typeIdentifier, bundle: copyBundle)
                )
            }
            if representation.showsUnavailablePreviewNotice {
                Label(PanelActionsCopy.text("Preview unavailable", bundle: copyBundle), systemImage: "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        PanelActionsCopy.format("Preview unavailable for %@", representation.typeIdentifier, bundle: copyBundle)
                    )
            }
        }
        .padding(.vertical, PanelTheme.spacingXXXSmall)
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
private enum ContentBasis: String, Hashable {
    case effective
    case canonical
}

/// Details' complete text-preview decision for one representation row.
///
/// Exact UTF-8 and native/external UTF-16 plain text use their declared byte
/// order, matching the large preview. Valid UTF-8 bytes under RTF, HTML,
/// abstract `public.text`, or encoding-unspecified `public.plain-text` remain
/// opaque; a sibling exact
/// plain-text representation is rendered independently by its own row. This
/// path performs no document import or external-resource work (review TYPE-2;
/// content-types review §3.4).
package enum DetailsRepresentationPresentation: Equatable, Sendable {
    case plainText(String)
    case metadataOnly

    package static func resolve(
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
        return .plainText(String(text.prefix(500)))
    }
}

/// Immutable display values prepared once for one Details load. Rows retain
/// bounded text and byte counts, never another copy of the source Data. This
/// is owned by the loaded phase and discarded with that snapshot.
package struct DetailsContentPresentation: Sendable {
    package struct Representation: Sendable {
        package let typeIdentifier: String
        package let byteCount: Int
        package let presentation: DetailsRepresentationPresentation
        package let isImage: Bool

        /// Item-thumbnail success or failure does not classify an individual
        /// image representation. Its row retains metadata without claiming
        /// that the source image was decoded or found unavailable (04 §9).
        package var showsUnavailablePreviewNotice: Bool {
            presentation == .metadataOnly && !isImage
        }
    }

    package let canonical: [Representation]
    package let effective: [Representation]
    package let effectiveMatchesCanonical: Bool
    package let symbolName: String
    /// Literal active-revision or first text title; the view localizes only
    /// its absent-title fallback, not user content or durable revision titles.
    package let title: String?

    package init(details: HistoryDetails) throws {
        canonical = try Self.prepare(details.canonical)
        try Task.checkCancellation()
        effectiveMatchesCanonical = details.effective == details.canonical
        // Domain equality deliberately accepts canonically equivalent type
        // identifiers (02 §2.1), but display rows retain each DTO's spelling.
        // Only share prepared rows when that spelling is byte-identical too.
        if effectiveMatchesCanonical,
           zip(details.canonical, details.effective).allSatisfy({ pair in
               pair.0.typeIdentifier.utf8.elementsEqual(pair.1.typeIdentifier.utf8)
           }) {
            effective = canonical
        } else {
            effective = try Self.prepare(details.effective)
        }
        symbolName = typeSymbol(for: details.effective.map(\.typeIdentifier))
        if let active = details.revisions.first(where: \.isActive) {
            title = active.title
        } else {
            title = effective.lazy.compactMap { representation -> String? in
                guard case .plainText(let text) = representation.presentation else { return nil }
                let firstLine = text.split(whereSeparator: \.isNewline).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return firstLine.isEmpty ? nil : String(firstLine.prefix(100))
            }.first
        }
        try Task.checkCancellation()
    }

    private static func prepare(
        _ representations: [HistoryRepresentation]
    ) throws -> [Representation] {
        try representations.map { representation in
            try Task.checkCancellation()
            return Representation(
                typeIdentifier: representation.typeIdentifier,
                byteCount: representation.bytes.count,
                presentation: DetailsRepresentationPresentation.resolve(representation),
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
            usesTwoColumnLayout: false,
            onRevise: { _ in }
        )
        .frame(width: 400, height: 560)
    }
}

#Preview("Content (Two-Column)") {
    let details = detailsPreviewDetails()
    if let content = try? DetailsContentPresentation(details: details) {
        DetailsBody(
            details: details,
            content: content,
            thumbnails: ThumbnailStore(history: PreviewClipboardHistory.empty),
            basis: .constant(.effective),
            usesTwoColumnLayout: true,
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
        canonical: [
            HistoryRepresentation(
                typeIdentifier: ClipboardFormatIdentifier.html.rawValue,
                bytes: Data("<p>Meeting notes</p>".utf8)
            ),
            HistoryRepresentation(
                typeIdentifier: ClipboardFormatIdentifier.utf8PlainText.rawValue,
                bytes: Data(
                    (
                        "Meeting notes — Clipy design review\n"
                            + "Second line of the bounded preview."
                    ).utf8
                )
            ),
        ],
        effective: [
            HistoryRepresentation(
                typeIdentifier: ClipboardFormatIdentifier.utf8PlainText.rawValue,
                bytes: Data(
                    (
                        "Meeting notes — Clipy design review\n"
                            + "Second line of the bounded preview."
                    ).utf8
                )
            ),
        ],
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
