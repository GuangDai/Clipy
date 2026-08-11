/// Source-inclusive thumbnail single-flight proofs. The production service
/// receives source/validation operations from the facade; these tests freeze
/// the deep seam directly so duplicate source hydration cannot hide behind a
/// successful shared ImageIO decode. docs/04-coherence.md §9;
/// V1-Verified `thumbnail-source-full-image-copy`.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

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
        let finalCounts = await probe.counts()
        #expect(finalCounts.sourceLoads == 1)
        #expect(finalCounts.joinValidations == 1)
    }
}
