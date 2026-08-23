/// Card 10C's neutral Presentation contract. No ServiceManagement value or
/// error crosses this target boundary.
import PresentationUI
import Testing

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
}
