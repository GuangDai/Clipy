import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SQLiteContentReadBoundsTests {
    @Test func malformedInlineLengthDoesNotPoisonMetadataOrAnotherRepresentation() async throws {
        let history = try await WSSupport.makeHistory()
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [
                .init(typeIdentifier: "com.example.bad", bytes: Data("bad".utf8)),
                .init(typeIdentifier: "com.example.good", bytes: Data("good".utf8)),
            ],
            origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 900_000_000)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        try await history.authority.withTestDatabase { authority in
            // SQLite creates this malformed value without first allocating a
            // matching Swift Data. Its metadata still declares three bytes.
            try authority.database.execute("PRAGMA ignore_check_constraints = ON")
            try authority.database.execute("""
                UPDATE representations SET inlineBytes=zeroblob(1048576)
                WHERE contentID=(SELECT currentContentID FROM history_items WHERE id=?)
                  AND exactType='com.example.bad'
                """, bindings: [.text(item.id.rawValue.uuidString)])
            try authority.database.execute("PRAGMA ignore_check_constraints = OFF")
        }
        let before = try await history.usage()
        let details = try await history.details(for: item.id)
        #expect(details.effective.map(\.byteCount) == [3, 4])
        #expect(try await history.representationMetadata(for: item) == details.effective)
        let good = try await history.representation(.init(
            item: item, basis: .effective, typeIdentifier: "com.example.good"
        ))
        #expect(good.bytes == Data("good".utf8))
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.representation(.init(
                item: item, basis: .effective, typeIdentifier: "com.example.bad"
            ))
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.pastePayload(for: item.id)
        }
        #expect(try await history.usage() == before)
    }

    @Test(arguments: [
        "UPDATE history_items SET titleUTF8=zeroblob(1048576)",
        "UPDATE history_items SET firstSource=replace(hex(zeroblob(65536)),'0','a')",
        "UPDATE history_items SET lastSource=replace(hex(zeroblob(65536)),'0','a')",
        "UPDATE contents SET titleUTF8=zeroblob(1048576)",
        "UPDATE representations SET exactType=replace(hex(zeroblob(65536)),'0','a')",
    ])
    func oversizedMetadataRejectsDetailsWithoutChangingHistory(sql: String) async throws {
        let history = try await WSSupport.makeHistory()
        let item = try await RetainedBytesTestSupport.capture("bounded", in: history)
        let before = try await history.usage()
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute(sql)
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.details(for: item.id)
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.representationMetadata(for: item)
        }
        #expect(try await history.usage() == before)
    }
}
