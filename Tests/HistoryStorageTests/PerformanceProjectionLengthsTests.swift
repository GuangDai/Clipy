import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct PerformanceProjectionLengthsTests {
    @Test func frequenciesUseActualTruncatedUTF8BytesAndDoNotChangeHistory() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .temporary, initialMaximumUnpinnedItems: nil
        ))
        let empty = try await history.performanceProjectionLengths()
        #expect(empty.titleUTF8Bytes.isEmpty && empty.searchBodyUTF8Bytes.isEmpty)

        // A CJK scalar is three UTF-8 bytes. The 1,024-byte title and
        // 262,144-byte body limits retain complete characters: 1,023 and
        // 262,143 bytes, rather than the 300,000-byte source or scalar counts.
        for (index, text) in ["one", "two", String(repeating: "中", count: 100_000)].enumerated() {
            _ = try await history.perform(.capture(WSSupport.textCapture(
                text, observedAt: Date(timeIntervalSinceReferenceDate: Double(index))
            )))
        }
        let before = try await history.usage()
        let lengths = try await history.performanceProjectionLengths()
        #expect(lengths.titleUTF8Bytes == [3: 2, 1_023: 1])
        #expect(lengths.searchBodyUTF8Bytes == [3: 2, 262_143: 1])
        // Independent stored-byte reads establish the measured values are
        // the actual projections, without rerunning the projection algorithm.
        let persisted = try await history.authority.withTestDatabase { authority in
            let rows = try authority.database.prepare("SELECT titleUTF8, searchBodyUTF8 FROM history_items")
            defer { rows.finalize() }
            var title: [Int: Int] = [:]
            var body: [Int: Int] = [:]
            while try rows.step() {
                title[try rows.blob(at: 0).count, default: 0] += 1
                body[try rows.blob(at: 1).count, default: 0] += 1
            }
            return (title, body)
        }
        #expect(lengths.titleUTF8Bytes == persisted.0)
        #expect(lengths.searchBodyUTF8Bytes == persisted.1)
        let after = try await history.usage()
        #expect(after.position == before.position && after.itemCount == before.itemCount)
        #expect(after.canonicalBytes == before.canonicalBytes)
    }
}
