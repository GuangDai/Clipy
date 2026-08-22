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
/// (docs/06-cross-cutting.md §2), and every row-read path re-verifies the
/// projection schema and the scalar fields it consumes
/// (docs/05-authority-kernel.md §4). `effectiveTypeIdentifiers` is the sorted,
/// unique, non-empty type summary of the projected content.
internal struct ContentProjection: Sendable {
    /// Projection schema version; exactly `ContentProjector.schemaVersion`
    /// (projection recipe v2 = 2) for every newly projected value.
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

/// Byte counts already computed while fail-closed projection validation runs.
/// Debug search tracing consumes them; Release callers discard the value, so
/// correctness validation has one implementation in every configuration.
internal struct StoredProjectionSize: Equatable, Sendable {
    let titleUTF8Bytes: Int
    let searchBodyUTF8Bytes: Int
}

// MARK: - Projector (docs/05-authority-kernel.md §15)

/// Pure, deterministic projection from Effective Content to its bounded
/// durable `ContentProjection`. docs/05-authority-kernel.md §15
///
/// The projector is a namespace of pure functions — no actor, clock, I/O, or
/// framework decode. Image bytes are never decoded for title/search (§15):
/// only representations whose exact type identifier declares the frozen v2
/// plain-text encoding are decoded, so identical content always projects
/// identically. Encoding-unspecified, abstract, and structured text formats
/// remain opaque.
internal enum ContentProjector {
    /// The current projection recipe. Version 2 removes the v1 guessed UTF-8
    /// decode of encoding-unspecified, abstract, RTF, and HTML values (§15).
    internal static let schemaVersion: UInt16 = 2

    /// The only legacy projection recipe accepted by startup rebuild. It is
    /// never accepted by an ordinary read boundary (§13, §15).
    internal static let legacySchemaVersion: UInt16 = 1

    // MARK: Stored projection validation (docs/05-authority-kernel.md §4)

    /// Re-validates the schema tag before any durable projection scalar is
    /// trusted. A future projection schema requires an explicit migration;
    /// ordinary reads never guess how to interpret another version.
    internal static func validateStoredSchemaVersion(_ found: UInt16) throws {
        guard found == schemaVersion else {
            throw CodecRejection.unknownProjectionSchemaVersion(found: found)
        }
    }

    /// Re-validates a durable title at its read boundary. The write-side
    /// projector truncates valid values; an over-bound stored value is
    /// corruption, not input to truncate or repair locally.
    @discardableResult
    internal static func validateStoredTitle(
        _ title: String,
        limits: HistoryLimits
    ) throws -> Int {
        let found = title.utf8.count
        guard found <= limits.maximumStoredTitleUTF8Bytes else {
            throw CodecRejection.storedTitleExceedsBound(
                found: found,
                bound: limits.maximumStoredTitleUTF8Bytes
            )
        }
        return found
    }

    /// Re-validates a durable search body under the same fail-closed rule.
    @discardableResult
    internal static func validateStoredSearchBody(
        _ searchBody: String,
        limits: HistoryLimits
    ) throws -> Int {
        let found = searchBody.utf8.count
        guard found <= limits.maximumStoredSearchBodyUTF8Bytes else {
            throw CodecRejection.storedSearchBodyExceedsBound(
                found: found,
                bound: limits.maximumStoredSearchBodyUTF8Bytes
            )
        }
        return found
    }

    /// Full validation used by lineage hydration and search corpus reads.
    @discardableResult
    internal static func validateStoredProjection(
        schemaVersion: UInt16,
        title: String,
        searchBody: String,
        limits: HistoryLimits
    ) throws -> StoredProjectionSize {
        try validateStoredSchemaVersion(schemaVersion)
        let titleUTF8Bytes = try validateStoredTitle(title, limits: limits)
        let searchBodyUTF8Bytes = try validateStoredSearchBody(
            searchBody,
            limits: limits
        )
        return StoredProjectionSize(
            titleUTF8Bytes: titleUTF8Bytes,
            searchBodyUTF8Bytes: searchBodyUTF8Bytes
        )
    }

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
        var searchBody = ""
        var remainingSearchBodyBytes = limits.maximumStoredSearchBodyUTF8Bytes
        var hasSearchBodyPart = false
        for representation in content.representations {
            // Both sinks complete: nothing later can contribute. A textual
            // representation can only add search-body bytes (budget already
            // exhausted) or a title (already found), so its full decode and
            // newline-normalization copy are skipped entirely — decisive
            // when a capture carries multi-megabyte representations after
            // the first one already filled the 256-KiB body budget.
            if title != nil, remainingSearchBodyBytes == 0 {
                break
            }
            guard let text = decodedText(of: representation) else { continue }
            let normalized = normalizingNewlines(text)
            if title == nil {
                title = firstContentLine(of: normalized)
            }

            // Build the durable corpus directly under its hard byte bound.
            // Joining all decoded representations first lets transient memory
            // scale with arbitrarily large capture bytes even though the
            // stored value is bounded (docs/06-cross-cutting.md §9, WL3).
            guard containsNonWhitespace(in: normalized) else { continue }
            if hasSearchBodyPart {
                guard appendUTF8Prefix(
                    "\n",
                    to: &searchBody,
                    remainingByteCount: &remainingSearchBodyBytes
                ) else {
                    break
                }
            }
            hasSearchBodyPart = true
            guard appendUTF8Prefix(
                normalized,
                to: &searchBody,
                remainingByteCount: &remainingSearchBodyBytes
            ) else {
                break
            }
        }
        return ContentProjection(
            schemaVersion: schemaVersion,
            title: truncatedToUTF8ByteLimit(
                title ?? typeBasedFallbackTitle(typeIdentifiers: typeIdentifiers),
                limit: limits.maximumStoredTitleUTF8Bytes
            ),
            searchBody: searchBody,
            effectiveTypeIdentifiers: typeIdentifiers
        )
    }

