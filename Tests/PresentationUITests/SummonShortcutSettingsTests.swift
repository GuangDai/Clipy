import PresentationUI
import Testing

@MainActor
private final class SummonShortcutChangeIntentRecorder {
    var callCount = 0
}

@MainActor
struct SummonShortcutSettingsTests {
    @Test func stoppedSnapshotDoesNotBeginChange() {
        let recorder = SummonShortcutChangeIntentRecorder()
        let settings = SummonShortcutSettings(
            status: .stopped,
            beginChange: { recorder.callCount += 1 }
        )

        #expect(!settings.canChange)
        settings.beginChange()
        #expect(recorder.callCount == 0)
    }

    @Test func activeAndUnavailableSnapshotsCanBeginChange() {
        let recorder = SummonShortcutChangeIntentRecorder()
        let active = SummonShortcutSettings(
            status: .current("⇧⌘C"),
            beginChange: { recorder.callCount += 1 }
        )
        let unavailable = SummonShortcutSettings(
            status: .unavailable(
                requested: "Key code 40, modifiers 2304",
                retainedCurrent: "⇧⌘C"
            ),
            beginChange: { recorder.callCount += 1 }
        )

        #expect(active.canChange)
        #expect(unavailable.canChange)
        active.beginChange()
        unavailable.beginChange()
        #expect(recorder.callCount == 2)
    }
}
