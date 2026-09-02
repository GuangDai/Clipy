/// HistoryRowLayoutTests — the pure wide-presentation rules behind the
/// browsing column's row breathing: the inclusive 560pt width threshold and
/// the effective summary/snippet line count. The base is the setting
/// resolved against the row density (`.automatic` reproduces the retired
/// density mapping: compact 1, comfortable 2); wide presentation adds one
/// line, hard capped at three.
import Foundation
import PresentationUI
import Testing

@Suite("History row layout rules")
struct HistoryRowLayoutTests {
    @Test("wide presentation starts at exactly 560pt")
    func widePresentationThresholdIsInclusive() {
        #expect(!HistoryRowLayout.usesWidePresentation(width: 0))
        #expect(!HistoryRowLayout.usesWidePresentation(width: 359))
        #expect(!HistoryRowLayout.usesWidePresentation(width: 559))
        #expect(!HistoryRowLayout.usesWidePresentation(width: 559.9))
        #expect(HistoryRowLayout.usesWidePresentation(width: 560))
        #expect(HistoryRowLayout.usesWidePresentation(width: 560.1))
        #expect(HistoryRowLayout.usesWidePresentation(width: 720))
        #expect(HistoryRowLayout.widePresentationMinimumWidth == 560)
    }

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

    @Test("below the wide threshold the effective line count is the resolved base")
    func narrowPresentationKeepsTheResolvedBaseCount() {
        // Automatic: the shipped narrow 1 (compact) / 2 (comfortable).
        #expect(
            HistoryRowLayout.effectiveSnippetLineLimit(
                setting: .automatic,
                density: .compact,
                isWide: false
            ) == 1
        )
        #expect(
            HistoryRowLayout.effectiveSnippetLineLimit(
                setting: .automatic,
                density: .comfortable,
                isWide: false
            ) == 2
        )
        // Explicit: the literal count at either density.
        for density in HistoryRowDensity.allCases {
            #expect(
                HistoryRowLayout.effectiveSnippetLineLimit(
                    setting: .one,
                    density: density,
                    isWide: false
                ) == 1
            )
            #expect(
                HistoryRowLayout.effectiveSnippetLineLimit(
                    setting: .two,
                    density: density,
                    isWide: false
                ) == 2
            )
            #expect(
                HistoryRowLayout.effectiveSnippetLineLimit(
                    setting: .three,
                    density: density,
                    isWide: false
                ) == 3
            )
        }
    }

    @Test("wide presentation adds one line, hard capped at three")
    func widePresentationAddsOneLineCappedAtThree() {
        // Automatic: compact 1→2, comfortable 2→3 — the spec'd
        // narrow-2/wide-3 default pair at the shipped density.
        #expect(
            HistoryRowLayout.effectiveSnippetLineLimit(
                setting: .automatic,
                density: .compact,
                isWide: true
            ) == 2
        )
        #expect(
            HistoryRowLayout.effectiveSnippetLineLimit(
                setting: .automatic,
                density: .comfortable,
                isWide: true
            ) == 3
        )
        // Explicit: a user choosing 1 is never overridden to 3; 3 caps.
        #expect(
            HistoryRowLayout.effectiveSnippetLineLimit(
                setting: .one,
                density: .comfortable,
                isWide: true
            ) == 2
        )
        #expect(
            HistoryRowLayout.effectiveSnippetLineLimit(
                setting: .two,
                density: .compact,
                isWide: true
            ) == 3
        )
        #expect(
            HistoryRowLayout.effectiveSnippetLineLimit(
                setting: .three,
                density: .comfortable,
                isWide: true
            ) == 3
        )
        #expect(
            HistoryRowLayout.effectiveSnippetLineLimit(
                setting: .three,
                density: .compact,
                isWide: true
            ) == 3
        )
    }
}
