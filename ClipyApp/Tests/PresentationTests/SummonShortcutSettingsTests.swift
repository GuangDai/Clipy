@testable import ClipyApp
import Testing

@MainActor
private final class SummonShortcutChangeIntentRecorder {
    var callCount = 0
}

@MainActor
struct SummonShortcutSettingsTests {
    @Test func disabledBindingCanBeChangedOrResetButCannotBeClearedAgain() {
        let recorder = SummonShortcutChangeIntentRecorder()
        let settings = SummonShortcutSettings(
            status: .disabled,
            beginChange: { recorder.callCount += 1 },
            reset: { recorder.callCount += 1 },
            clear: { recorder.callCount += 10 }
        )
        #expect(settings.canChange)
        #expect(settings.canReset)
        #expect(!settings.canClear)
        #expect(!settings.canRetry)
        settings.beginChange()
        settings.reset()
        settings.clear()
        #expect(recorder.callCount == 2)
    }

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
