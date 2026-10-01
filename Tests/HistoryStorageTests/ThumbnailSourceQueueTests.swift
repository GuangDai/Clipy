/// Distinct thumbnail requests wait before source loading, while exact-key
/// joiners retain their scalar validation. Tiny real PNGs keep the test about
/// source/decode ordering rather than memory pressure or timing thresholds.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

private actor ThumbnailQueueProbe {
    private(set) var sourceLoads = 0
    private var decodeEntries = 0

    func loadedSource() { sourceLoads += 1 }
    func enteredDecode() -> Int {
        decodeEntries += 1
        return decodeEntries
    }
}

struct ThumbnailSourceQueueTests {
    private static let first = HistoryItemReference(
        id: HistoryItemID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000CA01")!),
        contentVersion: .initial
    )
    private static let second = HistoryItemReference(
        id: HistoryItemID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000CA02")!),
        contentVersion: .initial
    )
    private static let pixels = PixelSize(width: 32, height: 32)
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    )!

    @Test func cancelledQueuedRequestsExitWhileCancelledNativeWorkKeepsItsRealSlot() async throws {
        let service = ThumbnailService(maximumInFlightCount: 2)
        let history = try await SQLiteHistory.open(
            configuration: .init(persistence: .temporary), thumbnailService: service,
            makeCandidateID: { HistoryItemID(rawValue: UUID()) }
        )
        let item = try await capturePNG("retired native owner", in: history)
        let native = ThumbnailResourceGate()
        await service.setSuspensionHandler { _ in await native.park("native") }
        let first = Task { try await history.thumbnail(for: item, pixels: Self.pixels) }
        let started = await waitUntil { await native.isParked("native") }
        if !started {
            first.cancel()
            await native.release()
            _ = await first.result
            try #require(started)
            return
        }
        first.cancel()
        let retired = await waitUntil { await native.wasCancelled }
        if !retired {
            await native.release()
            _ = await first.result
            try #require(retired)
            return
        }
        #expect(await service.inFlightCount == 1)
        let completions = ThumbnailResourceCompletions()
        for index in 0..<12 {
            let next = Task {
                do {
                    let payload = try await history.thumbnail(for: item, pixels: Self.pixels)
                    await completions.record(index)
                    return payload
                } catch {
                    await completions.record(index)
                    throw error
                }
            }
            let queued = await waitUntil { await service.queuedSourceCount == 1 }
            next.cancel()
            let finishedBeforeNativeReturned = await waitUntil { await completions.contains(index) }
            if !queued || !finishedBeforeNativeReturned {
                await native.release()
                _ = await first.result
                _ = await next.result
                try #require(queued && finishedBeforeNativeReturned)
                return
            }
            await #expect(throws: CancellationError.self) { try await next.value }
            #expect(await service.inFlightCount == 1)
            #expect(await service.inFlightCallerCount == 1)
            #expect(await native.entryCount == 1, "Cancelled queued demand cannot hydrate another source")
        }
        await native.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await service.inFlightCount == 0)
        #expect(await service.inFlightCallerCount == 0)
        #expect(try await history.thumbnail(for: item, pixels: Self.pixels)?.item == item)
    }

    @Test func cancelledJoinValidationKeepsPhysicalCallerCapacityAfterCreatorCompletion() async throws {
        let service = ThumbnailService(maximumInFlightCount: 1)
        let history = try await SQLiteHistory.open(
            configuration: .init(persistence: .temporary), thumbnailService: service,
            makeCandidateID: { HistoryItemID(rawValue: UUID()) }
        )
        let item = try await capturePNG("joined native owner", in: history)
        let native = ThumbnailResourceGate()
        let validations = ThumbnailResourceGate()
        let secondSource = ThumbnailResourceGate()
        await service.setSuspensionHandler { _ in await native.park("native") }
        let creator = Task { try await history.thumbnail(for: item, pixels: Self.pixels) }
        let started = await waitUntil { await native.isParked("native") }
        if !started {
            creator.cancel()
            await native.release()
            _ = await creator.result
            try #require(started)
            return
        }
        let authority = history.authority
        let joins = (0..<31).map { index in
            Task {
                try await service.thumbnail(
                    for: item, pixels: Self.pixels,
                    loadSource: { try await authority.thumbnailSource(for: item, pixels: Self.pixels)?.bytes },
                    validateJoin: {
                        try await authority.validateThumbnailFlightJoin(for: item, pixels: Self.pixels)
                        await validations.park("join-\(index)")
                    }
                )
            }
        }
        let joined = await waitUntil {
            for index in 0..<31 {
                if !(await validations.isParked("join-\(index)")) { return false }
            }
            return true
        }
        if !joined {
            for join in joins { join.cancel() }
            await validations.release()
            await native.release()
            _ = await creator.result
            for join in joins { _ = await join.result }
            try #require(joined)
            return
        }
        for join in joins { join.cancel() }
        await native.release()
        let creatorResult = await creator.result
        #expect(await service.inFlightCount == 0)
        #expect(await service.inFlightCallerCount == 31)
        let next = Task {
            try await service.thumbnail(
                for: item, pixels: Self.pixels,
                loadSource: {
                    await secondSource.park("source")
                    return try await authority.thumbnailSource(for: item, pixels: Self.pixels)?.bytes
                }, validateJoin: {}
            )
        }
        let sourceStarted = await waitUntil { await secondSource.isParked("source") }
        if !sourceStarted {
            next.cancel()
            await secondSource.release()
            await validations.release()
            _ = await next.result
            for join in joins { _ = await join.result }
            try #require(sourceStarted)
            return
        }
        // The first creator is gone, but its cancelled consumers still own
        // their blocked validation frames. New calls cannot borrow those slots.
        let completions = ThumbnailResourceCompletions()
        let rejected = Task {
            do {
                let payload = try await history.thumbnail(for: item, pixels: Self.pixels)
                await completions.record(0)
                return payload
            } catch {
                await completions.record(0)
                throw error
            }
        }
        let didRejectBeforeSourceReturned = await waitUntil { await completions.contains(0) }
        #expect(await service.inFlightCallerCount == 32)
        await secondSource.release()
        await validations.release()
        let nextResult = await next.result
        let rejectedResult = await rejected.result
        for join in joins {
            await #expect(throws: CancellationError.self) { try await join.value }
        }
        #expect(didRejectBeforeSourceReturned)
        #expect(throws: HistoryFailure.temporarilyUnavailable(.thumbnailResources)) { try rejectedResult.get() }
        #expect(try creatorResult.get()?.item == item)
        #expect(try nextResult.get()?.item == item)
        #expect(await service.inFlightCallerCount == 0)
        #expect(await service.inFlightCount == 0)
        #expect(try await history.thumbnail(for: item, pixels: Self.pixels)?.item == item)
    }

    private func capturePNG(_ title: String, in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            title, observedAt: Date(timeIntervalSinceReferenceDate: 700_060_100),
            extra: [("public.png", [UInt8](Self.png))]
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { return false }
        }
        return await condition()
    }

    @Test func anotherKeyDoesNotLoadSourceWhileTheCurrentSourceAwaitsDecode() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        var references: [HistoryItemReference] = []
        for title in ["first", "second", "third", "fourth", "fifth", "sixth"] {
            let receipt = try await history.perform(.capture(WSSupport.textCapture(
                title, observedAt: Date(timeIntervalSinceReferenceDate: 700_060_000),
                extra: [("public.png", [UInt8](Self.png))]
            )))
            guard case let .committed(commit) = receipt,
                  case let .inserted(reference) = commit.outcome else {
                Issue.record("Expected distinct thumbnail fixture items")
                return
            }
            references.append(reference)
        }
        let firstReference = references[0]
        let service = history.thumbnailService
        let authority = history.authority
        let probe = ThumbnailQueueProbe()
        let decodeGate = SuspensionGate()
        let joinGate = SuspensionGate()
        await service.setSuspensionHandler { _ in
            if await probe.enteredDecode() == 1 {
                await decodeGate.park(at: "first.decode")
            }
        }
        let first = Task {
            try await service.thumbnail(
                for: firstReference, pixels: Self.pixels,
                loadSource: {
                    await probe.loadedSource()
                    return try await authority.thumbnailSource(
                        for: firstReference, pixels: Self.pixels
                    )?.bytes
                },
                validateJoin: {}
            )
        }
        await decodeGate.waitForPark("first.decode")

        // Each pair's join callback proves its distinct flight was admitted
        // while the first source is parked. Merely starting tasks would not
        // prove they reached the service before the source-count assertion.
        let queued = references.dropFirst().map { reference in
            let request: @Sendable () async throws -> ThumbnailPayload? = {
                try await service.thumbnail(
                    for: reference, pixels: Self.pixels,
                    loadSource: {
                        await probe.loadedSource()
                        return try await authority.thumbnailSource(
                            for: reference, pixels: Self.pixels
                        )?.bytes
                    },
                    validateJoin: {
                        try await authority.validateThumbnailFlightJoin(
                            for: reference, pixels: Self.pixels
                        )
                        await joinGate.park(at: reference.id.description)
                    }
                )
            }
            return (reference, Task { try await request() }, Task { try await request() })
        }
        for (reference, _, _) in queued {
            await joinGate.waitForPark(reference.id.description)
        }
        #expect(await service.inFlightCount == 6)
        #expect(await probe.sourceLoads == 1)

        await joinGate.resumeAll()
        await decodeGate.resume("first.decode")
        let firstPayload = try #require(try await first.value)
        #expect(firstPayload.item == firstReference)
        for (reference, firstCall, secondCall) in queued {
            let payload = try #require(try await firstCall.value)
            #expect(try await secondCall.value == payload)
            #expect(payload.item == reference)
        }
        #expect(await probe.sourceLoads == 6)
        #expect(await service.inFlightCount == 0)
    }

    enum FirstOutcome: Sendable {
        case noImage, sourceFailure, cancelled, malformedImage
    }

    @Test func cancellingEveryQueuedConsumerSkipsItsSourceRead() async throws {
        let service = ThumbnailService()
        let sourceGate = SuspensionGate()
        let joinGate = SuspensionGate()
        let probe = ThumbnailQueueProbe()
        let first = Task {
            try await service.thumbnail(
                for: Self.first, pixels: Self.pixels,
                loadSource: {
                    await probe.loadedSource()
                    await sourceGate.park(at: "active.source")
                    return Self.png
                }, validateJoin: {}
            )
        }
        await sourceGate.waitForPark("active.source")
        let queuedRequest: @Sendable () async throws -> ThumbnailPayload? = {
            try await service.thumbnail(
                for: Self.second, pixels: Self.pixels,
                loadSource: { await probe.loadedSource(); return Self.png },
                validateJoin: { await joinGate.park(at: "queued.join") }
            )
        }
        let queuedCreator = Task { try await queuedRequest() }
        let queuedJoiner = Task { try await queuedRequest() }
        await joinGate.waitForPark("queued.join")
        queuedCreator.cancel()
        queuedJoiner.cancel()
        await joinGate.resume("queued.join")
        // Let the creator's cancellation handler reach the service while
        // the predecessor is still parked. This establishes retirement
        // before releasing the queue, rather than depending on task order.
        var retired = false
        for _ in 0..<2_000 {
            if await service.inFlightCount == 1 { retired = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(retired)
        await sourceGate.resume("active.source")
        #expect(try await first.value?.item == Self.first)
        await #expect(throws: CancellationError.self) { try await queuedJoiner.value }
        await #expect(throws: CancellationError.self) { try await queuedCreator.value }
        #expect(await probe.sourceLoads == 1)
        #expect(await service.inFlightCount == 0)

        // Retirement does not negative-cache the exact key. New demand
        // starts one fresh source read after the cancelled queue drains.
        let restarted = try await service.thumbnail(
            for: Self.second, pixels: Self.pixels,
            loadSource: { await probe.loadedSource(); return Self.png },
            validateJoin: {}
        )
        #expect(restarted?.item == Self.second)
        #expect(await probe.sourceLoads == 2)
    }

    @Test(arguments: [FirstOutcome.noImage, .sourceFailure, .cancelled, .malformedImage])
    func everyTerminalOutcomeLetsTheFollowingSourceRun(_ outcome: FirstOutcome) async throws {
        let service = ThumbnailService()
        let sourceGate = SuspensionGate()
        let joinGate = SuspensionGate()
        let probe = ThumbnailQueueProbe()
        let first = Task {
            try await service.thumbnail(
                for: Self.first, pixels: Self.pixels,
                loadSource: {
                    await probe.loadedSource()
                    await sourceGate.park(at: "first.source")
                    switch outcome {
                    case .noImage: return nil
                    case .sourceFailure: throw HistoryFailure.notFound(Self.first.id)
                    case .cancelled: throw CancellationError()
                    case .malformedImage: return Data("not an image".utf8)
                    }
                },
                validateJoin: {}
            )
        }
        await sourceGate.waitForPark("first.source")
        let requestSecond: @Sendable () async throws -> ThumbnailPayload? = {
            try await service.thumbnail(
                for: Self.second, pixels: Self.pixels,
                loadSource: { await probe.loadedSource(); return Self.png },
                validateJoin: { await joinGate.park(at: "second.join") }
            )
        }
        let second = Task { try await requestSecond() }
        let joined = Task { try await requestSecond() }
        await joinGate.waitForPark("second.join")
        #expect(await service.inFlightCount == 2)
        #expect(await probe.sourceLoads == 1)
        await joinGate.resume("second.join")
        await sourceGate.resume("first.source")

        switch outcome {
        case .noImage:
            #expect(try await first.value == nil)
        case .sourceFailure:
            await #expect(throws: HistoryFailure.notFound(Self.first.id)) { try await first.value }
        case .cancelled:
            await #expect(throws: CancellationError.self) { try await first.value }
        case .malformedImage:
            await #expect(throws: HistoryFailure.thumbnailUnavailable) { try await first.value }
        }
        let payload = try #require(try await second.value)
        #expect(try await joined.value == payload)
        #expect(payload.item == Self.second)
        #expect(await probe.sourceLoads == 2)
        #expect(await service.inFlightCount == 0)
        // After quiescence, the same key starts another source load rather
        // than reusing the previous completed payload.
        let next = try await service.thumbnail(
            for: Self.second, pixels: Self.pixels,
            loadSource: { await probe.loadedSource(); return Self.png },
            validateJoin: {}
        )
        #expect(next?.item == Self.second)
        #expect(await probe.sourceLoads == 3)
    }
}

private actor ThumbnailResourceGate {
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var isReleased = false
    private(set) var wasCancelled = false
    private(set) var entryCount = 0

    func park(_ point: String) async {
        entryCount += 1
        guard !isReleased else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations[point] = continuation
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    private func recordCancellation() { wasCancelled = true }

    func isParked(_ point: String) -> Bool { continuations[point] != nil }

    func release() {
        isReleased = true
        let parked = Array(continuations.values)
        continuations.removeAll()
        for continuation in parked { continuation.resume() }
    }
}

private actor ThumbnailResourceCompletions {
    private var completed: Set<Int> = []

    func record(_ index: Int) { completed.insert(index) }
    func contains(_ index: Int) -> Bool { completed.contains(index) }
}
