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

}
