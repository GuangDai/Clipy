/// SourceIconProviderFactory.swift — the AppKit half of the history row's
/// source-application icon: resolves a capture's source bundle identifier
/// to the application's icon and rasterizes it into a display-ready
/// `CGImage`. PresentationUI never sees AppKit (01 §8), so the
/// `SourceIconProvider` value it consumes is built here at the composition
/// boundary; a nil image is the row's documented fallback-symbol signal.
///
/// The rasterized cache lives for the process run: application icons do
/// not change meaningfully between panel sessions, and PresentationUI's
/// own store must never re-rasterize across them. Misses are memoized too
/// (a nil entry), so an unresolvable bundle identifier is looked up once.
import AppKit
import CoreGraphics
import PresentationUI

@MainActor
enum SourceIconProviderFactory {
    /// Rendered icons keyed by bundle identifier; `nil` values memoize
    /// misses. Static process-lifetime storage is safe here because every
    /// entry is an immutable `CGImage` and the whole factory is confined to
    /// the main actor (01 §6).
    private static var rasterizedIcons: [String: CGImage?] = [:]

    /// The rasterization edge in pixels: 2× the 32-point row slot, so the
    /// image stays sharp on Retina displays (the consumer chooses the
    /// point size; only pixels cross this boundary).
    private static let iconPixels = 64

    /// Builds the row-icon provider. Any lookup miss — unknown bundle
    /// identifier, vanished application, unrasterizable icon — yields nil
    /// so the row keeps today's fallback symbol; no failure is invented
    /// and nothing is retried eagerly.
    static func makeProvider() -> SourceIconProvider {
        SourceIconProvider(loadIcon: { bundleID in
            icon(for: bundleID)
        })
    }

    private static func icon(for bundleID: String) -> CGImage? {
        if let cached = rasterizedIcons[bundleID] {
            return cached
        }
        let rendered = rasterizeIcon(for: bundleID)
        rasterizedIcons[bundleID] = rendered
        return rendered
    }

    /// Resolves the owning application and draws its icon into one
    /// 64×64 BGRA bitmap. Drawing in pixel space (not point space) keeps
    /// the output size independent of any graphics-context scale
    /// assumption; the `.cgImage` handed to PresentationUI is exactly
    /// 64×64 pixels.
    private static func rasterizeIcon(for bundleID: String) -> CGImage? {
        guard let applicationURL = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: iconPixels,
            pixelsHigh: iconPixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(
            in: NSRect(
                x: 0, y: 0,
                width: iconPixels, height: iconPixels
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }
}
