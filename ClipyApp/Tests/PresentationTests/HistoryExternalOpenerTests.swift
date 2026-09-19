import Foundation
@testable import HistoryCore
@testable import HistoryStorage
import Testing
@testable import ClipyApp

@MainActor
struct HistoryExternalOpenerTests {
    @Test(arguments: ["file://server/share/file.txt", "https://example.com/file.txt", "file:relative",
                      "file:///tmp/a%00b", "file:///tmp/a?query", "file:///tmp/a#fragment"])
    func rejectsNonlocalOrAmbiguousReferences(_ address: String) {
        #expect(HistoryExternalOpener.localFileURL(Data(address.utf8)) == nil)
    }

    @Test func decodesExactLocalPathWithoutFollowingIt() throws {
        let url = try #require(HistoryExternalOpener.localFileURL(Data("file:///not-present/a%20b.txt".utf8)))
        #expect(url.path == "/not-present/a b.txt")
        #expect(HistoryExternalOpener.localFileURL(Data([0xFF])) == nil)
    }

    @Test func webImageFallsBackToRasterAndFileReferenceWinsOverIcon() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let opener = HistoryExternalOpener(history: history, applicationFor: { _, _ in URL(filePath: "/Applications/Viewer.app") })
        let web = try await capture([
            .init(typeIdentifier: "public.url", bytes: Data("https://example.com/image.png".utf8)),
            .init(typeIdentifier: "public.png", bytes: Data([1, 2, 3]))
        ], in: history)
        let options = try await opener.options(for: web)
        #expect(options.count == 1)
        #expect(options.first?.imageExtension == "png")
        #expect(options.first?.applicationName == "Viewer")
        let file = try await capture([
            .init(typeIdentifier: "public.file-url", bytes: Data("file:///tmp/document.txt".utf8)),
            .init(typeIdentifier: "public.png", bytes: Data([4, 5, 6]))
        ], in: history)
        let fileOptions = try await opener.options(for: file)
        #expect(fileOptions.first?.file?.path == "/tmp/document.txt")
        #expect(fileOptions.first?.imageExtension == nil)
        #expect(try await history.pastePayload(for: web.id).representations.first(where: { $0.typeIdentifier == "public.png" })?.bytes == Data([1, 2, 3]))
        _ = try await history.perform(.remove(web.id))
        let option = try #require(options.first)
        await #expect(throws: HistoryOpenFailure.changed) { try await opener.open(option) }
    }

    @Test func invalidMultiItemReferenceDoesNotHideValidSibling() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture([
            .init(typeIdentifier: "public.file-url", bytes: Data("file://remote/unsafe.txt".utf8), pasteboardItemIndex: 0),
            .init(typeIdentifier: "public.file-url", bytes: Data("file:///tmp/valid.txt".utf8), pasteboardItemIndex: 1)
        ], in: history)
        let opener = HistoryExternalOpener(history: history, applicationFor: { _, _ in URL(filePath: "/Applications/Viewer.app") })
        let options = try await opener.options(for: item)
        #expect(options.count == 1)
        #expect(options.first?.request.pasteboardItemIndex == 1)
        #expect(options.first?.file?.path == "/tmp/valid.txt")
    }

    @Test func unavailableImageApplicationDoesNotHideAnOpenableRepresentation() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture([
            .init(typeIdentifier: "public.png", bytes: Data([1, 2])),
            .init(typeIdentifier: "public.jpeg", bytes: Data([3, 4]))
        ], in: history)
        let metadata = try await history.representationMetadata(for: item)
        let unavailableType = try #require(metadata.first).typeIdentifier
        let supportedType = try #require(metadata.last).typeIdentifier
        var resolvedTypes: [String] = []
        let opener = HistoryExternalOpener(history: history, applicationFor: { _, identifier in
            resolvedTypes.append(identifier)
            return identifier == unavailableType ? nil : URL(filePath: "/Applications/Viewer.app")
        })

        let options = try await opener.options(for: item)

        #expect(resolvedTypes == [unavailableType, supportedType])
        #expect(options.count == 1)
        #expect(options.first?.request.typeIdentifier == supportedType)
        #expect(options.first?.imageExtension == HistoryExternalOpener.imageExtension(for: supportedType))
        #expect(options.first?.applicationName == "Viewer")
    }

    @Test func fileWithoutAnApplicationDoesNotOpenItsIconInstead() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture([
            .init(typeIdentifier: "public.file-url", bytes: Data("file:///tmp/document.unknown".utf8)),
            .init(typeIdentifier: "public.png", bytes: Data([1, 2]))
        ], in: history)
        var resolvedTypes: [String] = []
        let opener = HistoryExternalOpener(history: history, applicationFor: { _, identifier in
            resolvedTypes.append(identifier)
            return identifier == "public.png" ? URL(filePath: "/Applications/Viewer.app") : nil
        })

        await #expect(throws: HistoryOpenFailure.noApplication) { try await opener.options(for: item) }
        #expect(resolvedTypes == ["public.file-url"])
    }

    @Test func revisionInvalidatesPreparedOpenWithoutExportingOldBytes() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture([.init(typeIdentifier: "public.png", bytes: Data([1]))], in: history)
        let opener = HistoryExternalOpener(history: history, applicationFor: { _, _ in URL(filePath: "/Applications/Viewer.app") })
        let options = try await opener.options(for: item)
        _ = try await history.perform(.revise(.init(itemID: item.id, expected: item.contentVersion,
            intent: .replace(.init(decisions: [.init(typeIdentifier: "public.png", action: .replace(bytes: Data([2])))])))))
        let option = try #require(options.first)
        await #expect(throws: HistoryOpenFailure.changed) { try await opener.open(option) }
        #expect(try await history.pastePayload(for: item.id).representations.first?.bytes == Data([2]))
    }

    @Test func localSymlinkIsAcceptedAndMissingFileIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        try Data([1]).write(to: original)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let files = ExternalImageFiles(root: root.appendingPathComponent("exports"))
        #expect(try await files.validateLocalFile(original) == original)
        #expect(try await files.validateLocalFile(link) == link)
        try FileManager.default.removeItem(at: original)
        await #expect(throws: HistoryOpenFailure.unavailable) { try await files.validateLocalFile(link) }
    }

    @Test func tempFilesKeepExactBytesAndEnforceLimitsAcrossSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ExternalImageFiles(root: root, maximumFileBytes: 4, maximumSessionBytes: 6)
        let bytes = Data([0, 255, 12, 1])
        let url = try await first.export(bytes, extension: "png")
        #expect(try Data(contentsOf: url) == bytes)
        #expect(url.pathExtension == "png")
        await #expect(throws: HistoryOpenFailure.temporaryLimit) { try await first.export(Data(repeating: 1, count: 5), extension: "jpg") }
        let next = ExternalImageFiles(root: root, maximumFileBytes: 4, maximumSessionBytes: 6)
        await #expect(throws: HistoryOpenFailure.temporaryLimit) { try await next.export(Data([1, 2, 3]), extension: "jpg") }
        #expect(try Data(contentsOf: url) == bytes, "Capacity failure preserves the external reader's file")
        let later = ExternalImageFiles(root: root, maximumFileBytes: 4, maximumSessionBytes: 6,
            cleanupDate: Date().addingTimeInterval(25 * 60 * 60))
        let fresh = try await later.export(Data([4, 5, 6]), extension: "tiff")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: fresh) == Data([4, 5, 6]))
    }

    @Test func cleanupLeavesOtherFilesAndSymlinkDestinationsUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("user-original.png")
        try Data([7, 8]).write(to: original)
        let link = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let files = ExternalImageFiles(root: root, cleanupDate: Date().addingTimeInterval(25 * 60 * 60))
        _ = try await files.export(Data([1]), extension: "gif")
        #expect(try Data(contentsOf: original) == Data([7, 8]))
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    private func capture(_ representations: [CapturedRepresentation], in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(.init(representations: representations,
            origin: .init(sourceApplication: nil, lineageHint: nil), observedAt: Date())))
        guard case let .committed(commit) = receipt, case let .inserted(item) = commit.outcome else {
            throw HistoryOpenFailure.unavailable
        }
        return item
    }
}
