/// ContentPreview — the concrete package-only renderer for transient preview
/// artifacts. Its small interface accepts immutable representation bytes plus
/// a closed product purpose and returns only bounded `Sendable` values.
///
/// Ownership: source priority, exact text codecs, ImageIO decode, eager pixel
/// materialization, resource profiles, and typed renderer outcomes. It never
/// reads History, observes selection, owns panel lifecycle, performs external
/// I/O, or exposes a framework object. `PreviewContentLoader` remains the sole
/// History/reference/task owner (01 §5/§6; REVIEW PREVIEW-1).
import ClipboardFormats
import CoreGraphics
import Foundation
import ImageIO

package struct PreviewRepresentation: Equatable, Sendable {
    package let typeIdentifier: String
    package let bytes: Data

    package init(typeIdentifier: String, bytes: Data) {
        self.typeIdentifier = typeIdentifier
        self.bytes = bytes
    }
}

package struct PreviewText: Equatable, Sendable {
    package static let maximumCharacters = 50_000

    package let text: String
    package let wasTruncated: Bool

    internal init(text: String, wasTruncated: Bool) {
        self.text = text
        self.wasTruncated = wasTruncated
    }
}

/// Fixed eager display artifact: premultiplied BGRA8 in the sRGB color space.
/// Its initializer is module-internal so callers cannot fabricate unchecked
/// dimensions or byte counts.
package struct PreviewRaster: Equatable, Sendable {
    package let pixels: Data
    package let width: Int
    package let height: Int
    package let rowBytes: Int

    internal init(pixels: Data, width: Int, height: Int, rowBytes: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.rowBytes = rowBytes
    }
}

package enum PreviewArtifact: Equatable, Sendable {
    case text(PreviewText)
    case raster(PreviewRaster)
}

package enum PreviewUnavailability: Equatable, Sendable {
    case unsupported
}

package enum PreviewFailure: Equatable, Sendable {
    case malformedRepresentation
    case resourceLimit
    case renderer
    case cancelled
}

package enum PreviewOutcome: Equatable, Sendable {
    case content(PreviewArtifact)
    case unavailable(PreviewUnavailability)
    case failed(PreviewFailure)
}

#if DEBUG
/// Content-free deterministic instrumentation. Task-local inheritance lets
/// loader tests park a render after accounting without adding a Release hook
/// or mutable singleton (PREVIEW-A3/A4/A5).
package enum ContentPreviewDebugInstrumentation {
    @TaskLocal package static var renderDidStart: (@Sendable () async -> Void)? = nil
}

package struct ContentPreviewDebugSnapshot: Equatable, Sendable {
    package let activeJobs: Int
    package let retainedSourceBytes: Int
}
#endif

