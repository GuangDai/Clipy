/// Direct ImageIO-family fit evidence beyond the small, unscaled fixtures.
/// Source geometry/color and expected output geometry are independent literals.
import ContentPreview
import CoreGraphics
import Foundation
import ImageIO
import Testing

struct ImageFormatFitTests {
    struct OrientationFixture: Sendable {
        let orientation: Int
        let width: Int
        let height: Int
        let expectedOrder: [Int]
    }

    /// Source rows are A B C / D E F. Each output order below is an
    /// independent EXIF display-layout literal, not a product transform or
    /// an expected image generated through ImageIO's thumbnail API.
    @Test(arguments: [
        OrientationFixture(orientation: 1, width: 3, height: 2, expectedOrder: [0, 1, 2, 3, 4, 5]),
        OrientationFixture(orientation: 2, width: 3, height: 2, expectedOrder: [2, 1, 0, 5, 4, 3]),
        OrientationFixture(orientation: 3, width: 3, height: 2, expectedOrder: [5, 4, 3, 2, 1, 0]),
        OrientationFixture(orientation: 4, width: 3, height: 2, expectedOrder: [3, 4, 5, 0, 1, 2]),
        OrientationFixture(orientation: 5, width: 2, height: 3, expectedOrder: [0, 3, 1, 4, 2, 5]),
        OrientationFixture(orientation: 6, width: 2, height: 3, expectedOrder: [3, 0, 4, 1, 5, 2]),
        OrientationFixture(orientation: 7, width: 2, height: 3, expectedOrder: [5, 2, 4, 1, 3, 0]),
        OrientationFixture(orientation: 8, width: 2, height: 3, expectedOrder: [2, 5, 1, 4, 0, 3]),
    ])
    func asymmetricPixelsFollowEveryEXIFOrientation(_ fixture: OrientationFixture) async throws {
        let bytes = try Self.encodedAsymmetricTIFF(orientation: fixture.orientation)
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        try #require(properties[kCGImagePropertyPixelWidth] as? Int == 3)
        try #require(properties[kCGImagePropertyPixelHeight] as? Int == 2)
        let encodedOrientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        try #require(encodedOrientation == fixture.orientation)

        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.tiff", bytes: bytes),
        ])
        guard case .content(.raster(let raster)) = outcome else {
            Issue.record("expected EXIF-oriented TIFF, got \(outcome)")
            return
        }
        #expect(raster.width == fixture.width)
        #expect(raster.height == fixture.height)
        #expect(raster.rowBytes == fixture.width * 4)
        #expect(raster.sourceImageCount == 1)
        // BGRA literals for A red, B green, C blue, D cyan, E magenta,
        // F yellow. TIFF is lossless and no scaling is needed for six pixels.
        let palette: [[UInt8]] = [
            [0, 0, 255, 255], [0, 255, 0, 255], [255, 0, 0, 255],
            [255, 255, 0, 255], [255, 0, 255, 255], [0, 255, 255, 255],
        ]
        let expected = Data(fixture.expectedOrder.flatMap { palette[$0] })
        #expect(raster.pixels == expected)
    }

    struct Fixture: Sendable {
        let format: String
        let label: String
        let width: Int
        let height: Int
        let orientation: Int
        let expectedWidth: Int
        let expectedHeight: Int
    }

    @Test(arguments: [
        Fixture(format: "public.tiff", label: "public.tiff", width: 800, height: 200,
                orientation: 1, expectedWidth: 640, expectedHeight: 160),
        Fixture(format: "public.tiff", label: "public.tiff", width: 200, height: 800,
                orientation: 1, expectedWidth: 160, expectedHeight: 640),
        Fixture(format: "public.tiff", label: "public.tiff", width: 800, height: 200,
                orientation: 6, expectedWidth: 160, expectedHeight: 640),
        Fixture(format: "public.jpeg", label: "public.jpeg", width: 800, height: 200,
                orientation: 1, expectedWidth: 640, expectedHeight: 160),
        Fixture(format: "public.jpeg", label: "public.jpeg", width: 200, height: 800,
                orientation: 1, expectedWidth: 160, expectedHeight: 640),
        Fixture(format: "public.heic", label: "public.heif", width: 200, height: 800,
                orientation: 1, expectedWidth: 160, expectedHeight: 640),
        // An exact admitted label selects image rendering; the actual HEIC
        // payload still determines decoding, independent of the TIFF label.
        Fixture(format: "public.heic", label: "public.tiff", width: 800, height: 200,
                orientation: 1, expectedWidth: 640, expectedHeight: 160),
    ])
    func rectangularImagesFitBothAxesWithoutStretching(_ fixture: Fixture) async throws {
        let bytes = try Self.encodedRedImage(fixture)
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        try #require(properties[kCGImagePropertyPixelWidth] as? Int == fixture.width)
        try #require(properties[kCGImagePropertyPixelHeight] as? Int == fixture.height)
        if fixture.orientation != 1 {
            try #require(properties[kCGImagePropertyOrientation] as? Int == fixture.orientation)
        }

        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: fixture.label, bytes: bytes),
        ])
        guard case let .content(.raster(raster)) = outcome else {
            Issue.record("expected fitted \(fixture.format) raster, got \(outcome)")
            return
        }
        #expect(raster.width == fixture.expectedWidth)
        #expect(raster.height == fixture.expectedHeight)
        #expect(raster.rowBytes == fixture.expectedWidth * 4)
        #expect(raster.pixels.count == fixture.expectedWidth * fixture.expectedHeight * 4)

        // The source fills the complete frame. Red opaque corners distinguish
        // fitted content from a padded or empty raster; JPEG/HEIC permit
        // a small color tolerance rather than fixing encoder quantization.
        for (x, y) in [(0, 0), (raster.width - 1, 0),
                       (0, raster.height - 1), (raster.width - 1, raster.height - 1)] {
            let offset = y * raster.rowBytes + x * 4
            #expect(raster.pixels[offset] < 32)
            #expect(raster.pixels[offset + 1] < 32)
            #expect(raster.pixels[offset + 2] > 223)
            #expect(raster.pixels[offset + 3] == 255)
        }
        if fixture.format == "public.tiff" {
            let redPixels = Data(Array(
                repeating: [UInt8(0), 0, 255, 255],
                count: fixture.expectedWidth * fixture.expectedHeight
            ).joined())
            #expect(raster.pixels == redPixels)
        }
    }

    private static func encodedAsymmetricTIFF(orientation: Int) throws -> Data {
        // Raw RGBA scanlines define top-to-bottom source order without a
        // drawing context's coordinate system participating in the fixture.
        let pixels = Data([
            UInt8(255), 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
            0, 255, 255, 255, 255, 0, 255, 255, 255, 255, 0, 255,
        ])
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(
            width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 12, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = try #require(CFDataCreateMutable(kCFAllocatorDefault, 0))
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: orientation,
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func encodedRedImage(_ fixture: Fixture) throws -> Data {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: fixture.width, height: fixture.height,
            bitsPerComponent: 8, bytesPerRow: fixture.width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let red = try #require(CGColor(colorSpace: colorSpace, components: [1, 0, 0, 1]))
        context.setFillColor(red)
        context.fill(CGRect(
            x: 0, y: 0, width: CGFloat(fixture.width), height: CGFloat(fixture.height)
        ))
        let image = try #require(context.makeImage())
        let data = try #require(CFDataCreateMutable(kCFAllocatorDefault, 0))
        let destination = try #require(CGImageDestinationCreateWithData(
            data, fixture.format as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: fixture.orientation,
        ] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
