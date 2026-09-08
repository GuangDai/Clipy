import Foundation
@testable import HistoryCore
@testable import HistoryStorage
import Testing
@testable import ClipyApp

@MainActor
struct HistoryBackupSettingsTests {
    @Test func completedBackupReportsActualCountAndRevealsOnlyTheCompletedDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("My Backup", isDirectory: true)
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let content = Data("saved clipboard".utf8)
        let capture = try await history.perform(.capture(ClipboardCapture(
            representations: [.init(typeIdentifier: "public.utf8-plain-text", bytes: content)],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 100)
        )))
        guard case .committed(let commit) = capture,
              case .inserted(let item) = commit.outcome else {
            Issue.record("Expected captured item")
            return
        }
        var revealed: [URL] = []
        let location = location(choose: { destination }, reveal: { revealed.append($0) })
        let model = HistoryBackupSettingsModel()
        model.reveal(using: location)
        #expect(revealed.isEmpty)

        await model.backUp(history: history, location: location)
        #expect(!model.isWorking)
        #expect(model.outcome == .completed(itemCount: 1))
        #expect(model.completedDirectory == destination)
        model.reveal(using: location)
        #expect(revealed == [destination])
        let saved = try await SQLiteHistory.open(configuration: .init(
            persistence: .persistent(storeURL: destination.appendingPathComponent("history.sqlite"))
        ))
        #expect(try await saved.pastePayload(for: item.id).representations.map(\.bytes) == [content])

        // A second request must not reuse a success message or silently
        // replace a previous backup. The original remains readable.
        await model.backUp(history: history, location: location)
        #expect(model.outcome == .failed(.destinationAlreadyExists))
        #expect(model.completedDirectory == nil)
        model.reveal(using: location)
        #expect(revealed == [destination])
        #expect(try await saved.pastePayload(for: item.id).representations.map(\.bytes) == [content])
    }

    @Test func pickerCancellationDoesNotCreateABackupAndTheNextRequestCanSucceed() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        var selections = 0
        let location = location(choose: {
            selections += 1
            return selections == 1 ? nil : destination
        })
        let model = HistoryBackupSettingsModel()
        await model.backUp(history: history, location: location)
        #expect(model.outcome == .cancelled)
        #expect(!model.isWorking)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        await model.backUp(history: history, location: location)
        #expect(model.outcome == .completed(itemCount: 0))
        #expect(selections == 2)
    }

    @Test func cancellationDuringDestinationChoicePreventsCopyAndOverlappingRequests() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let picker = PendingBackupDestination()
        var selections = 0
        let location = location(choose: {
            selections += 1
            return await picker.choose()
        })
        let model = HistoryBackupSettingsModel()
        let first = Task { await model.backUp(history: history, location: location) }
        await picker.waitUntilEntered()
        #expect(model.isWorking)
        await model.backUp(history: history, location: location)
        #expect(selections == 1)
        first.cancel()
        picker.finish(destination)
        await first.value
        #expect(!model.isWorking)
        #expect(model.outcome == .cancelled)
        #expect(model.completedDirectory == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    private func location(
        choose: @escaping @MainActor @Sendable () async -> URL?,
        reveal: @escaping @MainActor @Sendable (URL) -> Void = { _ in }
    ) -> StorageLocationSettings {
        StorageLocationSettings(
            directoryPath: "/unused",
            allocatedBytes: { 0 },
            processMemory: { .init(residentBytes: 0, peakResidentBytes: 0, footprintBytes: 0) },
            reveal: {},
            chooseBackupDirectory: choose,
            revealBackup: reveal
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-backup-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
private final class PendingBackupDestination {
    private var response: CheckedContinuation<URL?, Never>?
    private var entered: CheckedContinuation<Void, Never>?

    func choose() async -> URL? {
        await withCheckedContinuation { continuation in
            response = continuation
            entered?.resume()
            entered = nil
        }
    }

    func waitUntilEntered() async {
        if response != nil { return }
        await withCheckedContinuation { entered = $0 }
    }

    func finish(_ url: URL) {
        response?.resume(returning: url)
        response = nil
    }
}
