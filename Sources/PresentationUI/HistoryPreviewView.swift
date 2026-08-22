/// HistoryPreviewView.swift — the preview column shown beside the history
/// list (Maccy's `PreviewItemView` replicated onto HistoryCore DTOs): the
/// selected item's Effective Content rendered large — image representations
/// downsampled OFF the MainActor through `DisplayImageDecoder`, textual
/// representations decoded per the frozen encoding rule — plus a compact
/// metadata bar.
///
/// Owning spec: docs/01-architecture.md §5.2/§6 (main-actor UI over
/// HistoryCore DTOs only — no AppKit, no SwiftData, no MainActor image
/// decode), §5.7 (image handling); docs/03b-instruction-set.md §9
/// (Effective Content representations); docs/05-authority-kernel.md §15
/// (the frozen textual UTI set and the never-guess-an-encoding rule,
/// mirrored here as in HistoryDetailsView). Async load law: audit
/// docs/reviews/2026-08-20-clipy-maccy-audit/02-spec-implementation.md
/// §SPEC-IMPL-007 and 05-recommended-target-design.md §4.1 PREVIEW-FENCE-1
/// (exact-reference fence; late results never publish).
import CoreGraphics
import Foundation
import HistoryCore
import SwiftUI

/// What the preview column renders for one item, resolved from its
/// Effective Content representations. Image representations win over text
/// (Maccy's image-first preview); anything else renders as unavailable.
public enum PreviewContent: Equatable, Sendable {
    /// Decoded body text, capped at `textCharacterCap` characters.
    case text(String)
    /// Encoded image bytes (the frozen v1 ImageIO-decodable UTIs).
    case image(Data)
    /// No previewable representation.
    case unavailable

    /// Long-body cap for the preview column: SwiftUI `Text` lays out its
    /// whole string, so the body is cut here (Maccy solves this with an
    /// NSTextView, which PresentationUI's no-AppKit rule forbids — 01 §8).
    /// `package` so the in-package resolver tests can size fixtures to it.
    package static let textCharacterCap = 50_000

    /// Resolves the preview content for one item's Effective Content.
    /// Image representations win; otherwise the first textual
    /// representation decodes per the frozen encoding rule (UTF-16 for
    /// `public.utf16-plain-text`, UTF-8 otherwise — 05 §15), truncated to
    /// `textCharacterCap` with a marker. Public so the app-hosted smoke
    /// suites (outside the SwiftPM package) can drive the same resolution
    /// the view renders.
    public static func resolve(
        effective representations: [HistoryRepresentation]
    ) -> PreviewContent {
        if let image = representations.first(where: {
            previewImageTypeIdentifiers.contains($0.typeIdentifier)
        }) {
            return .image(image.bytes)
        }
        if let text = representations.first(where: {
            previewTextualTypeIdentifiers.contains($0.typeIdentifier)
        }), let decoded = decodedPreviewText(of: text), !decoded.isEmpty {
            if decoded.count > textCharacterCap {
                return .text(String(decoded.prefix(textCharacterCap)) + "\n\n…")
            }
            return .text(decoded)
        }
        return .unavailable
    }

    /// Decodes one textual representation per its frozen encoding — mirrors
    /// storage's projector rule (05 §15): never guess a fallback encoding.
    private static func decodedPreviewText(
        of representation: HistoryRepresentation
    ) -> String? {
        if representation.typeIdentifier == "public.utf16-plain-text" {
            return String(data: representation.bytes, encoding: .utf16)
        }
        return String(data: representation.bytes, encoding: .utf8)
    }
}

