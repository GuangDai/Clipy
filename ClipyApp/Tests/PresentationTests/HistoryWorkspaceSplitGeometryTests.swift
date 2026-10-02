import Testing
@testable import ClipyApp

@Suite("Settings history split layout")
struct HistoryWorkspaceSplitGeometryTests {
    @Test func preferredListWidthLeavesTheRemainingWidthForPreview() {
        let layout = HistoryWorkspaceSplitGeometry(preferredListWidth: 350, availableWidth: 1_000)
        #expect(layout.listWidth == 350)
        #expect(layout.dividerWidth == 8)
        #expect(layout.previewWidth == 642)
    }

    @Test func eachColumnKeepsItsMinimumWhenTheWindowHasEnoughSpace() {
        let narrowList = HistoryWorkspaceSplitGeometry(preferredListWidth: 100, availableWidth: 1_000)
        #expect(narrowList.listWidth == 260)
        #expect(narrowList.previewWidth == 732)
        let narrowPreview = HistoryWorkspaceSplitGeometry(preferredListWidth: 950, availableWidth: 1_000)
        #expect(narrowPreview.listWidth == 732)
        #expect(narrowPreview.previewWidth == 260)
        let exactMinimum = HistoryWorkspaceSplitGeometry(preferredListWidth: 350, availableWidth: 528)
        #expect(exactMinimum.listWidth == 260)
        #expect(exactMinimum.previewWidth == 260)
    }

    @Test func aNarrowWindowSharesTheAvailableContentWidthWithoutOverflowing() {
        let layout = HistoryWorkspaceSplitGeometry(preferredListWidth: 700, availableWidth: 500)
        #expect(layout.listWidth == 246)
        #expect(layout.previewWidth == 246)
        #expect(layout.listWidth + layout.dividerWidth + layout.previewWidth == 500)
        let collapsed = HistoryWorkspaceSplitGeometry(preferredListWidth: 350, availableWidth: 5)
        #expect(collapsed.listWidth == 0)
        #expect(collapsed.previewWidth == 0)
        #expect(collapsed.dividerWidth == 5)
    }

    @Test func wideningTheWindowRestoresTheUsersPreferredWidth() {
        let preferred = 700.0
        let constrained = HistoryWorkspaceSplitGeometry(preferredListWidth: preferred, availableWidth: 800)
        #expect(constrained.listWidth == 532)
        let restored = HistoryWorkspaceSplitGeometry(preferredListWidth: preferred, availableWidth: 1_200)
        #expect(restored.listWidth == preferred)
        #expect(restored.previewWidth == 492)
    }

    @Test func fractionalWidthsRemainExactAndDoNotAccumulateLayoutRounding() {
        let layout = HistoryWorkspaceSplitGeometry(preferredListWidth: 360.25, availableWidth: 900.5)
        #expect(layout.listWidth == 360.25)
        #expect(layout.previewWidth == 532.25)
        #expect(layout.listWidth + layout.dividerWidth + layout.previewWidth == 900.5)
    }

    @Test func unavailableOrDamagedDimensionsNeverProduceNegativeOrNonfiniteFrames() {
        for available in [0.0, -20, .infinity, .nan] {
            let layout = HistoryWorkspaceSplitGeometry(preferredListWidth: 350, availableWidth: available)
            #expect(layout.listWidth == 0)
            #expect(layout.previewWidth == 0)
            #expect(layout.dividerWidth == 0)
        }
        for preferred in [Double.infinity, .nan] {
            let layout = HistoryWorkspaceSplitGeometry(preferredListWidth: preferred, availableWidth: 800)
            #expect(layout.listWidth == 260)
            #expect(layout.previewWidth == 532)
        }
    }
}
