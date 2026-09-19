/// BoundedJSONWriter — deterministic compact JSON bytes with the response
/// envelope enforced during construction, before an oversized value can be
/// materialized (V2-05 §0.1.1–0.1.2; PLAY-PY-A2G).
import Foundation

struct BoundedJSONWriter {
    private let maximumBytes: Int
    private(set) var data = Data()
    private(set) var exceeded = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    mutating func appendASCII(_ value: String) {
        append(value.utf8)
    }

    /// RFC 4648's standard alphabet needs no JSON escaping. Admit its padded
    /// size before encoding, then copy the encoded bytes directly instead of
    /// constructing and scanning a potentially 32 MB Swift string (V2-05 §0.1.2).
    mutating func appendBase64(_ bytes: Data) {
        guard !exceeded else { return }
        let available = maximumBytes - data.count
        guard available >= 2, bytes.count <= ((available - 2) / 4) * 3 else {
            exceeded = true
            return
        }
        data.append(0x22)
        data.append(bytes.base64EncodedData())
        data.append(0x22)
    }

    mutating func appendJSON(_ value: String) {
        guard !exceeded else { return }
        guard value.utf8.count <= maximumBytes - data.count - 2 else {
            exceeded = true
            return
        }
        // JSON escapes only ASCII bytes; all other UTF-8 bytes can be copied
        // unchanged. Emit contiguous runs without allocating a String for
        // each Unicode scalar (V2-05 §0.1.2 exact UTF-8 emission).
        let bytes = value.utf8
        appendByte(0x22)
        var runStart = bytes.startIndex
        var index = runStart
        while index != bytes.endIndex {
            let byte = bytes[index]
            let next = bytes.index(after: index)
            if byte <= 0x1F || byte == 0x22 || byte == 0x5C {
                append(bytes[runStart..<index])
                guard !exceeded else { return }
                switch byte {
                case 0x22:
                    appendASCII("\\\"")
                case 0x5C:
                    appendASCII("\\\\")
                case 0x08:
                    appendASCII("\\b")
                case 0x0C:
                    appendASCII("\\f")
                case 0x0A:
                    appendASCII("\\n")
                case 0x0D:
                    appendASCII("\\r")
                case 0x09:
                    appendASCII("\\t")
                default:
                    appendASCII("\\u00")
                    appendByte(Self.hexDigit(byte >> 4))
                    appendByte(Self.hexDigit(byte & 0x0F))
                }
                guard !exceeded else { return }
                runStart = next
            }
            index = next
        }
        append(bytes[runStart..<bytes.endIndex])
        appendByte(0x22)
    }

    private static func hexDigit(_ value: UInt8) -> UInt8 {
        value < 10 ? 0x30 + value : 0x61 + value - 10
    }

    mutating func appendByte(_ byte: UInt8) {
        guard !exceeded else { return }
        guard data.count < maximumBytes else {
            exceeded = true
            return
        }
        data.append(byte)
    }

    private mutating func append<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        guard !exceeded else { return }
        guard bytes.count <= maximumBytes - data.count else {
            exceeded = true
            return
        }
        data.append(contentsOf: bytes)
    }
}
