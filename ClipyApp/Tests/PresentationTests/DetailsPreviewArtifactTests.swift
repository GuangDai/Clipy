/// Details must preserve renderer facts when adapting an explicitly selected
/// representation: inert references and excerpt truncation.
@testable import ContentPreview
import Foundation
@testable import HistoryCore
@testable import HistoryStorage
import Testing
@testable import ClipyApp

struct DetailsPreviewArtifactTests {
    @Test func hugeFinalCharacterKeepsEveryScalarWithinTheDetailsExcerpt() async throws {
        let expected = String(repeating: "x", count: 499) + "e" + String(repeating: "\u{301}", count: 20_000)
        let bytes = Data((expected + "tail").utf8)
        let (history, request, metadata) = try await capture(bytes, type: "public.utf8-plain-text")
        let preview = try await DetailsRepresentationPresentation.load(
            request, metadata: metadata, history: history, renderer: ContentPreview()
        )
        let text = try #require(preview.text)
        #expect(text.text.count == 500)
        #expect(text.wasTruncated)
        #expect(text.text.utf8.elementsEqual(expected.utf8))
        #expect(text.displaySegments.joined().utf8.elementsEqual(expected.utf8))
        #expect(text.displaySegments.allSatisfy { $0.utf16.count <= 512 })
        #expect(text.displaySegmentGroups.allSatisfy { $0.count <= 8 })
        #expect(try await history.representation(request).bytes == bytes)
    }

    @Test func unsupportedDocumentKeepsMetadataAndOriginalBytes() async throws {
        let bytes = Data("opaque document bytes".utf8)
        let (history, request, metadata) = try await capture(bytes, type: "com.adobe.pdf")
        let preview = try await DetailsRepresentationPresentation.load(
            request, metadata: metadata, history: history, renderer: ContentPreview()
        )
        #expect(preview == .metadataOnly)
        #expect(try await history.representation(request).bytes == bytes)
    }

    @Test(arguments: [
        ("public.url", "https://example.invalid/a%2Fb?q=e%CC%81#section"),
        ("public.file-url", "file:///clipy-nonexistent-preview-fixture/a%20b.pdf"),
    ])
    func referencePreviewKeepsLiteralAddressWithoutOpeningItsDestination(type: String, address: String) async throws {
        let bytes = Data(address.utf8)
        let (history, request, metadata) = try await capture(bytes, type: type)
        let preview = try await DetailsRepresentationPresentation.load(
            request, metadata: metadata, history: history, renderer: ContentPreview()
        )
        guard case .reference(let reference) = preview else {
            Issue.record("Details discarded the renderer's inert reference")
            return
        }
        #expect(reference.address.utf8.elementsEqual(address.utf8))
        #expect(reference.kind == (type == "public.file-url" ? .file : .url))
        #expect(reference.filePath == (type == "public.file-url" ? "/clipy-nonexistent-preview-fixture/a b.pdf" : nil))
        #expect(preview.raster == nil)
        let exported = try await history.representation(request)
        #expect(exported.bytes == bytes)
    }

    @Test(arguments: ["public.utf8-plain-text", "public.rtf", "public.html"], [500, 501])
    func textExcerptReportsTruncationWithoutChangingExport(type: String, count: Int) async throws {
        let text = String(repeating: "x", count: count)
        let source: String
        switch type {
        case "public.rtf": source = "{\\rtf1\\ansi " + text + "}"
        case "public.html": source = "<p>" + text + "</p>"
        default: source = text
        }
        let bytes = Data(source.utf8)
        let (history, request, metadata) = try await capture(bytes, type: type)
        let preview = try await DetailsRepresentationPresentation.load(
            request, metadata: metadata, history: history, renderer: ContentPreview()
        )
        #expect(preview.text?.text == String(repeating: "x", count: 500))
        #expect(preview.text?.wasTruncated == (count > 500))
        let exported = try await history.representation(request)
        #expect(exported.bytes == bytes)
    }

    private func capture(
        _ bytes: Data, type: String
    ) async throws -> (SQLiteHistory, HistoryRepresentationRequest, HistoryRepresentationMetadata) {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: type, bytes: bytes)],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSince1970: 1)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let details = try await history.details(for: item.id)
        let metadata = try #require(details.effective.first)
        return (history, HistoryRepresentationRequest(item: item, basis: .effective, typeIdentifier: type), metadata)
    }

}
