/// DEBUG-only parsing proofs for the running-app launch envelope. These
/// tests pin only the supported privacy facts and one recovery transition;
/// the product graph and its production capture-access reducer stay intact.
import Foundation
import PasteboardAdapter
import Testing
@testable import ClipyApp

@Suite("Running UI test capture-access configuration")
struct RunningUITestCaptureAccessConfigurationTests {
    @Test("running UI tests default to allowed capture access")
    func defaultsToAllowed() throws {
        let configuration = try #require(
            RunningUITestConfiguration.current(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH": "/tmp/clipy-ui-default.store",
            ])
        )

        #expect(configuration.initialCaptureAccessBehavior == .allowed)
        #expect(configuration.currentCaptureAccessBehavior == .allowed)
        #expect(
            configuration.capturePauseDuration
                == CapturePausePolicy.standardDuration
        )
        #expect(
            RunningUITestConfiguration.current(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH": "/tmp/clipy-ui-allowed.store",
                "CLIPY_UI_TEST_CAPTURE_ACCESS": "allowed",
            ])?.initialCaptureAccessBehavior == .allowed
        )
    }

    @Test("running UI tests accept an exact denied capture-access posture")
    func selectsDeniedExactly() throws {
        let configuration = try #require(
            RunningUITestConfiguration.current(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH": "/tmp/clipy-ui-denied.store",
                "CLIPY_UI_TEST_CAPTURE_ACCESS": "denied",
            ])
        )

        #expect(configuration.initialCaptureAccessBehavior == .denied)
        #expect(configuration.currentCaptureAccessBehavior == .denied)
        #expect(
            RunningUITestConfiguration.current(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH": "/tmp/clipy-ui-invalid.store",
                "CLIPY_UI_TEST_CAPTURE_ACCESS": "Denied",
            ]) == nil
        )
    }

    @Test("running UI tests can re-read allowed after an initial denial")
    func selectsDeniedThenAllowedRecoveryExactly() throws {
        let configuration = try #require(
            RunningUITestConfiguration.current(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH": "/tmp/clipy-ui-recovery.store",
                "CLIPY_UI_TEST_CAPTURE_ACCESS": "denied-then-allowed",
            ])
        )

        #expect(configuration.initialCaptureAccessBehavior == .denied)
        #expect(configuration.currentCaptureAccessBehavior == .allowed)
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
        #expect(configuration.capturePauseDuration == .seconds(8))
        #expect(
            RunningUITestConfiguration.current(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH": "/tmp/clipy-ui-pause-invalid.store",
                "CLIPY_UI_TEST_SHORT_PAUSE": "true",
            ]) == nil
        )
    }
}
