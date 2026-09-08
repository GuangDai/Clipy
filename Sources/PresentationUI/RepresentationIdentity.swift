import HistoryCore

/// A format row belongs to one constituent pasteboard item. The same exact
/// type can occur on several items without sharing editor state or selection.
package struct RepresentationIdentity: Hashable, Sendable {
    package let pasteboardItemIndex: Int
    package let typeIdentifier: String

    package init(typeIdentifier: String, pasteboardItemIndex: Int = 0) {
        self.typeIdentifier = typeIdentifier
        self.pasteboardItemIndex = pasteboardItemIndex
    }

    package var accessibilityLabel: String {
        pasteboardItemIndex == 0 ? typeIdentifier : "\(pasteboardItemIndex + 1) · \(typeIdentifier)"
    }

    /// Preserve existing single-item accessibility identifiers.
    package var accessibilitySuffix: String {
        pasteboardItemIndex == 0 ? typeIdentifier : "\(pasteboardItemIndex).\(typeIdentifier)"
    }
}

extension HistoryRepresentationMetadata {
    package var representationIdentity: RepresentationIdentity {
        RepresentationIdentity(typeIdentifier: typeIdentifier, pasteboardItemIndex: pasteboardItemIndex)
    }
}
