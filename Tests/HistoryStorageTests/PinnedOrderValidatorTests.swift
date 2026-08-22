/// Pure-value coverage for the shared D12 pinned-order permutation proof.
/// docs/02-domain.md §3.2, D12; docs/05-authority-kernel.md §7.2, §10,
/// §13 step 10.
import Testing
@testable import HistoryStorage

struct PinnedOrderValidatorTests {
    private struct Entry {
        let name: String
        let ordinal: Int
    }

    @Test func emptyAndSingletonOrdersAreValid() {
        #expect(PinnedOrderValidator.sourceOffsetsByOrdinal(
            in: [Int](),
            ordinal: { $0 }
        ) == [])
        #expect(PinnedOrderValidator.sourceOffsetsByOrdinal(
            in: [0],
            ordinal: { $0 }
        ) == [0])
    }

    @Test func arbitraryPermutationReturnsSourceOffsetsInOrdinalOrder() {
        let entries = [
            Entry(name: "third", ordinal: 2),
            Entry(name: "first", ordinal: 0),
            Entry(name: "second", ordinal: 1),
        ]

        let sourceOffsets = PinnedOrderValidator.sourceOffsetsByOrdinal(
            in: entries,
            ordinal: { $0.ordinal }
        )

        #expect(sourceOffsets == [1, 2, 0])
        #expect(sourceOffsets?.map { entries[$0].name } == [
            "first",
            "second",
            "third",
        ])
    }

    @Test func invalidOrdinalSetsFailClosed() {
        let invalidSets = [
            [-1],
            [1],
            [Int.max],
            [0, 0],
            [0, 2],
            [0, 2, 2],
        ]

        for ordinals in invalidSets {
            #expect(PinnedOrderValidator.sourceOffsetsByOrdinal(
                in: ordinals,
                ordinal: { $0 }
            ) == nil)
        }
    }

    @Test func hardCapPermutationRemainsLinearAndComplete() throws {
        let ordinals = Array((0..<5_000).reversed())
        let sourceOffsets = try #require(
            PinnedOrderValidator.sourceOffsetsByOrdinal(
                in: ordinals,
                ordinal: { $0 }
            )
        )

        #expect(sourceOffsets.count == 5_000)
        #expect(sourceOffsets.first == 4_999)
        #expect(sourceOffsets.last == 0)
    }
}