/// One concrete renderer; no protocol/registry/plugin/cache. The actor keeps
/// native decode off the MainActor and owns one native slot plus in-flight
/// accounting; it owns no completed artifact cache.
package actor ContentPreview {
    /// Preserve the old single-decoder resource ceiling while allowing text
    /// work to overtake a slow native rasterization. Waiters carry no content;
    /// their caller tasks retain their own immutable snapshots.
    private var rasterizationActive = false
    private var rasterizationWaiters: [CheckedContinuation<Void, Never>] = []

    #if DEBUG
    private var debugActiveJobs = 0
    private var debugRetainedSourceBytes = 0
    #endif

    package init() {}

    /// Common-caller preset: history-owned Effective Content bytes, the
    /// current image-first/exact-text route, and the fixed history-pane
    /// resource profile. No History identity or lifecycle enters this actor.
    package func renderHistoryPane(
        _ representations: [PreviewRepresentation]
    ) async -> PreviewOutcome {
        await render(representations, operation: .historyPane)
    }

    /// Display-only PNG materialization for an encoded payload whose semantic
    /// owner already selected, version-fenced, and bounded it. In particular,
    /// ThumbnailStore/HistoryStorage retain all row-thumbnail request/source/
    /// cache policy; this method knows only inert PNG bytes.
    package func rasterizePNGForDisplay(_ bytes: Data) async -> PreviewOutcome {
        await render(
            [PreviewRepresentation(typeIdentifier: "public.png", bytes: bytes)],
            operation: .displayPNG
        )
    }

    private func render(
        _ representations: [PreviewRepresentation],
        operation: RenderOperation
    ) async -> PreviewOutcome {
        #if DEBUG
        guard let sourceBytes = checkedSourceByteCount(
            representations,
            maximum: operation.resourceProfile.maximumInputBytes
        ) else {
            return .failed(.resourceLimit)
        }
        debugActiveJobs += 1
        debugRetainedSourceBytes += sourceBytes
        defer {
            debugActiveJobs -= 1
            debugRetainedSourceBytes -= sourceBytes
        }
        #else
        guard checkedSourceByteCount(
            representations,
            maximum: operation.resourceProfile.maximumInputBytes
        ) != nil else {
            return .failed(.resourceLimit)
        }
        #endif

        guard !Task.isCancelled else { return .failed(.cancelled) }
        switch operation {
        case .historyPane:
            return await resolveHistoryPane(representations)
        case .displayPNG:
            return await renderRasterOffActor(
                representations[0],
                profile: operation.resourceProfile
            )
        }
    }

    #if DEBUG
    package func debugSnapshot() -> ContentPreviewDebugSnapshot {
        ContentPreviewDebugSnapshot(
            activeJobs: debugActiveJobs,
            retainedSourceBytes: debugRetainedSourceBytes
        )
    }
    #endif

    private func resolveHistoryPane(
        _ representations: [PreviewRepresentation]
    ) async -> PreviewOutcome {
        if let image = representations.first(where: {
            Self.imageTypeIdentifiers.contains($0.typeIdentifier)
        }) {
            return await renderRasterOffActor(image, profile: .historyPane)
        }

        var sawTextCandidate = false
        for representation in representations {
            guard let codec = PreviewTextCodec(
                typeIdentifier: representation.typeIdentifier
            ) else { continue }
            sawTextCandidate = true
            guard representation.bytes.count <= ResourceProfile.historyPane.maximumInputBytes,
                  let decoded = codec.decode(representation.bytes),
                  !decoded.isEmpty
            else { continue }
            let wasTruncated = decoded.count > PreviewText.maximumCharacters
            let body = wasTruncated
                ? String(decoded.prefix(PreviewText.maximumCharacters)) + "\n\n…"
                : decoded
            return .content(.text(PreviewText(
                text: body,
                wasTruncated: wasTruncated
            )))
        }
        return sawTextCandidate
            ? .failed(.malformedRepresentation)
            : .unavailable(.unsupported)
    }

    /// One production suspension exists around native raster work in every
    /// build: the actor remains available to resolve a newer text preview,
    /// while a single native slot preserves bounded decode concurrency.
    private func renderRasterOffActor(
        _ representation: PreviewRepresentation,
        profile: ResourceProfile
    ) async -> PreviewOutcome {
        await acquireRasterizationSlot()
        defer { releaseRasterizationSlot() }
        guard !Task.isCancelled else { return .failed(.cancelled) }

        #if DEBUG
        let renderDidStart = ContentPreviewDebugInstrumentation.renderDidStart
        #endif
        let priority = Task.currentPriority
        let task = Task.detached(priority: priority) {
            #if DEBUG
            if let renderDidStart {
                await renderDidStart()
            }
            #endif
            guard !Task.isCancelled else { return PreviewOutcome.failed(.cancelled) }
            let outcome = Self.renderRaster(representation, profile: profile)
            return Task.isCancelled ? .failed(.cancelled) : outcome
        }
        return await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
    }

    private func acquireRasterizationSlot() async {
        guard rasterizationActive else {
            rasterizationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            rasterizationWaiters.append(continuation)
        }
    }

    private func releaseRasterizationSlot() {
        guard !rasterizationWaiters.isEmpty else {
            rasterizationActive = false
            return
        }
        rasterizationWaiters.removeFirst().resume()
    }

    private static func renderRaster(
        _ representation: PreviewRepresentation,
        profile: ResourceProfile
    ) -> PreviewOutcome {
        guard representation.bytes.count <= profile.maximumInputBytes else {
            return .failed(.resourceLimit)
        }
        guard let source = CGImageSourceCreateWithData(
            representation.bytes as CFData,
            nil
        ) else {
            return .failed(.malformedRepresentation)
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: profile.maximumPixelExtent,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            CGImageSourceGetPrimaryImageIndex(source),
            options as CFDictionary
        ) else {
            return .failed(.malformedRepresentation)
        }
        guard image.width > 0,
              image.height > 0,
              image.width <= profile.maximumPixelExtent,
              image.height <= profile.maximumPixelExtent,
              let rowBytes = checkedMultiply(image.width, 4),
              let byteCount = checkedMultiply(rowBytes, image.height),
              byteCount <= profile.maximumOutputBytes
        else {
            return .failed(.resourceLimit)
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return .failed(.renderer)
        }
        var pixels = Data(count: byteCount)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                      data: address,
                      width: image.width,
                      height: image.height,
                      bitsPerComponent: 8,
                      bytesPerRow: rowBytes,
                      space: colorSpace,
                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                          | CGImageAlphaInfo.premultipliedFirst.rawValue
                  )
            else { return false }
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        guard rendered, pixels.count == byteCount else {
            return .failed(.renderer)
        }
        return .content(.raster(PreviewRaster(
            pixels: pixels,
            width: image.width,
            height: image.height,
            rowBytes: rowBytes
        )))
    }

    /// Admit the complete immutable source snapshot before route selection.
    /// Opaque siblings still consume the fixed profile; otherwise a tiny
    /// selected artifact could hide unbounded retained input (REVIEW 08 §6.2).
    private func checkedSourceByteCount(
        _ representations: [PreviewRepresentation],
        maximum: Int
    ) -> Int? {
        var total = 0
        for representation in representations {
            let (next, overflow) = total.addingReportingOverflow(
                representation.bytes.count
            )
            guard !overflow, next <= maximum else { return nil }
            total = next
        }
        return total
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : result
    }
}

