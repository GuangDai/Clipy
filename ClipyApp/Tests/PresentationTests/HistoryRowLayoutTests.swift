import Foundation
import Testing
@testable import ClipyApp

/// Explicit line choices continue to override density after removing width modes.
struct HistoryRowLayoutTests {
    @Test("automatic resolves through density; explicit settings override it")
    func automaticReproducesTheRetiredDensityMapping() throws {
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
        let custom = try #require(HistorySnippetLineCount(rawValue: "5"))
        for density in HistoryRowDensity.allCases {
            #expect(custom.baseLineLimit(density: density) == 5)
        }
    }

    @Test("fractional font points and custom lines size the actual row")
    func customTypographySizesRows() throws {
        let font = try #require(HistoryRowFontSize(rawValue: "17.5"))
        let lines = try #require(HistorySnippetLineCount(rawValue: "5"))
        let row = PanelContentFit.RowDescriptor(
            isImageRow: false,
            titleLineCount: lines.baseLineLimit(density: .compact),
            snippetLineCount: 0
        )
        #expect(font.points == 17.5)
        #expect(PanelContentFit.titleLineHeight(for: font) == 21)
        #expect(PanelContentFit.rowHeight(row, density: .compact, fontSize: font) == 113)
    }

    @Test("text rows use a 16/24pt slot; image rows get 44/56pt")
    func densityRowMetrics() {
        #expect(PanelTheme.thumbnailSize(for: .compact) == 16)
        #expect(PanelTheme.thumbnailSize(for: .comfortable) == 24)
        #expect(PanelTheme.imageThumbnailHeight(for: .compact) == 44)
        #expect(PanelTheme.imageThumbnailHeight(for: .comfortable) == 56)
        // The taller image slot adds no vertical padding beyond density.
        #expect(PanelTheme.rowVerticalPadding(for: .compact) == 2)
        #expect(PanelTheme.rowVerticalPadding(for: .comfortable) == 4)
    }

}
