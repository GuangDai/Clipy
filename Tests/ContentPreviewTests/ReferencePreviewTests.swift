/// URL previews are inert references. All expectations are literal source
/// bytes and decoded paths; no fixture opens a URL or touches its target file.
import ContentPreview
import Foundation
import Testing

@Suite("ContentPreview inert URL references")
struct ReferencePreviewTests {
    @Test("URL addresses retain their complete original spelling")
    func completeAddress() async {
        let address = "https://example.invalid/a%2fb?q=%E4%B8%AD%20x&empty=#fragment%2Fend"
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.url", bytes: Data(address.utf8)),
        ])
        guard case let .content(.reference(reference)) = outcome else {
            Issue.record("expected URL reference, got \(outcome)")
            return
        }
        #expect(reference.kind == .url)
        #expect(Data(reference.address.utf8) == Data(address.utf8))
        #expect(reference.filePath == nil)
    }

    @Test("file references expose a decoded path without resolving the target")
    func inertFilePaths() async throws {
        let fixtures = [
            ("public.file-url", "file:///clipy-nonexistent-reference/%E4%B8%AD%20name.txt",
             "/clipy-nonexistent-reference/中 name.txt"),
            ("public.file-url", "file://remote/clipy-nonexistent-reference/a%20b.txt",
             "/clipy-nonexistent-reference/a b.txt"),
            ("public.url", "file:///clipy-nonexistent-reference/cafe%CC%81.txt",
             "/clipy-nonexistent-reference/cafe\u{301}.txt"),
        ]
        for (identifier, address, path) in fixtures {
            let outcome = await ContentPreview().renderHistoryPane([
                PreviewRepresentation(typeIdentifier: identifier, bytes: Data(address.utf8)),
            ])
            guard case let .content(.reference(reference)) = outcome else {
                Issue.record("expected inert file reference, got \(outcome)")
                continue
            }
            #expect(reference.kind == .file)
            // In particular, the remote authority must remain visible in the
            // full address; the path alone is not a claim of local access.
            #expect(Data(reference.address.utf8) == Data(address.utf8))
            let filePath = try #require(reference.filePath)
            #expect(Data(filePath.utf8) == Data(path.utf8))
        }
    }

    @Test("a combining mark after the root slash does not make a file path relative",
          arguments: ["public.url", "public.file-url"])
    func rootSlashFollowedByCombiningMark(_ identifier: String) async throws {
        let address = "file:///%CC%81name.txt"
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: identifier, bytes: Data(address.utf8)),
        ])
        guard case let .content(.reference(reference)) = outcome else {
            Issue.record("expected absolute file reference, got \(outcome)")
            return
        }
        #expect(reference.kind == .file)
        #expect(Data(reference.address.utf8) == Data(address.utf8))
        let path = try #require(reference.filePath)
        // U+002F and U+0301 share a Character but remain separate scalars.
        #expect(Data(path.utf8) == Data("/\u{301}name.txt".utf8))
    }

    @Test("a leading UTF-8 BOM is not silently stripped from a reference",
          arguments: ["public.url", "public.file-url"])
    func leadingBOMIsMalformed(_ identifier: String) async {
        let address = identifier == "public.url"
            ? "https://example.invalid/bom"
            : "file:///clipy-nonexistent-reference/bom.txt"
        let bom = Data([0xEF, 0xBB, 0xBF])
        let renderer = ContentPreview()
        for bytes in [bom, bom + Data(address.utf8)] {
            #expect(await renderer.renderHistoryPane([
                PreviewRepresentation(typeIdentifier: identifier, bytes: bytes),
            ]) == .failed(.malformedRepresentation))
        }
    }

    @Test("a percent-encoded U+FEFF in a filename remains filename content",
          arguments: ["public.url", "public.file-url"])
    func encodedBOMInFilenameIsPreserved(_ identifier: String) async throws {
        let address = "file:///clipy-nonexistent-reference/%EF%BB%BFname.txt"
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: identifier, bytes: Data(address.utf8)),
        ])
        guard case let .content(.reference(reference)) = outcome else {
            Issue.record("expected encoded U+FEFF file reference, got \(outcome)")
            return
        }
        #expect(reference.kind == .file)
        #expect(Data(reference.address.utf8) == Data(address.utf8))
        let path = try #require(reference.filePath)
        #expect(Data(path.utf8) == Data("/clipy-nonexistent-reference/\u{FEFF}name.txt".utf8))
    }

    @Test("declared references reject malformed bytes and nonabsolute addresses")
    func malformedReferences() async {
        let invalidURLs = [
            Data(),
            Data([0xFF]),
            Data("https://example.invalid/".utf8) + Data([0xC3, 0x28]),
            Data("https://example.invalid/a\0b".utf8),
            Data("relative/path".utf8),
            Data("//example.invalid/path".utf8),
            Data("https://example.invalid/%".utf8),
            Data("https://example.invalid/%GG".utf8),
            Data("https://example.invalid/a b".utf8),
        ]
        let renderer = ContentPreview()
        for bytes in invalidURLs {
            #expect(await renderer.renderHistoryPane([
                PreviewRepresentation(typeIdentifier: "public.url", bytes: bytes),
            ]) == .failed(.malformedRepresentation))
        }
        #expect(await renderer.renderHistoryPane([
            PreviewRepresentation(
                typeIdentifier: "public.file-url",
                bytes: Data("https://example.invalid/not-a-file".utf8)
            ),
        ]) == .failed(.malformedRepresentation))
        for identifier in ["public.url", "public.file-url"] {
            for address in ["file:relative", "file:"] {
                #expect(await renderer.renderHistoryPane([
                    PreviewRepresentation(typeIdentifier: identifier, bytes: Data(address.utf8)),
                ]) == .failed(.malformedRepresentation))
            }
        }
    }

    @Test("a reference accepts exactly 16 KiB but rejects the next byte",
          arguments: ["public.url", "public.file-url"])
    func candidateByteBoundary(_ identifier: String) async {
        let prefix = identifier == "public.url" ? "https://example.invalid/" : "file:///"
        let address = prefix + String(repeating: "a", count: 16_384 - prefix.utf8.count)
        let bytes = Data(address.utf8)
        #expect(bytes.count == 16_384)
        let renderer = ContentPreview()
        let outcome = await renderer.renderHistoryPane([
            PreviewRepresentation(typeIdentifier: identifier, bytes: bytes),
        ])
        guard case let .content(.reference(reference)) = outcome else {
            Issue.record("expected exact-boundary reference, got \(outcome)")
            return
        }
        #expect(Data(reference.address.utf8) == bytes)
        #expect(await renderer.renderHistoryPane([
            PreviewRepresentation(typeIdentifier: identifier, bytes: bytes + Data([0x61])),
        ]) == .failed(.resourceLimit))
    }

    @Test("lookalike identifiers never acquire URL semantics",
          arguments: ["public.url.private", "public.file-url.private", "PUBLIC.URL", "dyn.url"])
    func unknownIdentifiers(_ identifier: String) async {
        #expect(await ContentPreview().renderHistoryPane([
            PreviewRepresentation(
                typeIdentifier: identifier,
                bytes: Data("https://example.invalid/".utf8)
            ),
        ]) == .unavailable(.unsupported))
    }

    @Test("valid plain text wins regardless of reference validity or ordering")
    func plainTextPriority() async {
        let plainBytes = Data("cafe\u{301} literal text".utf8)
        for bytes in [Data("https://example.invalid/".utf8), Data([0xFF]),
                      Data(repeating: 0x61, count: 16_385)] {
            let outcome = await ContentPreview().renderHistoryPane([
                PreviewRepresentation(typeIdentifier: "public.url", bytes: bytes),
                PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: plainBytes),
            ])
            guard case let .content(.text(text)) = outcome else {
                Issue.record("expected higher-priority plain text, got \(outcome)")
                continue
            }
            #expect(Data(text.text.utf8) == plainBytes)
            #expect(!text.wasTruncated)
        }
    }

    @Test("invalid plain text can yield to a valid reference")
    func invalidPlainTextFallback() async {
        let address = "https://example.invalid/fallback?q=1#part"
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data([0xFF])),
            PreviewRepresentation(typeIdentifier: "public.url", bytes: Data(address.utf8)),
        ])
        guard case let .content(.reference(reference)) = outcome else {
            Issue.record("expected reference after invalid plain text, got \(outcome)")
            return
        }
        #expect(Data(reference.address.utf8) == Data(address.utf8))
    }

    @Test("the first exact reference owns its failure rather than trying later references")
    func firstReferenceFailure() async {
        let fixtures: [(Data, PreviewFailure)] = [
            (Data("relative/path".utf8), .malformedRepresentation),
            (Data(repeating: 0x61, count: 16_385), .resourceLimit),
        ]
        for (bytes, failure) in fixtures {
            #expect(await ContentPreview().renderHistoryPane([
                PreviewRepresentation(typeIdentifier: "public.url", bytes: bytes),
                PreviewRepresentation(
                    typeIdentifier: "public.file-url",
                    bytes: Data("file:///clipy-nonexistent-reference/fallback".utf8)
                ),
            ]) == .failed(failure))
        }
    }

    @Test("image priority still wins over plain text and references")
    func imagePriority() async throws {
        // Literal 1x1 red PNG; no fixture file or URL fetch is involved.
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
        ))
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.url", bytes: Data("https://example.invalid/".utf8)),
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("plain sibling".utf8)),
            PreviewRepresentation(typeIdentifier: "public.png", bytes: png),
        ])
        guard case let .content(.raster(raster)) = outcome else {
            Issue.record("expected higher-priority raster, got \(outcome)")
            return
        }
        #expect(raster.width == 1)
        #expect(raster.height == 1)
        #expect(raster.pixels == Data([0x00, 0x00, 0xFF, 0xFF]))
    }
}
