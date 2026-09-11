/// Inert flat-RTFD body-text extraction (REVIEW PREVIEW-RTF; 01 §6).
/// Foundation's serialized wrapper initializer consumes the supplied RTFD
/// stream without associating it with any filesystem node. Only the package's
/// top-level TXT.rtf regular-file bytes reach the existing offline RTF parser.
/// Attachments remain opaque; no wrapper is written or resolved through a URL.
import Foundation

internal enum PreviewRTFDRenderer {
    internal static func render(_ bytes: Data, textConfiguration: PreviewTextConfiguration = .init()) -> PreviewOutcome {
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard bytes.count <= 1_048_576 else { return .failed(.resourceLimit) }
        guard let wrapper = FileWrapper(serializedRepresentation: bytes),
              wrapper.isDirectory, let children = wrapper.fileWrappers else {
            return .failed(.malformedRepresentation)
        }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        // One document plus at most the RTF renderer's 128 attachment slots.
        // This limits accepted packages; Foundation's opaque deserialization
        // itself has no allocation budget or cooperative cancellation API.
        guard children.count <= 129 else { return .failed(.resourceLimit) }
        guard let document = children["TXT.rtf"] else {
            return .failed(.malformedRepresentation)
        }
        // A symbolic link or directory in the document slot is a wrapper
        // feature we do not support. In particular, never follow a symlink.
        // regularFileContents throws an ObjC exception for other wrapper kinds.
        guard document.isRegularFile else { return .unavailable(.unsupported) }
        guard let rtf = document.regularFileContents else {
            return .failed(.malformedRepresentation)
        }
        return PreviewRTFRenderer.render(rtf, textConfiguration: textConfiguration)
    }
}
