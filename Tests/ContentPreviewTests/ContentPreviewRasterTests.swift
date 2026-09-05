/// 05-ART6: real encoded raster bytes through the production preview renderer.
/// Fixture dimensions, colors, and frame order are chosen before encoding;
/// expected outcomes do not reproduce the renderer's ImageIO operations.
import ContentPreview
import CoreGraphics
import Foundation
import ImageIO
import Testing

@Suite("ContentPreview raster semantics")
struct ContentPreviewRasterTests {
    @Test("supported raster families produce bounded eager pixels",
          arguments: ["public.png", "public.jpeg", "public.tiff", "public.heic",
                      "public.heif", "com.compuserve.gif", "com.microsoft.bmp"])
    func supportedFamily(_ identifier: String) async throws {
        // HEIC is the concrete encoded HEIF variant supported by ImageIO's
        // encoder; both existing clipboard labels admit those image bytes.
        let bytes = try Self.imageBytes(
            format: identifier == "public.heif" ? "public.heic" : identifier
        )
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: identifier, bytes: bytes),
        ])
        guard case let .content(.raster(raster)) = outcome else {
            Issue.record("expected \(identifier) raster, got \(outcome)")
            return
        }
        #expect(raster.width == 32)
        #expect(raster.height == 16)
        #expect(raster.rowBytes == 32 * 4)
        #expect(raster.pixels.count == 32 * 16 * 4)
        // JPEG/HEIC are lossy: test the selected red image, not encoder-specific
        // quantization. The eager artifact must still contain opaque BGRA8.
        #expect(raster.pixels[0] < 32)
        #expect(raster.pixels[1] < 32)
        #expect(raster.pixels[2] > 223)
        #expect(raster.pixels[3] == 255)
    }

    @Test("GIF animation and TIFF pages render only the first primary image",
          arguments: ["com.compuserve.gif", "public.tiff"])
    func multiImageUsesFirstFrame(_ identifier: String) async throws {
        let bytes = try Self.imageBytes(format: identifier, frameCount: 2)
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        try #require(CGImageSourceGetCount(source) == 2)

        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: identifier, bytes: bytes),
        ])
        guard case let .content(.raster(raster)) = outcome else {
            Issue.record("expected first-frame raster, got \(outcome)")
            return
        }
        // First frame is red, second is blue. A static preview must neither
        // select the last frame nor composite them (ImageIO primary = 0).
        #expect(raster.width == 32)
        #expect(raster.height == 16)
        let redPixels = Data(Array(repeating: [UInt8(0), 0, 255, 255], count: 32 * 16).joined())
        #expect(raster.pixels == redPixels)
    }

    @Test("JPEG EXIF orientation transforms the output axes",
          arguments: [1, 6, 8])
    func jpegOrientation(_ orientation: Int) async throws {
        let bytes = try Self.imageBytes(format: "public.jpeg", orientation: orientation)
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        try #require(properties[kCGImagePropertyOrientation] as? Int == orientation)

        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.jpeg", bytes: bytes),
        ])
        guard case let .content(.raster(raster)) = outcome else {
            Issue.record("expected oriented JPEG, got \(outcome)")
            return
        }
        #expect(raster.width == (orientation >= 5 ? 16 : 32))
        #expect(raster.height == (orientation >= 5 ? 32 : 16))
        #expect(raster.pixels.count == 32 * 16 * 4)
    }

    @Test("malformed bytes fail for every admitted image label",
          arguments: ["public.png", "public.jpeg", "public.tiff", "public.heic",
                      "public.heif", "com.compuserve.gif", "com.microsoft.bmp"])
    func malformedRaster(_ identifier: String) async {
        let renderer = ContentPreview()
        for bytes in [Data(), Data([0x89, 0x50, 0x4E, 0x47])] {
            let outcome = await renderer.renderHistoryPane([
                PreviewRepresentation(typeIdentifier: identifier, bytes: bytes),
                PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("sibling".utf8)),
            ])
            #expect(outcome == .failed(.malformedRepresentation))
        }
    }

    @Test("an admitted image label uses the actual encoded bytes")
    func differingImageLabelStillDecodesActualContainer() async throws {
        let bytes = try Self.imageBytes(format: "public.png")
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.jpeg", bytes: bytes),
        ])
        guard case let .content(.raster(raster)) = outcome else {
            Issue.record("expected actual PNG pixels under an image label, got \(outcome)")
            return
        }
        #expect(raster.width == 32)
        #expect(raster.height == 16)
        let redPixels = Data(Array(repeating: [UInt8(0), 0, 255, 255], count: 32 * 16).joined())
        #expect(raster.pixels == redPixels)
    }

    @Test("valid image bytes under unknown or unsupported labels remain opaque",
          arguments: ["public.png.private", "dyn.example", "com.adobe.pdf"])
    func unsupportedLabelDoesNotSniffImageBytes(_ identifier: String) async throws {
        let bytes = try Self.imageBytes(format: "public.png")
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: identifier, bytes: bytes),
        ])
        #expect(outcome == .unavailable(.unsupported))
    }

    private static func imageBytes(
        format: String,
        frameCount: Int = 1,
        orientation: Int? = nil
    ) throws -> Data {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 32, height: 16, bitsPerComponent: 8,
            bytesPerRow: 32 * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let data = try #require(CFDataCreateMutable(kCFAllocatorDefault, 0))
        let destination = try #require(CGImageDestinationCreateWithData(
            data, format as CFString, frameCount, nil
        ))
        for frame in 0..<frameCount {
            context.setFillColor(CGColor(
                red: frame == 0 ? 1 : 0, green: 0,
                blue: frame == 0 ? 0 : 1, alpha: 1
            ))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
            let image = try #require(context.makeImage())
            let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
            CGImageDestinationAddImage(destination, image, properties)
        }
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
