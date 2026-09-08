/// Direct PDF rendering with independent literal page/stream objects. The
/// test assembler computes only PDF byte offsets, never the expected raster.
/// A separate native writer fixture is used solely to establish encryption.
import CoreGraphics
import Foundation
import Testing
@testable import ContentPreview

struct PreviewPDFRendererTests {
    @Test func concreteRendererSelectsExactPDFIncludingAfterMalformedText() async throws {
        let pdfBytes = Self.page(commands: "0 g\n0 0 40 20 re f\n")
        for includeMalformedText in [false, true] {
            var representations = [PreviewRepresentation(typeIdentifier: "com.adobe.pdf", bytes: pdfBytes)]
            if includeMalformedText {
                representations.append(PreviewRepresentation(
                    typeIdentifier: "public.utf8-plain-text", bytes: Data([0xFF])
                ))
            }
            let outcome = await ContentPreview().renderHistoryPane(representations)
            let pdf = try Self.artifact(outcome)
            #expect(pdf.pageCount == 1)
            #expect(pdf.pageNumber == 1)
            #expect(pdf.raster.width == 40 && pdf.raster.height == 20)
            #expect(pdf.raster.pixels == Self.solidPixels(gray: 0, count: 40 * 20))
        }
    }

    @Test func concreteRendererKeepsExistingImageAndValidTextPriority() async {
        let pdf = PreviewRepresentation(typeIdentifier: "com.adobe.pdf", bytes: Self.page(commands: ""))
        let renderer = ContentPreview()
        #expect(await renderer.renderHistoryPane([
            pdf,
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("plain sibling".utf8)),
        ]) == .content(.text(PreviewText(text: "plain sibling", wasTruncated: false))))
        // A PDF does not rescue an exact image candidate's existing failure.
        #expect(await renderer.renderHistoryPane([
            pdf,
            PreviewRepresentation(typeIdentifier: "public.png", bytes: Data([0x89, 0x50, 0x4E, 0x47])),
        ]) == .failed(.malformedRepresentation))
    }

    @Test func concreteRendererDoesNotSkipTheFirstMalformedPDF() async {
        #expect(await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "com.adobe.pdf", bytes: Data()),
            PreviewRepresentation(typeIdentifier: "com.adobe.pdf", bytes: Self.page(commands: "")),
            PreviewRepresentation(typeIdentifier: "public.url", bytes: Data("https://example.invalid/".utf8)),
        ]) == .failed(.malformedRepresentation))
    }

    @Test func concreteRendererLeavesLookalikePDFTypesOpaque() async throws {
        for identifier in ["com.adobe.pdf.private", "COM.ADOBE.PDF", "public.pdf"] {
            let opaque = PreviewRepresentation(typeIdentifier: identifier, bytes: Self.page(commands: ""))
            let renderer = ContentPreview()
            #expect(await renderer.renderHistoryPane([opaque]) == .unavailable(.unsupported))
            let outcome = await renderer.renderHistoryPane([
                opaque,
                PreviewRepresentation(typeIdentifier: "public.url", bytes: Data("https://example.invalid/".utf8)),
            ])
            guard case .content(.reference(let reference)) = outcome else {
                Issue.record("opaque PDF-like type must leave the exact URL available, got \(outcome)")
                continue
            }
            #expect(reference.address == "https://example.invalid/")
        }
    }

    @Test func defaultPageAndRequestedPageCarryTheirOwnPixelsAndPosition() async throws {
        let representation = PreviewRepresentation(typeIdentifier: "com.adobe.pdf", bytes: Self.twoPages())
        let renderer = ContentPreview()
        let first = try Self.artifact(await renderer.renderHistoryPane([representation]))
        #expect(first.pageCount == 2)
        #expect(first.pageNumber == 1)
        #expect(first.raster.width == 40 && first.raster.height == 20)
        #expect(first.raster.pixels == Self.solidPixels(gray: 0, count: 40 * 20))

        let second = try Self.artifact(await renderer.renderHistoryPane([representation], pdfPage: 2))
        #expect(second.pageCount == 2)
        #expect(second.pageNumber == 2)
        #expect(second.raster.width == 20 && second.raster.height == 40)
        #expect(second.raster.pixels == Self.solidPixels(gray: 255, count: 20 * 40))

        let source = try #require(ContentPreview.prepareHistoryPane([
            PreviewRepresentationMetadata(typeIdentifier: representation.typeIdentifier, byteCount: representation.bytes.count),
        ]).first)
        #expect(await renderer.renderSelectedHistoryPane(source, representation: representation, pdfPage: 2)
            == .content(.pdf(second)))
        // Returning to page one must not reuse the most recent page's pixels.
        #expect(await renderer.renderSelectedHistoryPane(source, representation: representation, pdfPage: 1)
            == .content(.pdf(first)))
    }

    @Test(arguments: [Int.min, -1, 0, 3, Int.max])
    func missingPageIsUnavailableWithoutMarkingThePDFCorrupt(_ page: Int) async throws {
        let representation = PreviewRepresentation(typeIdentifier: "com.adobe.pdf", bytes: Self.twoPages())
        let renderer = ContentPreview()
        #expect(await renderer.renderHistoryPane([representation], pdfPage: page) == .unavailable(.pageUnavailable))
        let valid = try Self.artifact(await renderer.renderHistoryPane([representation], pdfPage: 2))
        #expect(valid.pageNumber == 2)
    }

    @Test func pageRequestDoesNotChangeNonPDFSourceSelection() async {
        #expect(await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "com.adobe.pdf", bytes: Self.twoPages()),
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("plain sibling".utf8)),
        ], pdfPage: Int.max) == .content(.text(PreviewText(text: "plain sibling", wasTruncated: false))))
    }

    @Test func blankPageHasAnOpaqueWhiteBackground() throws {
        let pdf = try Self.artifact(Self.render(Self.page(commands: "")))
        #expect(pdf.pageCount == 1)
        #expect(pdf.raster.width == 40)
        #expect(pdf.raster.height == 20)
        #expect(pdf.raster.pixels == Self.solidPixels(gray: 255, count: 40 * 20))
    }

    @Test func cropBoxUsesItsNonzeroOriginAndIntersectsTheMediaBox() throws {
        let bytes = Self.page(
            media: "[0 0 40 20]", crop: "[10 5 60 30]",
            commands: "0 g\n10 5 30 15 re f\n"
        )
        let pdf = try Self.artifact(Self.render(bytes))
        #expect(pdf.raster.width == 30)
        #expect(pdf.raster.height == 15)
        #expect(pdf.raster.pixels == Self.solidPixels(gray: 0, count: 30 * 15))
    }

    @Test(arguments: [90, 270, -90])
    func pageRotationExchangesTheOutputAxes(_ rotation: Int) throws {
        let bytes = Self.page(rotation: rotation, commands: "0 g\n0 0 40 20 re f\n")
        let pdf = try Self.artifact(Self.render(bytes))
        #expect(pdf.raster.width == 20)
        #expect(pdf.raster.height == 40)
        #expect(pdf.raster.pixels == Self.solidPixels(gray: 0, count: 20 * 40))
    }

    @Test func largePageFitsWithinThePixelAndOutputByteBounds() throws {
        let pdf = try Self.artifact(Self.render(Self.page(
            media: "[0 0 2000 1000]", commands: ""
        )))
        #expect(pdf.raster.width == 640)
        #expect(pdf.raster.height == 320)
        #expect(pdf.raster.rowBytes == 2_560)
        #expect(pdf.raster.pixels.count == 819_200)
        #expect(pdf.raster.pixels == Self.solidPixels(gray: 255, count: 640 * 320))
    }

    @Test func sourceAndOutputLimitsRejectBeforeOversizedAllocation() throws {
        let bytes = Self.page(commands: "")
        _ = try Self.artifact(PreviewPDFRenderer.render(
            bytes, maximumInputBytes: bytes.count,
            maximumPixelExtent: 640, maximumOutputBytes: 40 * 20 * 4
        ))
        #expect(PreviewPDFRenderer.render(
            bytes, maximumInputBytes: bytes.count - 1,
            maximumPixelExtent: 640, maximumOutputBytes: 640 * 640 * 4
        ) == .failed(.resourceLimit))
        #expect(PreviewPDFRenderer.render(
            bytes, maximumInputBytes: bytes.count,
            maximumPixelExtent: 640, maximumOutputBytes: 40 * 20 * 4 - 1
        ) == .failed(.resourceLimit))
    }

    @Test func emptyInvalidAndPagelessDocumentsFailExplicitly() {
        let noPages = Self.document([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [] /Count 0 >>",
        ])
        for bytes in [Data(), Data("not a PDF".utf8), noPages] {
            #expect(Self.render(bytes) == .failed(.malformedRepresentation))
        }
    }

    @Test func encryptedDocumentIsNotUnlockedOrRendered() throws {
        // Only this encrypted fixture uses a writer. Pixel expectations in
        // the other tests come from their literal PDF drawing instructions.
        let output = try #require(CFDataCreateMutable(kCFAllocatorDefault, 0))
        let consumer = try #require(CGDataConsumer(data: output))
        var media = CGRect(x: 0, y: 0, width: 40, height: 20)
        let options: [CFString: Any] = [
            kCGPDFContextUserPassword: "clipy-test-user" as CFString,
            kCGPDFContextOwnerPassword: "clipy-test-owner" as CFString,
        ]
        let writer = try #require(CGContext(
            consumer: consumer, mediaBox: &media, options as CFDictionary
        ))
        writer.beginPDFPage(nil)
        writer.setFillColor(gray: 0, alpha: 1)
        writer.fill(media)
        writer.endPDFPage()
        writer.closePDF()
        let bytes = output as Data
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let document = try #require(CGPDFDocument(provider))
        try #require(document.isEncrypted)
        #expect(Self.render(bytes) == .unavailable(.unsupported))
    }

    private static func render(_ bytes: Data) -> PreviewOutcome {
        PreviewPDFRenderer.render(
            bytes, maximumInputBytes: 64 * 1_048_576,
            maximumPixelExtent: 640, maximumOutputBytes: 640 * 640 * 4
        )
    }

    private static func artifact(_ outcome: PreviewOutcome) throws -> PreviewPDF {
        guard case .content(.pdf(let pdf)) = outcome else {
            Issue.record("expected a PDF page artifact, got \(outcome)")
            throw FixtureFailure.missingPDF
        }
        return pdf
    }

    private enum FixtureFailure: Error { case missingPDF }

    private static func solidPixels(gray: UInt8, count: Int) -> Data {
        Data((0..<count).flatMap { _ in [gray, gray, gray, UInt8(255)] })
    }

    private static func twoPages() -> Data {
        document([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 40 20] /Resources << >> /Contents 4 0 R >>",
            stream("0 g\n0 0 40 20 re f\n"),
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 40 20] /Rotate 90 /Resources << >> /Contents 6 0 R >>",
            stream("1 g\n0 0 40 20 re f\n"),
        ])
    }

    private static func page(
        media: String = "[0 0 40 20]", crop: String? = nil,
        rotation: Int = 0, commands: String
    ) -> Data {
        let cropEntry = crop.map { " /CropBox \($0)" } ?? ""
        return document([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox \(media)\(cropEntry) /Rotate \(rotation) /Resources << >> /Contents 4 0 R >>",
            stream(commands),
        ])
    }

    private static func stream(_ commands: String) -> String {
        "<< /Length \(commands.utf8.count) >>\nstream\n\(commands)endstream"
    }

    private static func document(_ objects: [String]) -> Data {
        var bytes = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(contentsOf: "\(index + 1) 0 obj\n\(object)\nendobj\n".utf8)
        }
        let xrefOffset = bytes.count
        bytes.append(contentsOf: "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
        for offset in offsets {
            let digits = String(offset)
            let padded = String(repeating: "0", count: 10 - digits.count) + digits
            bytes.append(contentsOf: "\(padded) 00000 n \n".utf8)
        }
        bytes.append(contentsOf: "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
        return bytes
    }
}
