/// DEBUG-only parsing proofs for the running-app launch envelope. These
/// tests pin only the supported privacy facts and one recovery transition;
/// the product graph and its production capture-access reducer stay intact.
import Foundation
import PasteboardAdapter
import Testing
@testable import ClipyApp

@Suite("Running UI test capture-access configuration")
struct RunningUITestCaptureAccessConfigurationTests {
    @Test("access launch inputs keep their initial and recovery states distinct")
    func selectsAccessPosturesAndRejectsUnknownSpellings() throws {
        let cases: [(String?, PasteboardAccessBehavior, PasteboardAccessBehavior)] = [
            (nil, .allowed, .allowed),
            ("allowed", .allowed, .allowed),
            ("denied", .denied, .denied),
            ("denied-then-allowed", .denied, .allowed),
            ("system-default", .systemDefault, .systemDefault),
            ("system-default-then-allowed", .systemDefault, .allowed),
            ("ask", .ask, .ask),
            ("ask-then-allowed", .ask, .allowed),
            ("read-failure", .unavailable, .unavailable),
            ("read-failure-then-allowed", .unavailable, .allowed),
        ]
        for (value, initial, current) in cases {
            var environment = [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH": "/tmp/clipy-ui-access.store",
            ]
            if let value { environment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = value }
            let configuration = try #require(RunningUITestConfiguration.current(environment: environment))
            #expect(configuration.initialCaptureAccessBehavior == initial)
            #expect(configuration.currentCaptureAccessBehavior == current)
            if value == nil {
                #expect(configuration.capturePauseDuration == CapturePausePolicy.standardDuration)
            }
        }
        for value in ["Denied", "unavailable"] {
            #expect(RunningUITestConfiguration.current(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH": "/tmp/clipy-ui-invalid.store",
                "CLIPY_UI_TEST_CAPTURE_ACCESS": value,
            ]) == nil)
        }
    }

    @Test("running UI tests accept only the exact short-Pause switch")
    func selectsShortPauseExactly() throws {
        let configuration = try #require(
            RunningUITestConfiguration.current(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH": "/tmp/clipy-ui-pause.store",
                "CLIPY_UI_TEST_SHORT_PAUSE": "1",
            ])
        )

        #expect(
            configuration.capturePauseDuration
                == CapturePausePolicy.runningUITestDuration
        )
        #expect(
            RunningUITestConfiguration.current(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH": "/tmp/clipy-ui-pause-invalid.store",
                "CLIPY_UI_TEST_SHORT_PAUSE": "true",
            ]) == nil
        )
    }

    @Test("running UI tests admit only the one-shot Preview failure")
    func selectsPreviewFailureExactly() {
        #expect(
            RunningUITestConfiguration.current(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH": "/tmp/clipy-ui-preview.store",
                "CLIPY_UI_TEST_PREVIEW_FAILURE": "transient-details-once",
            ]) != nil
        )
        #expect(
            RunningUITestConfiguration.current(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH": "/tmp/clipy-ui-preview-invalid.store",
                "CLIPY_UI_TEST_PREVIEW_FAILURE": "always-fail",
            ]) == nil
        )
    }

    @Test("running UI tests admit only the bounded editor stale journey")
    func selectsEditorJourneyExactly() throws {
        let configuration = try #require(
            RunningUITestConfiguration.current(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH": "/tmp/clipy-ui-editor.store",
                "CLIPY_UI_TEST_EDITOR_JOURNEY":
                    "stale-reload-failure-once",
            ])
        )
        #expect(
            configuration.editorJourney == .staleThenReloadFailureOnce
        )
        #expect(
            RunningUITestConfiguration.current(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH":
                    "/tmp/clipy-ui-editor-invalid.store",
                "CLIPY_UI_TEST_EDITOR_JOURNEY": "always-stale",
            ]) == nil
        )
    }
}
