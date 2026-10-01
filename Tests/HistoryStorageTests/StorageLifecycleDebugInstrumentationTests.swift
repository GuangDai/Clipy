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
        let initial = try WSSupport.fetchPosition(WSSupport.makeDatabase(storeURL: storeURL))
        #expect(initial.rawValue == 0)
        #expect(initial.retainedItemCount == 0)
        let privateText = "private storage lifecycle payload"
        let privateSource = "com.example.private-storage-source"
        let tiedObservedAt = Date(timeIntervalSinceReferenceDate: 710_200_000)
        let preparation = IngestPreparationActor()
        var privateItemIDs: [String] = []
        for index in 0..<12 {
            let bundle = try await preparation.prepare(
                WSSupport.textCapture(
                    "\(privateText) \(index)",
                    observedAt: tiedObservedAt,
                    source: privateSource
                )
            )
            privateItemIDs.append(bundle.domain.candidateID.rawValue.uuidString)
            _ = try await authority.commitCapture(bundle)
        }
        let page = try await authority.recentPage(limit: 10, cursor: nil)
        #expect(page.rows.count == 10)
        #expect(page.next != nil)

        // A second real SQLite connection takes the existing-store startup
        // path that the fresh-process admission diagnostic measures.
        let reopened = try HistoryAuthority(storeLocation: location)
        await reopened.setStorageLifecycleDebugProbe(
            StorageLifecycleDebugProbe(isEnabled: true) { event in
                _ = continuation.yield(event)
            }
        )
        try await reopened.performStartup(initialMaximumUnpinnedItems: 200)
        let reopenedPage = try await reopened.recentPage(limit: 10, cursor: nil)
        #expect(reopenedPage.rows == page.rows)
        #expect(reopenedPage.position == page.position)

        await authority.setStorageLifecycleDebugProbe(
            StorageLifecycleDebugProbe(isEnabled: false)
        )
        await reopened.setStorageLifecycleDebugProbe(
            StorageLifecycleDebugProbe(isEnabled: false)
        )
        continuation.finish()

        var captured: [StorageLifecycleDebugEvent] = []
        for await event in events {
            captured.append(event)
        }
        let phases = Set(captured.map(\.phase))
        let expectedPhases: Set<StorageLifecycleDebugPhase> = [
            .startupFetchBegin,
            .startupFetchComplete,
            .startupAutoreleasePoolDrained,
            .captureFactLoadBegin,
            .captureFactLoadComplete,
            .captureTransactionBegin,
            .captureTransactionComplete,
            .captureAutoreleasePoolDrained,
            .recentFetchBegin,
            .recentPinnedFetchBegin,
            .recentPinnedFetchComplete,
            .recentUnpinnedFetchBegin,
            .recentUnpinnedFetchComplete,
            .recentFetchComplete,
            .recentAutoreleasePoolDrained,
        ]
        #expect(expectedPhases.isSubset(of: phases))
        #expect(captured.allSatisfy {
            $0.event == StorageLifecycleDebugEvent.eventName
                && $0.schemaVersion == 1
                && $0.elapsedMilliseconds >= 0
                && $0.rows >= 0
        })

        let startupBegins = captured.indices.filter { captured[$0].phase == .startupFetchBegin }
        let startupCompletes = captured.indices.filter { captured[$0].phase == .startupFetchComplete }
        let startupDrains = captured.indices.filter { captured[$0].phase == .startupAutoreleasePoolDrained }
        try #require(startupBegins.count == 2)
        try #require(startupCompletes.count == 2)
        try #require(startupDrains.count == 2)
        for index in startupBegins.indices {
            #expect(startupBegins[index] < startupCompletes[index])
            #expect(startupCompletes[index] < startupDrains[index])
        }

        let captureTransactionCompleteIndex = try #require(captured.firstIndex {
            $0.phase == .captureTransactionComplete
        })
        let captureDrainedIndex = try #require(captured.firstIndex {
            $0.phase == .captureAutoreleasePoolDrained
        })
        #expect(captureTransactionCompleteIndex < captureDrainedIndex)

        let unpinnedFetch = try #require(captured.first {
            $0.phase == .recentUnpinnedFetchComplete
        })
        #expect(unpinnedFetch.rows == 11)
        let fetchCompleteIndex = try #require(captured.firstIndex {
            $0.phase == .recentUnpinnedFetchComplete
        })
        let recentCompleteIndex = try #require(captured.firstIndex {
            $0.phase == .recentFetchComplete
        })
        let recentDrainedIndex = try #require(captured.firstIndex {
            $0.phase == .recentAutoreleasePoolDrained
        })
        #expect(fetchCompleteIndex < recentCompleteIndex)
        #expect(recentCompleteIndex < recentDrainedIndex)

        let rendered = captured.compactMap(\.logLine).joined(separator: "\n")
        #expect(!rendered.isEmpty)
        #expect(rendered.split(separator: "\n").allSatisfy {
            $0.hasPrefix(StorageLifecycleDebugProbe.logPrefix)
        })
        #expect(!rendered.contains(privateText))
        #expect(!rendered.contains(privateSource))
        #expect(!rendered.contains(storeURL.path))
        #expect(privateItemIDs.allSatisfy { !rendered.contains($0) })
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
