/// HistoryPreviewView.swift — the preview column shown beside the history
/// list (Maccy's `PreviewItemView` replicated onto HistoryCore DTOs): the
/// selected item's Effective Content rendered large — image representations
/// downsampled OFF the MainActor through `DisplayImageDecoder`, exact
/// plain-text representations decoded only through their declared codec —
/// plus a compact metadata bar.
///
/// Owning spec: docs/01-architecture.md §5.2/§6 (main-actor UI over
/// HistoryCore DTOs only — no AppKit, no SwiftData, no MainActor image
/// decode), §5.7 (image handling); docs/03b-instruction-set.md §9
/// (Effective Content representations); review TYPE-2 / 08 §7 (structured
/// and encoding-unspecified text stays opaque; exact plain siblings win).
/// Async load law: audit
/// docs/reviews/2026-08-20-clipy-maccy-audit/02-spec-implementation.md
/// §SPEC-IMPL-007 and 05-recommended-target-design.md §4.1 PREVIEW-FENCE-1
/// (exact-reference fence; late results never publish).
import CoreGraphics
import ClipboardFormats
import Foundation
import HistoryCore
import SwiftUI

/// What the preview column renders for one item, resolved from its
/// Effective Content representations. Image representations win over text
/// (Maccy's image-first preview); the loader deepens its coarse unavailable
/// result into unsupported versus failed without widening this public DTO.
public enum PreviewContent: Equatable, Sendable {
    /// Decoded body text, capped at `textCharacterCap` characters.
    case text(String)
    /// Encoded image bytes (the frozen v1 ImageIO-decodable UTIs).
    case image(Data)
    /// No preview body resolved at this public presentation seam.
    case unavailable

    /// Long-body cap for the preview column: SwiftUI `Text` lays out its
    /// whole string, so the body is cut here (Maccy solves this with an
    /// NSTextView, which PresentationUI's no-AppKit rule forbids — 01 §8).
    /// `package` so the in-package resolver tests can size fixtures to it.
    package static let textCharacterCap = 50_000

    /// Resolves the preview content for one item's Effective Content.
    /// Image representations win; otherwise the first exact plain-text
    /// representation with a declared codec is decoded and truncated to
    /// `textCharacterCap` with a marker. Structured (`public.rtf` /
    /// `public.html`) and abstract or encoding-unspecified text is never
    /// presented as UTF-8 source. Public so app-hosted smoke suites (outside
    /// the SwiftPM package) can drive the same resolution the view renders.
    public static func resolve(
        effective representations: [HistoryRepresentation]
    ) -> PreviewContent {
        if let image = representations.first(where: {
            previewImageTypeIdentifiers.contains($0.typeIdentifier)
        }) {
            return .image(image.bytes)
        }
        for text in representations where PreviewTextCodec(
            typeIdentifier: text.typeIdentifier
        ) != nil {
            guard let decoded = decodedPreviewText(of: text), !decoded.isEmpty else {
                continue
            }
            if decoded.count > textCharacterCap {
                return .text(String(decoded.prefix(textCharacterCap)) + "\n\n…")
            }
            return .text(decoded)
        }
        return .unavailable
    }

    /// Decodes only an exact type with an explicit codec. There is no
    /// conformance-based or fallback encoding guess (review TYPE-2).
    private static func decodedPreviewText(
        of representation: HistoryRepresentation
    ) -> String? {
        guard let codec = PreviewTextCodec(
            typeIdentifier: representation.typeIdentifier
        ) else {
            return nil
        }
        return codec.decode(representation.bytes)
    }
}

/// Exact plain-text types admitted by this preview owner and the codec each
/// declares. External UTF-16 is intentionally not admitted until its distinct
/// big-endian rule has an owned fixture (review TYPE-2 / PLAY-FORMAT-B).
private enum PreviewTextCodec: Sendable {
    case declared(DeclaredStringCodec)

    init?(typeIdentifier: String) {
        let identifier = ClipboardFormatIdentifier(rawValue: typeIdentifier)
        guard previewTextIdentifiers.contains(identifier),
              let codec = identifier.declaredStringCodec
        else {
            return nil
        }
        self = .declared(codec)
    }

    func decode(_ bytes: Data) -> String? {
        switch self {
        case .declared(.utf8):
            return String(data: bytes, encoding: .utf8)
        case .declared(.nativeUTF16):
            // UTType.utf16PlainText is native byte order with an optional
            // BOM. Clipy's only platform is arm64 macOS, so BOM-less input is
            // UTF-16LE; an explicit BOM overrides that default.
            if bytes.starts(with: [0xFE, 0xFF]) {
                return String(data: bytes.dropFirst(2), encoding: .utf16BigEndian)
            }
            if bytes.starts(with: [0xFF, 0xFE]) {
                return String(data: bytes.dropFirst(2), encoding: .utf16LittleEndian)
            }
            return String(data: bytes, encoding: .utf16LittleEndian)
        }
    }
}

/// Preview owns this admission choice. The shared module contributes only the
/// exact identifiers and their declared codec facts; external UTF-8 remains a
/// separate product decision even though its wire encoding is known.
private let previewTextIdentifiers: Set<ClipboardFormatIdentifier> = [
    .utf8PlainText,
    .utf16PlainText,
]

