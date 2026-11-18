#if DEBUG
/// Debug-only proofs for the opt-in storage lifecycle checkpoints. The first
/// test drives the real Authority, SQLite transactions, and the
/// production capture transaction; the probe changes only the synchronous
/// event sink and never substitutes persistence behavior.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct StorageLifecycleDebugInstrumentationTests {
    @Test func authorityEmitsPrivacySafeLifecycleCheckpoints() async throws {
        let storeURL = WSSupport.tempStoreURL("storage-lifecycle-trace")
        defer { WSSupport.removeStore(storeURL) }

        let location = try HistoryStoreLocation(persistence: .persistent(storeURL: storeURL))
        let authority = try HistoryAuthority(storeLocation: location)
        let (events, continuation) = AsyncStream<StorageLifecycleDebugEvent>
            .makeStream(bufferingPolicy: .unbounded)
        await authority.setStorageLifecycleDebugProbe(
            StorageLifecycleDebugProbe(isEnabled: true) { event in
                _ = continuation.yield(event)
            }
        )

        try await authority.performStartup(initialMaximumUnpinnedItems: 200)
        let privateText = "private storage lifecycle payload"
        let privateSource = "com.example.private-storage-source"
        let bundle = try await IngestPreparationActor().prepare(
            WSSupport.textCapture(
                privateText, observedAt: Date(timeIntervalSinceReferenceDate: 710_200_000),
                source: privateSource
            )
        )
        _ = try await authority.commitCapture(bundle)
        let page = try await authority.recentPage(limit: 10, cursor: nil)
        #expect(page.rows.map(\.title) == [privateText])

        await authority.setStorageLifecycleDebugProbe(StorageLifecycleDebugProbe(isEnabled: false))
        continuation.finish()
        var captured: [StorageLifecycleDebugEvent] = []
        for await event in events { captured.append(event) }

        let startupBegin = try #require(captured.firstIndex { $0.phase == .startupFetchBegin })
        let startupComplete = try #require(captured.firstIndex { $0.phase == .startupFetchComplete })
        let captureComplete = try #require(captured.firstIndex { $0.phase == .captureTransactionComplete })
        let recentComplete = try #require(captured.firstIndex { $0.phase == .recentFetchComplete })
        #expect(startupBegin < startupComplete)
        #expect(startupComplete < captureComplete)
        #expect(captureComplete < recentComplete)

        let rendered = captured.compactMap(\.logLine).joined(separator: "\n")
        #expect(!rendered.isEmpty)
        #expect(rendered.split(separator: "\n").allSatisfy {
            $0.hasPrefix(StorageLifecycleDebugProbe.logPrefix)
        })
        #expect(!rendered.contains(privateText))
        #expect(!rendered.contains(privateSource))
        #expect(!rendered.contains(storeURL.path))
        #expect(!rendered.contains(bundle.domain.candidateID.rawValue.uuidString))
    }

    @Test func failedStartupDoesNotEmitSuccessfulCompletion() async throws {
        let authority = try HistoryAuthority(storeLocation: HistoryStoreLocation(persistence: .temporary))
        try await authority.performStartup(initialMaximumUnpinnedItems: 200)
        try await authority.withTestDatabase { owner in
            try owner.database.execute("UPDATE gateway_config SET configSchemaVersion=2")
        }
        let (events, continuation) = AsyncStream<StorageLifecycleDebugEvent>.makeStream()
        await authority.setStorageLifecycleDebugProbe(StorageLifecycleDebugProbe(isEnabled: true) { event in
            _ = continuation.yield(event)
        })
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await authority.performStartup(initialMaximumUnpinnedItems: 200)
        }
        await authority.setStorageLifecycleDebugProbe(StorageLifecycleDebugProbe(isEnabled: false))
        continuation.finish()
        var phases: [StorageLifecycleDebugPhase] = []
        for await event in events { phases.append(event.phase) }
        #expect(phases.contains(.startupFetchBegin))
        #expect(!phases.contains(.startupFetchComplete))
        #expect(!phases.contains(.startupAutoreleasePoolDrained))
    }

    @Test func disabledLifecycleProbeEmitsNothing() async {
        let (events, continuation) = AsyncStream<StorageLifecycleDebugEvent>
            .makeStream(bufferingPolicy: .unbounded)
        let probe = StorageLifecycleDebugProbe(isEnabled: false) { event in
            _ = continuation.yield(event)
        }
        probe.record(phase: .startupFetchBegin)
        continuation.finish()

        var count = 0
        for await _ in events {
            count += 1
        }
        #expect(count == 0)
    }
}
#endif
