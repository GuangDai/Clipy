import Foundation
import HistoryCore
@testable import HistoryStorage
import Testing
@testable import ClipyApp

#if DEBUG
@Suite("Real thumbnail capacity across browsing surfaces", .serialized)
@MainActor
struct RealHistoryThumbnailCapacityTests {
    enum Release: Sendable, Equatable { case nativeCompletion, closeWaitingSurface, criticalHoldingSurface }

    @Test func releasingTheSurfaceRetiresItsCapacitySubscription() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await capture("released browsing surface", in: history)
        var store: ThumbnailStore? = ThumbnailStore(history: history)
        weak var released = store
        store?.setDisplayed(item, true)
        store?.prefetch(item)
        try #require(await pollUntil { store?.liveRequestCount == 0 })
        try #require(await pollUntil { await history.thumbnailService.capacityObserverCount == 1 })
        store = nil
        try #require(await pollUntil { released == nil })
        try #require(await pollUntil { await history.thumbnailService.capacityObserverCount == 0 })
        #expect(try await history.details(for: item.id).item == item)
    }

    @Test func appearanceAfterResourceRejectionRestoresEligibleDemandWithoutFetchingTextRows() async throws {
        let service = ThumbnailService(maximumInFlightCount: 1)
        let history = try await SQLiteHistory.open(
            configuration: .init(persistence: .temporary), thumbnailService: service,
            makeCandidateID: { HistoryItemID(rawValue: UUID()) }
        )
        let first = try await capture("holding first image", in: history)
        let image = try await capture("image before appearance", in: history)
        let cold = try await capture("cold capacity fact", in: history)
        let extraCold = try await capture("cold past pending budget", in: history)
        let text = try await capture("unrequested text row", includeImage: false, in: history)
        let holding = ThumbnailStore(history: history)
        let waiting = ThumbnailStore(history: history, maximumEntries: 2, maximumDecodedBytes: 64)
        let native = ThumbnailCapacityNativeGate()
        await service.setSuspensionHandler { _ in await native.parkFirst() }
        holding.prefetch(first)
        let started = await pollUntil { await native.isParked }
        if !started {
            holding.reset()
            await native.release()
            _ = await pollUntil { holding.liveRequestCount == 0 }
            try #require(started)
            return
        }
        do {
            // SwiftUI's row task can run before onAppear. These failures
            // remember only bounded eligibility; neither key is visible yet.
            for item in [image, cold, extraCold] {
                waiting.prefetch(item)
                try #require(await pollUntil { waiting.liveRequestCount == 0 })
            }
            #expect(waiting.pendingRequestCount == 0)
            #expect(waiting.pendingAddressCount == 2)
            #expect(waiting.cachedEntryCount == 0)
            waiting.setDisplayed(text, true)
            #expect(waiting.liveRequestCount == 0)
            waiting.setDisplayed(image, true)
            try #require(await pollUntil {
                waiting.liveRequestCount == 0 && waiting.pendingRequestCount == 1
            })
            #expect(waiting.pendingAddressCount == 2)
            await native.release()
            try #require(await pollUntil {
                waiting.liveRequestCount == 0 && waiting.pendingRequestCount == 0
                    && waiting.imagePixelSize(for: image) != nil
            })
            #expect(waiting.cachedEntryCount == 1)
            #expect(waiting.imagePixelSize(for: cold) == nil)
            #expect(waiting.imagePixelSize(for: extraCold) == nil)
            #expect(!waiting.isUnavailable(for: text))
            holding.reset()
            waiting.reset()
            try #require(await pollUntil { await service.capacityObserverCount == 0 })
        } catch {
            holding.reset()
            waiting.reset()
            await native.release()
            _ = await pollUntil { holding.liveRequestCount == 0 && waiting.liveRequestCount == 0 }
            throw error
        }
    }

    @Test(arguments: [Release.nativeCompletion, .closeWaitingSurface, .criticalHoldingSurface])
    func releasedCapacityRestoresOnlyCurrentVisibleDemand(_ release: Release) async throws {
        let service = ThumbnailService(maximumInFlightCount: 2)
        let history = try await SQLiteHistory.open(
            configuration: .init(persistence: .temporary), thumbnailService: service,
            makeCandidateID: { HistoryItemID(rawValue: UUID()) }
        )
        let first = try await capture("holding source", in: history)
        let second = try await capture("holding queued source", in: history)
        let visible = try await capture("waiting visible row", in: history)
        let cold = try await capture("unrequested cold row", in: history)
        let before = try await history.browse(.init(kind: .recent, limit: 10))
        let holding = ThumbnailStore(history: history)
        let waiting = ThumbnailStore(history: history)
        let native = ThumbnailCapacityNativeGate()
        await service.setSuspensionHandler { _ in await native.parkFirst() }
        holding.setDisplayed(first, true)
        holding.setDisplayed(second, true)
        holding.prefetch(first)
        holding.prefetch(second)
        let started = await pollUntil { await native.isParked }
        if !started {
            holding.reset()
            waiting.reset()
            await native.release()
            _ = await pollUntil { holding.liveRequestCount == 0 }
            try #require(started)
            return
        }
        do {
            try #require(await pollUntil { await service.queuedSourceCount == 1 })
            #expect(await service.inFlightCount == 2)
            waiting.setDisplayed(visible, true)
            waiting.prefetch(visible)
            waiting.prefetch(cold)
            try #require(await pollUntil {
                waiting.liveRequestCount == 0 && waiting.pendingRequestCount == 1
            })
            #expect(waiting.imagePixelSize(for: visible) == nil)
            #expect(!waiting.isUnavailable(for: visible))
            #expect(waiting.cachedEntryCount == 0)
            try #require(await pollUntil { await service.capacityObserverCount == 2 })

            switch release {
            case .nativeCompletion:
                break
            case .closeWaitingSurface:
                waiting.isSurfaceActive = false
                try #require(await pollUntil { await service.capacityObserverCount == 1 })
                #expect(waiting.pendingRequestCount == 0)
            case .criticalHoldingSurface:
                holding.respondToMemoryPressure(.critical)
                // The cancelled active native job still owns one real slot;
                // only the actually exited queued job releases the other one.
                // That event admits the other surface's visible request.
                try #require(await pollUntil {
                    holding.liveRequestCount == 1 && waiting.inFlightCount == 1
                })
                #expect(await service.inFlightCount == 2)
                #expect(await service.queuedSourceCount == 1)
                #expect(waiting.imagePixelSize(for: visible) == nil)
                #expect(holding.cachedEntryCount == 0)
            }
            // No new row appearance, view .task, explicit prefetch or History
            // mutation follows rejection. The real release stream owns retry.
            await native.release()
            try #require(await pollUntil {
                holding.liveRequestCount == 0 && waiting.liveRequestCount == 0
                    && waiting.pendingRequestCount == 0
            })
            if release == .closeWaitingSurface {
                #expect(waiting.imagePixelSize(for: visible) == nil)
                #expect(waiting.cachedEntryCount == 0)
            } else {
                #expect(waiting.imagePixelSize(for: visible) == PixelSize(width: 1, height: 1))
                #expect(waiting.cachedEntryCount == 1)
                #expect(waiting.cachedDecodedBytes == 4)
            }
            #expect(waiting.imagePixelSize(for: cold) == nil)
            #expect(!waiting.isUnavailable(for: visible))
            #expect(await service.inFlightCount == 0)
            #expect(await service.inFlightCallerCount == 0)
            let after = try await history.browse(.init(kind: .recent, limit: 10))
            #expect(after.position == before.position)
            #expect(after.rows == before.rows)
            holding.reset()
            waiting.reset()
            try #require(await pollUntil { await service.capacityObserverCount == 0 })
        } catch {
            holding.reset()
            waiting.reset()
            await native.release()
            _ = await pollUntil { holding.liveRequestCount == 0 && waiting.liveRequestCount == 0 }
            throw error
        }
    }

    @Test func aSurfaceKeepsOnlyFourRealTasksWhenCriticalPressureRetiresTheirKeys() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        var items: [HistoryItemReference] = []
        for index in 0..<8 { items.append(try await capture("displayed \(index)", in: history)) }
        let store = ThumbnailStore(history: history)
        let native = ThumbnailCapacityNativeGate()
        await history.thumbnailService.setSuspensionHandler { _ in await native.parkFirst() }
        for item in items {
            store.setDisplayed(item, true)
            store.prefetch(item)
        }
        let started = await pollUntil { await native.isParked }
        if !started {
            store.reset()
            await native.release()
            _ = await pollUntil { store.liveRequestCount == 0 }
            try #require(started)
            return
        }
        do {
            #expect(store.liveRequestCount == 4)
            #expect(store.pendingRequestCount == 4)
            store.respondToMemoryPressure(.critical)
            #expect(store.inFlightCount == 0)
            #expect(store.pendingRequestCount == 0)
            try #require(await pollUntil { store.liveRequestCount == 1 })
            #expect(await history.thumbnailService.inFlightCount == 1)
            store.respondToMemoryPressure(.normal)
            for item in items { store.prefetch(item) }
            #expect(store.liveRequestCount == 4)
            #expect(store.pendingRequestCount == 5)
            #expect(store.cachedEntryCount == 0)
            await native.release()
            try #require(await pollUntil {
                store.liveRequestCount == 0 && store.pendingRequestCount == 0
                    && store.cachedEntryCount == items.count
            })
            #expect(store.cachedDecodedBytes == 4 * items.count)
            #expect(items.allSatisfy { store.imagePixelSize(for: $0) != nil })
            #expect(await history.thumbnailService.inFlightCount == 0)
            store.reset()
            try #require(await pollUntil { await history.thumbnailService.capacityObserverCount == 0 })
        } catch {
            store.reset()
            await native.release()
            _ = await pollUntil { store.liveRequestCount == 0 }
            throw error
        }
    }

    private func capture(
        _ label: String, includeImage: Bool = true, in history: SQLiteHistory
    ) async throws -> HistoryItemReference {
        var representations = [CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(label.utf8))]
        if includeImage { representations.insert(CapturedRepresentation(typeIdentifier: "public.png", bytes: fixturePNGData), at: 0) }
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: representations, origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_095_000)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }
}

private actor ThumbnailCapacityNativeGate {
    private var entered = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isParked = false

    func parkFirst() async {
        guard !entered else { return }
        entered = true
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isParked = true
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
        isParked = false
    }
}
#endif