/// Mirror of storage's frozen v1 textual UTI set (05 §15), duplicated for
/// display-only heuristics (PresentationUI cannot import HistoryStorage —
/// the same convention HistoryDetailsView documents).
private let previewTextualTypeIdentifiers: Set<String> = [
    "public.plain-text",
    "public.utf8-plain-text",
    "public.utf16-plain-text",
    "public.utf8-external-plain-text",
    "public.text",
    "public.rtf",
    "public.html",
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
/// any published state (the newer load owns `isLoading` and the content).
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
        /// Nothing previewable, or a typed failure — the preview is a
        /// convenience surface, not an error owner (03b §10's failure
        /// surface stays with the panel's banner).
        case unavailable
        /// Body text, capped at `PreviewContent.textCharacterCap`.
        case text(String)
        /// A bounded decoded image is published on `image`.
        case image
        /// The representation looked decodable but ImageIO produced nothing.
        case imageDecodeFailed
    }

    /// The applied content — always fenced to `requestedItem`.
    package private(set) var content: AppliedContent = .unavailable

    /// The metadata-bar facts for the applied item (03b §9).
    package private(set) var occurrence: CopyOccurrenceSummary?

    /// Whether the requested item's load is in flight.
    package private(set) var isLoading = false

    /// The exact reference the loader is serving — set synchronously at the
    /// head of every `load(item:)`; late completions compare against it.
    package private(set) var requestedItem: HistoryItemReference?

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

    /// Loads the preview content for `item` (`nil` clears the pane's
    /// content state). Driven by the view's `.task(id: previewedItem)`: a
    /// retarget cancels the previous load's task, and the fence covers the
    /// case where cancellation arrives late or the awaited work does not
    /// throw on cancellation.
    package func load(item: HistoryItemReference?) async {
        requestedItem = item
        guard let item else {
            image = nil
            content = .unavailable
            occurrence = nil
            isLoading = false
            return
        }
        isLoading = true
        do {
            let details = try await history.details(for: item.id)
            try Task.checkCancellation()
            guard requestedItem == item, details.item == item else { return }
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
                guard requestedItem == item else { return }
                image = decoded
                content = decoded == nil ? .imageDecodeFailed : .image
                occurrence = details.occurrence
            case .text(let text):
                image = nil
                content = .text(text)
                occurrence = details.occurrence
            case .unavailable:
                image = nil
                content = .unavailable
                occurrence = details.occurrence
            }
            isLoading = false
        } catch is CancellationError {
            // Discarded: a cancelled load publishes nothing — the retargeting
            // load (or the nil reset) owns every value from here.
        } catch {
            // A typed failure renders as unavailable — but only under the
            // still-current reference; a superseded/cancelled load's failure
            // must not clear the newer load's spinner.
            guard !Task.isCancelled, requestedItem == item else { return }
            image = nil
            content = .unavailable
            occurrence = nil
            isLoading = false
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

    @State private var loader: PreviewContentLoader

    public init(viewState: HistoryViewState, previewState: PreviewPaneState) {
        self.viewState = viewState
        self.previewState = previewState
        _loader = State(
            initialValue: PreviewContentLoader(history: viewState.history)
        )
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
        // One load per exact previewed reference; the loader's fence
        // discards a late result, so a superseded selection never renders
        // another item's content (SPEC-IMPL-007 / PREVIEW-FENCE-1).
        .task(id: previewState.previewedItem) {
            await loader.load(item: previewState.previewedItem)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var previewBody: some View {
        if loader.isLoading {
            ProgressView()
                .accessibilityLabel("Loading preview")
        } else {
            switch loader.content {
            case .image:
                if let image = loader.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    imageDecodeFailedBody
                }
            case .imageDecodeFailed:
                imageDecodeFailedBody
            case .text(let text):
                ScrollView(.vertical) {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            case .unavailable:
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
        }
    }

    /// The decode-failure placeholder: the representation looked decodable
    /// but ImageIO produced no image.
    private var imageDecodeFailedBody: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Preview Unavailable")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Metadata bar

    @ViewBuilder
    private var metadataBar: some View {
        HStack(spacing: 6) {
            if let occurrence = loader.occurrence {
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
