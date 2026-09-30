/// ContentPreview — the concrete renderer for transient preview
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

public struct PreviewRepresentation: Equatable, Sendable {
    public let typeIdentifier: String
    public let bytes: Data

    public init(typeIdentifier: String, bytes: Data) {
        self.typeIdentifier = typeIdentifier
        self.bytes = bytes
    }
}

/// Payload-free source facts. Preparation never reads or retains content.
public struct PreviewRepresentationMetadata: Sendable, Equatable {
    package let typeIdentifier: String
    package let byteCount: Int

    public init(typeIdentifier: String, byteCount: Int) {
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
    }
}

/// One candidate chosen by the concrete preview owner. Callers only fetch its
/// bytes; source priority, resource limits and fallback stay in ContentPreview.
public struct PreviewSource: Sendable {
    package let representationIndex: Int
    public let typeIdentifier: String
    package let byteCount: Int
    fileprivate let maximumInputBytes: Int
    fileprivate let kind: Kind

    fileprivate enum Kind: Sendable {
        case image, text(PreviewTextCodec), rtf, rtfd, html, reference
    }

    public var preflightFailure: PreviewOutcome? {
        guard byteCount >= 0 else { return .failed(.malformedRepresentation) }
        return byteCount > maximumInputBytes ? .failed(.resourceLimit) : nil
    }

    public func permitsFallback(after outcome: PreviewOutcome) -> Bool {
        if case .text = kind { return outcome == .failed(.malformedRepresentation) }
        return false
    }
}

/// Fixed eager display artifact: premultiplied BGRA8 in the sRGB color space.
/// The renderer constructs it after validation; the per-surface pixel cache
/// may reconstruct the same layout from independently copied cached bytes.
public struct PreviewRaster: Equatable, Sendable {
    public let pixels: Data
    public let width: Int
    public let height: Int
    public let rowBytes: Int
    public let sourceImageCount: Int

    public init(pixels: Data, width: Int, height: Int, rowBytes: Int, sourceImageCount: Int = 1) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.rowBytes = rowBytes
        self.sourceImageCount = sourceImageCount
    }
}

public enum PreviewArtifact: Equatable, Sendable {
    case text(PreviewText)
    case raster(PreviewRaster)
    case reference(PreviewReference)
}

public enum PreviewUnavailability: Equatable, Sendable {
    case unsupported
}

public enum PreviewFailure: Equatable, Sendable {
    case malformedRepresentation
    case resourceLimit
    /// Native rendering resources are unavailable, including an occupied
    /// raster slot whose bounded wait expired. The caller may offer Retry.
    case renderer
    case cancelled
}

public enum PreviewOutcome: Equatable, Sendable {
    case content(PreviewArtifact)
    case unavailable(PreviewUnavailability)
    case failed(PreviewFailure)
}

internal enum PreviewResourceLimits {
    static let richTextInputBytes = 1_048_576
    static let referenceInputBytes = 16 * 1_024
}

#if DEBUG
/// Content-free deterministic instrumentation. Task-local inheritance lets
/// loader tests park a render after accounting without adding a Release hook
/// or mutable singleton (PREVIEW-A3/A4/A5).
package enum ContentPreviewDebugInstrumentation {
    @TaskLocal package static var renderDidStart: (@Sendable () async -> Void)? = nil
    @TaskLocal package static var textRenderDidStart: (@Sendable () -> Void)? = nil
}

public struct ContentPreviewDebugSnapshot: Equatable, Sendable {
    package let activeJobs: Int
    package let retainedSourceBytes: Int
    package let queuedRasterJobs: Int
    package let queuedTextJobs: Int
}
#endif