private extension ContentPreview {
    enum RenderOperation: Sendable {
        case historyPane
        case displayPNG

        var resourceProfile: ResourceProfile {
            switch self {
            case .historyPane:
                .historyPane
            case .displayPNG:
                .displayPNG
            }
        }
    }

    struct ResourceProfile: Sendable {
        let maximumInputBytes: Int
        let maximumPixelExtent: Int
        let maximumOutputBytes: Int

        static let historyPane = Self(
            maximumInputBytes: 64 * 1_048_576,
            maximumPixelExtent: 640,
            maximumOutputBytes: 640 * 640 * 4
        )
        static let displayPNG = Self(
            maximumInputBytes: 16 * 1_048_576,
            maximumPixelExtent: 2_048,
            maximumOutputBytes: 2_048 * 2_048 * 4
        )
    }

    static let imageTypeIdentifiers: Set<String> = [
        "public.png",
        "public.jpeg",
        "public.tiff",
        "public.heic",
        "public.heif",
        "com.compuserve.gif",
        "com.microsoft.bmp",
    ]
}

private enum PreviewTextCodec: Sendable {
    case declared(DeclaredStringCodec)

    init?(typeIdentifier: String) {
        let identifier = ClipboardFormatIdentifier(rawValue: typeIdentifier)
        guard Self.admittedIdentifiers.contains(identifier),
              let codec = identifier.declaredStringCodec
        else { return nil }
        self = .declared(codec)
    }

    func decode(_ bytes: Data) -> String? {
        switch self {
        case .declared(.utf8):
            return String(data: bytes, encoding: .utf8)
        case .declared(.nativeUTF16):
            if bytes.starts(with: [0xFE, 0xFF]) {
                return String(data: bytes.dropFirst(2), encoding: .utf16BigEndian)
            }
            if bytes.starts(with: [0xFF, 0xFE]) {
                return String(data: bytes.dropFirst(2), encoding: .utf16LittleEndian)
            }
            return String(data: bytes, encoding: .utf16LittleEndian)
        }
    }

    private static let admittedIdentifiers: Set<ClipboardFormatIdentifier> = [
        .utf8PlainText,
        .utf16PlainText,
    ]
}
