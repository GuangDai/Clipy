import HistoryCore
import Testing
@testable import PresentationUI

@MainActor
struct LocalAutomationCommandLineSettingsTests {
    @Test(arguments: [true, false])
    func explicitCommandLineActionsWorkWhileDisabledWithoutEnrollment(copySucceeds: Bool) async {
        var enrollmentCalls = 0
        var revealCalls = 0
        var copyCalls = 0
        let disabled = LocalAutomationSettingsState(enabled: false, grants: [])
        let model = LocalAutomationSettingsModel(settings: LocalAutomationSettings(
            load: { disabled },
            enable: { enrollmentCalls += 1; return disabled },
            revoke: { enrollmentCalls += 1; return disabled },
            setCapability: { _, _ in enrollmentCalls += 1; return disabled },
            commandLine: LocalAutomationCommandLine(
                executablePath: "/Applications/Clipy.app/Contents/MacOS/clipyctl",
                helpCommand: "'/Applications/Clipy.app/Contents/MacOS/clipyctl' --help",
                reveal: { revealCalls += 1 },
                copyHelpCommand: { copyCalls += 1; return copySucceeds }
            )
        ))
        await model.load()
        #expect(model.commandLine != nil)
        #expect(revealCalls == 0)
        #expect(copyCalls == 0)
        model.revealCommandLine()
        model.copyHelpCommand()
        #expect(revealCalls == 1)
        #expect(copyCalls == 1)
        #expect(enrollmentCalls == 0)
        #expect(model.state == disabled)
        #expect(!model.failed)
        #expect(model.commandLineNotice == (copySucceeds
            ? "Help command copied." : "Could not copy the help command. Try again."))
    }
}
