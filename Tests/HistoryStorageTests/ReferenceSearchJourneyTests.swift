/// Recipe 5 through real public capture, Exact browse, immutable revision,
/// Details and paste reads. Literal URL bytes remain independent of derived
/// filenames and paths; no URL target is opened or inspected.
import Foundation
import HistoryCore
import HistoryStorage
import Testing

struct ReferenceSearchJourneyTests {
    @Test(arguments: [("%EF%BB%BF", "\u{FEFF}"), ("%CC%81", "\u{301}")])
    func leadingFilenameScalarSurvivesSearchAndRevision(
        encodedPrefix: String, prefix: String
    ) async throws {
        let history = try await openHistory()
        let original = Data("file:///\(encodedPrefix)before.txt".utf8)
        let captured = try await capture(original, type: "public.file-url", in: history)
        let originalName = prefix + "before.txt"
        let originalResult = try await singleResult(originalName, in: history)
        #expect(originalResult.item == captured)
        #expect(Data(originalResult.title.utf8) == Data(originalName.utf8))
        #expect(originalResult.search?.snippet == nil)
        try expectHighlighted(originalName, in: originalResult)
        try await expectBytes(original, effective: original, item: captured, in: history)

        let replacement = Data("file:///\(encodedPrefix)after.txt".utf8)
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
            Issue.record("expected a revision preserving the filename's leading scalar")
            return
        }
        #expect(revised.id == captured.id)
        #expect(revised.contentVersion != captured.contentVersion)
        #expect(try await search(originalName, in: history).rows.isEmpty)
        let revisedName = prefix + "after.txt"
        let revisedResult = try await singleResult(revisedName, in: history)
        #expect(revisedResult.item == revised)
        #expect(Data(revisedResult.title.utf8) == Data(revisedName.utf8))
        #expect(revisedResult.search?.snippet == nil)
        try expectHighlighted(revisedName, in: revisedResult)
        try await expectBytes(original, effective: replacement, item: revised, in: history)
        let details = try await history.details(for: revised.id)
        #expect(details.revisions.map { Data($0.title.utf8) } == [Data(revisedName.utf8)])
        #expect(details.revisions.map(\.isActive) == [true])
    }

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

    @Test(arguments: [
        ("public.url", "https://EXAMPLE.invalid/old%20section?q=1", "/old section"),
        ("public.file-url", "file:///offline/old%20section/summary.txt", "/offline/old section/summary.txt"),
    ])
    func labeledReferenceIsSearchableWithoutChangingItsTitleOrBytes(
        type: String, address: String, decodedPath: String
    ) async throws {
        let history = try await openHistory()
        let label = "Cafe\u{301} notes"
        let labelBytes = Data(label.utf8)
        let original = Data(address.utf8)
        let textType = "public.utf8-plain-text"
        let captured = try await capture([
            .init(typeIdentifier: textType, bytes: labelBytes),
            .init(typeIdentifier: type, bytes: original),
        ], in: history)

        let titleHit = try await singleResult(label, in: history)
        #expect(titleHit.item == captured)
        #expect(Data(titleHit.title.utf8) == labelBytes)
        #expect(titleHit.search?.snippet == nil)
        try expectHighlighted(label, in: titleHit)

        let addressHit = try await singleResult(address, in: history)
        #expect(addressHit.item == captured)
        #expect(Data(addressHit.title.utf8) == labelBytes)
        #expect(addressHit.search?.snippet == label + "\n" + address + "\n" + decodedPath)
        try expectHighlighted(address, in: addressHit)
        let pathHit = try await singleResult(decodedPath, in: history)
        #expect(pathHit.item == captured)
        try expectHighlighted(decodedPath, in: pathHit)

        let replacementAddress = address.replacingOccurrences(of: "old", with: "new")
        let replacement = Data(replacementAddress.utf8)
        let receipt = try await history.perform(.revise(.init(
            itemID: captured.id,
            expected: captured.contentVersion,
            intent: .replace(.init(decisions: [
                .init(typeIdentifier: textType, action: .inheritCurrent),
                .init(typeIdentifier: type, action: .replace(bytes: replacement)),
            ]))
        )))
        guard case .committed(let commit) = receipt, case .revised(let revised) = commit.outcome else {
            Issue.record("expected a reference revision")
            return
        }
        #expect(try await search(address, in: history).rows.isEmpty)
        #expect(try await search(decodedPath, in: history).rows.isEmpty)
        let revisedHit = try await singleResult(replacementAddress, in: history)
        #expect(revisedHit.item == revised)
        #expect(Data(revisedHit.title.utf8) == labelBytes)
        try expectHighlighted(replacementAddress, in: revisedHit)

        let canonical = try await history.representation(.init(item: revised, basis: .canonical, typeIdentifier: type))
        #expect(canonical.bytes == original)
        let paste = try await history.pastePayload(for: revised.id)
        #expect(paste.item == revised)
        #expect(paste.representations.count == 2)
        #expect(paste.representations.first { $0.typeIdentifier == textType }?.bytes == labelBytes)
        #expect(paste.representations.first { $0.typeIdentifier == type }?.bytes == replacement)
        #expect(paste.representations.allSatisfy { $0.pasteboardItemIndex == 0 })
    }

    @Test func aReferenceAlreadyPresentAsPlainTextDoesNotRepeatInTheExcerpt() async throws {
        let history = try await openHistory()
        let address = "https://example.invalid/archive/item"
        let plaintext = "Notes\n" + address
        let item = try await capture([
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data(plaintext.utf8)),
            .init(typeIdentifier: "public.url", bytes: Data(address.utf8)),
        ], in: history)

        let hit = try await singleResult("/archive/item", in: history)
        #expect(hit.item == item)
        #expect(hit.title == "Notes")
        #expect(hit.search?.snippet == plaintext)
        try expectHighlighted("/archive/item", in: hit)
    }

    @Test func collectionKeepsLaterReferenceSearchableBesideATextAndImageItem() async throws {
        let history = try await openHistory()
        let label = "Saved screenshot"
        let address = "file:///offline/folder%20for%20notes/summary.txt"
        let addressBytes = Data(address.utf8)
        let item = try await capture([
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data(label.utf8)),
            .init(typeIdentifier: "public.png", bytes: Data([0xFF])),
            .init(typeIdentifier: "public.file-url", bytes: addressBytes, pasteboardItemIndex: 1),
        ], in: history)

        let hit = try await singleResult("folder for notes", in: history)
        #expect(hit.item == item)
        #expect(hit.title == "2 items: " + label)
        try expectHighlighted("folder for notes", in: hit)
        let paste = try await history.pastePayload(for: item.id)
        #expect(paste.representations.map(\.pasteboardItemIndex) == [0, 0, 1])
        #expect(paste.representations.last?.bytes == addressBytes)
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

    private func openHistory() async throws -> SQLiteHistory {
        try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
    }

    private func capture(
        _ bytes: Data, type: String, in history: SQLiteHistory
    ) async throws -> HistoryItemReference {
        try await capture([.init(typeIdentifier: type, bytes: bytes)], in: history)
    }

    private func capture(
        _ representations: [CapturedRepresentation], in history: SQLiteHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: representations,
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

    private func search(_ query: String, in history: SQLiteHistory) async throws -> HistoryPage {
        try await history.browse(HistoryBrowseRequest(
            kind: .search(text: query, mode: .exact), limit: 10
        ))
    }

    private func singleResult(_ query: String, in history: SQLiteHistory) async throws -> HistoryRow {
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
        _ canonical: Data, effective: Data, item: HistoryItemReference, in history: SQLiteHistory
    ) async throws {
        let details = try await history.details(for: item.id)
        #expect(details.item == item)
        #expect(details.canonical.map(\.byteCount) == [canonical.count])
        #expect(details.effective.map(\.byteCount) == [effective.count])
        #expect(details.effectiveMatchesCanonical == (canonical == effective))
        let canonicalType = try #require(details.canonical.first?.typeIdentifier)
        let effectiveType = try #require(details.effective.first?.typeIdentifier)
        let canonicalValue = try await history.representation(.init(
            item: item, basis: .canonical, typeIdentifier: canonicalType
        ))
        let effectiveValue = try await history.representation(.init(
            item: item, basis: .effective, typeIdentifier: effectiveType
        ))
        #expect(canonicalValue.bytes == canonical)
        #expect(effectiveValue.bytes == effective)
        let paste = try await history.pastePayload(for: item.id)
        #expect(paste.item == item)
        #expect(paste.representations.map(\.bytes) == [effective])
        #expect(paste.representations.map(\.typeIdentifier) == details.effective.map(\.typeIdentifier))
    }
}
