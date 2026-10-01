import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct StoreOpenCancellationTests {
    @Test func alreadyCancelledOpenDoesNotCreateStoreArtifacts() async throws {
        let url = WSSupport.tempStoreURL("cancelled-before-open")
        defer { WSSupport.removeStore(url) }
        let opening = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WSSupport.openHistory(storeURL: url)
        }
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).isEmpty)

        let reopened = try await WSSupport.openHistory(storeURL: url)
        let usage = try await reopened.usage()
        #expect(usage.itemCount == 0)
        #expect(usage.position.rawValue == 0)
    }

    @Test func cancellationDuringBootstrapRollsBackAndAllowsARealReopen() async throws {
        let url = WSSupport.tempStoreURL("cancelled-bootstrap")
        defer { WSSupport.removeStore(url) }
        try await cancelBootstrap(at: url)

        let reopened = try await WSSupport.openHistory(storeURL: url)
        let item = try await RetainedBytesTestSupport.capture("after cancelled startup", in: reopened)
        let payload = try await reopened.pastePayload(for: item.id)
        #expect(payload.item == item)
        #expect(payload.representations.map(\.bytes) == [Data("after cancelled startup".utf8)])
        #expect(try await reopened.usage().position.rawValue == 1)
    }

    private func cancelBootstrap(at url: URL) async throws {
        let authority = try HistoryAuthority(
            storeLocation: HistoryStoreLocation(persistence: .persistent(storeURL: url)),
            storageClock: CancellingClock()
        )
        // Gateway bootstrap samples this clock after the fresh History schema
        // and its first singletons have been inserted, inside the transaction.
        let startup = Task { try await authority.performStartup(initialMaximumUnpinnedItems: 200) }
        await #expect(throws: CancellationError.self) { try await startup.value }
        try await authority.withTestDatabase { owner in
            let tables = try owner.database.prepare("SELECT count(*) FROM sqlite_master WHERE type='table'")
            defer { tables.finalize() }
            try #require(try tables.step())
            #expect(try tables.integer(at: 0) == 0)
        }
    }

    private struct CancellingClock: StorageClock {
        func now() -> Date {
            withUnsafeCurrentTask { $0?.cancel() }
            return Date(timeIntervalSinceReferenceDate: 900_000_000)
        }
    }
}
