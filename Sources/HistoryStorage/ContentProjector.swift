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
import ClipboardFormats
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
    /// (projection recipe v5 = 5) for every newly projected value.
    internal let schemaVersion: UInt16
    /// First eligible textual line, otherwise eligible reference metadata or
    /// a stable type-based fallback (§15).
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
/// The projector is a namespace of pure functions — no actor, clock, or I/O.
/// Image bytes are never decoded for title/search (§15). Recipe-v4 exact
/// plain-text codecs keep priority; recipe 5 additionally projects bounded
/// URL/file reference metadata without following the reference. Other
/// encoding-unspecified, abstract, and structured text formats remain opaque.
internal enum ContentProjector {
    /// Recipe 5 adds inert reference metadata when neither a textual title
    /// nor a known image owns the projection. Startup rebuilds recipes 1–4
    /// using their unchanged Canonical/revision bytes (§15).
    internal static let schemaVersion: UInt16 = 5

    /// The original recipe used by legacy migration fixtures. Startup also
    /// accepts recipes 2–4; ordinary reads accept only recipe 5 (§13, §15).
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
    ///   representation yields such a line and no known image is present,
    ///   a valid reference supplies its filename/address before type fallback.
    /// - Search body: the newline-normalized text of every eligible textual
    ///   representation, in the content's normalized type-identifier order,
    ///   joined by `\n` and truncated to
    ///   `limits.maximumStoredSearchBodyUTF8Bytes`. Whitespace-only texts
    ///   contribute nothing. A reference owning the title instead contributes
    ///   its original address and non-empty decoded path under the same join
    ///   and byte budget. The body may be empty (image-only/opaque content).
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
            // search-body traversal are skipped entirely — decisive
            // when a capture carries multi-megabyte representations after
            // the first one already filled the 256-KiB body budget.
            if title != nil, remainingSearchBodyBytes == 0 {
                break
            }
            guard let text = decodedText(of: representation) else { continue }
            if title == nil {
                title = firstContentLine(of: text)
            }

