/// Source-inclusive thumbnail single-flight proofs. The production service
/// receives source/validation operations from the facade; these tests freeze
/// success, nil, failure, and removal at the deep seam so duplicate source
/// hydration cannot hide behind a successful shared ImageIO decode.
/// docs/04-coherence.md §9;
/// V1-Verified `thumbnail-source-full-image-copy`.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

private enum ThumbnailFlightProbeFailure: Error, Equatable {
    case source
}

private actor ThumbnailFlightProbe {
    private var sourceLoads = 0
    private var joinValidations = 0

    func recordSourceLoad() -> Int {
        sourceLoads += 1
        return sourceLoads
    }

    func recordJoinValidation() {
        joinValidations += 1
    }

    func counts() -> (sourceLoads: Int, joinValidations: Int) {
        (sourceLoads, joinValidations)
    }
}

struct ThumbnailSourceSingleFlightTests {
    private static let png1x1TransparentBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    private static let reference = HistoryItemReference(
        id: HistoryItemID(rawValue: UUID(uuidString:
            "00000000-0000-0000-0000-000000000001"
        )!),
        contentVersion: .initial
    )

    @Test func concurrentIdenticalCallsLoadSourceOnceAndValidateTheJoiner() async throws {
        let png = try #require(Data(base64Encoded: Self.png1x1TransparentBase64))
        let service = ThumbnailService()
        let probe = ThumbnailFlightProbe()
        let sourceGate = SuspensionGate()
        let validationGate = SuspensionGate()
        let sourcePoint = "thumbnail-source-flight.source"
        let validationPoint = "thumbnail-source-flight.validation"
        let pixels = PixelSize(width: 32, height: 32)

        let first = Task { () -> ThumbnailPayload? in
            try await service.thumbnail(
                for: Self.reference,
                pixels: pixels,
                loadSource: {
                    let call = await probe.recordSourceLoad()
                    if call == 1 {
                        await sourceGate.park(at: sourcePoint)
                    }
                    return png
                },
                validateJoin: {
                    await probe.recordJoinValidation()
                }
            )
        }
        await sourceGate.waitForPark(sourcePoint)

        let second = Task { () -> ThumbnailPayload? in
            try await service.thumbnail(
                for: Self.reference,
                pixels: pixels,
                loadSource: {
                    _ = await probe.recordSourceLoad()
                    return png
                },
                validateJoin: {
                    await probe.recordJoinValidation()
                    await validationGate.park(at: validationPoint)
                }
            )
        }
        await validationGate.waitForPark(validationPoint)

        let parkedCounts = await probe.counts()
        #expect(parkedCounts.sourceLoads == 1)
        #expect(parkedCounts.joinValidations == 1)

        await validationGate.resume(validationPoint)
        await sourceGate.resume(sourcePoint)
        let firstPayload = try #require(try await first.value)
        let secondPayload = try #require(try await second.value)

        #expect(firstPayload == secondPayload)
        #expect(firstPayload.item == Self.reference)
        #expect(firstPayload.pixels == pixels)

        // Completion removes the flight. A later exact-key request must own a
        // fresh source load rather than joining completed bytes.
        let nextPayload = try #require(try await service.thumbnail(
            for: Self.reference,
            pixels: pixels,
            loadSource: {
                _ = await probe.recordSourceLoad()
                return png
            },
            validateJoin: {
                await probe.recordJoinValidation()
            }
        ))
        #expect(nextPayload.item == Self.reference)

        let finalCounts = await probe.counts()
        #expect(finalCounts.sourceLoads == 2)
        #expect(finalCounts.joinValidations == 1)
    }

    @Test func concurrentIdenticalCallsShareNilAndRemoveTheFlight() async throws {
        let png = try #require(Data(base64Encoded: Self.png1x1TransparentBase64))
        let service = ThumbnailService()
        let probe = ThumbnailFlightProbe()
        let sourceGate = SuspensionGate()
        let validationGate = SuspensionGate()
        let sourcePoint = "thumbnail-source-flight.nil-source"
        let validationPoint = "thumbnail-source-flight.nil-validation"
        let pixels = PixelSize(width: 32, height: 32)

        let first = Task { () -> ThumbnailPayload? in
            try await service.thumbnail(
                for: Self.reference,
                pixels: pixels,
                loadSource: {
                    _ = await probe.recordSourceLoad()
                    await sourceGate.park(at: sourcePoint)
                    return nil
                },
                validateJoin: {
                    await probe.recordJoinValidation()
                }
            )
        }
        await sourceGate.waitForPark(sourcePoint)

        let second = Task { () -> ThumbnailPayload? in
            try await service.thumbnail(
                for: Self.reference,
                pixels: pixels,
                loadSource: {
                    _ = await probe.recordSourceLoad()
                    return png
                },
                validateJoin: {
                    await probe.recordJoinValidation()
                    await validationGate.park(at: validationPoint)
                }
            )
        }
        await validationGate.waitForPark(validationPoint)
        await validationGate.resume(validationPoint)
        await sourceGate.resume(sourcePoint)

        let firstValue = try await first.value
        let secondValue = try await second.value
        #expect(firstValue == nil)
        #expect(secondValue == nil)

        // Nil completion is not cached; the next request creates a new flight.
        let next = try await service.thumbnail(
            for: Self.reference,
            pixels: pixels,
            loadSource: {
                _ = await probe.recordSourceLoad()
                return png
            },
            validateJoin: {
                await probe.recordJoinValidation()
            }
        )
        #expect(next != nil)
        let counts = await probe.counts()
        #expect(counts.sourceLoads == 2)
        #expect(counts.joinValidations == 1)
    }

    @Test func concurrentIdenticalCallsShareFailureAndRemoveTheFlight() async throws {
        let png = try #require(Data(base64Encoded: Self.png1x1TransparentBase64))
        let service = ThumbnailService()
        let probe = ThumbnailFlightProbe()
        let sourceGate = SuspensionGate()
        let validationGate = SuspensionGate()
        let sourcePoint = "thumbnail-source-flight.failure-source"
        let validationPoint = "thumbnail-source-flight.failure-validation"
        let pixels = PixelSize(width: 32, height: 32)

        let first = Task { () -> ThumbnailPayload? in
            try await service.thumbnail(
                for: Self.reference,
                pixels: pixels,
                loadSource: { () async throws -> Data? in
                    _ = await probe.recordSourceLoad()
                    await sourceGate.park(at: sourcePoint)
                    throw ThumbnailFlightProbeFailure.source
                },
                validateJoin: {
                    await probe.recordJoinValidation()
                }
            )
        }
        await sourceGate.waitForPark(sourcePoint)

        let second = Task { () -> ThumbnailPayload? in
            try await service.thumbnail(
                for: Self.reference,
                pixels: pixels,
                loadSource: {
                    _ = await probe.recordSourceLoad()
                    return png
                },
                validateJoin: {
                    await probe.recordJoinValidation()
                    await validationGate.park(at: validationPoint)
                }
            )
        }
        await validationGate.waitForPark(validationPoint)
        await validationGate.resume(validationPoint)
        await sourceGate.resume(sourcePoint)

        await #expect(throws: ThumbnailFlightProbeFailure.source) {
            try await first.value
        }
        await #expect(throws: ThumbnailFlightProbeFailure.source) {
            try await second.value
        }

        // Failure completion is not cached; the next request creates a fresh
        // source-to-decode task and succeeds.
        let next = try await service.thumbnail(
            for: Self.reference,
            pixels: pixels,
            loadSource: {
                _ = await probe.recordSourceLoad()
                return png
            },
            validateJoin: {
                await probe.recordJoinValidation()
            }
        )
        #expect(next != nil)
        let counts = await probe.counts()
        #expect(counts.sourceLoads == 2)
        #expect(counts.joinValidations == 1)
    }
}
