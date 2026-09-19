import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct SQLiteMutationReadBoundsTests {
    @Test(arguments: [
        "UPDATE history_items SET contentVersion=zeroblob(1048576)",
        "UPDATE history_items SET copyCount=zeroblob(1048576)",
        "UPDATE history_items SET firstSource=replace(hex(zeroblob(65536)),'0','a')",
        "UPDATE representations SET inlineBytes=zeroblob(1048576) WHERE ordinal=1",
        "UPDATE representations SET fingerprint=zeroblob(1048576) WHERE ordinal=1",
        "UPDATE representations SET exactType=replace(hex(zeroblob(65536)),'0','a') WHERE ordinal=1",
        "UPDATE representations SET typeKey=replace(hex(zeroblob(65536)),'0','a') WHERE ordinal=1",
        "UPDATE representations SET inlineBytes=NULL,blobID=replace(hex(zeroblob(65536)),'0','a') WHERE ordinal=1",
    ])
    func corruptCandidateFieldsRejectCaptureAndRevisionWithoutCommit(sql: String) async throws {
        let history = try await WSSupport.makeHistory()
        let item = try await capture(in: history)
        let before = try await history.usage()
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("PRAGMA ignore_check_constraints = ON")
            defer { try? authority.database.execute("PRAGMA ignore_check_constraints = OFF") }
            try authority.database.execute(sql)
        }
        // The first format qualifies the candidate. The confirmer must
        // reject corruption in its remaining fields before coalescing.
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.perform(.capture(Self.subsetCapture))
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.perform(.revise(.init(
                itemID: item.id, expected: item.contentVersion, intent: .revert(to: .canonical)
            )))
        }
        #expect(try await history.usage() == before)
    }

    @Test func canonicallyEquivalentButNonNormalizedIndexKeyRejectsCandidate() async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await capture(in: history)
        let before = try await history.usage()
        try await history.authority.withTestDatabase { authority in
            // Swift String equality alone accepts this spelling, but SQLite
            // candidate lookup binds NFC and would miss this stored key.
            try authority.database.execute("UPDATE representations SET typeKey=? WHERE ordinal=1",
                bindings: [.text("com.example.e\u{301}")])
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.perform(.capture(Self.subsetCapture))
        }
        #expect(try await history.usage() == before)
    }

    @Test func cancelledInlineCaptureAndRevisionSkipCorruptPayloads() async throws {
        let history = try await WSSupport.makeHistory()
        let item = try await capture(in: history)
        let before = try await history.usage()
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("PRAGMA ignore_check_constraints = ON")
            defer { try? authority.database.execute("PRAGMA ignore_check_constraints = OFF") }
            try authority.database.execute("UPDATE representations SET inlineBytes=zeroblob(1048576) WHERE ordinal=1")
        }
        let capture = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await history.perform(.capture(Self.subsetCapture))
        }
        await #expect(throws: CancellationError.self) { try await capture.value }
        let revision = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await history.perform(.revise(.init(
                itemID: item.id, expected: item.contentVersion, intent: .revert(to: .canonical)
            )))
        }
        await #expect(throws: CancellationError.self) { try await revision.value }
        let reuse = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await history.authority.reusableRepresentation(
                ContentRepresentation(typeIdentifier: "com.example.é", bytes: Data("extra".utf8)), itemID: item.id
            )
        }
        await #expect(throws: CancellationError.self) { try await reuse.value }
        #expect(try await history.usage() == before)
    }

    @Test func reuseRejectsMalformedInlineLength() async throws {
        let history = try await WSSupport.makeHistory()
        let item = try await capture(in: history)
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("PRAGMA ignore_check_constraints = ON")
            defer { try? authority.database.execute("PRAGMA ignore_check_constraints = OFF") }
            try authority.database.execute("UPDATE representations SET inlineBytes=zeroblob(1048576) WHERE ordinal=1")
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.authority.reusableRepresentation(
                ContentRepresentation(typeIdentifier: "com.example.é", bytes: Data("extra".utf8)), itemID: item.id
            )
        }
    }

    private static var subsetCapture: ClipboardCapture {
        ClipboardCapture(
            representations: [.init(typeIdentifier: "com.example.a", bytes: Data("match".utf8))],
            origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 900_000_001)
        )
    }

    private func capture(in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: Self.subsetCapture.representations + [
                .init(typeIdentifier: "com.example.é", bytes: Data("extra".utf8)),
            ], origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 900_000_000)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }
}