    /// Computes only the bounded title for read paths that do not consume a
    /// search body or type summary. In particular, revision summaries must not
    /// decode and join the full search corpus merely to display a title
    /// (docs/05-authority-kernel.md §9, §15; docs/06-cross-cutting.md §9).
    internal static func projectTitle(
        _ content: EffectiveContent,
        limits: HistoryLimits = .standard
    ) -> String {
        for representation in content.representations {
            guard
                let text = decodedText(of: representation),
                let title = firstContentLine(of: normalizingNewlines(text))
            else {
                continue
            }
            return truncatedToUTF8ByteLimit(
                title,
                limit: limits.maximumStoredTitleUTF8Bytes
            )
        }
        return truncatedToUTF8ByteLimit(
            typeBasedFallbackTitle(
                typeIdentifiers: content.representations.map(\.typeIdentifier)
            ),
            limit: limits.maximumStoredTitleUTF8Bytes
        )
    }

    // MARK: Textual eligibility and decoding (§15)

    /// The frozen projection-v2 set whose exact type names declare the byte
    /// encoding used for title/search projection. Encoding-unspecified
    /// `public.plain-text`, abstract `public.text`, RTF, and HTML stay opaque
    /// until an owning format decoder is separately approved (§15).
    internal static let textualTypeIdentifiers: Set<String> = [
        "public.utf8-plain-text",
        "public.utf16-plain-text",
        "public.utf8-external-plain-text",
    ]

    /// Decodes one representation's bytes as text, or returns `nil` when the
    /// representation is not title/search eligible (§15: image bytes are not
    /// decoded). Encoding is fixed by the explicit type: UTF-16 only for
    /// `public.utf16-plain-text`, UTF-8 for every other frozen textual type.
    /// The projector never guesses a fallback encoding for malformed bytes;
    /// an undecodable representation is skipped rather than durable mojibake.
    /// Set membership means the non-UTF-16 cases have an exact UTF-8 contract;
    /// there is no generic textual fallback.
    private static func decodedText(
        of representation: ContentRepresentation
    ) -> String? {
        guard textualTypeIdentifiers.contains(representation.typeIdentifier) else {
            return nil
        }
        let encoding: String.Encoding =
            representation.typeIdentifier == "public.utf16-plain-text"
            ? .utf16
            : .utf8
        return String(data: representation.bytes, encoding: encoding)
    }

    // MARK: Normalization (§15)

    /// Newline normalization: CRLF and lone CR fold to LF so line splitting,
    /// title selection, and stored search bodies are independent of the
    /// source newline convention. Deterministic; no other bytes change.
    private static func normalizingNewlines(_ text: String) -> String {
        var normalized = ""
        normalized.reserveCapacity(text.utf8.count)
        for character in text {
            if character == "\r\n" || character == "\r" {
                normalized.append("\n")
            } else {
                normalized.append(character)
            }
        }
        return normalized
    }

    /// The first line whose whitespace-trimmed form is non-empty, trimmed;
    /// `nil` when the text has no such line (§15: "first eligible textual
    /// line after normalization").
    private static func firstContentLine(of normalizedText: String) -> String? {
        var start = normalizedText.startIndex
        while true {
            let end = normalizedText[start...].firstIndex(of: "\n")
                ?? normalizedText.endIndex
            let trimmed = normalizedText[start..<end]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            guard end != normalizedText.endIndex else { return nil }
            start = normalizedText.index(after: end)
        }
    }

    /// `true` when a normalized textual representation contributes something
    /// other than whitespace/newlines to the search corpus (§15).
    private static func containsNonWhitespace(in text: String) -> Bool {
        text.unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    /// Appends as much of `text` as fits at a Character boundary and reports
    /// whether the full input was appended. The destination never grows past
    /// its caller-owned UTF-8 budget.
    private static func appendUTF8Prefix(
        _ text: String,
        to result: inout String,
        remainingByteCount: inout Int
    ) -> Bool {
        for character in text {
            let width = character.utf8.count
            guard width <= remainingByteCount else { return false }
            result.append(character)
            remainingByteCount -= width
        }
        return true
    }

    // MARK: Type-based fallback title (§15)

    /// Image type identifiers recognized by the fallback title. Frozen for v2
    /// alongside `textualTypeIdentifiers`.
    private static let imageTypeIdentifiers: Set<String> = [
        "public.image",
        "public.png",
        "public.jpeg",
        "public.tiff",
        "com.compuserve.gif",
        "public.heic",
        "public.heif",
        "com.microsoft.bmp",
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
