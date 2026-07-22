/// ContentProjection / ContentProjector — the bounded durable projection of
/// current Effective Content that backs list/search reads without decoding
/// content bytes.
/// Owning spec: docs/05-authority-kernel.md §15 (projection rules), §6.1
/// (the `ContentProjection` value and capture-side projection step), §3.1
/// (the projection columns of `HistoryItemRow`); bounds and the truncation
/// rule: docs/06-cross-cutting.md §2 ("Truncating title/search projection is
/// allowed at a deterministic Unicode boundary").
///
/// Capture projection uses initial Effective Content (Canonical Content with
/// fingerprints stripped); revision projection uses the prepared proposed
/// Effective Content. Copy Coalescing, pin, unpin, clear, removal, and
/// retention never recompute it (§15). Projection schema changes require an
/// explicit schema version and a migration/rebuild plan; they never change
/// Canonical Content, revisions, or Content Version by themselves.
import Foundation
import HistoryCore
import HistoryDomain

// MARK: - Projected value (docs/05-authority-kernel.md §6.1, §15)

/// The durable bounded projection of one Effective Content state.
/// docs/05-authority-kernel.md §6.1, §15
///
/// `title` and `searchBody` obey the Part VI stored-projection bounds
/// (`HistoryLimits.maximumStoredTitleUTF8Bytes`,
/// `HistoryLimits.maximumStoredSearchBodyUTF8Bytes`) by construction:
/// `ContentProjector` truncates at a deterministic Unicode boundary
/// (docs/06-cross-cutting.md §2), and blob/row decode re-verifies the same
/// bounds (docs/05-authority-kernel.md §4). `effectiveTypeIdentifiers` is the
/// sorted, unique, non-empty type summary of the projected content.
internal struct ContentProjection: Sendable {
    /// Projection schema version; exactly `ContentProjector.schemaVersion`
    /// (v1 = 1) for every value the v1 projector emits.
    internal let schemaVersion: UInt16
    /// First eligible textual line after normalization, otherwise a stable
    /// type-based fallback (§15).
    internal let title: String
    /// Eligible textual representations in deterministic type order,
    /// normalized and truncated to the hard search-body bound (§15).
    internal let searchBody: String
    /// Sorted unique list of the Effective Content's type identifiers (§15).
    internal let effectiveTypeIdentifiers: [String]
}

// MARK: - Projector (docs/05-authority-kernel.md §15)

/// Pure, deterministic projection from Effective Content to its bounded
/// durable `ContentProjection`. docs/05-authority-kernel.md §15
///
/// The projector is a namespace of pure functions — no actor, clock, I/O, or
/// framework decode. Image bytes are never decoded for title/search (§15):
/// only representations whose type identifier is in the frozen v1 textual set
/// are decoded, with a fixed encoding precedence, so identical content always
/// projects identically.
internal enum ContentProjector {
    /// The only projection schema version v1 writes (§6.1: "v1 = 1"; §15:
    /// projection schema changes require an explicit schema version).
    internal static let schemaVersion: UInt16 = 1

    // MARK: Projection

    /// Projects one Effective Content state to its bounded durable value.
    /// docs/05-authority-kernel.md §15
    ///
    /// - Title: the first line (in deterministic representation order, then
    ///   line order) whose whitespace-trimmed form is non-empty, trimmed and
    ///   truncated to `limits.maximumStoredTitleUTF8Bytes`; when no textual
    ///   representation yields such a line, a stable type-based fallback.
    /// - Search body: the newline-normalized text of every eligible textual
    ///   representation, in the content's normalized type-identifier order,
    ///   joined by `\n` and truncated to
    ///   `limits.maximumStoredSearchBodyUTF8Bytes`. Whitespace-only texts
    ///   contribute nothing. The body may be empty (image-only content);
    ///   the §4 decode bounds permit that.
    /// - Effective type identifiers: the content's type identifiers, already
    ///   sorted, unique, and non-empty by the normalized-set invariant
    ///   (docs/02-domain.md §2.1).
    ///
    /// `content` must be a normalized, non-normalized-empty Effective Content
    /// value as produced by `effectiveContent(of:)` or capture preparation;
    /// the projector relies on that invariant rather than re-validating.
    /// `limits` is the fixed `HistoryLimits.standard` profile in production
    /// (docs/06-cross-cutting.md §2); focused tests inject smaller bounds.
    internal static func project(
        _ content: EffectiveContent,
        limits: HistoryLimits = .standard
    ) -> ContentProjection {
        let typeIdentifiers = content.representations.map(\.typeIdentifier)
        var title: String?
        var bodyParts: [String] = []
        bodyParts.reserveCapacity(content.representations.count)
        for representation in content.representations {
            guard let text = decodedText(of: representation) else { continue }
            let normalized = normalizingNewlines(text)
            if title == nil {
                title = firstContentLine(of: normalized)
            }
            if !normalized.isEmpty {
                bodyParts.append(normalized)
            }
        }
        return ContentProjection(
            schemaVersion: schemaVersion,
            title: truncatedToUTF8ByteLimit(
                title ?? typeBasedFallbackTitle(typeIdentifiers: typeIdentifiers),
                limit: limits.maximumStoredTitleUTF8Bytes
            ),
            searchBody: truncatedToUTF8ByteLimit(
                bodyParts.joined(separator: "\n"),
                limit: limits.maximumStoredSearchBodyUTF8Bytes
            ),
            effectiveTypeIdentifiers: typeIdentifiers
        )
    }

