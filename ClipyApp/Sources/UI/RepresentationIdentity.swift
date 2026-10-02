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

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pasteboardItemIndex == rhs.pasteboardItemIndex
            && lhs.typeIdentifier.utf8.elementsEqual(rhs.typeIdentifier.utf8)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pasteboardItemIndex)
        // String's default equality normalizes Unicode composition. Formats
        // are exact identifiers; hash their original bytes without a Data copy.
        var spelling = typeIdentifier
        spelling.withUTF8 { bytes in
            hasher.combine(bytes: UnsafeRawBufferPointer(bytes))
        }
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