/// Mirror of storage's frozen v1 ImageIO-decodable set (04 §9), duplicated
/// for display-only heuristics (same convention as HistoryDetailsView and
/// `ThumbnailStore.thumbnailableTypeIdentifiers`).
private let previewImageTypeIdentifiers: Set<String> = [
    "public.png",
    "public.jpeg",
    "public.tiff",
    "public.heic",
    "public.heif",
    "com.compuserve.gif",
    "com.microsoft.bmp",
]

/// The preview column's content loader (audit 02 §SPEC-IMPL-007; 05 §4.1
/// PREVIEW-FENCE-1): owns the async details read, the off-MainActor bounded
/// image decode, and the exact-reference fence.
///
/// Fence law: a load captures its `HistoryItemReference` at start; after
/// EVERY await it re-checks cancellation AND that its reference is still
/// the requested one. The details answer itself must also carry that same
/// reference: `details(for:)` reads by ID, so a concurrent revision that
/// advanced the Content Version is invisible to the request — the
/// `details.item == item` half pins the version (04 §9's caller-side fence
/// convention). A late or superseded result is DISCARDED without touching
/// any published state (the newer load owns the phase and applied content).
/// Starting a new exact reference invalidates the previous publication
/// before the first suspension, so old sensitive content is not retained as
/// a loading placeholder.
///
/// Retention: only the REQUESTED item's applied content lives here — a
/// bounded decoded image or a capped text body. The full Effective Content
/// bytes are a transient local of `load(item:)`, never stored (closing
/// SPEC-IMPL-007's "retains the full selected image bytes in view state").
/// Bounding those bytes BEFORE they reach the MainActor needs the 05 §3.1
/// `preview(for:pixels:)` storage seam — an owned follow-up outside this
/// file set.
@MainActor @Observable
package final class PreviewContentLoader {

    /// What the preview column renders for the requested item. Carries no
    /// image pixels: the decoded `CGImage` stays on the internal `image`
    /// property, so no `CGImage` appears on a package/public signature
    /// (05 §4.1 rule 3).
    package enum AppliedContent: Equatable {
        /// Body text, capped at `PreviewContent.textCharacterCap`.
        case text(String)
        /// A bounded decoded image is published on `image`.
        case image
    }

    /// The loader's closed presentation phase (review Card 9D). A valid type
    /// without a renderer is stable `.unsupported`; History and decoder
    /// failures are retryable `.failed` episodes and never masquerade as
    /// unsupported content.
    package enum Phase: Equatable {
        case loading
        case content(AppliedContent)
        case failed
        case unsupported
    }

    /// The current phase — always fenced to `requestedItem`.
    package private(set) var phase: Phase = .unsupported

    /// The metadata-bar facts for the applied item (03b §9).
    package private(set) var occurrence: CopyOccurrenceSummary?

    /// The exact reference the loader is serving — set synchronously at the
    /// head of every `load(item:)`; late completions compare against it.
    package private(set) var requestedItem: HistoryItemReference?

    /// Distinguishes overlapping load episodes even when they request the
    /// same exact reference. Reference equality alone cannot tell an older
    /// retry from the current request (review Card 9A).
    private var requestGeneration = 0

    /// The decoded, bounded preview pixels — valid while `content` is
    /// `.image`. Internal: a `CGImage` never appears on a package/public
    /// signature (05 §4.1 rule 3).
    private(set) var image: CGImage?

    /// The applied image's pixel dimensions — the package-observable proof
    /// of a decode without exposing the image itself.
    package var appliedImageSize: CGSize? {
        image.map { CGSize(width: $0.width, height: $0.height) }
    }

    private let history: any ClipboardHistory

    /// The off-MainActor decode hop (S-2/SPEC-IMPL-002); stateless.
    private let decoder = DisplayImageDecoder()

    /// The ImageIO thumbnail bound for the preview column — generous versus
    /// the 320 pt column so retina renders stay crisp.
    private static let previewMaxPixelSize = 640

    package init(history: any ClipboardHistory) {
        self.history = history
    }

    /// Starts a fresh episode for the same exact reference. The loader owns
    /// the generation/reference transition, so the view never reconstructs
    /// a request from an ID after a retryable failure (review Card 9D).
    package func retry() async {
        guard phase == .failed, let requestedItem else { return }
        await load(item: requestedItem)
    }

    /// Loads the preview content for `item` (`nil` clears the pane's
    /// content state). Driven by the view's `.task(id: targetItem)`: a
    /// retarget cancels the previous load's task, and the fence covers the
    /// case where cancellation arrives late or the awaited work does not
    /// throw on cancellation.
    package func load(item: HistoryItemReference?) async {
        requestGeneration += 1
        let generation = requestGeneration
        requestedItem = item
        image = nil
        occurrence = nil
        phase = item == nil ? .unsupported : .loading
        guard let item else {
            return
        }
        do {
            let details = try await history.details(for: item.id)
            try Task.checkCancellation()
            guard requestGeneration == generation,
                  requestedItem == item
            else { return }
            guard details.item == item else {
                // The ID-based detail read raced a revision. Observation
                // retargets the current exact reference; this stale episode
                // must settle instead of retaining a permanent spinner.
                phase = .failed
                return
            }
            switch PreviewContent.resolve(effective: details.effective) {
            case .image(let bytes):
                // Bounded decode OFF the MainActor (S-2/SPEC-IMPL-002): only
                // the downsampled image is published; the full encoded bytes
                // drop with this scope.
                let decoded = await decoder.previewImage(
                    from: bytes,
                    maxPixelSize: Self.previewMaxPixelSize
                )
                try Task.checkCancellation()
                guard requestGeneration == generation,
                      requestedItem == item
                else { return }
                image = decoded
                if decoded == nil {
                    phase = .failed
                    occurrence = nil
                } else {
                    phase = .content(.image)
                    occurrence = details.occurrence
                }
            case .text(let text):
                image = nil
                phase = .content(.text(text))
                occurrence = details.occurrence
            case .unavailable:
                image = nil
                if details.effective.contains(where: {
                    PreviewTextCodec(typeIdentifier: $0.typeIdentifier) != nil
                }) {
                    phase = .failed
                    occurrence = nil
                } else {
                    phase = .unsupported
                    occurrence = details.occurrence
                }
            }
        } catch is CancellationError {
            // Cancellation is only a publication fence. It does not publish
            // a phase transition or claim that underlying History/native
            // work stopped; a superseding request owns the next phase.
            return
        } catch {
            // History keeps its own typed taxonomy. Presentation records only
            // a retryable failed episode, and only under the still-current
            // exact reference; no Storage failure is reclassified here.
            guard !Task.isCancelled,
                  requestGeneration == generation,
                  requestedItem == item
            else { return }
            image = nil
            occurrence = nil
            phase = .failed
        }
    }
}

