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
}

/// Detail screen for one retained item (roadmap 05). Loads `HistoryDetails`
/// via the view state, renders the Effective/Canonical content with
/// per-representation previews, offers revision revert, and the per-item
/// action set. A `.staleContent` typed failure from any revise/revert (03b
/// §10) reloads the details and surfaces an inline notice instead of
/// discarding the user's place.
public struct HistoryDetailsView: View {

    private let viewState: HistoryViewState
    private let item: HistoryItemReference

    /// Reference-exact thumbnail cache (01 §5.7; 04 §9): keyed by
    /// `HistoryItemReference`, so a revised item never shows stale pixels.
    /// 128 px ≈ 2× the 64 pt header cell, keeping the header sharp on
    /// retina displays (the row list keeps the 72 px default).
    @State private var thumbnails: ThumbnailStore

    @State private var phase: DetailsPhase = .loading
    @State private var basis: ContentBasis = .effective
    @State private var showsStaleNotice = false
    @State private var failureNotice: String?
    @State private var showsEditor = false
    @State private var showsRemoveConfirmation = false
    @State private var isRemoving = false
    @State private var loadFence = HistoryDetailsLoadFence()

    public init(viewState: HistoryViewState, item: HistoryItemReference) {
        self.viewState = viewState
        self.item = item
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

    public var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .loading:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .removed:
                ContentUnavailableView(
                    "Item Removed",
                    systemImage: "trash",
                    description: Text("This item is no longer in your clipboard history.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label(
                        "Couldn't Load Item",
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task { await load() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let details):
                loadedLayout(for: details)
            }
        }
        .navigationTitle("Details")
        .task { await load() }
        .sheet(
            isPresented: $showsEditor,
            onDismiss: {
                // A saved revision advances the Content Version; this reload
                // keeps the screen on current state (04 §5 — observation is
                // snapshot replacement; the detail view re-reads on demand).
                Task { await load(presentingTransition: false) }
            }
        ) {
            if case .loaded(let details) = phase {
                ReviseEditorView(viewState: viewState, details: details)
            }
        }
        .confirmationDialog(
            "Remove this item from your clipboard history?",
            isPresented: $showsRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task { await remove() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: viewState.surfacePurge, initial: true) { _, _ in
            _ = reconcileSurfacePurge(viewState.surfacePurge)
        }
    }

    // MARK: Loaded layout

    @ViewBuilder
    private func loadedLayout(for details: HistoryDetails) -> some View {
        VStack(spacing: 0) {
            if showsStaleNotice {
                noticeBanner(
                    text: "This item changed while you were viewing it."
                        + " Details reloaded.",
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
                thumbnails: thumbnails,
                basis: $basis,
                onRevise: { intent in
                    Task {
                        await revise(
                            intent: intent,
                            expected: details.item.contentVersion
                        )
                    }
                }
            )
            Divider()
            actionBar(isPinned: details.pinnedPosition != nil)
        }
    }

    /// The per-item action set (contract §4.2 "toolbar"): rendered as a
    /// persistent bottom bar because a MenuBarExtra window has no window
    /// toolbar surface for `.toolbar` items — the four actions are identical.
    private func actionBar(isPinned: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                // The only History→pasteboard hand-off (01 §5.6); the view
                // state routes it to the composition root's paste closure.
                viewState.requestPaste(item)
            } label: {
                Label("Copy to Clipboard", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            Spacer(minLength: 8)
            Button {
                Task { await togglePin(isPinned: isPinned) }
            } label: {
                Image(systemName: isPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.bordered)
            .help(isPinned ? "Unpin" : "Pin")
            .accessibilityLabel(isPinned ? "Unpin" : "Pin")
            .accessibilityHint(
                "Pinned items stay at the top of the list and are exempt"
                    + " from unpinned retention limits."
            )
            Button {
                showsEditor = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.bordered)
            .help("Edit Content…")
            .accessibilityLabel("Edit Content")
            .accessibilityHint("Opens the revision editor for this item.")
            Button {
                showsRemoveConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .help("Remove")
            .accessibilityLabel("Remove")
            .accessibilityHint(
                "Removes this item from your clipboard history."
            )
            .disabled(isRemoving)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Inline dismissible notice row (stale reload / typed failure).
    private func noticeBanner(
        text: String,
        systemImage: String,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05))
    }

    // MARK: Data flow

    /// Loads (or reloads) the detail snapshot. `.notFound` maps to the
    /// removed placeholder; every other typed failure maps to the
    /// user-facing `FailurePresentation` message (03b §10).
    @MainActor
    private func load(presentingTransition: Bool = true) async {
        guard reconcileSurfacePurge(viewState.surfacePurge) else { return }
        guard let generation = loadFence.begin() else {
            phase = .removed
            return
        }
        if presentingTransition {
            phase = .loading
        }
        do {
            let details = try await viewState.details(for: item.id)
            guard reconcileSurfacePurge(viewState.surfacePurge) else { return }
            guard loadFence.accepts(
                generation,
                returned: details.item,
                expected: item,
                isCancelled: Task.isCancelled
            ) else {
                if !Task.isCancelled,
                   loadFence.owns(generation),
                   details.item != item {
                    phase = .removed
                }
                return
            }
            phase = .loaded(details)
        } catch let failure as HistoryFailure {
            guard reconcileSurfacePurge(viewState.surfacePurge) else { return }
            guard !Task.isCancelled, loadFence.owns(generation) else { return }
            switch failure {
            case .notFound:
                phase = .removed
            default:
                phase = .failed(
                    message: FailurePresentation.message(for: failure)
                )
            }
        } catch {
            guard reconcileSurfacePurge(viewState.surfacePurge) else { return }
            guard !Task.isCancelled, loadFence.owns(generation) else { return }
            guard error is CancellationError else {
                phase = .failed(message: "Clipy couldn't load this item.")
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
        if let scope = loadFence.reconcile(purge, item: item) {
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
        do {
            if isPinned {
                _ = try await viewState.unpinAwaitingReceipt(item.id)
            } else {
                _ = try await viewState.pinAwaitingReceipt(item.id)
            }
            await load(presentingTransition: false)
        } catch let failure as HistoryFailure {
            failureNotice = FailurePresentation.message(for: failure)
        } catch {
            guard error is CancellationError else {
                failureNotice = "Clipy couldn't update this item."
                return
            }
        }
    }

    /// Performs one revise/revert against the version the screen loaded,
    /// then reloads. `.staleContent` reloads plus the inline notice (03b §10);
    /// other typed failures surface their message inline.
    @MainActor
    private func revise(intent: RevisionIntent, expected: ContentVersion) async {
        do {
            _ = try await viewState.revise(
                RevisionRequest(itemID: item.id, expected: expected, intent: intent)
            )
            await load(presentingTransition: false)
        } catch let failure as HistoryFailure {
            if case .staleContent = failure {
                showsStaleNotice = true
                await load(presentingTransition: false)
            } else {
                failureNotice = FailurePresentation.message(for: failure)
            }
        } catch {
            guard error is CancellationError else {
                failureNotice = "Clipy couldn't update this item."
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
            _ = try await viewState.removeAwaitingReceipt(item.id)
            // The receipt-confirmed surface purge owns dismissal. Do not
            // issue a guaranteed-notFound read after a successful Remove.
        } catch let failure as HistoryFailure {
            failureNotice = FailurePresentation.message(for: failure)
        } catch {
            guard error is CancellationError else {
                failureNotice = "Clipy couldn't remove this item."
                return
            }
        }
    }
}

// MARK: - Loaded body (private, previewable with canned DTOs)

/// The loaded-details layout: header, occurrence facts, the Effective/
/// Canonical content section, and the revision list.
private struct DetailsBody: View {

    let details: HistoryDetails
    let thumbnails: ThumbnailStore
    @Binding var basis: ContentBasis
    let onRevise: (RevisionIntent) -> Void

    var body: some View {
        Form {
            headerSection
            infoSection
            contentSection
            revisionsSection
        }
        .formStyle(.grouped)
    }

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
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
                VStack(alignment: .leading, spacing: 4) {
                    Text(detailTitle(for: details))
                        .font(.headline)
                        .lineLimit(2)
                    pinBadge
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = thumbnails.image(for: details.item) {
            Image(image, scale: 2, label: Text("Item thumbnail"))
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Item thumbnail")
        } else {
            Image(
                systemName: typeSymbol(
                    for: details.effective.map(\.typeIdentifier)
                )
            )
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
            .frame(width: 64, height: 64)
            .background(
                Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .accessibilityLabel("Content type icon")
        }
    }

    @ViewBuilder
    private var pinBadge: some View {
        if let position = details.pinnedPosition {
            // `pinnedPosition` is 0-based (03b §8); display is 1-based.
            Label("Pinned #\(position + 1)", systemImage: "pin.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: Capsule()
                )
                .accessibilityLabel("Pinned at position \(position + 1)")
        } else {
            Text("Unpinned")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    private var infoSection: some View {
        Section("Info") {
            LabeledContent(
                "First Copied",
                value: DetailsFormat.mediumDateTime.string(
                    from: details.occurrence.firstCopiedAt
                )
            )
            LabeledContent(
                "Last Copied",
                value: DetailsFormat.mediumDateTime.string(
                    from: details.occurrence.lastCopiedAt
                )
            )
            LabeledContent(
                "Copy Count",
                value: String(details.occurrence.count)
            )
            LabeledContent(
                "Source",
                value: details.occurrence.lastSource.map {
                    ($0 as NSString).lastPathComponent
                } ?? "Unknown"
            )
            LabeledContent(
                "Content Version",
                value: String(details.item.contentVersion.rawValue)
            )
        }
    }

    private var contentSection: some View {
        Section {
            Picker("Content", selection: $basis) {
                Text("Effective").tag(ContentBasis.effective)
                Text("Canonical").tag(ContentBasis.canonical)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Content view")
            .accessibilityHint(
                "Effective lists what pasting produces now; Canonical lists"
                    + " every retained original type."
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
                        ),
                    thumbnails: thumbnails,
                    item: details.item
                )
            }
        } header: {
            Text("Content")
        }
    }

    private var revisionsSection: some View {
        Section {
            if details.revisions.isEmpty {
                Text("No revisions")
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
                Text("Revisions")
                Spacer()
                Button {
                    onRevise(.revert(to: .canonical))
                } label: {
                    Label(
                        "Revert to Original",
                        systemImage: "arrow.uturn.backward"
                    )
                }
                .controlSize(.small)
                .accessibilityLabel("Revert to Original")
                .accessibilityHint(
                    "Restores the canonical content as this item's current"
                        + " content."
                )
            }
        }
    }

    private var representations: [HistoryRepresentation] {
        basis == .effective ? details.effective : details.canonical
    }

    private var effectiveTypeIdentifiers: Set<String> {
        Set(details.effective.map(\.typeIdentifier))
    }
}

// MARK: - Rows (private)

/// One representation row in the Content section: monospaced type identifier,
/// byte size, "Hidden" badge (canonical-but-not-effective types), and the
/// bounded preview — ≤500 characters only for exact UTF-8 plain text, or the
/// item thumbnail for image types. Structured, abstract, encoding-unspecified,
/// and unknown representations remain type + byte metadata (review TYPE-2).
private struct RepresentationRow: View {

    let representation: HistoryRepresentation
    let isHiddenFromEffective: Bool
    let thumbnails: ThumbnailStore
    let item: HistoryItemReference

    var body: some View {
        let presentation = DetailsRepresentationPresentation.resolve(
            representation
        )
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(representation.typeIdentifier)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if isHiddenFromEffective {
                    Label("Hidden", systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Color.primary.opacity(0.06),
                            in: Capsule()
                        )
                        .accessibilityLabel("Hidden from effective content")
                }
                Text(
                    DetailsFormat.bytes.string(
                        fromByteCount: Int64(representation.bytes.count)
                    )
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
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(
                    Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.12))
                }
                .accessibilityLabel(
                    "Text preview of \(representation.typeIdentifier)"
                )
            }
            if presentation == .metadataOnly,
                !isImageType(representation.typeIdentifier)
            {
                Label("Preview unavailable", systemImage: "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "Preview unavailable for \(representation.typeIdentifier)"
                    )
            }
            if isImageType(representation.typeIdentifier),
                let image = thumbnails.image(for: item)
            {
                Image(image, scale: 2, label: Text("Item thumbnail"))
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 120, maxHeight: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(
                        "Image preview of \(representation.typeIdentifier)"
                    )
            }
        }
        .padding(.vertical, 2)
    }
}

/// One revision row: title, creation date, byte count, the Active badge, and
/// the revert action (03b §9 `RevisionSummary`). Reverting to the already
/// active revision is a no-op state, so its button is disabled.
private struct RevisionRow: View {

    let revision: RevisionSummary
    let onRevert: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(revision.title)
                    .font(
                        .subheadline.weight(
                            revision.isActive ? .semibold : .regular
                        )
                    )
                    .lineLimit(1)
                Text(
                    DetailsFormat.mediumDateTime.string(
                        from: revision.createdAt
                    )
                        + " · "
                        + DetailsFormat.bytes.string(
                            fromByteCount: Int64(revision.byteCount)
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if revision.isActive {
                Label("Active", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Active revision")
            }
            Button("Revert", action: onRevert)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(revision.isActive)
                .accessibilityLabel("Revert to \(revision.title)")
                .accessibilityHint(
                    "Restores this revision as the item's current content."
                )
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Private helpers (file-scoped)

/// The lifecycle of one detail load (03b §10 typed failures mapped).
private enum DetailsPhase {
    case loading
    case loaded(HistoryDetails)
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
/// Exact `public.utf8-plain-text` is the only admitted text contract in this
/// owner. Valid UTF-8 bytes under RTF, HTML, abstract `public.text`, or
/// encoding-unspecified `public.plain-text` remain opaque; a sibling exact
/// plain-text representation is rendered independently by its own row. This
/// path performs no document import or external-resource work (review TYPE-2;
/// content-types review §3.4).
package enum DetailsRepresentationPresentation: Equatable, Sendable {
    case plainText(String)
    case metadataOnly

    package static func resolve(
        _ representation: HistoryRepresentation
    ) -> DetailsRepresentationPresentation {
        guard ClipboardFormatIdentifier(
            rawValue: representation.typeIdentifier
        ) == .utf8PlainText,
            let text = String(data: representation.bytes, encoding: .utf8),
            !text.isEmpty
        else {
            return .metadataOnly
        }
        return .plainText(String(text.prefix(500)))
    }
}

/// Main-actor-cached formatters (Foundation formatters are not Sendable;
/// they stay confined to the UI actor, 01 §6).
@MainActor
private enum DetailsFormat {
    static let mediumDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

/// Text-like icon classification only. This set is not a decoding contract:
/// `DetailsRepresentationPresentation` owns exact preview admission (review
/// TYPE-2).
private let textualTypeIdentifiers: Set<String> = [
    ClipboardFormatIdentifier.plainText.rawValue,
    ClipboardFormatIdentifier.utf8PlainText.rawValue,
    ClipboardFormatIdentifier.utf16PlainText.rawValue,
    ClipboardFormatIdentifier.utf8ExternalPlainText.rawValue,
    ClipboardFormatIdentifier.text.rawValue,
    ClipboardFormatIdentifier.rtf.rawValue,
    ClipboardFormatIdentifier.html.rawValue,
]

/// Mirror of storage's frozen v1 ImageIO-decodable set (docs/04-coherence.md
/// §9; `HistoryAuthority+DetailAndThumbnail.thumbnailImageTypeIdentifiers`).
private let imageTypeIdentifiers: Set<String> = [
    "public.png",
    "public.jpeg",
    "public.tiff",
    "public.heic",
    "public.heif",
    "com.compuserve.gif",
    "com.microsoft.bmp",
]

/// Image-type display heuristic (thumbnail row in the Content section).
private func isImageType(_ typeIdentifier: String) -> Bool {
    imageTypeIdentifiers.contains(typeIdentifier)
        || typeIdentifier.hasPrefix("public.image")
}

/// SF Symbol fallback by dominant representation type.
private func typeSymbol(for typeIdentifiers: [String]) -> String {
    if typeIdentifiers.contains(where: isImageType) {
        return "photo"
    }
    if typeIdentifiers.contains(where: { $0.contains("url") }) {
        return "link"
    }
    if typeIdentifiers.contains(where: textualTypeIdentifiers.contains) {
        return "doc.text"
    }
    return "doc.on.clipboard"
}

/// The header title. Storage projects every revision's title from its
/// content (ContentProjector, 05 §15), so the active revision's title IS the
/// item's current title; the client-side fallback mirrors that derivation
/// for robustness.
private func detailTitle(for details: HistoryDetails) -> String {
    if let active = details.revisions.first(where: \.isActive) {
        return active.title
    }
    for representation in details.effective {
        guard case .plainText(let text) =
            DetailsRepresentationPresentation.resolve(representation)
        else { continue }
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstLine.isEmpty {
            return String(firstLine.prefix(100))
        }
    }
    return "Clipboard Item"
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
    DetailsBody(
        details: detailsPreviewDetails(),
        thumbnails: ThumbnailStore(history: PreviewClipboardHistory.empty),
        basis: .constant(.effective),
        onRevise: { _ in }
    )
    .frame(width: 400, height: 560)
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
