/// PreviewDividerGeometryTests — the pure preview-divider interaction
/// vocabulary (V2-07 §3/§9): the placement-signed raw drag width, the
/// drag-to-collapse verdict (a raw end or fling predicted end below the
/// 200 threshold), the ±8 pt magnetic snap stops, the closed-pane edge
/// pull's inward distance, and the footer's context-keyed shortcut-hint
/// literals. The view-side wiring (hit strips, badge, overlay placement)
/// is not provable here; these tests pin the decision math the gestures
/// delegate to.
import Foundation
@testable import PresentationUI
import Testing

struct PreviewDividerGeometryTests {

    @Test func interactionConstantsStayPinned() {
        #expect(PanelGeometry.previewCollapseThreshold == 200)
        #expect(PanelGeometry.previewDragVisualFloor == 160)
        // The collapse affordance band lives strictly below the persisted
        // floor: nothing the live drag renders below the threshold can
        // become a settled or persisted width.
        #expect(
            PanelGeometry.previewDragVisualFloor
                < PanelGeometry.previewCollapseThreshold
        )
        #expect(
            PanelGeometry.previewCollapseThreshold
                < PanelGeometry.minimumPreviewColumnWidth
        )
        #expect(PanelGeometry.previewSnapStops == [280, 320, 400])
        #expect(PanelGeometry.previewSnapTolerance == 8)
        #expect(PanelGeometry.previewEdgeOpenerWidth == 6)
        #expect(PanelGeometry.previewEdgeOpenDistance == 48)
    }

    @Test func rawDragWidthAppliesThePlacementSign() {
        // Trailing: a rightward drag narrows, a leftward drag widens.
        #expect(PanelGeometry.rawPreviewDragWidth(
            startWidth: 320,
            translation: 40,
            placement: .trailing
        ) == 280)
        #expect(PanelGeometry.rawPreviewDragWidth(
            startWidth: 320,
            translation: -40,
            placement: .trailing
        ) == 360)
        // Leading: the mirror.
        #expect(PanelGeometry.rawPreviewDragWidth(
            startWidth: 320,
            translation: 40,
            placement: .leading
        ) == 360)
        #expect(PanelGeometry.rawPreviewDragWidth(
            startWidth: 320,
            translation: -40,
            placement: .leading
        ) == 280)
    }

    @Test func rawEndBelowTheThresholdCollapses() {
        // Trailing: 320 - 130 = 190 < 200.
        #expect(PanelGeometry.previewDragOutcome(
            startWidth: 320,
            translation: 130,
            predictedEndTranslation: 130,
            placement: .trailing
        ) == .collapse)
        // Leading: 320 - 130 = 190 < 200 through the mirrored sign.
        #expect(PanelGeometry.previewDragOutcome(
            startWidth: 320,
            translation: -130,
            predictedEndTranslation: -130,
            placement: .leading
        ) == .collapse)
    }

    @Test func flingBelowTheThresholdCollapsesWhenTheEndIsAbove() {
        // Released at a settle (320 - 80 = 240) but flicked: the raw
        // predicted end 320 - 160 = 160 is below the threshold.
        #expect(PanelGeometry.previewDragOutcome(
            startWidth: 320,
            translation: 80,
            predictedEndTranslation: 160,
            placement: .trailing
        ) == .collapse)
        #expect(PanelGeometry.previewDragOutcome(
            startWidth: 320,
            translation: -80,
            predictedEndTranslation: -160,
            placement: .leading
        ) == .collapse)
    }

    @Test func endAtOrAboveTheThresholdSettles() {
        // Exactly 200 settles: the threshold is exclusive.
        #expect(PanelGeometry.previewDragOutcome(
            startWidth: 320,
            translation: 120,
            predictedEndTranslation: 120,
            placement: .trailing
        ) == .settle)
        // A predicted end exactly at the threshold settles as well.
        #expect(PanelGeometry.previewDragOutcome(
            startWidth: 320,
            translation: 100,
            predictedEndTranslation: 120,
            placement: .trailing
        ) == .settle)
        // A widening drag with a huge outward fling stays a settle.
        #expect(PanelGeometry.previewDragOutcome(
            startWidth: 320,
            translation: -100,
            predictedEndTranslation: -400,
            placement: .trailing
        ) == .settle)
    }

    @Test func theCollapseDecisionUsesThePlacementSign() {
        // The same leftward 130-point drag: trailing widens (450) and
        // settles; leading narrows (190) and collapses.
        #expect(PanelGeometry.previewDragOutcome(
            startWidth: 320,
            translation: -130,
            predictedEndTranslation: -130,
            placement: .trailing
        ) == .settle)
        #expect(PanelGeometry.previewDragOutcome(
            startWidth: 320,
            translation: -130,
            predictedEndTranslation: -130,
            placement: .leading
        ) == .collapse)
    }

    @Test func snapHitsEveryStopInsideTheTolerance() {
        let stops: [CGFloat] = [280, 320, 400]
        for stop in stops {
            #expect(PanelGeometry.snappedPreviewColumnWidth(stop) == stop)
            #expect(PanelGeometry.snappedPreviewColumnWidth(stop - 8) == stop)
            #expect(PanelGeometry.snappedPreviewColumnWidth(stop + 8) == stop)
        }
    }

    @Test func snapLeavesWidthsOutsideTheToleranceUntouched() {
        #expect(PanelGeometry.snappedPreviewColumnWidth(271) == 271)
        #expect(PanelGeometry.snappedPreviewColumnWidth(289) == 289)
        #expect(PanelGeometry.snappedPreviewColumnWidth(342) == 342)
        // The hard bounds are not stops and never move.
        #expect(PanelGeometry.snappedPreviewColumnWidth(240) == 240)
        #expect(PanelGeometry.snappedPreviewColumnWidth(480) == 480)
    }

    @Test func edgePullOpensOnlyPastTheInwardDistance() {
        // Trailing edge: a LEFTWARD (negative) pull is inward.
        #expect(PanelGeometry.previewEdgeDragOpens(
            translation: -48,
            placement: .trailing
        ))
        #expect(PanelGeometry.previewEdgeDragOpens(
            translation: -120,
            placement: .trailing
        ))
        #expect(!PanelGeometry.previewEdgeDragOpens(
            translation: -47,
            placement: .trailing
        ))
        // Clicks and outward drags never open.
        #expect(!PanelGeometry.previewEdgeDragOpens(
            translation: 0,
            placement: .trailing
        ))
        #expect(!PanelGeometry.previewEdgeDragOpens(
            translation: 80,
            placement: .trailing
        ))
        // The leading edge mirrors the sign.
        #expect(PanelGeometry.previewEdgeDragOpens(
            translation: 48,
            placement: .leading
        ))
        #expect(!PanelGeometry.previewEdgeDragOpens(
            translation: -120,
            placement: .leading
        ))
    }

    @Test func footerHintsFollowTheSearchContext() throws {
        let url = try #require(PanelFooterCopy.bundle.url(
            forResource: "en", withExtension: "lproj"
        ))
        let english = try #require(Bundle(url: url))
        #expect(
            PanelFooterShortcutHints.text(isSearchActive: true, bundle: english)
                == "↑↓ Select · Esc Clear"
        )
        #expect(
            PanelFooterShortcutHints.text(isSearchActive: false, bundle: english)
                == "⏎ Paste · Space Quick Look · ⌘I Details"
        )
    }
}
