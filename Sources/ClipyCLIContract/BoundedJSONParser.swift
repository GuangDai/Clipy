/// BoundedJSONParser — the deliberately small JSON reader at the X.8 wire
/// boundary. It owns structural admission only; typed request policy remains
/// in `ClipyCLIContract` (V2-05 §0.1.1; PLAY-PY-A2B–A2E).
import Foundation

indirect enum BoundedJSONValue: Equatable, Sendable {
    case object([(String, BoundedJSONValue)])
    case array([BoundedJSONValue])
    case string(String)
    case number(String)
    case boolean(Bool)
    case null

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.object(lhs), .object(rhs)):
            lhs.elementsEqual(rhs) { left, right in
                left.0 == right.0 && left.1 == right.1
            }
        case let (.array(lhs), .array(rhs)):
            lhs == rhs
        case let (.string(lhs), .string(rhs)):
            lhs == rhs
        case let (.number(lhs), .number(rhs)):
            lhs == rhs
        case let (.boolean(lhs), .boolean(rhs)):
            lhs == rhs
        case (.null, .null):
            true
        default:
            false
        }
    }
}

enum BoundedJSONParser {
    static let maximumDepth = 8
    static let maximumObjectMembers = 32
    static let maximumArrayElements = 512

    static func parse(_ data: Data) throws -> BoundedJSONValue {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        guard !parser.isAtEnd else {
            throw ParseFailure.invalidJSON
        }
        let value = try parser.parseValue(depth: 1)
        parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw ParseFailure.invalidJSON
        }
        return value
    }

    enum ParseFailure: Error, Equatable, Sendable {
        case invalidJSON
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        var isAtEnd: Bool { offset == bytes.count }

        mutating func skipWhitespace() {
            while let byte = peek(), Self.isWhitespace(byte) {
                offset += 1
            }
        }

        mutating func parseValue(depth: Int) throws -> BoundedJSONValue {
            guard let byte = peek() else {
                throw ParseFailure.invalidJSON
            }
            switch byte {
            case 0x7B: // {
                guard depth <= BoundedJSONParser.maximumDepth else {
                    throw ParseFailure.invalidJSON
                }
                return try parseObject(depth: depth)
            case 0x5B: // [
                guard depth <= BoundedJSONParser.maximumDepth else {
                    throw ParseFailure.invalidJSON
                }
                return try parseArray(depth: depth)
            case 0x22: // "
                return .string(try parseString())
            case 0x74: // true
                try consumeLiteral([0x74, 0x72, 0x75, 0x65])
                return .boolean(true)
            case 0x66: // false
                try consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
                return .boolean(false)
            case 0x6E: // null
                try consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
                return .null
            case 0x2D, 0x30...0x39:
                return .number(try parseNumber())
            default:
                throw ParseFailure.invalidJSON
            }
        }

        mutating func parseObject(depth: Int) throws -> BoundedJSONValue {
            try consume(0x7B)
            skipWhitespace()
            if consumeIfPresent(0x7D) {
                return .object([])
            }

            var members: [(String, BoundedJSONValue)] = []
            while true {
                guard members.count < BoundedJSONParser.maximumObjectMembers,
                      peek() == 0x22 else {
                    throw ParseFailure.invalidJSON
                }
                let key = try parseString()
                guard !members.contains(where: {
                    $0.0.utf8.elementsEqual(key.utf8)
                }) else {
                    throw ParseFailure.invalidJSON
                }
                skipWhitespace()
                try consume(0x3A)
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                members.append((key, value))
                skipWhitespace()
                if consumeIfPresent(0x7D) {
                    return .object(members)
                }
                try consume(0x2C)
                skipWhitespace()
            }
        }

        mutating func parseArray(depth: Int) throws -> BoundedJSONValue {
            try consume(0x5B)
            skipWhitespace()
            if consumeIfPresent(0x5D) {
                return .array([])
            }

            var elements: [BoundedJSONValue] = []
            while true {
                guard elements.count < BoundedJSONParser.maximumArrayElements else {
                    throw ParseFailure.invalidJSON
                }
                elements.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                if consumeIfPresent(0x5D) {
                    return .array(elements)
                }
                try consume(0x2C)
                skipWhitespace()
            }
        }

        mutating func parseString() throws -> String {
            try consume(0x22)
            var decoded: [UInt8] = []

            while let byte = peek() {
                offset += 1
                switch byte {
                case 0x22:
                    guard let value = String(bytes: decoded, encoding: .utf8) else {
                        throw ParseFailure.invalidJSON
                    }
                    return value
                case 0x5C:
                    try appendEscape(to: &decoded)
                case 0x00...0x1F:
                    throw ParseFailure.invalidJSON
                default:
                    decoded.append(byte)
                }
            }
            throw ParseFailure.invalidJSON
        }

        mutating func appendEscape(to decoded: inout [UInt8]) throws {
            guard let escaped = peek() else {
                throw ParseFailure.invalidJSON
            }
            offset += 1
            switch escaped {
            case 0x22, 0x5C, 0x2F:
                decoded.append(escaped)
            case 0x62:
                decoded.append(0x08)
            case 0x66:
                decoded.append(0x0C)
            case 0x6E:
                decoded.append(0x0A)
            case 0x72:
                decoded.append(0x0D)
            case 0x74:
                decoded.append(0x09)
            case 0x75:
                let first = try parseHexCodeUnit()
                let scalar: UInt32
                if (0xD800...0xDBFF).contains(first) {
                    try consume(0x5C)
                    try consume(0x75)
                    let second = try parseHexCodeUnit()
                    guard (0xDC00...0xDFFF).contains(second) else {
                        throw ParseFailure.invalidJSON
                    }
                    scalar = 0x10000
                        + (UInt32(first - 0xD800) << 10)
                        + UInt32(second - 0xDC00)
                } else {
                    guard !(0xDC00...0xDFFF).contains(first) else {
                        throw ParseFailure.invalidJSON
                    }
                    scalar = UInt32(first)
                }
                guard let unicodeScalar = Unicode.Scalar(scalar) else {
                    throw ParseFailure.invalidJSON
                }
                decoded.append(contentsOf: String(unicodeScalar).utf8)
            default:
                throw ParseFailure.invalidJSON
            }
        }

        mutating func parseHexCodeUnit() throws -> UInt16 {
            var result: UInt16 = 0
            for _ in 0..<4 {
                guard let byte = peek(), let digit = Self.hexDigit(byte) else {
                    throw ParseFailure.invalidJSON
                }
                offset += 1
                result = (result << 4) | UInt16(digit)
            }
            return result
        }

        mutating func parseNumber() throws -> String {
            let start = offset
            _ = consumeIfPresent(0x2D)
            guard let first = peek() else {
                throw ParseFailure.invalidJSON
            }
            if first == 0x30 {
                offset += 1
                if let following = peek(), (0x30...0x39).contains(following) {
                    throw ParseFailure.invalidJSON
                }
            } else if (0x31...0x39).contains(first) {
                repeat {
                    offset += 1
                } while peek().map { (0x30...0x39).contains($0) } == true
            } else {
                throw ParseFailure.invalidJSON
            }

            if consumeIfPresent(0x2E) {
                guard peek().map({ (0x30...0x39).contains($0) }) == true else {
                    throw ParseFailure.invalidJSON
                }
                repeat {
                    offset += 1
                } while peek().map { (0x30...0x39).contains($0) } == true
            }
            if peek() == 0x65 || peek() == 0x45 {
                offset += 1
                if peek() == 0x2B || peek() == 0x2D {
                    offset += 1
                }
                guard peek().map({ (0x30...0x39).contains($0) }) == true else {
                    throw ParseFailure.invalidJSON
                }
                repeat {
                    offset += 1
                } while peek().map { (0x30...0x39).contains($0) } == true
            }
            return String(decoding: bytes[start..<offset], as: UTF8.self)
        }

        mutating func consumeLiteral(_ literal: [UInt8]) throws {
            guard bytes[offset...].starts(with: literal) else {
                throw ParseFailure.invalidJSON
            }
            offset += literal.count
        }

        mutating func consume(_ expected: UInt8) throws {
            guard consumeIfPresent(expected) else {
                throw ParseFailure.invalidJSON
            }
        }

        mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
            guard peek() == expected else { return false }
            offset += 1
            return true
        }

        func peek() -> UInt8? {
            guard offset < bytes.count else { return nil }
            return bytes[offset]
        }

        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        static func hexDigit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x41 + 10
            case 0x61...0x66: byte - 0x61 + 10
            default: nil
            }
        }
    }
}
