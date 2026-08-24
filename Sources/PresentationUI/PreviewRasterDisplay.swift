/// MainActor display edge for ContentPreview's fixed eager BGRA8 artifact.
/// CoreGraphics objects are created and consumed locally by SwiftUI; none is
/// stored in observable state or returned across a target/actor seam.
import ContentPreview
import CoreGraphics
import Foundation
import SwiftUI

enum PreviewRasterDisplay {
    @MainActor
    static func image(
        _ raster: PreviewRaster,
        scale: CGFloat,
        label: Text
    ) -> Image? {
        guard raster.width > 0,
              raster.height > 0,
              raster.rowBytes == raster.width * 4,
              raster.pixels.count == raster.rowBytes * raster.height,
              let provider = CGDataProvider(data: raster.pixels as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: raster.width,
                  height: raster.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: raster.rowBytes,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                          | CGImageAlphaInfo.premultipliedFirst.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { return nil }
        return Image(image, scale: scale, label: label)
    }
}