            // Build the durable corpus directly under its hard byte bound.
            // Joining all decoded representations first lets transient memory
            // scale with arbitrarily large capture bytes even though the
            // stored value is bounded (docs/06-cross-cutting.md §9, WL3).
            guard containsNonWhitespace(in: text) else { continue }
            if hasSearchBodyPart {
                guard appendNormalizedUTF8Prefix(
                    "\n",
                    to: &searchBody,
                    remainingByteCount: &remainingSearchBodyBytes
                ) else {
                    break
                }
            }
            hasSearchBodyPart = true
            guard appendNormalizedUTF8Prefix(
                text,
                to: &searchBody,
                remainingByteCount: &remainingSearchBodyBytes
            ) else {
                break
            }
        }
        if title == nil, let reference = referenceProjection(in: content) {
            title = reference.title
            var parts = [reference.address]
            if !reference.path.isEmpty {
                parts.append(reference.path)
            }
            for part in parts {
                if hasSearchBodyPart {
                    guard appendNormalizedUTF8Prefix(
                        "\n",
                        to: &searchBody,
                        remainingByteCount: &remainingSearchBodyBytes
                    ) else { break }
                }
                hasSearchBodyPart = true
                guard appendNormalizedUTF8Prefix(
                    part,
                    to: &searchBody,
                    remainingByteCount: &remainingSearchBodyBytes
                ) else { break }
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
                let title = firstContentLine(of: text)
            else {
                continue
            }
            return truncatedToUTF8ByteLimit(
                title,
                limit: limits.maximumStoredTitleUTF8Bytes
            )
        }
        return truncatedToUTF8ByteLimit(
            referenceProjection(in: content)?.title ?? typeBasedFallbackTitle(
                typeIdentifiers: content.representations.map(\.typeIdentifier)
            ),
            limit: limits.maximumStoredTitleUTF8Bytes
        )
    }

    // MARK: Inert reference metadata (recipe 5, §15)

    private static let maximumReferenceSourceBytes = 16 * 1_024

    /// Called only after plain text failed to supply a title. The first exact
    /// reference owns this attempt; invalid/oversized input never advances to
    /// another candidate. Known images retain their existing opaque projection.
    /// The tuple contains fields, not a joined search body, so title-only reads
    /// perform no body normalization or assembly.
    private static func referenceProjection(
        in content: EffectiveContent
    ) -> (title: String, address: String, path: String)? {
        guard !content.representations.contains(where: {
            imageTypeIdentifiers.contains($0.typeIdentifier)
        }), let representation = content.representations.first(where: {
            let identifier = ClipboardFormatIdentifier(rawValue: $0.typeIdentifier)
            return identifier == .url || identifier == .fileURL
        }) else { return nil }

        guard representation.bytes.count <= maximumReferenceSourceBytes,
              let address = String(validating: representation.bytes, as: UTF8.self),
              !address.isEmpty,
              let url = URL(string: address, encodingInvalidCharacters: false),
              let scheme = url.scheme,
              !scheme.isEmpty else { return nil }
        let identifier = ClipboardFormatIdentifier(rawValue: representation.typeIdentifier)
        guard identifier != .fileURL || url.isFileURL else { return nil }

        // These are lexical URL components, never filesystem resource reads.
        // Host spelling is retained in address; remote file references are
        // neither rejected nor presented as evidence of a local file.
        let path = url.path(percentEncoded: false)
        guard url.isFileURL else {
            return (title: address, address: address, path: path)
        }
        let scalars = path.unicodeScalars
        guard scalars.first?.value == 0x2F else { return nil }
        // Foundation's lastPathComponent can strip a leading BOM while
        // decoding the filename. The path is already decoded: slice its
        // scalars directly, including when '/' shares a Character with a
        // combining mark. Ignore trailing separators; an all-slash root
        // keeps its original path instead of inventing an empty filename.
        let filename: String
        if let last = scalars.lastIndex(where: { $0 != "/" }) {
            let end = scalars.index(after: last)
            let start = scalars[..<end].lastIndex(of: "/").map {
                scalars.index(after: $0)
            } ?? scalars.startIndex
            filename = String(scalars[start..<end])
        } else {
            filename = path
        }
        return (
            title: filename,
            address: address,
            path: path
        )
    }

    // MARK: Textual eligibility and decoding (§15)

    /// Projection-owned recipe-v4 admission. `ClipboardFormats` supplies the
    /// exact codec facts, but adding a future stable codec must not silently
    /// change durable title/search behavior.
    private static let textualProjectionIdentifiers: Set<ClipboardFormatIdentifier> = [
        .utf8PlainText,
        .utf16ExternalPlainText,
        .utf16PlainText,
    ]

    /// Decodes one representation's bytes as text, or returns `nil` when the
    /// representation is not title/search eligible (§15: image bytes are not
    /// decoded). Encoding is fixed by the explicit type: UTF-16 only for
    /// `public.utf16-plain-text`; external UTF-16 honors a BOM and otherwise
    /// defaults to big-endian. Only `public.utf8-plain-text` declares UTF-8.
    /// The projector never guesses a fallback encoding for malformed bytes;
    /// an undecodable representation is skipped rather than durable mojibake.
    /// There is no generic textual fallback.
    private static func decodedText(
        of representation: ContentRepresentation
    ) -> String? {
        let identifier = ClipboardFormatIdentifier(
            rawValue: representation.typeIdentifier
        )
        guard textualProjectionIdentifiers.contains(identifier),
              let codec = identifier.declaredStringCodec else {
            return nil
        }
        switch codec {
        case .utf8:
            return String(data: representation.bytes, encoding: .utf8)
        case .nativeUTF16, .externalUTF16:
            let bytes = representation.bytes
            // Foundation may decode a complete prefix and ignore one final
            // byte. An incomplete UTF-16 code unit is malformed in full (§15).
            guard bytes.count.isMultiple(of: 2) else { return nil }
            if bytes.starts(with: [0xFE, 0xFF]) {
                return String(data: bytes.dropFirst(2), encoding: .utf16BigEndian)
            }
            if bytes.starts(with: [0xFF, 0xFE]) {
                return String(data: bytes.dropFirst(2), encoding: .utf16LittleEndian)
            }
            // Native byte order is little-endian on the supported arm64
            // platform; external UTF-16 without a BOM is big-endian (§15).
            let encoding: String.Encoding = codec == .externalUTF16
                ? .utf16BigEndian : .utf16LittleEndian
            return String(data: bytes, encoding: encoding)
        }
    }

    // MARK: Normalization (§15)

    /// The first line whose whitespace-trimmed form is non-empty, trimmed;
    /// `nil` when the text has no such line (§15: "first eligible textual
    /// line after normalization"). CRLF, CR, and LF delimit the same lines
    /// before or after normalization. A title-only read therefore scans only
    /// through its selected line without allocating a normalized copy of the
    /// whole decoded representation. Other Unicode newline scalars retain
    /// the existing trim-only behavior; they do not become line delimiters.
    private static func firstContentLine(of text: String) -> String? {
        var start = text.startIndex
        while true {
            let end = text[start...].firstIndex {
                $0 == "\n" || $0 == "\r" || $0 == "\r\n"
            } ?? text.endIndex
            let trimmed = text[start..<end]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            guard end != text.endIndex else { return nil }
            start = text.index(after: end)
        }
    }

    /// `true` when a textual representation contributes something other than
    /// whitespace/newlines to the corpus (§15). CR/LF normalization preserves
    /// this predicate, so it can inspect the decoded source directly.
    private static func containsNonWhitespace(in text: String) -> Bool {
        text.unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    /// Normalizes CRLF/lone CR to LF while appending only the prefix that
    /// fits the caller-owned UTF-8 budget at Character boundaries. Measure
    /// the output Character (CRLF becomes one byte), preserving the exact
    /// normalize-then-truncate result without allocating a full normalized
    /// copy. Returns whether the complete input was appended.
    private static func appendNormalizedUTF8Prefix(
        _ text: String,
        to result: inout String,
        remainingByteCount: inout Int
    ) -> Bool {
        for character in text {
            let normalized: Character = character == "\r\n" || character == "\r"
                ? "\n" : character
            let width = normalized.utf8.count
            guard width <= remainingByteCount else { return false }
            result.append(normalized)
            remainingByteCount -= width
        }
        return true
    }

    // MARK: Type-based fallback title (§15)

    /// Image type identifiers recognized by the fallback title. This remains
    /// projection-owned purpose policy; it is frozen with recipe v2.
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