/// The preview column: a loading indicator while the item's content loads,
/// the resolved content, and a metadata bar (source, copy count, last
/// copied time — Maccy's preview footer replicated without AppKit app
/// icons, which PresentationUI's confinement forbids).
public struct HistoryPreviewView: View {
    private let viewState: HistoryViewState
    private let previewState: PreviewPaneState
    private let selectionSource: SelectionSource

    @State private var loader: PreviewContentLoader

    /// Standalone entry point: PreviewPaneState owns the exact target.
    public init(viewState: HistoryViewState, previewState: PreviewPaneState) {
        self.viewState = viewState
        self.previewState = previewState
        selectionSource = .paneState
        _loader = State(
            initialValue: PreviewContentLoader(history: viewState.history)
        )
    }

    /// The composed panel supplies the reference derived directly from its
    /// latest rows, closing the observation→preview gap before dwell state
    /// finishes retargeting the visible pane (review Card 9A).
    package init(
        viewState: HistoryViewState,
        previewState: PreviewPaneState,
        selection: PreviewSelectionResolution
    ) {
        self.viewState = viewState
        self.previewState = previewState
        selectionSource = .observedRows(selection)
        _loader = State(
            initialValue: PreviewContentLoader(history: viewState.history)
        )
    }

    private enum SelectionSource {
        case paneState
        case observedRows(PreviewSelectionResolution)
    }

    private var targetItem: HistoryItemReference? {
        switch selectionSource {
        case .paneState:
            previewState.previewedItem
        case .observedRows(let selection):
            selection.previewTarget(previewedItem: previewState.previewedItem)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            previewBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            metadataBar
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        // One load per exact observed reference; the loader's fence
        // discards a late result, so a superseded selection never renders
        // another item's content (SPEC-IMPL-007 / PREVIEW-FENCE-1).
        .task(id: targetItem) {
            await loader.load(item: targetItem)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var previewBody: some View {
        if targetItem == nil {
            unavailableBody
        } else if loader.requestedItem != targetItem {
            ProgressView()
                .accessibilityLabel("Loading preview")
        } else {
            switch loader.phase {
            case .loading:
                ProgressView()
                    .accessibilityLabel("Loading preview")
            case .content(.image):
                if let image = loader.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    failedBody
                }
            case .content(.text(let text)):
                ScrollView(.vertical) {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            case .failed:
                failedBody
            case .unsupported:
                unavailableBody
            }
        }
    }

    private var unavailableBody: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No Preview")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Retry is offered only for a supported preview whose History read or
    /// decoder failed. Stable unsupported content uses `unavailableBody` and
    /// therefore never presents this control (review Card 9D).
    private var failedBody: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Preview Unavailable")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task {
                    await loader.retry()
                }
            }
        }
    }

    // MARK: - Metadata bar

    @ViewBuilder
    private var metadataBar: some View {
        HStack(spacing: 6) {
            if loader.requestedItem == targetItem,
               let occurrence = loader.occurrence {
                if let source = occurrence.lastSource {
                    Text(source)
                        .lineLimit(1)
                }
                Text("Copied \(occurrence.count)×")
                Spacer(minLength: 4)
                Text(occurrence.lastCopiedAt, style: .date)
                Text(occurrence.lastCopiedAt, style: .time)
            } else {
                Spacer()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
