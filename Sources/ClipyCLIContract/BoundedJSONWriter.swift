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

    mutating func appendJSON(_ value: String) {
        guard !exceeded else { return }
        guard value.utf8.count <= maximumBytes - data.count - 2 else {
            exceeded = true
            return
        }
        let needsEscaping = value.unicodeScalars.contains {
            $0.value <= 0x1F || $0.value == 0x22 || $0.value == 0x5C
        }
        if !needsEscaping {
            appendByte(0x22)
            append(value.utf8)
            appendByte(0x22)
            return
        }
        appendByte(0x22)
        for scalar in value.unicodeScalars where !exceeded {
            switch scalar.value {
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
            case 0x00...0x1F:
                let digits = Array("0123456789abcdef".utf8)
                appendASCII("\\u00")
                appendByte(digits[Int(scalar.value >> 4)])
                appendByte(digits[Int(scalar.value & 0x0F)])
            default:
                append(String(scalar).utf8)
            }
        }
        appendByte(0x22)
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
