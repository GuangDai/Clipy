/// The editor's paired codec for an exact plain-text representation.
/// Capturing the original byte order and BOM keeps replacements in the
/// source encoding. An explicit BOM is added when a new first text scalar
/// would otherwise be mistaken for one on reopen. UTF-16 encoding facts
/// belong to ClipboardFormats.
import ClipboardFormats
import Foundation
import HistoryCore

package struct EditorTextCodec: Sendable, Equatable {
    private enum Encoding: Sendable, Equatable {
        case utf8
        case utf16(littleEndian: Bool, includesBOM: Bool)
    }

    private let encoding: Encoding

    /// Returns a codec only when this exact representation can be decoded
    /// without repairing malformed Unicode. Empty text is valid Unicode;
    /// the draft owns whether an empty replacement may be submitted.
    package static func matching(
        _ representation: HistoryRepresentation
    ) -> EditorTextCodec? {
        let identifier = ClipboardFormatIdentifier(rawValue: representation.typeIdentifier)
        let codec: Self
        switch identifier {
        case .utf8PlainText:
            codec = Self(encoding: .utf8)
        case .utf16PlainText, .utf16ExternalPlainText:
            let bytes = representation.bytes
            if bytes.starts(with: [0xFF, 0xFE]) {
                codec = Self(encoding: .utf16(littleEndian: true, includesBOM: true))
            } else if bytes.starts(with: [0xFE, 0xFF]) {
                codec = Self(encoding: .utf16(littleEndian: false, includesBOM: true))
            } else {
                codec = Self(encoding: .utf16(
                    littleEndian: identifier == .utf16PlainText,
                    includesBOM: false
                ))
            }
        default:
            return nil
        }
        return codec.decode(representation.bytes) == nil ? nil : codec
    }

    package func decode(_ bytes: Data) -> String? {
        switch encoding {
        case .utf8:
            // UTF-8 U+FEFF is text, not an encoding marker to strip. The
            // validating initializer rejects malformed input without repair.
            return String(validating: bytes, as: UTF8.self)
        case let .utf16(littleEndian, includesBOM):
            guard bytes.count.isMultiple(of: 2) else { return nil }
            let marker: [UInt8] = littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]
            let hasBOM = bytes.starts(with: marker)
            guard !includesBOM || hasBOM else { return nil }
            // A formerly BOM-less codec may add a marker to disambiguate
            // newly authored text. Consume that marker exactly once too.
            let body = bytes.dropFirst(hasBOM ? 2 : 0)
            var units: [UInt16] = []
            units.reserveCapacity(body.count / 2)
            var iterator = body.makeIterator()
            while let first = iterator.next(), let second = iterator.next() {
                units.append(littleEndian
                    ? UInt16(first) | (UInt16(second) << 8)
                    : (UInt16(first) << 8) | UInt16(second))
            }
            // After consuming the encoding marker, any further U+FEFF is
            // content. Validate code units without another BOM interpretation.
            return String(validating: units, as: UTF16.self)
        }
    }

    package func encode(_ text: String) -> Data {
        switch encoding {
        case .utf8:
            return Data(text.utf8)
        case let .utf16(littleEndian, includesBOM):
            let firstUnit = text.utf16.first
            // Either scalar would look like a BOM in one byte order. Prefix
            // a real marker so a newly matched codec preserves the scalar.
            let writesBOM = includesBOM || firstUnit == 0xFEFF || firstUnit == 0xFFFE
            var bytes = Data()
            bytes.reserveCapacity(text.utf16.count * 2 + (writesBOM ? 2 : 0))
            if writesBOM {
                bytes.append(contentsOf: littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF])
            }
            for unit in text.utf16 {
                let low = UInt8(truncatingIfNeeded: unit)
                let high = UInt8(truncatingIfNeeded: unit >> 8)
                bytes.append(littleEndian ? low : high)
                bytes.append(littleEndian ? high : low)
            }
            return bytes
        }
    }
}
