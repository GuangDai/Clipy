import Foundation
import Testing
@testable import ClipyApp

/// Explicit line choices continue to override density after removing width modes.
struct HistoryRowLayoutTests {
    @Test("automatic resolves through density; explicit settings override it")
    func automaticReproducesTheRetiredDensityMapping() {
        // The automatic rule IS the shipped `PanelTheme.snippetLineLimit`
        // mapping: compact 1, comfortable 2.
        #expect(
            HistorySnippetLineCount.automatic.baseLineLimit(
                density: .compact
            ) == 1
        )
        #expect(
            HistorySnippetLineCount.automatic.baseLineLimit(
                density: .comfortable
            ) == 2
        )
        // An explicit setting carries its literal count at either density.
        for density in HistoryRowDensity.allCases {
            #expect(
                HistorySnippetLineCount.one.baseLineLimit(density: density) == 1
            )
            #expect(
                HistorySnippetLineCount.two.baseLineLimit(density: density) == 2
            )
            #expect(
                HistorySnippetLineCount.three.baseLineLimit(density: density) == 3
            )
        }
        // CaseIterable order is the Settings picker's segment order:
        // Auto first.
        #expect(
            HistorySnippetLineCount.allCases == [.automatic, .one, .two, .three]
        )
    }

    @Test("text rows keep the 20/28pt slot; image rows get 44/56pt")
    func densityRowMetrics() {
        #expect(PanelTheme.thumbnailSize(for: .compact) == 20)
        #expect(PanelTheme.thumbnailSize(for: .comfortable) == 28)
        #expect(PanelTheme.imageThumbnailHeight(for: .compact) == 44)
        #expect(PanelTheme.imageThumbnailHeight(for: .comfortable) == 56)
        // The taller image slot adds no vertical padding beyond density.
        #expect(PanelTheme.rowVerticalPadding(for: .compact) == 2)
        #expect(PanelTheme.rowVerticalPadding(for: .comfortable) == 4)
    }

}
