/// HistoryPreviewView.swift — the preview column shown beside the history
/// list (Maccy's `PreviewItemView` replicated onto HistoryCore DTOs): the
/// selected item's Effective Content rendered large — image representations
/// downsampled through ImageIO, textual representations decoded per the
/// frozen encoding rule — plus a compact metadata bar.
///
/// Owning spec: docs/01-architecture.md §5.2/§6 (main-actor UI over
/// HistoryCore DTOs only — no AppKit, no SwiftData), §5.7 (image handling);
/// docs/03b-instruction-set.md §9 (Effective Content representations);
/// docs/05-authority-kernel.md §15 (the frozen textual UTI set and the
/// never-guess-an-encoding rule, mirrored here as in HistoryDetailsView).
import CoreGraphics
import Foundation
import HistoryCore
import ImageIO
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

/// The preview column: a loading indicator while the item's details load,
/// the resolved content, and a metadata bar (source, copy count, last
/// copied time — Maccy's preview footer replicated without AppKit app
/// icons, which PresentationUI's confinement forbids).
public struct HistoryPreviewView: View {
    private let viewState: HistoryViewState
    private let previewState: PreviewPaneState

    @State private var content: PreviewContent = .unavailable
    @State private var occurrence: CopyOccurrenceSummary?
    @State private var isLoading = false

    public init(viewState: HistoryViewState, previewState: PreviewPaneState) {
        self.viewState = viewState
        self.previewState = previewState
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
        .task(id: previewState.previewedItem) { await loadContent() }
    }

    // MARK: - Content

    @ViewBuilder
    private var previewBody: some View {
        if isLoading {
            ProgressView()
                .accessibilityLabel("Loading preview")
        } else {
            switch content {
            case .image(let bytes):
                imageContent(bytes)
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

    /// ImageIO-downsamples the encoded bytes into the preview box — the
    /// full bitmap never materializes (Maccy's `previewImageSize`
    /// downsampling replicated; CGImage keeps PresentationUI AppKit-free —
    /// 01 §6, the same seam `ThumbnailStore` uses).
    @ViewBuilder
    private func imageContent(_ bytes: Data) -> some View {
        if let image = Self.downsampledImage(from: bytes) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .padding(8)
        } else {
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
    }

    /// The ImageIO thumbnail bound for the preview column — generous versus
    /// the 320 pt column so retina renders stay crisp.
    private static let previewMaxPixelSize = 640

    private static func downsampledImage(from bytes: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: previewMaxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        // Primary-image index (audit
        // docs/reviews/2026-08-20-clipy-maccy-audit/03-apple-platform.md
        // §7 APL-C-06): CGImageSourceGetPrimaryImageIndex returns the
        // HEIF/HEIC container's designated primary image and 0 for every
        // non-HEIF source, so GIF/TIFF stay first-frame — a deliberate
        // product simplification (the audit's "GIF/TIFF first-frame may
        // be deliberate").
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            CGImageSourceGetPrimaryImageIndex(source),
            options as CFDictionary
        )
    }

    // MARK: - Metadata bar

    @ViewBuilder
    private var metadataBar: some View {
        HStack(spacing: 6) {
            if let occurrence {
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

    // MARK: - Loading

    /// Loads the previewed item's Effective Content through the view-state
    /// seam (a typed failure renders as unavailable — the preview is a
    /// convenience surface, not an error owner; 03b §10 stays with the
    /// panel's failure banner).
    private func loadContent() async {
        guard let item = previewState.previewedItem else {
            content = .unavailable
            occurrence = nil
            return
        }
        isLoading = true
        do {
            let details = try await viewState.details(for: item.id)
            content = PreviewContent.resolve(effective: details.effective)
            occurrence = details.occurrence
        } catch {
            content = .unavailable
            occurrence = nil
        }
        isLoading = false
    }
}
