#if DEBUG
/// Hosted-test observation of the production PreviewContentLoader. The driver
/// reports only content-free kind/dimensions/count facts and compiles out of
/// Release; it cannot inject History results or expose clipboard bytes.
import Foundation
import HistoryCore

struct PreviewLoaderDebugSnapshot: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text
        case raster
        case reference
        case failed
        case unsupported
    }

    let kind: Kind
    let textCharacterCount: Int?
    let rasterWidth: Int?
    let rasterHeight: Int?

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
final class PreviewLoaderDebugDriver {
    private let loader: PreviewContentLoader

    init(history: any ClipboardHistory) {
        loader = PreviewContentLoader(history: history)
    }

    func load(
        _ item: HistoryItemReference?
    ) async -> PreviewLoaderDebugSnapshot {
        await loader.load(item: item)
        switch loader.phase {
        case .content(.text(let text, _)):
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
        case .content(.reference):
            return PreviewLoaderDebugSnapshot(kind: .reference)
        case .failed:
            return PreviewLoaderDebugSnapshot(kind: .failed)
        case .loading, .unsupported:
            return PreviewLoaderDebugSnapshot(kind: .unsupported)
        }
    }
}
#endif
