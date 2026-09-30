import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// Native ICU grammar can hide structural characters inside escapes or keep
/// a group's quantifier adjacent across an inline comment/empty quoted region.
struct RegexpShapeBoundaryTests {
    @Test(arguments: [
        "(?dx)(a+) +", "(?ux)(a+) +",
        "(a+)(?#ignored)+", "(a|aa)(?#ignored)+", "(a+)(?#one)(?#two)+",
        #"(a+)\Q\E+"#, #"(?i\Q\Ex)(a+) +"#, #"(\Q\E?x)(a+) +"#,
        #"(?#\Q)[\E)(a+)+"#, #"(?#\c)[)(a+)+"#,
        #"(a+\c))+"#, #"(\c[a+)+"#,
    ])
    func nativeValidUnsafeShapesAreRejectedBeforeStoredReads(pattern: String) async throws {
        // Compile only: no adversarial native matching runs in this fixture.
        // The guard must reject valid unsafe expressions as well as syntax errors.
        _ = try NSRegularExpression(pattern: pattern)
        let history = try await WSSupport.makeHistory()
        _ = try await history.perform(.capture(WSSupport.textCapture(
            "stored row", observedAt: Date(timeIntervalSinceReferenceDate: 1)
        )))
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE history_items SET titleUTF8 = ?",
                                           bindings: [.blob(Data([0xFF]))])
        }
        await #expect(throws: HistoryFailure.invalidInput(.invalidRegularExpression)) {
            try await history.browse(.init(kind: .search(text: pattern, mode: .regexp), limit: 7))
        }
    }

    @Test(arguments: [
        (#"(\x{61})+"#, "aaa"), (#"(\c[)+"#, "\u{001B}\u{001B}"), (#"([]+])+"#, "]+]"),
        (#"(?d-x)(a)+"#, "aaa"), (#"(?u-x)(a)+"#, "aaa"),
        (#"(a)(?#ignored)+"#, "aaa"), (#"(a)\Q\E+"#, "aaa"),
        (#"\Q(a+)+\E"#, "(a+)+"),
        (#"(?#\Q)[\E)(a)+"#, "aaa"), (#"(?#\c)[)(a)+"#, "aaa"),
        (#"(a)(?#\)+"#, "aaa"),
    ])
    func literalEscapesAndSafeCommentQuantifiersStillMatch(pattern: String, text: String) async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await history.perform(.capture(WSSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: 1)
        )))
        let result = try await history.browse(.init(kind: .search(text: pattern, mode: .regexp), limit: 7))
        #expect(result.rows.map(\.title) == [text])
    }
}
