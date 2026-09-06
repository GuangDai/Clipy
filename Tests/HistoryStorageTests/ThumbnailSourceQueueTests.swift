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

    @Test func anotherKeyDoesNotLoadSourceWhileTheCurrentSourceAwaitsDecode() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
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