/// One concrete renderer; no protocol/registry/plugin/cache. The actor keeps
/// decoding off the MainActor and owns one raster slot and one text slot plus
/// in-flight accounting; it owns no completed artifact cache.
public actor ContentPreview {
    /// One decoded text document can coexist with one native rasterization,
    /// preserving the previous resource ceiling. Waiting never starts decoding
    /// or segmentation. Waiters carry no content; their callers keep snapshots.
    private enum RenderSlot: Int, Sendable { case raster, text }
    private struct RenderWaiter {
        let id: UUID
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<PreviewFailure?, Never>
    }
    private struct RenderSlotState {
        var active = false
        var waiters: [RenderWaiter] = []
    }
    private var renderSlots = [RenderSlotState(), RenderSlotState()]

    #if DEBUG
    private var debugActiveJobs = 0
    private var debugRetainedSourceBytes = 0
    #endif

    public init() {}

    /// Metadata-only preparation. An image is authoritative; otherwise exact
    /// text candidates may fail decoding before one rich/reference source
    /// applies. Unrelated representation bytes never enter the preview job.
    public static func prepareHistoryPane(
        _ representations: [PreviewRepresentationMetadata]
    ) -> [PreviewSource] {
        func source(_ index: Int, _ kind: PreviewSource.Kind,
                    maximum: Int = ResourceProfile.historyPane.maximumInputBytes) -> PreviewSource {
            PreviewSource(
                representationIndex: index, typeIdentifier: representations[index].typeIdentifier,
                byteCount: representations[index].byteCount, maximumInputBytes: maximum, kind: kind
            )
        }
        if let index = representations.firstIndex(where: { imageTypeIdentifiers.contains($0.typeIdentifier) }) {
            return [source(index, .image)]
        }
        var candidates: [PreviewSource] = []
        for (index, representation) in representations.enumerated() {
            if let codec = PreviewTextCodec(typeIdentifier: representation.typeIdentifier) {
                candidates.append(source(index, .text(codec)))
            }
        }
        if let index = representations.firstIndex(where: { $0.typeIdentifier == ClipboardFormatIdentifier.rtf.rawValue }) {
            candidates.append(source(index, .rtf, maximum: PreviewResourceLimits.richTextInputBytes))
        } else if let index = representations.firstIndex(where: { $0.typeIdentifier == ClipboardFormatIdentifier.flatRTFD.rawValue }) {
            candidates.append(source(index, .rtfd, maximum: PreviewResourceLimits.richTextInputBytes))
        } else if let index = representations.firstIndex(where: { $0.typeIdentifier == ClipboardFormatIdentifier.html.rawValue }) {
            candidates.append(source(index, .html, maximum: PreviewResourceLimits.richTextInputBytes))
        } else if let index = representations.firstIndex(where: {
            $0.typeIdentifier == ClipboardFormatIdentifier.url.rawValue
                || $0.typeIdentifier == ClipboardFormatIdentifier.fileURL.rawValue
        }) {
            candidates.append(source(index, .reference, maximum: PreviewResourceLimits.referenceInputBytes))
        }
        return candidates
    }

    /// In-memory convenience for explicitly loaded files and direct fixtures.
    /// It uses exactly the same metadata preparation and selected renderer as
    /// History's lazy representation reader; it owns no second source policy.
    public func renderHistoryPane(
        _ representations: [PreviewRepresentation],
        textConfiguration: PreviewTextConfiguration = .init()
    ) async -> PreviewOutcome {
        guard !Task.isCancelled else { return .failed(.cancelled) }
        // Unlike metadata-only preparation, this call already owns every
        // supplied payload throughout the candidate loop (01 §6).
        var totalInputBytes = 0
        for representation in representations {
            guard representation.bytes.count <= ResourceProfile.historyPane.maximumInputBytes - totalInputBytes else {
                return .failed(.resourceLimit)
            }
            totalInputBytes += representation.bytes.count
        }
        let sources = Self.prepareHistoryPane(representations.map {
            PreviewRepresentationMetadata(typeIdentifier: $0.typeIdentifier, byteCount: $0.bytes.count)
        })
        var outcome = PreviewOutcome.unavailable(.unsupported)
        for source in sources {
            #if DEBUG
            // The selected renderer accounts for its own bytes. Include the
            // siblings still retained by this wrapper, exactly once per await.
            let siblingBytes = totalInputBytes - source.byteCount
            debugRetainedSourceBytes += siblingBytes
            defer { debugRetainedSourceBytes -= siblingBytes }
            #endif
            outcome = await renderSelectedHistoryPane(
                source, representation: representations[source.representationIndex],
                textConfiguration: textConfiguration
            )
            if !source.permitsFallback(after: outcome) { return outcome }
        }
        return outcome
    }

    public func renderSelectedHistoryPane(
        _ source: PreviewSource, representation: PreviewRepresentation,
        textConfiguration: PreviewTextConfiguration = .init()
    ) async -> PreviewOutcome {
        if let failure = source.preflightFailure { return failure }
        guard representation.typeIdentifier.utf8.elementsEqual(source.typeIdentifier.utf8),
              representation.bytes.count == source.byteCount else { return .failed(.malformedRepresentation) }
        let outcome = await renderRepresentation(
            representation, kind: source.kind, maximumInputBytes: source.maximumInputBytes,
            profile: .historyPane, textConfiguration: textConfiguration
        )
        return Task.isCancelled ? .failed(.cancelled) : outcome
    }

    /// Display-only PNG materialization. Thumbnail request/source/version
    /// ownership remains entirely with HistoryStorage/ThumbnailStore.
    public func rasterizePNGForDisplay(_ bytes: Data) async -> PreviewOutcome {
        await renderRepresentation(
            PreviewRepresentation(typeIdentifier: "public.png", bytes: bytes),
            kind: .image, maximumInputBytes: ResourceProfile.displayPNG.maximumInputBytes, profile: .displayPNG
        )
    }

    private func renderRepresentation(
        _ representation: PreviewRepresentation, kind: PreviewSource.Kind,
        maximumInputBytes: Int, profile: ResourceProfile,
        textConfiguration: PreviewTextConfiguration = .init()
    ) async -> PreviewOutcome {
        guard representation.bytes.count <= maximumInputBytes else { return .failed(.resourceLimit) }
        #if DEBUG
        debugActiveJobs += 1
        debugRetainedSourceBytes += representation.bytes.count
        defer {
            debugActiveJobs -= 1
            debugRetainedSourceBytes -= representation.bytes.count
        }
        #endif
        guard !Task.isCancelled else { return .failed(.cancelled) }
        let slot: RenderSlot
        if case .image = kind { slot = .raster } else { slot = .text }
        if let failure = await acquireRenderSlot(slot) {
            return .failed(Task.isCancelled ? .cancelled : failure)
        }
        defer { releaseRenderSlot(slot) }
        return await renderOffActor(representation, kind: kind, maximumInputBytes: maximumInputBytes,
                                    profile: profile, textConfiguration: textConfiguration)
    }

    private static func render(
        _ representation: PreviewRepresentation, kind: PreviewSource.Kind,
        maximumInputBytes: Int, profile: ResourceProfile,
        textConfiguration: PreviewTextConfiguration
    ) -> PreviewOutcome {
        switch kind {
        case .image:
            return renderRaster(representation, profile: profile)
        case .text(let codec):
            guard let decoded = codec.decode(representation.bytes), !decoded.isEmpty else {
                return .failed(.malformedRepresentation)
            }
            do {
                return .content(.text(try PreviewText(
                    text: decoded, wasTruncated: false, configuration: textConfiguration,
                    checkCancellation: { try Task.checkCancellation() }
                )))
            } catch is CancellationError { return .failed(.cancelled) }
            catch { return .failed(.malformedRepresentation) }
        case .rtf:
            return PreviewRTFRenderer.render(representation.bytes, textConfiguration: textConfiguration)
        case .rtfd:
            return PreviewRTFDRenderer.render(representation.bytes, textConfiguration: textConfiguration)
        case .html:
            return PreviewHTMLRenderer.render(
                representation.bytes, maximumInputBytes: maximumInputBytes, maximumOutputBytes: 1_048_576,
                textConfiguration: textConfiguration
            )
        case .reference:
            return PreviewReference.resolve(representation) ?? .unavailable(.unsupported)
        }
    }

    #if DEBUG
    public func debugSnapshot() -> ContentPreviewDebugSnapshot {
        ContentPreviewDebugSnapshot(activeJobs: debugActiveJobs, retainedSourceBytes: debugRetainedSourceBytes,
                                    queuedRasterJobs: renderSlots[RenderSlot.raster.rawValue].waiters.count,
                                    queuedTextJobs: renderSlots[RenderSlot.text.rawValue].waiters.count)
    }
    #endif

    /// Parsing, segmentation, and native font fallback run away from the
    /// accounting actor. A slow rich-text document cannot delay acquisition,
    /// cancellation, or timeout of another preview's native raster slot.
    private func renderOffActor(
        _ representation: PreviewRepresentation, kind: PreviewSource.Kind,
        maximumInputBytes: Int, profile: ResourceProfile,
        textConfiguration: PreviewTextConfiguration
    ) async -> PreviewOutcome {
        guard !Task.isCancelled else { return .failed(.cancelled) }

        #if DEBUG
        let renderDidStart = ContentPreviewDebugInstrumentation.renderDidStart
        let textRenderDidStart = ContentPreviewDebugInstrumentation.textRenderDidStart
        #endif
        let priority = Task.currentPriority
        let task = Task.detached(priority: priority) {
            #if DEBUG
            if case .image = kind {
                if let renderDidStart { await renderDidStart() }
            } else {
                textRenderDidStart?()
            }
            #endif
            guard !Task.isCancelled else { return PreviewOutcome.failed(.cancelled) }
            let outcome = Self.render(representation, kind: kind, maximumInputBytes: maximumInputBytes,
                                      profile: profile, textConfiguration: textConfiguration)
            guard !Task.isCancelled else { return .failed(.cancelled) }
            if case .content(.text(let text)) = outcome {
                PreviewTextTypography.prepare(text)
            }
            return Task.isCancelled ? .failed(.cancelled) : outcome
        }
        return await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
    }

    private func acquireRenderSlot(_ slot: RenderSlot) async -> PreviewFailure? {
        guard !Task.isCancelled else { return .cancelled }
        guard renderSlots[slot.rawValue].active else {
            renderSlots[slot.rawValue].active = true
            return nil
        }
        let id = UUID()
        // ImageIO, FileWrapper deserialization, strict text decoding, and
        // native font fallback can remain busy after cancellation. Keep each
        // resource ceiling while allowing a queued request to fail and retry.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let timeout = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            finishRenderWaiter(id, slot: slot, failure: .renderer)
        }
        defer { timeout.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation may precede registration. The actor cannot
                // interleave waiter removal between this check and append.
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                renderSlots[slot.rawValue].waiters.append(RenderWaiter(
                    id: id, deadline: deadline, continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.finishRenderWaiter(id, slot: slot, failure: .cancelled) }
        }
    }

    private func finishRenderWaiter(_ id: UUID, slot: RenderSlot, failure: PreviewFailure) {
        guard let index = renderSlots[slot.rawValue].waiters.firstIndex(where: { $0.id == id }) else {
            // A waiter already handed the slot owns it and releases it via
            // renderRepresentation's defer, even if it was just cancelled.
            return
        }
        renderSlots[slot.rawValue].waiters.remove(at: index).continuation.resume(returning: failure)
    }

    private func releaseRenderSlot(_ slot: RenderSlot) {
        while !renderSlots[slot.rawValue].waiters.isEmpty {
            let waiter = renderSlots[slot.rawValue].waiters.removeFirst()
            // Recheck at handoff: actor scheduling must not let a delayed
            // timeout admit native work after its acquisition deadline.
            guard ContinuousClock.now < waiter.deadline else {
                waiter.continuation.resume(returning: .renderer)
                continue
            }
            waiter.continuation.resume(returning: nil)
            return
        }
        renderSlots[slot.rawValue].active = false
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
        let sourceImageCount = CGImageSourceGetCount(source)
        guard sourceImageCount > 0 else { return .failed(.malformedRepresentation) }
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
            rowBytes: rowBytes,
            sourceImageCount: sourceImageCount
        )))
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : result
    }
}

