/// SourceIconProviderFactory.swift — the AppKit half of the history row's
/// source-application icon: resolves a capture's source bundle identifier
/// to the application's icon and rasterizes it into a display-ready
/// `CGImage`. PresentationUI never sees AppKit (01 §8), so the
/// `SourceIconProvider` value it consumes is built here at the composition
/// boundary; a nil image is the row's documented fallback-symbol signal.
///
/// Retention belongs to PresentationUI's bounded per-surface SourceIconStore,
/// including negative results. This factory resolves and rasterizes only;
/// it does not keep a second process-lifetime collection of decoded icons.
import AppKit
import CoreGraphics
import PresentationUI

@MainActor
enum SourceIconProviderFactory {
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
            rasterizeIcon(for: bundleID)
        })
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
