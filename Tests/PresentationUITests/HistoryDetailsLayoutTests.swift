/// HistoryDetailsLayoutTests — threshold proofs for the Details surface's
/// pure two-column width branch (`DetailsLayout`).
import Foundation
import PresentationUI
import Testing

struct HistoryDetailsLayoutTests {

    /// Below the threshold the loaded Details surface keeps the original
    /// single-column Form.
    @Test func widthsBelowTheThresholdKeepTheSingleColumnForm() {
        #expect(!DetailsLayout.usesTwoColumnLayout(width: 0))
        #expect(!DetailsLayout.usesTwoColumnLayout(width: 359.5))
        #expect(!DetailsLayout.usesTwoColumnLayout(width: 639))
        #expect(!DetailsLayout.usesTwoColumnLayout(width: 639.5))
    }

    /// The threshold itself engages the two-column metadata/content layout.
    @Test func widthsAtOrAboveTheThresholdUseTheTwoColumnLayout() {
        #expect(DetailsLayout.usesTwoColumnLayout(width: 640))
        #expect(DetailsLayout.usesTwoColumnLayout(width: 640.5))
        #expect(DetailsLayout.usesTwoColumnLayout(width: 720))
    }

    /// The threshold must sit inside the browsing column's resizable range:
    /// at or below the minimum the wide layout would engage for every
    /// resizable width, and above the maximum it could never engage at all.
    @Test func thresholdStaysInsideTheResizableBrowsingColumnRange() {
        #expect(
            DetailsLayout.twoColumnMinimumWidth
                > PanelGeometry.minimumContentWidth
        )
        #expect(
            DetailsLayout.twoColumnMinimumWidth
                <= PanelGeometry.maximumContentWidth
        )
    }
}
