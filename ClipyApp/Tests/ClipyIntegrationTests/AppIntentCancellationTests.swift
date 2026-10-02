import AppIntents
import AppKit
import Foundation
import HistoryCore
import Testing
@testable import ClipyApp

@MainActor
struct AppIntentCancellationTests {
    enum Operation: Sendable {
        case search, details, paste, pin, unpin, remove
    }

    @Test(arguments: [Operation.search, .details, .paste, .pin, .unpin, .remove])
    func cancelledInvocationDoesNotEnterTheGateway(operation: Operation) async throws {
        let support = try await AppIntentTestSupport.make(grants: [.browse, .readContent, .manage])
        let before = try await support.history.auditLog(since: 1).filter { $0.operationKind != .adminReadAudit }
        let invocation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            switch operation {
            case .search:
                _ = try await SearchHistoryIntent(query: "intent", mode: .exact, limit: 20,
                    history: support.ingress, dependencyManager: support.manager).perform()
            case .details:
                _ = try await GetItemDetailsIntent(itemID: support.itemID.description,
                    history: support.ingress, dependencyManager: support.manager).perform()
            case .paste:
                _ = try await PasteItemIntent(itemID: support.itemID.description,
                    pasteboardName: "com.clipy.tests.cancelled-intent-\(UUID())",
                    history: support.ingress, dependencyManager: support.manager).perform()
            case .pin:
                _ = try await PinItemIntent(itemID: support.itemID.description,
                    history: support.ingress, dependencyManager: support.manager).perform()
            case .unpin:
                _ = try await UnpinItemIntent(itemID: support.itemID.description,
                    history: support.ingress, dependencyManager: support.manager).perform()
            case .remove:
                _ = try await RemoveItemIntent(itemID: support.itemID.description,
                    history: support.ingress, dependencyManager: support.manager).perform()
            }
        }
        await #expect(throws: CancellationError.self) { try await invocation.value }
        let after = try await support.history.auditLog(since: 1).filter { $0.operationKind != .adminReadAudit }
        #expect(after == before)
        let retained = try await support.history.browse(.init(kind: .recent, limit: 1))
        #expect(retained.rows.first?.item.id == support.itemID)
        #expect(retained.rows.first?.pinnedPosition == nil)
    }

    #if DEBUG
    @Test func cancellationAfterTheGrantedReadPreservesExistingClipboardBytes() async throws {
        let support = try await AppIntentTestSupport.make(grants: [.readContent])
        let name = "com.clipy.tests.intent-read-cancel-\(UUID())"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        pasteboard.clearContents()
        try #require(pasteboard.setString("existing clipboard", forType: .string))
        let originalChangeCount = pasteboard.changeCount
        defer { pasteboard.clearContents() }
        let boundary = IntentPasteReadBoundary()
        let intent = PasteItemIntent(itemID: support.itemID.description, pasteboardName: name,
            history: support.ingress, dependencyManager: support.manager)
        let invocation = ClipboardIntentDebugInstrumentation.$beforePasteboardWrite.withValue({
            await boundary.park()
        }) {
            Task {
                do {
                    _ = try await intent.perform()
                    await boundary.invocationFinished()
                } catch {
                    await boundary.invocationFinished()
                    throw error
                }
            }
        }
        try #require(await boundary.waitUntilParked())
        // The actual payload read and its successful audit have completed;
        // cancellation now retires only the pending clipboard side effect.
        #expect(try await support.lastAuditOperation() == .readPastePayload)
        invocation.cancel()
        await boundary.release()
        await #expect(throws: CancellationError.self) { try await invocation.value }
        #expect(pasteboard.changeCount == originalChangeCount)
        #expect(pasteboard.string(forType: .string) == "existing clipboard")
    }
    #endif
}

#if DEBUG
private actor IntentPasteReadBoundary {
    private var parked = false
    private var finished = false
    private var didPark: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?

    func park() async {
        parked = true
        didPark?.resume()
        didPark = nil
        await withCheckedContinuation { resume = $0 }
    }

    func waitUntilParked() async -> Bool {
        guard !parked, !finished else { return parked }
        await withCheckedContinuation { didPark = $0 }
        return parked
    }

    func invocationFinished() {
        finished = true
        didPark?.resume()
        didPark = nil
    }

    func release() {
        resume?.resume()
        resume = nil
    }
}
#endif
