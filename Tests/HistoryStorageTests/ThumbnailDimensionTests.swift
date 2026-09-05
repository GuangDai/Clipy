/// 05 §14.5: rectangular thumbnail requests bound both displayed axes,
/// including image orientations that swap the stored width and height.
import CoreGraphics
import Foundation
import HistoryCore
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HistoryStorage

struct ThumbnailDimensionTests {
    struct FitCase: Sendable {
        let width: Int
        let height: Int
        let request: PixelSize
        let expected: PixelSize
    }

    @Test(arguments: [
        FitCase(width: 320, height: 160, request: PixelSize(width: 120, height: 40),
                expected: PixelSize(width: 80, height: 40)),
        FitCase(width: 160, height: 320, request: PixelSize(width: 40, height: 120),
                expected: PixelSize(width: 40, height: 80)),
        FitCase(width: 320, height: 160, request: PixelSize(width: 40, height: 120),
                expected: PixelSize(width: 40, height: 20)),
        FitCase(width: 160, height: 320, request: PixelSize(width: 120, height: 40),
                expected: PixelSize(width: 20, height: 40)),
        FitCase(width: 160, height: 160, request: PixelSize(width: 120, height: 40),
                expected: PixelSize(width: 40, height: 40)),
        FitCase(width: 301, height: 199, request: PixelSize(width: 60, height: 20),
                expected: PixelSize(width: 30, height: 20)),
        FitCase(width: 199, height: 301, request: PixelSize(width: 20, height: 60),
                expected: PixelSize(width: 20, height: 30)),
        FitCase(width: 320, height: 160, request: PixelSize(width: 1, height: 1),
                expected: PixelSize(width: 1, height: 1)),
        FitCase(width: 16, height: 8, request: PixelSize(width: 120, height: 40),
                expected: PixelSize(width: 16, height: 8)),
    ])
    func pngFitsBothAxesWithoutUpscaling(_ fixture: FitCase) async throws {
        let bytes = try Self.imageBytes(width: fixture.width, height: fixture.height)
        let actual = try await Self.thumbnailSize(bytes: bytes, request: fixture.request)

        #expect(actual.width <= fixture.request.width)
        #expect(actual.height <= fixture.request.height)
        #expect(actual.width <= fixture.width)
        #expect(actual.height <= fixture.height)
        #expect(actual.width > 0 && actual.height > 0)
        // At most one output pixel of aspect-ratio rounding; catches cropping
        // or stretching while permitting ImageIO's integer dimensions.
        #expect(abs(actual.width * fixture.height - actual.height * fixture.width)
            <= max(fixture.width, fixture.height))
        #expect(abs(actual.width - fixture.expected.width) <= 1)
        #expect(abs(actual.height - fixture.expected.height) <= 1)
    }

    @Test(arguments: 1...8)
    func jpegOrientationFitsTheDisplayedAxes(_ orientation: Int) async throws {
        let bytes = try Self.imageBytes(width: 320, height: 160, orientation: orientation)
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any])
        #expect(properties[kCGImagePropertyOrientation] as? Int == orientation)

        let actual = try await Self.thumbnailSize(
            bytes: bytes, request: PixelSize(width: 120, height: 40)
        )
        #expect(actual == PixelSize(width: orientation >= 5 ? 20 : 80, height: 40))
    }

    private static func thumbnailSize(bytes: Data, request: PixelSize) async throws -> PixelSize {
        let reference = HistoryItemReference(
            id: HistoryItemID(rawValue: UUID()), contentVersion: .initial
        )
        let payload = try await ThumbnailWorker().decodeThumbnail(
            sourceBytes: bytes, item: reference, pixels: request
        )
        #expect(payload.item == reference)
        #expect(payload.pixels == request)
        #expect(payload.format == .png)
        let source = try #require(CGImageSourceCreateWithData(payload.encodedBytes as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return PixelSize(width: image.width, height: image.height)
    }

    private static func imageBytes(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = try #require(CFDataCreateMutable(kCFAllocatorDefault, 0))
        let format = orientation == nil ? UTType.png : UTType.jpeg
        let destination = try #require(CGImageDestinationCreateWithData(
            data, format.identifier as CFString, 1, nil
        ))
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
