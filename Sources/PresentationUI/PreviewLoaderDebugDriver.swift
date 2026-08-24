#if DEBUG
/// Hosted-test observation of the production PreviewContentLoader. The driver
/// reports only content-free kind/dimensions/count facts and compiles out of
/// Release; it cannot inject History results or expose clipboard bytes.
import Foundation
import HistoryCore

public struct PreviewLoaderDebugSnapshot: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case text
        case raster
        case failed
        case unsupported
    }

    public let kind: Kind
    public let textCharacterCount: Int?
    public let rasterWidth: Int?
    public let rasterHeight: Int?

    fileprivate init(
        kind: Kind,
        textCharacterCount: Int? = nil,
        rasterWidth: Int? = nil,
        rasterHeight: Int? = nil
    ) {
        self.kind = kind
        self.textCharacterCount = textCharacterCount
        self.rasterWidth = rasterWidth
        self.rasterHeight = rasterHeight
    }
}

@MainActor
public final class PreviewLoaderDebugDriver {
    private let loader: PreviewContentLoader

    public init(history: any ClipboardHistory) {
        loader = PreviewContentLoader(history: history)
    }

    public func load(
        _ item: HistoryItemReference?
    ) async -> PreviewLoaderDebugSnapshot {
        await loader.load(item: item)
        switch loader.phase {
        case .content(.text(let text)):
            return PreviewLoaderDebugSnapshot(
                kind: .text,
                textCharacterCount: text.count
            )
        case .content(.image):
            return PreviewLoaderDebugSnapshot(
                kind: .raster,
                rasterWidth: loader.raster?.width,
                rasterHeight: loader.raster?.height
            )
        case .failed:
            return PreviewLoaderDebugSnapshot(kind: .failed)
        case .loading, .unsupported:
            return PreviewLoaderDebugSnapshot(kind: .unsupported)
        }
    }
}
#endif
