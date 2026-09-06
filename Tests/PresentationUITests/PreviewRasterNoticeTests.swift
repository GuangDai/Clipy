import ContentPreview
import CoreGraphics
import Foundation
import HistoryCore
import HistoryStorage
import ImageIO
import Testing
@testable import PresentationUI

@MainActor
struct PreviewRasterNoticeTests {
    @Test(arguments: ["com.compuserve.gif", "public.tiff"])
    func multiImageNoticeClearsForSingleImageAndText(_ type: String) async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let bytes = try multiImageData(type: type)
        let multiple = try await capture(bytes, type: type, in: history)
        let single = try await capture(fixturePNGData, type: "public.png", in: history)
        let text = try await capture(Data("plain text".utf8), type: "public.utf8-plain-text", in: history)
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: multiple)
        #expect(loader.phase == .content(.image))
        #expect(loader.raster?.sourceImageCount == 2)
        #expect(loader.pdfPageCount == nil)
        #expect(loader.appliedRasterNotice() == PreviewCopy.multiImageDisclosure())
        #expect(try await history.pastePayload(for: multiple.id).representations.map(\.bytes) == [bytes])

        await loader.load(item: single)
        #expect(loader.phase == .content(.image))
        #expect(loader.raster?.sourceImageCount == 1)
        #expect(loader.appliedRasterNotice() == nil)
        await loader.load(item: text)
        #expect(loader.phase == .content(.text("plain text")))
        #expect(loader.raster == nil)
        #expect(loader.pdfPageCount == nil)
        #expect(loader.appliedRasterNotice() == nil)
    }

    @Test func pdfPageFactsFollowOnlyTheirLoadedDocument() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let bytes = try twoPagePDF()
        let pdf = try await capture(bytes, type: "com.adobe.pdf", in: history)
        let single = try await capture(fixturePNGData, type: "public.png", in: history)
        let malformed = try await capture(Data("not a PDF".utf8), type: "com.adobe.pdf", in: history)
        let unsupported = try await capture(Data([1, 2, 3]), type: "dyn.preview.notice", in: history)
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: pdf)
        #expect(loader.phase == .content(.image))
        #expect(loader.pdfPageCount == 2)
        #expect(loader.raster != nil)
        #expect(loader.appliedRasterNotice() == PreviewCopy.pdfPageDisclosure(pageCount: 2))
        #expect(loader.appliedImageAccessibilityLabel == PreviewCopy.pdfPageAccessibilityLabel(pageCount: 2))
        #expect(loader.imageAccessibilityLabel(locale: Locale(identifier: "de_DE")) ==
            PreviewCopy.pdfPageAccessibilityLabel(pageCount: 2, locale: Locale(identifier: "de_DE")))
        #expect(try await history.pastePayload(for: pdf.id).representations.map(\.bytes) == [bytes])

        await loader.load(item: single)
        #expect(loader.phase == .content(.image))
        #expect(loader.pdfPageCount == nil)
        #expect(loader.appliedRasterNotice() == nil)
        #expect(loader.appliedImageAccessibilityLabel == PreviewCopy.imageDimensions(width: 1, height: 1))
        #expect(loader.imageAccessibilityLabel(locale: Locale(identifier: "de_DE")) ==
            PreviewCopy.imageDimensions(width: 1, height: 1, locale: Locale(identifier: "de_DE")))
        await loader.load(item: pdf)
        loader.clear()
        #expect(loader.pdfPageCount == nil)
        #expect(loader.raster == nil)
        #expect(loader.appliedRasterNotice() == nil)
        #expect(loader.appliedImageAccessibilityLabel == nil)

        for target in [unsupported, malformed] {
            await loader.load(item: pdf)
            #expect(loader.pdfPageCount == 2)
            await loader.load(item: target)
            #expect(loader.phase == (target == unsupported ? .unsupported : .failed))
            #expect(loader.pdfPageCount == nil)
            #expect(loader.raster == nil)
            #expect(loader.appliedRasterNotice() == nil)
            #expect(loader.appliedImageAccessibilityLabel == nil)
        }
        await loader.load(item: pdf)
        _ = try await history.perform(.remove(pdf.id))
        await loader.load(item: pdf)
        #expect(loader.phase == .failed)
        #expect(loader.pdfPageCount == nil)
        #expect(loader.appliedRasterNotice() == nil)
    }

    private func multiImageData(type: String) throws -> Data {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 8 * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let data = try #require(CFDataCreateMutable(kCFAllocatorDefault, 0))
        let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 2, nil))
        for red in [CGFloat(1), CGFloat(0)] {
            context.setFillColor(red: red, green: 0, blue: 1 - red, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        }
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func twoPagePDF() throws -> Data {
        let data = try #require(CFDataCreateMutable(kCFAllocatorDefault, 0))
        let consumer = try #require(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 80, height: 60)
        let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        let context = try #require(pdfContext)
        for red in [CGFloat(1), CGFloat(0)] {
            context.beginPDFPage(nil)
            context.setFillColor(red: red, green: 0, blue: 1 - red, alpha: 1)
            context.fill(mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func capture(_ bytes: Data, type: String, in history: SwiftDataHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: type, bytes: bytes)],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_400_000)
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }
}
