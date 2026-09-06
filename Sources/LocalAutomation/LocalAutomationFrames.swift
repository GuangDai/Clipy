import ClipyCLIContract
import Foundation

/// One request and one response per private stream. The public interface is
/// JSON stdin/stdout; these framing bytes are not a second external SDK.
package enum LocalAutomationFrames {
    package static let credentialByteCount = 48
    package static let requestHeaderBytes = 8 + credentialByteCount
    private static let magic: UInt32 = 0x434C5031 // CLP1

    package static func requestHeader(credential: Data, jsonCount: Int) -> Data {
        var header = encode([magic, UInt32(jsonCount)])
        header.append(credential)
        return header
    }

    package static func decodeRequestHeader(_ header: Data) throws -> (credential: Data, count: Int) {
        guard header.count == requestHeaderBytes,
              integer(header, at: 0) == magic else {
            throw LocalAutomationSocket.Failure.invalidFrame
        }
        let count = Int(integer(header, at: 4))
        guard count <= ClipyCLIContract.maximumRequestBytes else {
            throw LocalAutomationSocket.Failure.invalidFrame
        }
        return (Data(header.suffix(credentialByteCount)), count)
    }

    package static func responseHeader(_ output: LocalAutomationOutput) -> Data {
        encode([UInt32(output.exitCode), UInt32(output.stdout.count), UInt32(output.stderr.count)])
    }

    package static func decodeResponseHeader(_ header: Data) throws -> (exitCode: Int32, stdout: Int, stderr: Int) {
        guard header.count == 12 else { throw LocalAutomationSocket.Failure.invalidFrame }
        let exit = integer(header, at: 0)
        let stdout = Int(integer(header, at: 4))
        let stderr = Int(integer(header, at: 8))
        guard [0, 2, 3, 4, 5, 6].contains(exit),
              stdout <= ClipyCLIContract.maximumResponseBytes, stderr <= 128 else {
            throw LocalAutomationSocket.Failure.invalidFrame
        }
        return (Int32(exit), stdout, stderr)
    }

    private static func encode(_ values: [UInt32]) -> Data {
        var bytes = Data()
        for value in values {
            bytes.append(UInt8(truncatingIfNeeded: value >> 24))
            bytes.append(UInt8(truncatingIfNeeded: value >> 16))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
            bytes.append(UInt8(truncatingIfNeeded: value))
        }
        return bytes
    }

    private static func integer(_ data: Data, at offset: Int) -> UInt32 {
        let bytes = Array(data.dropFirst(offset).prefix(4))
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }
}
