import HistoryCore

/// A format row belongs to one constituent pasteboard item. The same exact
/// type can occur on several items without sharing editor state or selection.
struct RepresentationIdentity: Hashable, Sendable {
    let pasteboardItemIndex: Int
    let typeIdentifier: String

    init(typeIdentifier: String, pasteboardItemIndex: Int = 0) {
        self.typeIdentifier = typeIdentifier
        self.pasteboardItemIndex = pasteboardItemIndex
    }

    var accessibilityLabel: String {
        pasteboardItemIndex == 0 ? typeIdentifier : "\(pasteboardItemIndex + 1) · \(typeIdentifier)"
    }

    /// Preserve existing single-item accessibility identifiers.
    var accessibilitySuffix: String {
        pasteboardItemIndex == 0 ? typeIdentifier : "\(pasteboardItemIndex).\(typeIdentifier)"
    }
}

extension HistoryRepresentationMetadata {
    var representationIdentity: RepresentationIdentity {
        RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)
    }
}
