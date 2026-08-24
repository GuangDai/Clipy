/// Card 9B's Presentation entry for one externally committed removal. The
/// app-owned ingress calls this only after the real Gateway returns a positive
/// result; the existing surface owner consumes the resulting exact purge.
import Foundation
import HistoryCore
import PresentationUI
import Testing

@MainActor
struct ExternalRemovalSurfacePurgeTests {
    @Test func committedExternalRemovalPublishesOneExactSurfacePurge() throws {
        let history = ScriptedHistory()
        let state = HistoryViewState(history: history)
        let removedID = HistoryItemID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-0000000033B1"
            )!
        )

        state.acceptCommittedExternalRemoval(removedID)

        let purge = try #require(state.surfacePurge)
        #expect(purge.generation == 1)
        #expect(purge.scope == .item(removedID))
    }
}
