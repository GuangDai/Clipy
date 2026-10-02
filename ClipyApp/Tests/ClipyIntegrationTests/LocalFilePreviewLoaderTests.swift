import Darwin
import Foundation
import HistoryCore
import Testing
@testable import ClipyApp

struct LocalFilePreviewLoaderTests {
    @Test(arguments: [
        ("file:///not-opened/file.txt", true),
        ("file:///not-opened/image.PNG", true),
        ("file:///not-opened/document.pdf", false),
        ("file:///not-opened/file.unknown", false),
        ("https://example.com/image.png", false),
        ("file://remote/image.png", false),
        ("file:///not-opened/image%00.png", false),
    ])
    func previewAvailabilityUsesAddressAndSupportedSuffixOnly(address: String, expected: Bool) {
        #expect(LocalFilePreviewLoader.canPreview(address: address) == expected)
    }

    @Test(arguments: [
        ("txt", "public.utf8-plain-text"), ("PNG", "public.png"),
        ("jpg", "public.jpeg"), ("tiff", "public.tiff"),
        ("heic", "public.heic"), ("heif", "public.heif"),
        ("gif", "com.compuserve.gif"), ("bmp", "com.microsoft.bmp"),
        ("rtf", "public.rtf"),
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
        await #expect(throws: FilePreviewFailure.unsupported) {
            try await loader.load(directory.appendingPathComponent("unread.pdf").absoluteString)
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

    @Test(arguments: ["rtf", "html", "htm"])
    func oversizedRichTextSparseFileIsRejectedBeforeAnyChunkRead(suffix: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.\(suffix)")
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1_048_577)
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

    @Test(arguments: [
        ("rtf", "public.rtf"), ("html", "public.html"), ("htm", "public.html"),
    ])
    func richTextFilesAtTheRendererLimitReturnExactBytes(suffix: String, type: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("preview.\(suffix)")
        let bytes = Data(repeating: 0x41, count: 1_048_576)
        try bytes.write(to: file)
        let result = try await LocalFilePreviewLoader().load(file.absoluteString)
        #expect(result.typeIdentifier == type)
        #expect(result.bytes == bytes)
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

    @Test(arguments: [false, true])
    func anotherFileWaitsWithoutReadingAndQueuedCancellationFinishesPromptly(cancelQueued: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstFile = directory.appendingPathComponent("first.txt")
        let secondFile = directory.appendingPathComponent("second.txt")
        let firstBytes = Data(repeating: 0x41, count: 128 * 1_024)
        let secondBytes = Data(repeating: 0x42, count: 128 * 1_024)
        try firstBytes.write(to: firstFile)
        try secondBytes.write(to: secondFile)
        let loader = LocalFilePreviewLoader()
        let firstProbe = FilePreviewReadProbe(parkFirst: true)
        let secondProbe = FilePreviewReadProbe()
        let first = Task {
            try await LocalFilePreviewDebugInstrumentation.$didReadChunk.withValue({ count in
                await firstProbe.record(count)
            }) { try await loader.load(firstFile.absoluteString) }
        }
        let didRead = await waitUntil { !(await firstProbe.chunkCounts).isEmpty }
        if !didRead {
            first.cancel()
            await firstProbe.resume()
            _ = await first.result
            try #require(didRead)
            return
        }
        let second = Task {
            do {
                let result = try await LocalFilePreviewDebugInstrumentation.$didReadChunk.withValue({ count in
                    await secondProbe.record(count)
                }) { try await loader.load(secondFile.absoluteString) }
                await secondProbe.markFinished()
                return result
            } catch {
                await secondProbe.markFinished()
                throw error
            }
        }
        let didQueue = await waitUntil { await loader.debugQueuedReadCount == 1 }
        #expect(await secondProbe.chunkCounts.isEmpty)
        var cancelledBeforeFirstFinished = false
        if cancelQueued || !didQueue {
            second.cancel()
            cancelledBeforeFirstFinished = await waitUntil { await secondProbe.didFinish }
        }
        await firstProbe.resume()
        let firstResult = await first.result
        let secondResult = await second.result
        try #require(didQueue)
        #expect(try firstResult.get().bytes == firstBytes)
        if cancelQueued {
            #expect(throws: CancellationError.self) { try secondResult.get() }
            #expect(cancelledBeforeFirstFinished)
            #expect(await secondProbe.chunkCounts.isEmpty)
        } else {
            #expect(try secondResult.get().bytes == secondBytes)
        }
        #expect(await loader.debugQueuedReadCount == 0)
        #expect(try await loader.load(secondFile.absoluteString).bytes == secondBytes)
    }

    @Test func cancellingTheActiveReadPassesItsSlotToTheNextFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queued.txt")
        let bytes = Data(repeating: 0x41, count: 128 * 1_024)
        try bytes.write(to: file)
        let loader = LocalFilePreviewLoader()
        let probe = FilePreviewReadProbe(parkFirst: true)
        let first = Task {
            try await LocalFilePreviewDebugInstrumentation.$didReadChunk.withValue({ count in
                await probe.record(count)
            }) { try await loader.load(file.absoluteString) }
        }
        let didRead = await waitUntil { !(await probe.chunkCounts).isEmpty }
        if !didRead {
            first.cancel()
            await probe.resume()
            _ = await first.result
            try #require(didRead)
            return
        }
        let next = Task { try await loader.load(file.absoluteString) }
        let didQueue = await waitUntil { await loader.debugQueuedReadCount == 1 }
        first.cancel()
        if !didQueue { next.cancel() }
        await probe.resume()
        await #expect(throws: CancellationError.self) { try await first.value }
        let nextResult = await next.result
        try #require(didQueue)
        #expect(try nextResult.get().bytes == bytes)
        #expect(await probe.chunkCounts == [64 * 1_024])
        #expect(await loader.debugQueuedReadCount == 0)
    }

    @Test func manyConfirmedFilesHaveABoundedQueueAndCancelledWaitersPerformNoRead() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("many.txt")
        try Data(repeating: 0x41, count: 128 * 1_024).write(to: file)
        let loader = LocalFilePreviewLoader()
        let activeProbe = FilePreviewReadProbe(parkFirst: true)
        let queuedProbe = FilePreviewReadProbe()
        let first = Task {
            try await LocalFilePreviewDebugInstrumentation.$didReadChunk.withValue({ count in
                await activeProbe.record(count)
            }) { try await loader.load(file.absoluteString) }
        }
        let didRead = await waitUntil { !(await activeProbe.chunkCounts).isEmpty }
        if !didRead {
            first.cancel()
            await activeProbe.resume()
            _ = await first.result
            try #require(didRead)
            return
        }
        let failures = FilePreviewQueueFailureProbe()
        let queued = (0..<80).map { _ in
            Task {
                do {
                    _ = try await LocalFilePreviewDebugInstrumentation.$didReadChunk.withValue({ count in
                        await queuedProbe.record(count)
                    }) { try await loader.load(file.absoluteString) }
                } catch let failure as FilePreviewFailure {
                    if failure == .unavailable { await failures.recordUnavailable() }
                    else { Issue.record(failure) }
                } catch is CancellationError {
                } catch {
                    Issue.record(error)
                }
            }
        }
        let didRejectOverflow = await waitUntil { await failures.unavailableCount > 0 }
        let queuedCount = await loader.debugQueuedReadCount
        #expect(didRejectOverflow)
        #expect(queuedCount > 0 && queuedCount < queued.count)
        #expect(await queuedProbe.chunkCounts.isEmpty)
        for request in queued { request.cancel() }
        let didDrain = await waitUntil { await loader.debugQueuedReadCount == 0 }
        await activeProbe.resume()
        let firstResult = await first.result
        for request in queued { await request.value }
        _ = try firstResult.get()
        #expect(didDrain)
        #expect(await queuedProbe.chunkCounts.isEmpty)
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

    @Test(arguments: ["rtf", "html", "htm"])
    func growingRichTextStopsAtTheRendererLimit(suffix: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("growing.\(suffix)")
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
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(LocalFilePreviewLoader.maximumBytes))
        } catch {
            await probe.resume()
            _ = await request.result
            throw error
        }
        await probe.resume()
        await #expect(throws: FilePreviewFailure.tooLarge) { try await request.value }
        #expect(await probe.chunkCounts.last == 1_048_576)
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

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { return false }
        }
        return await condition()
    }
}

private actor FilePreviewReadProbe {
    private let parkFirst: Bool
    private(set) var chunkCounts: [Int] = []
    private var firstChunkWaiter: CheckedContinuation<Void, Never>?
    private var readContinuation: CheckedContinuation<Void, Never>?
    private(set) var didFinish = false
    private var isReleased = false

    init(parkFirst: Bool = false) { self.parkFirst = parkFirst }

    func markFinished() { didFinish = true }

    func record(_ count: Int) async {
        chunkCounts.append(count)
        guard chunkCounts.count == 1 else { return }
        firstChunkWaiter?.resume()
        firstChunkWaiter = nil
        if parkFirst, !isReleased {
            await withCheckedContinuation { readContinuation = $0 }
        }
    }

    func waitUntilFirstChunk() async {
        guard chunkCounts.isEmpty else { return }
        await withCheckedContinuation { firstChunkWaiter = $0 }
    }

    func resume() {
        isReleased = true
        readContinuation?.resume()
        readContinuation = nil
    }
}

private actor FilePreviewQueueFailureProbe {
    private(set) var unavailableCount = 0

    func recordUnavailable() { unavailableCount += 1 }
}
