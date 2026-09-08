import Foundation
import HistoryCore
import Observation

/// Maintenance owns one explicit backup request. A completed receipt remains
/// authoritative even if cancellation arrives after the storage operation.
@Observable @MainActor
final class HistoryBackupSettingsModel {
    enum Outcome: Equatable {
        case cancelled
        case completed(itemCount: Int)
        case failed(HistoryBackupFailure)
        case sourceFailed
    }

    private(set) var isWorking = false
    private(set) var outcome: Outcome?
    private(set) var completedDirectory: URL?

    func backUp(history: any ClipboardHistory, location: StorageLocationSettings) async {
        guard !isWorking, !Task.isCancelled else { return }
        isWorking = true
        outcome = nil
        completedDirectory = nil
        defer { isWorking = false }
        do {
            guard let directory = await location.chooseBackupDirectory() else {
                outcome = .cancelled
                return
            }
            try Task.checkCancellation()
            let receipt = try await history.backup(to: directory)
            completedDirectory = directory
            outcome = .completed(itemCount: receipt.retainedItemCount)
        } catch is CancellationError {
            outcome = .cancelled
        } catch let failure as HistoryBackupFailure {
            outcome = .failed(failure)
        } catch {
            outcome = .sourceFailed
        }
    }

    func reveal(using location: StorageLocationSettings) {
        guard let completedDirectory else { return }
        location.revealBackup(at: completedDirectory)
    }
}
