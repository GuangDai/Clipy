/// Inert reference preview for exact URL pasteboard representations. Parsing
/// validates the address only: it never reads the referenced file, requests
/// resource values, resolves symlinks, or performs network access (01 §5/§6).
import ClipboardFormats
import Foundation

package struct PreviewReference: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        case url
        case file
    }

    package let kind: Kind
    /// The complete decoded source spelling, not URL's normalized rendering.
    package let address: String
    /// A decoded path for a file reference, not a resolved filesystem path.
    package let filePath: String?

    private static let maximumSourceBytes = 16 * 1_024

    private init(kind: Kind, address: String, filePath: String?) {
        self.kind = kind
        self.address = address
        self.filePath = filePath
    }

    /// `nil` means this representation is not an exact reference candidate.
    /// Candidate failures stay explicit; similarly named private/dynamic
    /// types never gain reference semantics from their bytes.
    internal static func resolve(
        _ representation: PreviewRepresentation
    ) -> PreviewOutcome? {
        let requiresFileURL: Bool
        switch ClipboardFormatIdentifier(rawValue: representation.typeIdentifier) {
        case .url:
            requiresFileURL = false
        case .fileURL:
            requiresFileURL = true
        default:
            return nil
        }

        guard representation.bytes.count <= maximumSourceBytes else {
            return .failed(.resourceLimit)
        }
        // Foundation's encoding-based initializer strips a UTF-8 BOM. Keep
        // every source scalar so URL validation cannot accept a rewritten
        // address, while malformed UTF-8 still fails instead of repairing it.
        guard let address = String(validating: representation.bytes, as: UTF8.self),
              !address.isEmpty,
              let url = URL(string: address, encodingInvalidCharacters: false),
              let scheme = url.scheme,
              !scheme.isEmpty,
              !requiresFileURL || url.isFileURL else {
            return .failed(.malformedRepresentation)
        }

        let isFile = url.isFileURL
        let filePath = isFile ? url.path(percentEncoded: false) : nil
        // A scheme alone does not make `file:relative` an absolute file
        // reference. Validate only its path shape, never filesystem state.
        if let filePath, filePath.unicodeScalars.first?.value != 0x2F {
            return .failed(.malformedRepresentation)
        }
        return .content(.reference(PreviewReference(
            kind: isFile ? .file : .url,
            address: address,
            filePath: filePath
        )))
    }
}
