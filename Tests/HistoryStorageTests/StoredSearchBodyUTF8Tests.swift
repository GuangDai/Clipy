import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct StoredSearchBodyUTF8Tests {
    @Test(arguments: [
        Data(),
        Data([0xEF, 0xBB, 0xBF]),
        Data([0xEF, 0xBB, 0xBF, 0x42, 0xF0, 0x9F, 0xA6, 0x8A]),
        Data("e\u{301}\r\n中🙂".utf8),
    ])
    func strictDecodePreservesEveryStoredByte(bytes: Data) throws {
        let body = try ContentProjector.decodeStoredSearchBody(bytes, limits: .standard)
        // Reading a projection does not strip content FEFF, normalize text,
        // or reinterpret an empty but valid search-body projection.
        #expect(Data(body.utf8) == bytes)
    }

    @Test(arguments: [
        Data([0xFF]), Data([0xC3]), Data([0xED, 0xA0, 0x80]),
        Data([0xEF, 0xBB, 0xBF, 0xFF]),
    ])
    func strictDecodeRejectsMalformedUTF8(bytes: Data) {
        #expect(throws: CodecRejection.invalidStoredSearchBodyUTF8) {
            try ContentProjector.decodeStoredSearchBody(bytes, limits: .standard)
        }
    }

    @Test func byteBoundPrecedesUTF8Decoding() throws {
        let bound = HistoryLimits.standard.maximumStoredSearchBodyUTF8Bytes
        let bytes = Data(repeating: 0x61, count: bound)
        let body = try ContentProjector.decodeStoredSearchBody(bytes, limits: .standard)
        #expect(Data(body.utf8) == bytes)

        // Even malformed input must report its excessive byte size first,
        // without repairing or truncating the stored projection.
        for byte in [UInt8(0x61), 0xFF] {
            #expect(throws: CodecRejection.storedSearchBodyExceedsBound(found: bound + 1, bound: bound)) {
                try ContentProjector.decodeStoredSearchBody(
                    Data(repeating: byte, count: bound + 1), limits: .standard
                )
            }
        }
    }
}
