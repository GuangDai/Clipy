import Foundation

/// The app's manual previews and automatic workflows share one execution slot.
/// A cancelled native OCR request retains that slot until its task really exits.
@MainActor
final class BuiltInAutomationExecutionQueue {
    static let maximumPendingRequests = 32
    static let maximumRetainedBytes = 64 * 1_048_576

    private struct Request {
        let id: UUID
        let bytes: Int
        let operation: @Sendable () async throws -> BuiltInAutomationOutput
        let onStart: @MainActor () -> Void
        let continuation: CheckedContinuation<BuiltInAutomationOutput, any Error>
    }

    private var pending: [Request] = []
    private var active: Request?
    private var computation: Task<BuiltInAutomationOutput, any Error>?
    private var retainedBytes = 0

    func execute(
        retainedBytes bytes: Int,
        onStart: @escaping @MainActor () -> Void = {},
        operation: @escaping @Sendable () async throws -> BuiltInAutomationOutput
    ) async throws -> BuiltInAutomationOutput {
        try Task.checkCancellation()
        guard bytes >= 0, bytes <= Self.maximumRetainedBytes - retainedBytes,
              pending.count < Self.maximumPendingRequests else {
            throw BuiltInAutomationFailure.executionQueueFull
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.append(Request(id: id, bytes: bytes, operation: operation,
                                       onStart: onStart, continuation: continuation))
                retainedBytes += bytes
                startNext()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

#if DEBUG
    var pendingRequestCountForTesting: Int { pending.count }
#endif

    private func cancel(_ id: UUID) {
        if active?.id == id {
            computation?.cancel()
        } else if let index = pending.firstIndex(where: { $0.id == id }) {
            let request = pending.remove(at: index)
            retainedBytes -= request.bytes
            request.continuation.resume(throwing: CancellationError())
        }
    }

    private func startNext() {
        guard active == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        active = request
        request.onStart()
        let operation = request.operation
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let output = try await operation()
            try Task.checkCancellation()
            return output
        }
        computation = worker
        Task { [self] in
            let result = await worker.result
            retainedBytes -= request.bytes
            active = nil
            computation = nil
            request.continuation.resume(with: result)
            startNext()
        }
    }
}
