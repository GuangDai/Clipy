/// App-owned storage location and read-only Maintenance intents.
/// Filesystem traversal and Finder remain in the composition root.
public struct StorageLocationSettings: Sendable {
    public let directoryPath: String
    private let readAllocatedBytes: @Sendable () async throws -> Int
    private let revealAction: @MainActor @Sendable () -> Void

    public init(
        directoryPath: String,
        allocatedBytes: @escaping @Sendable () async throws -> Int,
        reveal: @escaping @MainActor @Sendable () -> Void
    ) {
        self.directoryPath = directoryPath
        readAllocatedBytes = allocatedBytes
        revealAction = reveal
    }

    package func allocatedBytes() async throws -> Int {
        try await readAllocatedBytes()
    }

    @MainActor package func reveal() {
        revealAction()
    }
}