    // MARK: Textual eligibility and decoding (§15)

    /// The frozen v1 set of type identifiers whose bytes are treated as text
    /// for title/search projection. docs/05-authority-kernel.md §15 ("eligible
    /// textual") — the spec does not enumerate the set; v1 freezes the
    /// well-known textual UTIs so projection stays a pure, deterministic
    /// function of the content with no framework conformance lookup.
    internal static let textualTypeIdentifiers: Set<String> = [
        "public.plain-text",
        "public.utf8-plain-text",
        "public.utf16-plain-text",
        "public.utf8-external-plain-text",
        "public.text",
        "public.rtf",
        "public.html",
    ]

    /// Decodes one representation's bytes as text, or returns `nil` when the
    /// representation is not title/search eligible (§15: image bytes are not
    /// decoded). Encoding precedence is fixed: `public.utf16-plain-text`
    /// tries UTF-16 then UTF-8; every other textual type tries UTF-8 then
    /// UTF-16. A representation whose bytes decode under neither encoding is
    /// skipped rather than projected as mojibake.
    private static func decodedText(
        of representation: ContentRepresentation
    ) -> String? {
        guard textualTypeIdentifiers.contains(representation.typeIdentifier) else {
            return nil
        }
        let encodings: [String.Encoding] =
            representation.typeIdentifier == "public.utf16-plain-text"
            ? [.utf16, .utf8]
            : [.utf8, .utf16]
        for encoding in encodings {
            if let text = String(data: representation.bytes, encoding: encoding) {
                return text
            }
        }
        return nil
    }

    // MARK: Normalization (§15)

    /// Newline normalization: CRLF and lone CR fold to LF so line splitting,
    /// title selection, and stored search bodies are independent of the
    /// source newline convention. Deterministic; no other bytes change.
    private static func normalizingNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// The first line whose whitespace-trimmed form is non-empty, trimmed;
    /// `nil` when the text has no such line (§15: "first eligible textual
    /// line after normalization").
    private static func firstContentLine(of normalizedText: String) -> String? {
        for line in normalizedText.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: Type-based fallback title (§15)

    /// Image type identifiers recognized by the fallback title. Frozen for v1
    /// alongside `textualTypeIdentifiers`.
    private static let imageTypeIdentifiers: Set<String> = [
        "public.image",
        "public.png",
        "public.jpeg",
        "public.tiff",
        "com.compuserve.gif",
        "public.heic",
        "public.heif",
        "public.bmp",
    ]

    /// The stable type-based fallback title used when no textual
    /// representation yields a title line (§15: "otherwise a stable
    /// type-based fallback"). The spec does not fix the fallback's shape; v1
    /// freezes a deterministic function of the sorted type-identifier list:
    /// a fixed label for a recognized category, otherwise the first type
    /// identifier (never empty — a normalized content set is non-empty and
    /// identifiers are validated non-empty).
    private static func typeBasedFallbackTitle(typeIdentifiers: [String]) -> String {
        for identifier in typeIdentifiers where imageTypeIdentifiers.contains(identifier) {
            return "Image"
        }
        if typeIdentifiers.contains("public.url") { return "URL" }
        if typeIdentifiers.contains("public.file-url") { return "File" }
        return typeIdentifiers[0]
    }

    // MARK: Deterministic Unicode-boundary truncation (docs/06-cross-cutting.md §2)

    /// Truncates `text` to at most `limit` UTF-8 bytes at a Character
    /// (extended grapheme cluster) boundary — the deterministic Unicode
    /// boundary Part VI §2 permits for title/search projection. Truncating
    /// between Characters never splits a grapheme cluster. No-op when the
    /// text already fits.
    ///
    /// `limit - byteCount` is used instead of `byteCount + width <= limit` so
    /// no arithmetic can overflow: `byteCount` never exceeds `limit`.
    internal static func truncatedToUTF8ByteLimit(_ text: String, limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var byteCount = 0
        var end = text.startIndex
        for character in text {
            let width = character.utf8.count
            guard width <= limit - byteCount else { break }
            byteCount += width
            end = text.index(after: end)
        }
        return String(text[..<end])
    }
}
