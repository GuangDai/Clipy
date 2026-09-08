#if DEBUG
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct SQLiteSearchIndexTests {
    @Test(arguments: [SearchMode.exact, .fuzzy])
    func UnicodeCandidatesPreserveTheUnindexedMatcher(mode: SearchMode) async throws {
        let samples = [
            "Straße", "STRASSE", "İstanbul", "istanbul", "ı", "I", "ΟΣ", "οσ", "ος",
            "Kelvin", "kelvin", "e\u{301}", "é", "中文", "中", "😀", "👩‍💻", "ﬃ", "FFI",
            "ＡＢＣ", "abc", "\0", "a\r\nb", "\u{301}", "a\u{315}\u{300}b", "a\u{300}\u{315}b",
            "각", "각", "a b", "١٢٣", "𝔄𝔅𝔠", "a\u{FE0F}b", "a\u{200D}b",
        ]
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        for (index, sample) in samples.enumerated() {
            let body = "\(index)\n" + sample
            _ = try await capture(body, in: history, date: Double(index))
        }
        let recent = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 500))
        let bodies = try await history.authority.withTestDatabase { authority in
            let statement = try authority.database.prepare("SELECT id, searchBodyUTF8 FROM history_items")
            defer { statement.finalize() }
            var result: [HistoryItemID: String] = [:]
            while try statement.step() {
                let uuid = try #require(UUID(uuidString: statement.text(at: 0)))
                result[HistoryItemID(rawValue: uuid)] = try ContentProjector.decodeStoredSearchBody(
                    statement.blob(at: 1), limits: .standard
                )
            }
            return result
        }
        let rows = try recent.rows.map { row in
            let body = try #require(bodies[row.item.id])
            return SearchCorpusRow(
                id: row.item.id, contentVersion: row.item.contentVersion, title: row.title, searchBody: body,
                debugTitleUTF8Bytes: row.title.utf8.count, debugSearchBodyUTF8Bytes: body.utf8.count,
                typeIdentifiers: row.typeIdentifiers, lastCopiedAt: row.lastCopiedAt, copyCount: row.copyCount,
                lastSource: row.lastSource, pinOrdinal: nil
            )
        }
        let worker = SearchWorker()
        let corpus = SearchCorpusSnapshot(
            position: recent.position, rows: rows,
            debugTrace: SearchDebugTrace(id: UUID(), startedAt: ContinuousClock().now)
        )
        for query in samples + ["no-such-term", "ss", "σ", "\u{315}", "\u{301}z"] {
            let request = HistoryBrowseRequest(kind: .search(text: query, mode: mode), limit: 500)
            let oracle = try await worker.page(request, in: corpus, continuationAnchor: nil, processMarker: UUID())
            let indexed = try await history.browse(request)
            #expect(indexed.rows == oracle.rows, "candidate filtering lost or changed a Unicode result for \(query)")
        }
    }

    @Test func revisionRollbackAndDeletionKeepPostingsAtomic() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let original = try await capture("original dragonfruit", in: history, date: 1)
        await history.authority.setTransactionFailureInjection(.beforeSingletonUpdate)
        await #expect(throws: HistoryFailure.self) { _ = try await revise(original, to: "replacement kumquat", in: history) }
        #expect(try await search("dragonfruit", in: history).rows.map(\.item) == [original])
        #expect(try await search("kumquat", in: history).rows.isEmpty)
        let updated = try await revise(original, to: "replacement kumquat", in: history)
        #expect(try await search("dragonfruit", in: history).rows.isEmpty)
        #expect(try await search("kumquat", in: history).rows.map(\.item) == [updated])
        let extra = try await capture("retained dragonfruit", in: history, date: 2)
        _ = try await history.perform(.remove(updated.id))
        #expect(try await search("kumquat", in: history).rows.isEmpty)
        #expect(try await search("dragonfruit", in: history).rows.map(\.item) == [extra])
        _ = try await history.perform(.clear(.all))
        let count = try await history.authority.withTestDatabase { authority in
            let statement = try authority.database.prepare("SELECT count(*) FROM history_search")
            defer { statement.finalize() }
            guard try statement.step() else { throw HistoryFailure.persistence(.invariantViolation) }
            return try statement.integer(at: 0)
        }
        #expect(count == 0)
    }

    @Test func anchoredLiteralRegexpUsesCandidatesWithoutChangingRegexSemantics() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let item = try await capture("perf-item-0-target", in: history, date: 1)
        _ = try await capture("other perf-item-0-target", in: history, date: 2)
        let query = "^perf-item-0-"
        #expect(SQLiteSearchIndex.matchExpression(term: query, mode: .regexp) != nil)
        let page = try await history.browse(HistoryBrowseRequest(kind: .search(text: query, mode: .regexp), limit: 10))
        #expect(page.rows.map(\.item) == [item])
        for unsupported in ["foo|bar", "(?i)foo", "f.o", "foo?", "[foo]", "\\d", "^$"] {
            #expect(SQLiteSearchIndex.matchExpression(term: unsupported, mode: .regexp) == nil)
        }
    }

    @Test func fuzzyScoreFloorCountsMissingCharacterPositionsIncludingMarks() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        _ = try await capture("abcdef", in: history, date: 1)
        let floors = try await history.authority.withTestDatabase { authority in
            try ["abZZ", "ZZZ", "a\u{301}b", "fedcba"].map {
                try SQLiteSearchIndex.lowestPossibleFuzzyScore(term: $0, in: authority.database)
            }
        }
        #expect(floors == [0.5, 1, 0.5, 0])
    }

    @Test func sparseCandidateThresholdUsesANDSubsetsAndActualORUnion() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(
            persistence: .temporary, initialMaximumUnpinnedItems: 5_000
        ))
        _ = try await history.seedPerformanceFixture(rowCount: 4_097) { index in
            let boundary = index < 4_096 ? "bnd" : "lst"
            let half = index < 2_048 ? "lft" : (index < 4_096 ? "rgt" : "")
            return WSSupport.textCapture(
                "record\(index)\nall \(boundary) \(half)",
                observedAt: Date(timeIntervalSinceReferenceDate: Double(index))
            )
        }
        let all = try #require(SQLiteSearchIndex.matchExpression(term: "all", mode: .exact))
        let boundary = try #require(SQLiteSearchIndex.matchExpression(term: "bnd", mode: .exact))
        let left = try #require(SQLiteSearchIndex.matchExpression(term: "lft", mode: .exact))
        let right = try #require(SQLiteSearchIndex.matchExpression(term: "rgt", mode: .exact))
        let last = try #require(SQLiteSearchIndex.matchExpression(term: "lst", mode: .exact))
        let missing = try #require(SQLiteSearchIndex.matchExpression(term: "zzz", mode: .exact))
        let expressions = [
            boundary, all, missing,
            "\(all) AND \(boundary)", "\(all) AND \(all)", "\(all) AND \(missing)",
            "\(left) OR \(right)", "\(boundary) OR \(left)", "\(boundary) OR \(last)",
        ]
        let choices = try await history.authority.withTestDatabase { authority in
            try expressions.map {
                try SQLiteSearchIndex.prefersSparseCandidates(expression: $0, in: authority.database)
            }
        }
        #expect(choices == [true, false, true, true, false, true, true, true, false])
        // A frequent existing scalar costs zero edits; repeated absent query
        // positions each still cost one. Presence does not need its doc count.
        let floor = try await history.authority.withTestDatabase { authority in
            try SQLiteSearchIndex.lowestPossibleFuzzyScore(term: "aZZZZZZZ", in: authority.database)
        }
        #expect(floor == 0.875)
    }

    @Test func individuallyDenseGramsCanHaveAnEmptyOrSparseIntersection() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(
            persistence: .temporary, initialMaximumUnpinnedItems: 9_000
        ))
        _ = try await history.seedPerformanceFixture(rowCount: 8_194) { index in
            WSSupport.textCapture(
                "record\(index)\nall " + (index < 4_097 ? "abc" : "bcd"),
                observedAt: Date(timeIntervalSinceReferenceDate: Double(index))
            )
        }
        let first = try #require(SQLiteSearchIndex.matchExpression(term: "abc", mode: .exact))
        let second = try #require(SQLiteSearchIndex.matchExpression(term: "bcd", mode: .exact))
        let common = try #require(SQLiteSearchIndex.matchExpression(term: "all", mode: .exact))
        let intersection = try #require(SQLiteSearchIndex.matchExpression(term: "abcd", mode: .exact))
        let choices = try await history.authority.withTestDatabase { authority in
            try [first, second, intersection, "\(first) AND \(common)"].map {
                try SQLiteSearchIndex.prefersSparseCandidates(expression: $0, in: authority.database)
            }
        }
        // Each side has 4,097 postings, but none share an item. The control
        // AND really has 4,097 shared items and must retain the dense path.
        #expect(choices == [false, false, true, false])
        #expect(try await search("abcd", in: history).rows.isEmpty)

        let matching = try await capture("abcd", in: history, date: 8_195)
        let sparse = try await history.authority.withTestDatabase { authority in
            try SQLiteSearchIndex.prefersSparseCandidates(expression: intersection, in: authority.database)
        }
        #expect(sparse)
        #expect(try await search("abcd", in: history).rows.map(\.item) == [matching])
    }

    private func capture(_ text: String, in history: SQLiteHistory, date: Double) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: date)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }

    private func revise(_ item: HistoryItemReference, to text: String, in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: item.id, expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data(text.utf8))
            )]))
        )))
        guard case .committed(let commit) = receipt, case .revised(let revised) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return revised
    }

    private func search(_ text: String, in history: SQLiteHistory) async throws -> HistoryPage {
        try await history.browse(HistoryBrowseRequest(kind: .search(text: text, mode: .exact), limit: 100))
    }
}
#endif
