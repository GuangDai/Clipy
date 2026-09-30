import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SQLiteProjectionStringTests {
    @Test(arguments: [
        Data(), Data([0xEF, 0xBB, 0xBF]), Data([0xEF, 0xBB, 0xBF, 0x41]),
        Data([0xEF, 0xBB, 0xBF, 0x42, 0xF0, 0x9F, 0xA6, 0x8A]),
        Data("中🙂".utf8), Data("e\u{301}\r\n中🙂".utf8), Data("\u{FEFF}前\0后🦊e\u{301}\r\n".utf8),
    ])
    func decodedStringsOwnTheirBytesAfterTheStatementIsReusedAndClosed(bytes: Data) throws {
        let database = try SQLiteDatabase(url: nil)
        let statement = try database.prepare("SELECT ?", bindings: [.blob(bytes)])
        defer { statement.finalize() }
        try #require(try statement.step())
        let original = try statement.utf8Blob(at: 0, maximumByteCount: HistoryLimits.standard.maximumStoredSearchBodyUTF8Bytes)
        try statement.reset(bindings: [.blob(Data("replacement".utf8))])
        try #require(try statement.step())
        let replacement = try statement.utf8Blob(at: 0, maximumByteCount: 32)
        #expect(try !statement.step())
        try statement.reset(bindings: [.blob(Data())])
        try #require(try statement.step())
        #expect(try statement.utf8Blob(at: 0, maximumByteCount: 0).isEmpty)
        statement.finalize()
        try database.close()
        #expect(Data(original.utf8) == bytes)
        #expect(replacement == "replacement")
    }

    @Test(arguments: [
        SQLiteValue.text("valid text"), .integer(1), .null,
        .blob(Data([0xFF])), .blob(Data([0xC3])), .blob(Data([0xED, 0xA0, 0x80])),
        .blob(Data([0xEF, 0xBB, 0xBF, 0xFF])), .blob(Data(repeating: 0x61, count: 9)),
    ])
    func directProjectionReadsRejectWrongTypesMalformedUTF8AndExcessBytes(value: SQLiteValue) throws {
        let database = try SQLiteDatabase(url: nil)
        let statement = try database.prepare("SELECT ?", bindings: [value])
        defer { statement.finalize() }
        try #require(try statement.step())
        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try statement.utf8Blob(at: 0, maximumByteCount: 8)
        }
    }

    @Test(arguments: [
        HistoryLimits.standard.maximumStoredTitleUTF8Bytes,
        HistoryLimits.standard.maximumStoredSearchBodyUTF8Bytes,
    ])
    func projectionBoundsAcceptExactBytesAndRejectLargerValues(bound: Int) throws {
        let database = try SQLiteDatabase(url: nil)
        let bytes = Data(repeating: 0x61, count: bound)
        let statement = try database.prepare("SELECT ?", bindings: [.blob(bytes)])
        defer { statement.finalize() }
        try #require(try statement.step())
        let value = try statement.utf8Blob(at: 0, maximumByteCount: bound)
        #expect(Data(value.utf8) == bytes)
        // Both valid and malformed oversize storage fails without truncating
        // or repairing any title/body bytes (V2-09 §4, §11).
        for byte in [UInt8(0x61), 0xFF] {
            try statement.reset(bindings: [.blob(Data(repeating: byte, count: bound + 1))])
            try #require(try statement.step())
            #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
                try statement.utf8Blob(at: 0, maximumByteCount: bound)
            }
        }
    }
}
