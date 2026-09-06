/// Direct ImageIO-family fit evidence beyond the small, unscaled fixtures.
/// Source geometry/color and expected output geometry are independent literals.
import ContentPreview
import CoreGraphics
import Foundation
import ImageIO
import Testing

struct ImageFormatFitTests {
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
