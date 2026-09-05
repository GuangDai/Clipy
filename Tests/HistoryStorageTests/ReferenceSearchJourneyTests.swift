/// Recipe 5 through real public capture, Exact browse, immutable revision,
/// Details and paste reads. Literal URL bytes remain independent of derived
/// filenames and paths; no URL target is opened or inspected.
import Foundation
import HistoryCore
import HistoryStorage
import Testing

struct ReferenceSearchJourneyTests {
    @Test func fileNameAndDecodedDirectorySearchFollowEffectiveRevisionOnly() async throws {
        let history = try await openHistory()
        let original = Data(
            "file:///archive/%E6%97%A7%20folder/%E4%B8%AD%E6%96%87%20report.txt".utf8
        )
        let captured = try await capture(original, type: "public.file-url", in: history)

        let filename = try await singleResult("中文 report", in: history)
        #expect(filename.item == captured)
        #expect(filename.title == "中文 report.txt")
        #expect(filename.search?.snippet == nil)
        let directory = try await singleResult("旧 folder", in: history)
        #expect(directory.item == captured)
        #expect(directory.title == "中文 report.txt")
        #expect(directory.search?.snippet ==
            "file:///archive/%E6%97%A7%20folder/%E4%B8%AD%E6%96%87%20report.txt\n/archive/旧 folder/中文 report.txt")
        try expectHighlighted("旧 folder", in: directory)
        try await expectBytes(original, effective: original, item: captured, in: history)

        let replacement = Data(
            "file:///archive/%E6%96%B0%20folder/%E6%96%B0%20report.txt".utf8
        )
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: captured.id,
            expected: captured.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: "public.file-url",
                action: .replace(bytes: replacement)
            )]))
        )))
        guard case .committed(let commit) = receipt,
              case .revised(let revised) = commit.outcome else {
            Issue.record("expected a byte-changing file reference revision")
            return
        }
        #expect(revised.id == captured.id)
        #expect(revised.contentVersion != captured.contentVersion)
        for oldQuery in ["中文 report", "旧 folder"] {
            #expect(try await search(oldQuery, in: history).rows.isEmpty)
        }
        let newFilename = try await singleResult("新 report", in: history)
        #expect(newFilename.item == revised)
        #expect(newFilename.title == "新 report.txt")
        #expect(newFilename.search?.snippet == nil)
        let newDirectory = try await singleResult("新 folder", in: history)
        #expect(newDirectory.item == revised)
        #expect(newDirectory.search?.snippet ==
            "file:///archive/%E6%96%B0%20folder/%E6%96%B0%20report.txt\n/archive/新 folder/新 report.txt")
        try expectHighlighted("新 folder", in: newDirectory)
        try await expectBytes(original, effective: replacement, item: revised, in: history)
        let details = try await history.details(for: revised.id)
        #expect(details.revisions.map(\.title) == ["新 report.txt"])
        #expect(details.revisions.map(\.isActive) == [true])
    }

    @Test func genericURLSearchKeepsOriginalAddressSpellingAndBytes() async throws {
        let history = try await openHistory()
        let address = "https://EXAMPLE.invalid/a%20b?q=%E4%B8%AD%20words#part%2fend"
        let original = Data(address.utf8)
        let captured = try await capture(original, type: "public.url", in: history)
        let row = try await singleResult(address, in: history)
        #expect(row.item == captured)
        #expect(Data(row.title.utf8) == original)
        #expect(row.search?.snippet == nil)
        try expectHighlighted(address, in: row)
        let decodedPath = try await singleResult("a b", in: history)
        #expect(decodedPath.item == captured)
        #expect(Data(decodedPath.title.utf8) == original)
        #expect(decodedPath.search?.snippet ==
            "https://EXAMPLE.invalid/a%20b?q=%E4%B8%AD%20words#part%2fend\n/a b")
        try expectHighlighted("a b", in: decodedPath)
        try await expectBytes(original, effective: original, item: captured, in: history)
    }

    @Test(arguments: ["public.url.private", "public.file-url.private"])
    func lookalikeTypesKeepOpaqueBytesWithoutReferenceSearch(_ type: String) async throws {
        let history = try await openHistory()
        let original = Data(
            "file:///archive/%E6%97%A7%20folder/%E4%B8%AD%E6%96%87%20report.txt".utf8
        )
        let captured = try await capture(original, type: type, in: history)
        for query in ["中文 report", "旧 folder", "%E4%B8%AD%E6%96%87", "archive"] {
            #expect(try await search(query, in: history).rows.isEmpty)
        }
        let recent = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(recent.rows.map(\.item) == [captured])
        #expect(recent.rows.first?.title != "中文 report.txt")
        try await expectBytes(original, effective: original, item: captured, in: history)
    }

    private func openHistory() async throws -> SwiftDataHistory {
        try await SwiftDataHistory.open(configuration: HistoryConfiguration(persistence: .memory))
    }

    private func capture(
        _ bytes: Data, type: String, in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: type, bytes: bytes)],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 1)
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let item) = commit.outcome else {
            Issue.record("expected one reference fixture insertion")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }

    private func search(_ query: String, in history: SwiftDataHistory) async throws -> HistoryPage {
        try await history.browse(HistoryBrowseRequest(
            kind: .search(text: query, mode: .exact), limit: 10
        ))
    }

    private func singleResult(_ query: String, in history: SwiftDataHistory) async throws -> HistoryRow {
        let page = try await search(query, in: history)
        try #require(page.rows.count == 1)
        #expect(page.next == nil)
        return try #require(page.rows.first)
    }

    private func expectHighlighted(_ literal: String, in row: HistoryRow) throws {
        let match = try #require(row.search)
        try #require(match.matchedRanges.count == 1)
        let range = try #require(match.matchedRanges.first)
        let displayed = (match.snippet ?? row.title) as NSString
        try #require(range.location >= 0 && range.location + range.length <= displayed.length)
        let highlighted = displayed.substring(with: NSRange(location: range.location, length: range.length))
        #expect(Data(highlighted.utf8) == Data(literal.utf8))
    }

    private func expectBytes(
        _ canonical: Data, effective: Data, item: HistoryItemReference, in history: SwiftDataHistory
    ) async throws {
        let details = try await history.details(for: item.id)
        #expect(details.item == item)
        #expect(details.canonical.map(\.bytes) == [canonical])
        #expect(details.effective.map(\.bytes) == [effective])
        let paste = try await history.pastePayload(for: item.id)
        #expect(paste.item == item)
        #expect(paste.representations.map(\.bytes) == [effective])
        #expect(paste.representations.map(\.typeIdentifier) == details.effective.map(\.typeIdentifier))
    }
}
