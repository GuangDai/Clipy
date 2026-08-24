/// Card 10C's neutral Presentation contract. No ServiceManagement value or
/// error crosses this target boundary.
import PresentationUI
import Testing

@MainActor
private final class LaunchAtLoginIntentRecorder {
    var requestedEnabledValues: [Bool] = []
    var openSystemSettingsCount = 0
}

@Suite("Launch-at-login settings presentation")
struct LaunchAtLoginSettingsTests {
    @Test("the four authoritative states remain visually distinct")
    func authoritativeStatesRemainDistinct() {
        let cases: [(
            LaunchAtLoginState,
            isOn: Bool,
            canToggle: Bool,
            canOpenSystemSettings: Bool
        )] = [
            (.off, false, true, false),
            (.on, true, true, false),
            (.requiresApproval, true, true, true),
            (.unavailable, false, false, false),
        ]

        for (state, isOn, canToggle, canOpenSystemSettings) in cases {
            let value = LaunchAtLoginSettings(state: state)
            #expect(value.isOn == isOn)
            #expect(value.canToggle == canToggle)
            #expect(value.canOpenSystemSettings == canOpenSystemSettings)
            #expect(!value.operationFailed)
        }
    }

    @Test("operation failure is content-free and preserves authoritative state")
    func operationFailurePreservesState() {
        let value = LaunchAtLoginSettings(
            state: .requiresApproval,
            operationFailed: true
        )

        #expect(value.state == .requiresApproval)
        #expect(value.isOn)
        #expect(value.canOpenSystemSettings)
        #expect(value.operationFailed)
    }

    @Test("approval remains on while exposing unregister and recovery intents")
    @MainActor
    func approvalStateForwardsBothRecoveryIntents() {
        let recorder = LaunchAtLoginIntentRecorder()
        let value = LaunchAtLoginSettings(
            state: .requiresApproval,
            setEnabled: { recorder.requestedEnabledValues.append($0) },
            openSystemSettings: { recorder.openSystemSettingsCount += 1 }
        )

        value.setEnabled(false)
        value.openSystemSettings()

        #expect(value.isOn)
        #expect(recorder.requestedEnabledValues == [false])
        #expect(recorder.openSystemSettingsCount == 1)
    }

    @Test("only approval state can invoke the System Settings recovery intent")
    @MainActor
    func recoveryIntentFailsClosedOutsideApproval() {
        let recorder = LaunchAtLoginIntentRecorder()

        for state in [
            LaunchAtLoginState.off,
            .on,
            .unavailable,
        ] {
            let value = LaunchAtLoginSettings(
                state: state,
                openSystemSettings: {
                    recorder.openSystemSettingsCount += 1
                }
            )
            value.openSystemSettings()
        }

        #expect(recorder.openSystemSettingsCount == 0)
    }
}
