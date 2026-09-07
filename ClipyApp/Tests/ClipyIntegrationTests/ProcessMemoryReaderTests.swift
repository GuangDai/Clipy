import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import ClipyApp

@Suite("Maintenance process memory")
struct ProcessMemoryReaderTests {
    @Test("real kernel memory readings leave History content and position unchanged")
    @MainActor
    func kernelReadIsIndependentOfLogicalContent() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        _ = try await history.perform(.capture(ComposedSupport.textCapture(
            "memory-fact", observedAt: Date(), source: "com.example.maintenance"
        )))
        let before = try await history.usage()
        #expect(before.totalContentBytes == 11)
        let reader = ProcessMemoryReader()
        let first = try await reader.read()
        #expect(first.residentBytes > before.totalContentBytes)
        #expect(first.footprintBytes > before.totalContentBytes)
        #expect(first.peakResidentBytes >= first.residentBytes)

        // Both queries reach the real kernel. No fixed RSS value or monotone
        // current usage is assumed while hosted suites run concurrently.
        let second = try await reader.read()
        #expect(second.residentBytes > 0)
        #expect(second.footprintBytes > 0)
        #expect(second.peakResidentBytes >= second.residentBytes)
        #expect(second.peakResidentBytes >= first.peakResidentBytes)
        #expect(try await history.usage() == before)
    }
}
