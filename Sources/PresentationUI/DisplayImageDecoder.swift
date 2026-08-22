/// DisplayImageDecoder.swift — PresentationUI's ONE ImageIO decode point: a
/// concrete, deliberately non-MainActor decoder actor that turns
/// already-encoded image bytes into bounded `CGImage`s for display.
///
/// Owning spec/audit trail: docs/01-architecture.md §6 bans image decode on
/// the MainActor ("no content fingerprinting, rich-text parsing, search
/// scan, or image decode"); the audit found both `ThumbnailStore` and
/// `HistoryPreviewView` decoding on it anyway (docs/reviews/
/// 2026-08-20-clipy-maccy-audit/01-standards.md §S-2; 02-spec-implementation.md
/// §SPEC-IMPL-002). The recommended target design names this owner:
/// "a concrete internal `DisplayImageDecoder` actor … accepts only encoded
/// image, does not read History, knows no UTIs, holds no completed cache"
/// (05-recommended-target-design.md §4.1 rule 2). Apple's current `CGImage`
/// reference lists `Sendable` (audit 02 §SPEC-IMPL-002, documentation check
/// 2026-08-20), so the immutable decoded image may cross from this actor to
/// the MainActor — the decode itself runs on THIS actor's executor, never
/// on the caller's.
///
/// Boundary discipline (05 §4.1 rule 3, a [PC] whose narrow spec amendment
/// to docs/01-architecture.md §8 and docs/v2/V2-07-ux.md §12 UX-COMPILE-1
/// remains an owned follow-up): this is the ONLY PresentationUI file that
/// imports ImageIO; the type stays internal to the module so no `CGImage`
/// appears on a `package`/`public` decode signature; and the import gates
/// (`scripts/import_gate.py`, `.swiftlint.yml`) are deliberately NOT
/// amended here — a flat PresentationUI ImageIO blocklist entry would
/// reject this file, and the path-scoped allowlist 05 §4.1 PREVIEW-OWNER-1
/// asks for must land with that spec amendment, not ahead of it.
import CoreGraphics
import Foundation
import ImageIO

/// The internal display-image decoder (05 §4.1 rule 2). Stateless: no
/// History access, no UTI policy, no completed-result retention (S-3: the
/// deferred G1 shared completed-thumbnail cache stays unimplemented —
/// docs/06-cross-cutting.md §3).
actor DisplayImageDecoder {

    /// Decodes one encoded PNG thumbnail payload (docs/
    /// 03b-instruction-set.md §9: History hands the UI encoded, `Sendable`
    /// bytes) into a `CGImage`. A decode failure returns `nil` — the caller
    /// records a negative result, never a panel failure.
    func thumbnailImage(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Downsampling-decodes full encoded image bytes into at most
    /// `maxPixelSize`×`maxPixelSize` pixels — the full bitmap never
    /// materializes, so only a bounded decoded image crosses to the
    /// MainActor (the decode-side half of 05 §4.1 PREVIEW-BOUND-1; bounding
    /// the ENCODED bytes before they reach the MainActor is the 05 §3.1
    /// `preview(for:pixels:)` storage seam, an owned follow-up).
    func previewImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
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
}
