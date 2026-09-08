import Foundation

/// App-owned storage location, destination choice and Maintenance intents.
/// Filesystem traversal and Finder remain in the composition root.
public struct StorageLocationSettings: Sendable {
    public let directoryPath: String
    private let readAllocatedBytes: @Sendable () async throws -> Int
    private let readProcessMemory: @Sendable () async throws -> ProcessMemoryUsage
    private let chooseBackupDirectoryAction: @MainActor @Sendable () async -> URL?
    private let revealBackupAction: @MainActor @Sendable (URL) -> Void
    private let revealAction: @MainActor @Sendable () -> Void

    public init(
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

    package func allocatedBytes() async throws -> Int {
        try await readAllocatedBytes()
    }

    package func processMemory() async throws -> ProcessMemoryUsage {
        try await readProcessMemory()
    }

    @MainActor package func chooseBackupDirectory() async -> URL? {
        await chooseBackupDirectoryAction()
    }

    @MainActor package func revealBackup(at directory: URL) {
        revealBackupAction(directory)
    }

    @MainActor package func reveal() {
        revealAction()
    }
}
