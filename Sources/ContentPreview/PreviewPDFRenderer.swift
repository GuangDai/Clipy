/// Requested-page PDF rasterization from an already-selected in-memory source.
/// The caller owns the existing native rendering slot; no framework object
/// leaves this synchronous operation. This code supplies only Data, never a
/// URL, and invokes page drawing rather than document actions (01 §5/§6).
import CoreGraphics
import Foundation

internal enum PreviewPDFRenderer {
    internal static func render(
        _ bytes: Data,
        maximumInputBytes: Int,
        maximumPixelExtent: Int,
        maximumOutputBytes: Int,
        pdfPage: Int = 1
    ) -> PreviewOutcome {
        guard bytes.count <= maximumInputBytes,
              maximumPixelExtent > 0,
              maximumOutputBytes > 0 else {
            return .failed(.resourceLimit)
        }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard !bytes.isEmpty,
              let provider = CGDataProvider(data: bytes as CFData),
              let document = CGPDFDocument(provider) else {
            return .failed(.malformedRepresentation)
        }
        // Password protection is an unsupported capability, not corrupt data.
        // Do not attempt passwords or discard the original copyable document.
        guard !document.isEncrypted else { return .unavailable(.unsupported) }
        guard document.numberOfPages > 0 else {
            return .failed(.malformedRepresentation)
        }
        // Navigation outside this document is unavailable, not evidence that
        // the retained PDF is corrupt. Only the requested page is decoded.
        guard pdfPage >= 1, pdfPage <= document.numberOfPages else {
            return .unavailable(.pageUnavailable)
        }
        guard let page = document.page(at: pdfPage) else {
            return .failed(.malformedRepresentation)
        }

        // Quartz's drawing transform uses the crop/media intersection and
        // the page's Rotate entry. Size the output from that same rectangle,
        // including nonzero origins and portrait/landscape axis exchange.
        let media = page.getBoxRect(.mediaBox)
        let crop = page.getBoxRect(.cropBox)
        guard isFinitePositive(media), isFinitePositive(crop) else {
            return .failed(.malformedRepresentation)
        }
        let visible = media.intersection(crop)
        guard isFinitePositive(visible) else { return .failed(.malformedRepresentation) }
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        guard rotation.isMultiple(of: 90) else { return .failed(.malformedRepresentation) }
        let exchangesAxes = rotation == 90 || rotation == 270
        let sourceWidth = exchangesAxes ? visible.height : visible.width
        let sourceHeight = exchangesAxes ? visible.width : visible.height
        let scale = min(1, CGFloat(maximumPixelExtent) / max(sourceWidth, sourceHeight))
        let pixelWidth = min(CGFloat(maximumPixelExtent), max(1, (sourceWidth * scale).rounded(.up)))
        let pixelHeight = min(CGFloat(maximumPixelExtent), max(1, (sourceHeight * scale).rounded(.up)))
        // Validate before converting floating-point geometry to Int. Checked
        // multiplication below still owns the actual allocation byte bound.
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth <= CGFloat(maximumPixelExtent),
              pixelHeight <= CGFloat(maximumPixelExtent),
              pixelWidth <= CGFloat(Int.max / 4),
              pixelHeight <= CGFloat(Int.max / 4) else {
            return .failed(.resourceLimit)
        }
        let width = Int(pixelWidth)
        let height = Int(pixelHeight)
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, outputOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !outputOverflow, byteCount <= maximumOutputBytes else {
            return .failed(.resourceLimit)
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return .failed(.renderer)
        }
        let destination = CGRect(x: 0, y: 0, width: width, height: height)
        let transform = page.getDrawingTransform(
            .cropBox, rect: destination, rotate: 0, preserveAspectRatio: true
        )
        guard [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
            .allSatisfy(\.isFinite) else {
            return .failed(.malformedRepresentation)
        }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        var pixels = Data(count: byteCount)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                    data: address, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                        | CGImageAlphaInfo.premultipliedFirst.rawValue
                  ) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(destination)
            context.clip(to: destination)
            context.concatenate(transform)
            context.drawPDFPage(page)
            return true
        }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard rendered else { return .failed(.renderer) }
        return .content(.pdf(PreviewPDF(
            raster: PreviewRaster(pixels: pixels, width: width, height: height, rowBytes: rowBytes),
            pageCount: document.numberOfPages, pageNumber: pdfPage
        )))
    }

    private static func isFinitePositive(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
