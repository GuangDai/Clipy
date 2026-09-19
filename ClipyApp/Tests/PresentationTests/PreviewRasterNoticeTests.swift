@testable import ContentPreview
import CoreGraphics
import Foundation
@testable import HistoryCore
@testable import HistoryStorage
import ImageIO
import Testing
@testable import ClipyApp

@MainActor
struct PreviewRasterNoticeTests {
    @Test(arguments: ["com.compuserve.gif", "public.tiff"])
    func multiImageNoticeClearsForSingleImageAndText(_ type: String) async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let bytes = try multiImageData(type: type)
        let multiple = try await capture(bytes, type: type, in: history)
        let single = try await capture(fixturePNGData, type: "public.png", in: history)
        let text = try await capture(Data("plain text".utf8), type: "public.utf8-plain-text", in: history)
        let loader = PreviewContentLoader(history: history)
        await loader.load(item: multiple)
        #expect(loader.phase == .content(.image))
        #expect(loader.raster?.sourceImageCount == 2)
        #expect(loader.appliedRasterNotice() == PreviewCopy.multiImageDisclosure())
        #expect(try await history.pastePayload(for: multiple.id).representations.map(\.bytes) == [bytes])

        await loader.load(item: single)
        #expect(loader.phase == .content(.image))
        #expect(loader.raster?.sourceImageCount == 1)
        #expect(loader.appliedRasterNotice() == nil)
        await loader.load(item: text)
        #expect(loader.phase == .content(.text("plain text")))
        #expect(loader.raster == nil)
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

    private func capture(_ bytes: Data, type: String, in history: SQLiteHistory) async throws -> HistoryItemReference {
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
