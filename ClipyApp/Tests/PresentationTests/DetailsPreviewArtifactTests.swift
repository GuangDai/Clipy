/// Details must preserve renderer facts when adapting an explicitly selected
/// representation: inert references, PDF page counts, and excerpt truncation.
@testable import ContentPreview
import CoreGraphics
import Foundation
@testable import HistoryCore
@testable import HistoryStorage
import Testing
@testable import ClipyApp

struct DetailsPreviewArtifactTests {
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

    @Test func pdfPreviewPreservesTheDisplayedPageAndDocumentPageCount() async throws {
        let bytes = try twoPagePDF()
        let (history, request, metadata) = try await capture(bytes, type: "com.adobe.pdf")
        let preview = try await DetailsRepresentationPresentation.load(
            request, metadata: metadata, history: history, renderer: ContentPreview()
        )
        guard case .pdf(let pdf) = preview else {
            Issue.record("Details discarded the PDF page facts")
            return
        }
        #expect(pdf.pageNumber == 1)
        #expect(pdf.pageCount == 2)
        #expect(pdf.raster.width == 80)
        #expect(pdf.raster.height == 60)
        #expect(preview.raster == pdf.raster)
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
        #expect(preview == .plainText(String(repeating: "x", count: 500), wasTruncated: count > 500))
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

    private func twoPagePDF() throws -> Data {
        let output = try #require(CFDataCreateMutable(kCFAllocatorDefault, 0))
        let consumer = try #require(CGDataConsumer(data: output))
        var mediaBox = CGRect(x: 0, y: 0, width: 80, height: 60)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for gray in [CGFloat(0), CGFloat(1)] {
            context.beginPDFPage(nil)
            context.setFillColor(gray: gray, alpha: 1)
            context.fill(mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }
}
