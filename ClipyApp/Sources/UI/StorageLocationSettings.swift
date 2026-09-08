import Foundation

/// App-owned storage location, destination choice and Maintenance intents.
/// Filesystem traversal and Finder remain in the composition root.
struct StorageLocationSettings: Sendable {
    let directoryPath: String
    private let readAllocatedBytes: @Sendable () async throws -> Int
    private let readProcessMemory: @Sendable () async throws -> ProcessMemoryUsage
    private let chooseBackupDirectoryAction: @MainActor @Sendable () async -> URL?
    private let revealBackupAction: @MainActor @Sendable (URL) -> Void
    private let revealAction: @MainActor @Sendable () -> Void

    init(
        directoryPath: String,
        allocatedBytes: @escaping @Sendable () async throws -> Int,
        processMemory: @escaping @Sendable () async throws -> ProcessMemoryUsage,
        reveal: @escaping @MainActor @Sendable () -> Void,
        chooseBackupDirectory: @escaping @MainActor @Sendable () async -> URL?,
        revealBackup: @escaping @MainActor @Sendable (URL) -> Void
    ) {
        self.directoryPath = directoryPath
        readAllocatedBytes = allocatedBytes
        readProcessMemory = processMemory
        revealAction = reveal
        chooseBackupDirectoryAction = chooseBackupDirectory
        revealBackupAction = revealBackup
    }

    func allocatedBytes() async throws -> Int {
        try await readAllocatedBytes()
    }

    func processMemory() async throws -> ProcessMemoryUsage {
        try await readProcessMemory()
    }

    @MainActor func chooseBackupDirectory() async -> URL? {
        await chooseBackupDirectoryAction()
    }

    @MainActor func revealBackup(at directory: URL) {
        revealBackupAction(directory)
    }

    @MainActor func reveal() {
        revealAction()
    }
}
