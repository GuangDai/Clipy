import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import ClipyApp

@Suite("Maintenance folder usage")
struct StoreFolderUsageTests {
    @Test("folder size includes hidden and unrelated files without following links")
    func allocatedFilesIncludeHiddenDataButExcludeLinkedTargets() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Store", isDirectory: true)
        let hidden = folder.appendingPathComponent(".hidden", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        for directory in [hidden, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let included = [
            folder.appendingPathComponent("history.store"),
            folder.appendingPathComponent("history.store-wal"),
            hidden.appendingPathComponent("blob"),
            folder.appendingPathComponent("other-data"),
        ]
        for (index, file) in included.enumerated() {
            try Data(repeating: UInt8(index + 1), count: 16_384).write(to: file)
        }
        let externalFile = outside.appendingPathComponent("not-counted")
        try Data(repeating: 7, count: 262_144).write(to: externalFile)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("linked-folder"), withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("linked-file"), withDestinationURL: externalFile
        )
        // The filesystem supplies allocation units; the expected membership
        // is the four exact fixture files, not another directory traversal.
        let expected = try included.reduce(0) { try $0 + allocation(of: $1) }
        let reader = StoreFolderUsage(directoryURL: folder)
        #expect(try await reader.allocatedBytes() == expected)
    }

    @Test("refresh measures current allocation and missing folders are unavailable")
    func refreshDoesNotReuseCachedResourceValues() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reader = StoreFolderUsage(directoryURL: folder)
        #expect(try await reader.allocatedBytes() == 0)
        let file = folder.appendingPathComponent("growing")
        try Data(repeating: 1, count: 4_096).write(to: file)
        let first = try await reader.allocatedBytes()
        #expect(first == (try allocation(of: file)))
        try Data(repeating: 2, count: 262_144).write(to: file)
        let second = try await reader.allocatedBytes()
        #expect(second == (try allocation(of: file)))
        #expect(second > first)
        let missing = StoreFolderUsage(directoryURL: folder.appendingPathComponent("missing"))
        await #expect(throws: (any Error).self) { try await missing.allocatedBytes() }
    }

    @Test("measuring a real open store leaves History content and position unchanged")
    @MainActor
    func realStoreMeasurementIsReadOnly() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = try await SwiftDataHistory.open(configuration: HistoryConfiguration(
            persistence: .persistent(storeURL: folder.appendingPathComponent("history.store"))
        ))
        _ = try await history.perform(.capture(ComposedSupport.textCapture(
            "maintenance-content", observedAt: Date(), source: "com.example.maintenance"
        )))
        let before = try await history.usage()
        let reader = StoreFolderUsage(directoryURL: folder)
        #expect(try await reader.allocatedBytes() > 0)
        #expect(try await history.usage() == before)
        #expect(before.canonicalBytes == 19)
        #expect(before.itemCount == 1)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func allocation(of url: URL) throws -> Int {
        let values = try URL(fileURLWithPath: url.path).resourceValues(
            forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        )
        return try #require(values.totalFileAllocatedSize ?? values.fileAllocatedSize)
    }
}
