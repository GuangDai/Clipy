/// App-local bridge between committed mutation effects and the one real panel
/// surface. It is installed before the App Intents dependency can resolve;
/// absent surface means no derived panel state exists yet.
import HistoryCore
import PresentationUI

@MainActor
final class PanelSurfacePurgeRelay {
    private let viewState: HistoryViewState
    private var surface: HistoryPanelSurfaceState?

    init(viewState: HistoryViewState) {
        self.viewState = viewState
    }

    func install(_ surface: HistoryPanelSurfaceState) {
        self.surface = surface
    }

    func acceptCommittedExternalRemoval(_ itemID: HistoryItemID) {
        let purge = viewState.acceptCommittedExternalRemoval(itemID)
        surface?.apply(purge)
    }

    func apply(_ purge: HistorySurfacePurge) {
        surface?.apply(purge)
    }
}
