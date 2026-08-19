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
import Foundation
import HistoryCore
import SwiftUI

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

    public init(viewState: HistoryViewState, item: HistoryItemReference) {
        self.viewState = viewState
        self.item = item
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
                viewState.remove(item.id)
                Task { await load(presentingTransition: false) }
            }
            Button("Cancel", role: .cancel) {}
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
                if isPinned {
                    viewState.unpin(item.id)
                } else {
                    viewState.pin(item.id)
                }
                Task { await load(presentingTransition: false) }
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
        if presentingTransition {
            phase = .loading
        }
        do {
            phase = .loaded(try await viewState.details(for: item.id))
        } catch let failure as HistoryFailure {
            switch failure {
            case .notFound:
                phase = .removed
            default:
                phase = .failed(
                    message: FailurePresentation.message(for: failure)
                )
            }
        } catch {
            guard error is CancellationError else {
                phase = .failed(message: "Clipy couldn't load this item.")
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
/// bounded preview — ≤500 characters of monospaced text for UTF-8-decodable
/// textual types, or the item thumbnail for image types (03b §9).
private struct RepresentationRow: View {

    let representation: HistoryRepresentation
    let isHiddenFromEffective: Bool
    let thumbnails: ThumbnailStore
    let item: HistoryItemReference

    var body: some View {
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
            if let preview = textPreview(of: representation) {
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

/// Mirror of storage's frozen v1 textual UTI set (docs/05-authority-kernel.md
/// §15) — PresentationUI cannot import HistoryStorage, so the well-known set
/// is duplicated here for display-only heuristics.
private let textualTypeIdentifiers: Set<String> = [
    "public.plain-text",
    "public.utf8-plain-text",
    "public.utf16-plain-text",
    "public.utf8-external-plain-text",
    "public.text",
    "public.rtf",
    "public.html",
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
    "public.bmp",
]

/// `true` when the representation's type is one of the frozen textual UTIs
/// and its bytes decode as UTF-8 — the preview eligibility rule. The UTF-16
/// type is in the frozen set but naturally fails the UTF-8 decode.
private func isUTF8TextRepresentation(
    _ representation: HistoryRepresentation
) -> Bool {
    guard textualTypeIdentifiers.contains(representation.typeIdentifier) else {
        return false
    }
    return String(data: representation.bytes, encoding: .utf8) != nil
}

/// The ≤500-character UTF-8 preview of a textual representation, or `nil`
/// when the type is not textual or the bytes do not decode as UTF-8.
private func textPreview(of representation: HistoryRepresentation) -> String? {
    guard isUTF8TextRepresentation(representation),
        let text = String(data: representation.bytes, encoding: .utf8),
        !text.isEmpty
    else { return nil }
    return String(text.prefix(500))
}

/// Decodes one textual representation per its frozen encoding (UTF-16 for
/// `public.utf16-plain-text`, UTF-8 otherwise) — mirrors storage's
/// projector rule (05 §15): never guess a fallback encoding.
private func decodedText(of representation: HistoryRepresentation) -> String? {
    guard textualTypeIdentifiers.contains(representation.typeIdentifier) else {
        return nil
    }
    if representation.typeIdentifier == "public.utf16-plain-text" {
        return String(data: representation.bytes, encoding: .utf16)
    }
    return String(data: representation.bytes, encoding: .utf8)
}

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
        guard let text = decodedText(of: representation) else { continue }
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
                typeIdentifier: "public.html",
                bytes: Data("<p>Meeting notes</p>".utf8)
            ),
            HistoryRepresentation(
                typeIdentifier: "public.utf8-plain-text",
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
                typeIdentifier: "public.utf8-plain-text",
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
                typeIdentifiers: ["public.utf8-plain-text"],
                byteCount: 64
            ),
            RevisionSummary(
                id: RevisionID(rawValue: UUID()),
                createdAt: Date(timeIntervalSinceNow: -86_400),
                isActive: false,
                title: "Meeting notes",
                typeIdentifiers: ["public.html", "public.utf8-plain-text"],
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
