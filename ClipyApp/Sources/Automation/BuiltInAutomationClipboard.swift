import AppKit
import ImageIO

/// Explicit workflow input/output commands. These author new clipboard values,
/// not History revisions; normal capture observes a copied result afterward.
@MainActor
enum BuiltInAutomationClipboard {
    /// A workflow's steps choose a representation preference, not an input
    /// requirement. Its If block must still see the other supported type and
    /// select Otherwise when the preferred representation is absent.
    static func read(image: Bool, from pasteboard: NSPasteboard = .general) throws -> BuiltInAutomationInput {
        func readImage() throws -> BuiltInAutomationInput? {
            for type in [NSPasteboard.PasteboardType.png, .tiff, .init("public.jpeg"), .init("public.heic")] {
                if let data = pasteboard.data(forType: type) {
                    // Present but invalid content fails here; it cannot be
                    // silently replaced by another representation or text.
                    try BuiltInAutomation.validateImage(data)
                    return .image(data)
                }
            }
            return nil
        }
        if image, let selected = try readImage() { return selected }
        if let text = pasteboard.string(forType: .string) {
            try BuiltInAutomation.checkSize(text)
            return .text(text)
        }
        if !image, let selected = try readImage() { return selected }
        throw BuiltInAutomationFailure.clipboardUnavailable
    }

    static func copy(_ value: BuiltInAutomationInput, to pasteboard: NSPasteboard = .general) throws {
        let item = NSPasteboardItem()
        let type: NSPasteboard.PasteboardType
        let data: Data
        switch value {
        case let .text(text):
            try BuiltInAutomation.checkSize(text)
            type = .string
            data = Data(text.utf8)
        case let .image(image):
            try BuiltInAutomation.validateImage(image)
            guard let source = CGImageSourceCreateWithData(image as CFData, nil),
                  let identifier = CGImageSourceGetType(source) else {
                throw BuiltInAutomationFailure.invalidImage
            }
            type = .init(identifier as String)
            data = image
        }
        guard item.setData(data, forType: type) else { throw BuiltInAutomationFailure.clipboardUnavailable }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]), pasteboard.data(forType: type) == data else {
            throw BuiltInAutomationFailure.clipboardUnavailable
        }
    }
}
