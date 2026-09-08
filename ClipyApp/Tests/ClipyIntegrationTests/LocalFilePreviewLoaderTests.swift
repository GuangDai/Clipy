import Darwin
import Foundation
import HistoryCore
import Testing
@testable import ClipyApp

struct LocalFilePreviewLoaderTests {
    @Test(arguments: [
        ("txt", "public.utf8-plain-text"), ("PNG", "public.png"),
        ("jpg", "public.jpeg"), ("tiff", "public.tiff"),
        ("heic", "public.heic"), ("heif", "public.heif"),
        ("gif", "com.compuserve.gif"), ("bmp", "com.microsoft.bmp"),
        ("pdf", "com.adobe.pdf"), ("rtf", "public.rtf"),
        ("html", "public.html"),
    ])
    func supportedLocalFilesReturnExactBytes(suffix: String, type: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("preview.\(suffix)")
        let bytes = Data("literal bytes \u{0} stay unchanged".utf8)
        try bytes.write(to: file)
        let result = try await LocalFilePreviewLoader().load(file.absoluteString)
        #expect(result.typeIdentifier == type)
        #expect(result.bytes == bytes)
    }

    @Test(arguments: [Data([0xFF, 0xFE, 0x41, 0x00]), Data([0xFE, 0xFF, 0x00, 0x41])])
    func utf16BOMRemainsInTheDeclaredExternalEncoding(_ bytes: Data) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("preview.txt")
        try bytes.write(to: file)
        let result = try await LocalFilePreviewLoader().load(file.absoluteString)
        #expect(result.typeIdentifier == "public.utf16-external-plain-text")
        #expect(result.bytes == bytes)
    }

    @Test(arguments: [
        "https://example.com/file.txt", "file://example.com/file.txt",
        "file:relative.txt", "file:///tmp/item%00.txt", "file:///tmp/item.txt?read=1",
    ])
    func invalidReferencesNeverBecomeLocalReads(_ address: String) async {
        await #expect(throws: FilePreviewFailure.invalidReference) {
            try await LocalFilePreviewLoader().load(address)
        }
    }

    @Test func missingUnsupportedDirectoryAndSymlinkHaveTypedFailures() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = LocalFilePreviewLoader()
        await #expect(throws: FilePreviewFailure.unavailable) {
            try await loader.load(directory.appendingPathComponent("missing.txt").absoluteString)
        }
        await #expect(throws: FilePreviewFailure.unsupported) {
            try await loader.load(directory.appendingPathComponent("unread.zip").absoluteString)
        }
        let folder = directory.appendingPathComponent("directory.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        await #expect(throws: FilePreviewFailure.unsupported) { try await loader.load(folder.absoluteString) }
        let file = directory.appendingPathComponent("file.txt")
        try Data("target".utf8).write(to: file)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        await #expect(throws: FilePreviewFailure.unsupported) { try await loader.load(link.absoluteString) }
    }

    @Test func unreadableFileProducesPermissionFailure() async throws {
        try #require(geteuid() != 0, "Permission evidence requires the non-root CI account")
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("private.txt")
        try Data("private".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        await #expect(throws: FilePreviewFailure.permissionDenied) {
            try await LocalFilePreviewLoader().load(file.absoluteString)
        }
    }

    @Test func oversizedSparseFileIsRejectedBeforeAnyChunkRead() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.txt")
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(LocalFilePreviewLoader.maximumBytes + 1))
        try handle.close()
        let probe = FilePreviewReadProbe()
        await LocalFilePreviewDebugInstrumentation.$didReadChunk.withValue({ count in
            await probe.record(count)
        }) {
            await #expect(throws: FilePreviewFailure.tooLarge) {
                try await LocalFilePreviewLoader().load(file.absoluteString)
            }
        }
        #expect(await probe.chunkCounts.isEmpty)
    }

    @Test func cancellationBetweenRealChunksStopsTheRead() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cancel.txt")
        try Data(repeating: 0x41, count: 128 * 1_024).write(to: file)
        let probe = FilePreviewReadProbe(parkFirst: true)
        let request = Task {
            try await LocalFilePreviewDebugInstrumentation.$didReadChunk.withValue({ count in
                await probe.record(count)
            }) {
                try await LocalFilePreviewLoader().load(file.absoluteString)
            }
        }
        await probe.waitUntilFirstChunk()
        request.cancel()
        await probe.resume()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await probe.chunkCounts == [64 * 1_024])
    }

    @Test func growingFileStopsAtMaximumPlusOneInsteadOfReadingToEnd() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("growing.txt")
        try Data(repeating: 0x41, count: 64 * 1_024).write(to: file)
        let probe = FilePreviewReadProbe(parkFirst: true)
        let request = Task {
            try await LocalFilePreviewDebugInstrumentation.$didReadChunk.withValue({ count in
                await probe.record(count)
            }) {
                try await LocalFilePreviewLoader().load(file.absoluteString)
            }
        }
        await probe.waitUntilFirstChunk()
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(LocalFilePreviewLoader.maximumBytes * 2))
        try handle.close()
        await probe.resume()
        await #expect(throws: FilePreviewFailure.tooLarge) { try await request.value }
        #expect(await probe.chunkCounts.last == LocalFilePreviewLoader.maximumBytes)
    }

    enum MidReadChange: Sendable { case append, truncate, overwrite }

    @Test(arguments: [MidReadChange.append, .truncate, .overwrite])
    func fileChangedBetweenChunksDoesNotReturnMixedContents(_ change: MidReadChange) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("changing.txt")
        try Data(repeating: 0x41, count: 128 * 1_024).write(to: file)
        let probe = FilePreviewReadProbe(parkFirst: true)
        let request = Task {
            try await LocalFilePreviewDebugInstrumentation.$didReadChunk.withValue({ count in
                await probe.record(count)
            }) {
                try await LocalFilePreviewLoader().load(file.absoluteString)
            }
        }
        await probe.waitUntilFirstChunk()
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            switch change {
            case .append:
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: Data(repeating: 0x42, count: 64 * 1_024))
            case .truncate:
                try handle.truncate(atOffset: 64 * 1_024)
            case .overwrite:
                try handle.write(contentsOf: Data(repeating: 0x42, count: 128 * 1_024))
                // No sleep or filesystem timestamp-resolution assumption:
                // the actual same-length overwrite gets a distinct mtime.
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: file.path
                )
            }
        } catch {
            await probe.resume()
            _ = await request.result
            throw error
        }
        await probe.resume()
        await #expect(throws: FilePreviewFailure.changedDuringRead) { try await request.value }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor FilePreviewReadProbe {
    private let parkFirst: Bool
    private(set) var chunkCounts: [Int] = []
    private var firstChunkWaiter: CheckedContinuation<Void, Never>?
    private var readContinuation: CheckedContinuation<Void, Never>?

    init(parkFirst: Bool = false) { self.parkFirst = parkFirst }

    func record(_ count: Int) async {
        chunkCounts.append(count)
        guard chunkCounts.count == 1 else { return }
        firstChunkWaiter?.resume()
        firstChunkWaiter = nil
        if parkFirst {
            await withCheckedContinuation { readContinuation = $0 }
        }
    }

    func waitUntilFirstChunk() async {
        guard chunkCounts.isEmpty else { return }
        await withCheckedContinuation { firstChunkWaiter = $0 }
    }

    func resume() {
        readContinuation?.resume()
        readContinuation = nil
    }
}
