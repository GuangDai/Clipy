#if CLIPY_UDS_F0
import Darwin
import Foundation

/// The deliberately tiny wire contract shared by the signed F0 discriminator
/// app and its diagnostic client. This is a runtime-evidence protocol only: it
/// carries no History, Gateway, credential, or X.8 JSON value.
enum UnixSocketF0Protocol {
    static let endpointEnvironmentKey = "CLIPY_UDS_F0_ENDPOINT"

    static let version: UInt8 = 1
    static let nonceByteCount = 16
    static let generationByteCount = 16
    static let requestByteCount = 25
    static let replyByteCount = 53
    static let maximumEndpointUTF8ByteCount = 103

    struct Request: Equatable, Sendable {
        let nonce: [UInt8]
    }

    struct Reply: Equatable, Sendable {
        let nonce: [UInt8]
        let generation: [UInt8]
        let effectiveUserID: UInt32
        let effectiveGroupID: UInt32
        let processID: UInt32
    }

    enum FrameError: Error, Equatable {
        case invalidLength
        case invalidMagic
        case unsupportedVersion
        case invalidNonceLength
        case invalidGenerationLength
        case invalidEndpoint
    }

    static func encodeRequest(nonce: [UInt8]) throws -> Data {
        guard nonce.count == nonceByteCount else {
            throw FrameError.invalidNonceLength
        }
        var bytes = requestMagic
        bytes.append(version)
        bytes.append(contentsOf: nonce)
        return Data(bytes)
    }

    static func decodeRequest(_ data: Data) throws -> Request {
        let bytes = [UInt8](data)
        guard bytes.count == requestByteCount else {
            throw FrameError.invalidLength
        }
        guard Array(bytes[0..<requestMagic.count]) == requestMagic else {
            throw FrameError.invalidMagic
        }
        guard bytes[requestMagic.count] == version else {
            throw FrameError.unsupportedVersion
        }
        return Request(nonce: Array(bytes.suffix(nonceByteCount)))
    }

    static func encodeReply(
        nonce: [UInt8],
        generation: [UInt8],
        effectiveUserID: UInt32,
        effectiveGroupID: UInt32,
        processID: UInt32
    ) throws -> Data {
        guard nonce.count == nonceByteCount else {
            throw FrameError.invalidNonceLength
        }
        guard generation.count == generationByteCount else {
            throw FrameError.invalidGenerationLength
        }

        var bytes = replyMagic
        bytes.append(version)
        bytes.append(contentsOf: nonce)
        bytes.append(contentsOf: generation)
        appendBigEndian(effectiveUserID, to: &bytes)
        appendBigEndian(effectiveGroupID, to: &bytes)
        appendBigEndian(processID, to: &bytes)
        return Data(bytes)
    }

    static func decodeReply(_ data: Data) throws -> Reply {
        let bytes = [UInt8](data)
        guard bytes.count == replyByteCount else {
            throw FrameError.invalidLength
        }
        guard Array(bytes[0..<replyMagic.count]) == replyMagic else {
            throw FrameError.invalidMagic
        }
        guard bytes[replyMagic.count] == version else {
            throw FrameError.unsupportedVersion
        }

        let nonceStart = replyMagic.count + 1
        let generationStart = nonceStart + nonceByteCount
        let scalarStart = generationStart + generationByteCount
        return Reply(
            nonce: Array(bytes[nonceStart..<generationStart]),
            generation: Array(bytes[generationStart..<scalarStart]),
            effectiveUserID: decodeUInt32(bytes, at: scalarStart),
            effectiveGroupID: decodeUInt32(bytes, at: scalarStart + 4),
            processID: decodeUInt32(bytes, at: scalarStart + 8)
        )
    }

    /// Supplies a checked Darwin `sockaddr_un` whose storage remains alive for
    /// the duration of `body`. F0 uses pathname sockets only; embedded NUL and
    /// paths that cannot fit with their terminator are rejected.
    static func withSocketAddress<Result>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) throws -> Result {
        let pathBytes = Array(path.utf8)
        guard !pathBytes.isEmpty,
              pathBytes.count <= maximumEndpointUTF8ByteCount,
              !pathBytes.contains(0) else {
            throw FrameError.invalidEndpoint
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            pathPointer.withMemoryRebound(to: UInt8.self, capacity: 104) { bytes in
                for index in pathBytes.indices {
                    bytes[index] = pathBytes[index]
                }
                bytes[pathBytes.count] = 0
            }
        }

        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private static let requestMagic = Array("CLIPYF0Q".utf8)
    private static let replyMagic = Array("CLIPYF0R".utf8)

    private static func appendBigEndian(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    private static func decodeUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}
#endif