private extension ContentPreview {
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

fileprivate enum PreviewTextCodec: Sendable {
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
            // Preserve every source scalar, including a leading U+FEFF.
            // Foundation's encoding initializer consumes a UTF-8 signature,
            // changing the exact selectable prefix required by 06 §5.
            return String(validating: bytes, as: UTF8.self)
        case .declared(.nativeUTF16), .declared(.externalUTF16):
            // Foundation can decode a valid prefix while ignoring an odd
            // trailing byte. A UTF-16 preview requires complete code units.
            guard bytes.count.isMultiple(of: 2) else { return nil }
            let littleEndian: Bool
            let hasBOM: Bool
            if bytes.starts(with: [0xFE, 0xFF]) {
                littleEndian = false
                hasBOM = true
            } else if bytes.starts(with: [0xFF, 0xFE]) {
                littleEndian = true
                hasBOM = true
            } else {
                // Native text follows arm64 little endian; external UTF-16
                // defaults to big endian when no encoding marker is present.
                if case .declared(.externalUTF16) = self { littleEndian = false }
                else { littleEndian = true }
                hasBOM = false
            }
            let body = bytes.dropFirst(hasBOM ? 2 : 0)
            let units = PreviewUTF16CodeUnits(bytes: body, littleEndian: littleEndian)
            // Validate the complete source before applying any display cap.
            // Explicit code units reject unpaired surrogates without repair;
            // a second FEFF/FFFE is content, never another encoding marker
            // (roadmap 05: Details and the large preview share exact text).
            return String(validating: units, as: UTF16.self)
        }
    }

    private static let admittedIdentifiers: Set<ClipboardFormatIdentifier> = [
        .utf8PlainText,
        .utf16PlainText,
        .utf16ExternalPlainText,
    ]
}
