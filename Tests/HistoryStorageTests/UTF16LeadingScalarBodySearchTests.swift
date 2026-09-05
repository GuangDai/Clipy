/// The complete Exact term exceeds the byte-backed title's limit, so this
/// real History read must use the persisted search body. The UTF-16 wire BOM
/// is separate from a leading U+FEFF that belongs to the copied content.
import Foundation
import HistoryCore
import HistoryStorage
import Testing

struct UTF16LeadingScalarBodySearchTests {
    @Test(arguments: ["public.utf16-plain-text", "public.utf16-external-plain-text"])
    func completeBodyRemainsSearchableBeyondTheTitleLimit(_ identifier: String) async throws {
        let native = identifier == "public.utf16-plain-text"
        // Native LE / external BE: one encoding BOM, then the content's FEFF,
        // followed by exactly 1,200 ASCII A code units. No fixture decoder or
        // Foundation String-to-Data conversion chooses or removes either BOM.
        var wire = native ? Data([0xFF, 0xFE, 0xFF, 0xFE]) : Data([0xFE, 0xFF, 0xFE, 0xFF])
        for _ in 0..<1_200 {
            wire.append(contentsOf: native ? [0x41, 0x00] : [0x00, 0x41])
        }
        #expect(wire.count == 2_404)
        let body = "\u{FEFF}" + String(repeating: "A", count: 1_200)
        #expect(body.utf8.count == 1_203)
        #expect(body.utf8.count <= HistoryLimits.standard.maximumSearchTermUTF8Bytes)

        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: identifier, bytes: wire)],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_092_000)
        )))
        guard case let .committed(commit) = receipt,
              case let .inserted(item) = commit.outcome else {
            Issue.record("expected one UTF-16 item")
            return
        }

        let recent = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(recent.rows.map(\.item) == [item])
        let row = try #require(recent.rows.first)
        let expectedTitle = "\u{FEFF}" + String(repeating: "A", count: 1_021)
        try #require(Data(row.title.utf8) == Data(expectedTitle.utf8),
                     "the title must first establish that decoding kept the content FEFF")
        #expect(row.title.utf8.count == 1_024)
        #expect(row.title.utf8.count <= HistoryLimits.standard.maximumStoredTitleUTF8Bytes)
        #expect(body.utf8.count > row.title.utf8.count)

        let page = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: body, mode: .exact), limit: 10
        ))
        #expect(page.position == recent.position)
        #expect(page.rows.map(\.item) == [item])
        #expect(page.next == nil)
        let hit = try #require(page.rows.first)
        let presentation = try #require(hit.search)
        let snippet = try #require(presentation.snippet,
                                   "a 1,203-byte complete query cannot match the 1,024-byte title")
        // 03b §8: a match longer than the 320-Character content window keeps
        // its first 320 Characters. Here it starts at body offset zero, so
        // only a trailing ellipsis appears; the clipped UTF-16 range is 0–320.
        let expectedSnippet = "\u{FEFF}" + String(repeating: "A", count: 319) + "…"
        #expect(Data(snippet.utf8) == Data(expectedSnippet.utf8))
        #expect(presentation.matchedRanges == [UTF16TextRange(location: 0, length: 320)])

        let details = try await history.details(for: item.id)
        #expect(details.canonical.map(\.bytes) == [wire])
        #expect(details.effective.map(\.bytes) == [wire])
        let payload = try await history.pastePayload(for: item.id)
        #expect(payload.item == item)
        #expect(payload.representations.map(\.typeIdentifier) == [identifier])
        #expect(payload.representations.map(\.bytes) == [wire])
    }
}
