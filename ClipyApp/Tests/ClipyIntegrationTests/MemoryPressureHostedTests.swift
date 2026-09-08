import Dispatch
import HistoryCore
import PasteboardAdapter
import Testing
@testable import ClipyApp

@MainActor
struct MemoryPressureHostedTests {
    /// Real libdispatch registration/cancellation delivery without consuming
    /// RAM or pressuring the runner's other apps. Apple's memory-pressure
    /// source has no synthetic-data API: this is wiring evidence, not a claim
    /// that CI generated a real system pressure transition.
    @Test func realDispatchSourceRegistersOnceAndCancelsOnItsMainQueue() async throws {
        let owner = AppDelegate()
        owner.installMemoryPressureObservation()
        owner.installMemoryPressureObservation()
        defer { owner.removeMemoryPressureObservation() }
        try #require(await ComposedSupport.waitFor {
            owner.memoryPressureRegistrationCountForTesting == 1
        })
        let source = try #require(owner.memoryPressureSource)
        #expect(source.mask == [.normal, .warning, .critical])
        #expect(!source.isCancelled)
        owner.removeMemoryPressureObservation()
        try #require(await ComposedSupport.waitFor {
            owner.memoryPressureCancellationCountForTesting == 1
        })
        #expect(source.isCancelled)
        #expect(owner.memoryPressureSource == nil)
        owner.installMemoryPressureObservation()
        try #require(await ComposedSupport.waitFor {
            owner.memoryPressureRegistrationCountForTesting == 2
        })
    }

    @Test func pressureBeforeCompositionOpenReachesTheSurfaceAndNeverChangesHistory() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let owner = AppDelegate()
        owner.receiveMemoryPressure([.normal, .critical])
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: ComposedSupport.makePasteboard())
        )
        defer { composition.stop() }
        owner.installCompositionForTesting(composition)
        let surface = try #require(owner.panelSurfaceState)
        #expect(surface.memoryPressure == .critical)
        owner.receiveMemoryPressure(.warning)
        #expect(surface.memoryPressure == .critical)
        owner.receiveMemoryPressure(.normal)
        #expect(surface.memoryPressure == .normal)
        owner.receiveMemoryPressure(.warning)
        #expect(surface.memoryPressure == .warning)
        #expect(!surface.isSessionActive)
        #expect(surface.sessionGeneration == 0)
        #expect(surface.appliedPurgeGeneration == 0)
        #expect(try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10)).rows.isEmpty)
    }
}
