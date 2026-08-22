/// PasteboardLineageHint — the pasteboard marker Clipy writes on paste so
/// the next capture of its own paste can be recognized as a repeat copy and
/// coalesced (docs/01-architecture.md §5.6 paste flow and §5.1 copy
/// coalescing; docs/03b-instruction-set.md §9 `PastePayload.lineageHint`;
/// docs/04-coherence.md §8 paste coherence; roadmap
/// docs/roadmap/04-pasteboardadapter.md deliverable 2).
///
/// The hint is item metadata, never retainable content: the adapter decodes
/// it into `CopyOriginObservation.lineageHint` at capture time and excludes
/// its type from the frozen representations (docs/03a-instruction-set.md
/// §4 — an observation carries no item ID to create; storage validates the
/// hint against retained items and requires byte-equal Effective Content
/// before it can win).
import Foundation
import HistoryCore

/// UTF-8 encode/decode of the lineage hint over the fixed marker type.
///
/// `HistoryItemID.init(rawValue:)` is package access, which this target and
/// the test target share inside the SwiftPM package; minting stays
/// centralized in `HistoryStorage`, decoding here is read-only.
enum PasteboardLineageHint {
    /// The pasteboard type carrying the prior paste's item ID.
    static let typeIdentifier = "com.clipy.lineageHint"

    /// Encodes the item ID as its UUID string in UTF-8 — the exact wire form
    /// `decode(_:)` accepts (docs/03b-instruction-set.md §9).
    static func encode(_ id: HistoryItemID) -> Data {
        Data(id.rawValue.uuidString.utf8)
    }

    /// Decodes hint bytes back into an item ID, or nil when the payload is
    /// not valid UTF-8 / not a UUID. A malformed hint is an absent hint:
    /// the capture proceeds without one and coalescing falls back to
    /// content equality (docs/01-architecture.md §5.1).
    static func decode(_ data: Data) -> HistoryItemID? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let uuid = UUID(uuidString: text) else { return nil }
        return HistoryItemID(rawValue: uuid)
    }
}
