import ContentPreview
import HistoryCore
@testable import ClipyApp

/// Exercise Details' real selected renderer with literal bytes, including
/// malformed/empty input that History capture correctly refuses to persist.
func renderDetailsRepresentationForTest(
    _ representation: HistoryRepresentation
) async -> DetailsRepresentationPresentation {
    guard let source = ContentPreview.prepareHistoryPane([
        PreviewRepresentationMetadata(typeIdentifier: representation.typeIdentifier,
                                      byteCount: representation.bytes.count)
    ]).first else { return .metadataOnly }
    return await DetailsRepresentationPresentation.resolve(
        representation, source: source, renderer: ContentPreview()
    )
}
