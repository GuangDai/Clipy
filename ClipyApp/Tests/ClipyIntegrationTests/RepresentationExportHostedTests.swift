import AppKit
import Foundation
import HistoryCore
import PresentationUI
import Testing
@testable import ClipyApp

struct RepresentationExportHostedTests {
    @Test @MainActor
    func cancellingPendingExportDismissesItsRealSaveSheet() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let receipt = try await history.perform(.capture(ComposedSupport.textCapture(
            "cancelled export", observedAt: Date(timeIntervalSince1970: 0)
        )))
        let item = try #require(ComposedSupport.insertedReference(from: receipt, "export arrange"))
        let payload = try await history.pastePayload(for: item.id)
        let representation = try #require(payload.representations.first)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let request = Task { await RepresentationExporter.saveAs(representation, for: window) }
        defer {
            request.cancel()
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
            window.close()
        }
        try #require(await ComposedSupport.waitFor(timeout: 5) { window.attachedSheet is NSSavePanel })
        request.cancel()
        try await request.value.get()
        #expect(window.attachedSheet == nil)
        #expect(try await history.pastePayload(for: item.id).representations == payload.representations)
    }

    @Test func cancellationBeforeWritingPreservesTheExistingChosenFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("chosen-export.bin")
        let previous = Data("previous file".utf8)
        try previous.write(to: target)
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return RepresentationExporter.write(Data("must not write".utf8), to: target)
        }
        try await request.value.get()
        #expect(try Data(contentsOf: target) == previous)
    }

    @Test(arguments: [Data(), Data([0x00, 0xFF, 0x10]), Data([0xFE, 0xFF, 0x00, 0x41])])
    func chosenFileReceivesExactBytesIncludingEmptyAndOpaqueValues(bytes: Data) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("chosen-export.bin")
        // Replacement is exercised too: accepting overwrite must replace the
        // complete old file, including when the new representation is empty.
        try Data("previous longer file".utf8).write(to: target)
        try RepresentationExporter.write(bytes, to: target).get()
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test func aDirectoryDestinationReturnsTypedFailureWithoutChangingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("retained.txt")
        try Data("keep".utf8).write(to: existing)
        switch RepresentationExporter.write(Data("export".utf8), to: directory) {
        case .success:
            Issue.record("A directory is not a writable file destination")
        case .failure(let failure):
            #expect(failure == .writeFailed)
        }
        #expect(try Data(contentsOf: existing) == Data("keep".utf8))
    }

    @Test @MainActor
    func suggestedNamesUseKnownExtensionsAndOpaqueFallback() {
        #expect(RepresentationExporter.suggestedFileName(for: "public.png").hasSuffix(".png"))
        #expect(RepresentationExporter.suggestedFileName(for: "public.utf8-plain-text").hasSuffix(".txt"))
        #expect(RepresentationExporter.suggestedFileName(for: "com.example.unknown").hasSuffix(".bin"))
    }
}
