/// Hosted Card 14B wiring proofs: AppDelegate, rather than a parallel raw
/// GlobalHotKey property, owns persisted startup selection, visible conflict
/// recovery, and exact termination cleanup. The injected registration closure
/// does not claim real Carbon delivery or signed-runtime conflict behavior.
import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import ClipyApp

@MainActor
struct AppDelegateSummonShortcutTests {
    private let alternate = HotKeyChord(
        keyCode: UInt32(kVK_ANSI_K),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    @Test func startupRegistersThePersistedChordInsteadOfTheDefault() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(encode(alternate), forKey: SummonShortcutController.defaultsKey)
        let probe = AppDelegateShortcutProbe()
        let appDelegate = makeAppDelegate(defaults: defaults, probe: probe)

        #expect(appDelegate.startSummonShortcut())
        #expect(probe.attemptChords == [alternate])
        #expect(
            appDelegate.summonShortcutPresentation.status
                == .current(alternate.settingsDisplayName)
        )
        #expect(appDelegate.summonShortcutPresentation.warning == nil)

        appDelegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
    }

    @Test func unavailableSavedChordIsVisibleWithoutDefaultFallback() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let saved = encode(alternate)
        defaults.set(saved, forKey: SummonShortcutController.defaultsKey)
        let probe = AppDelegateShortcutProbe()
        probe.failNext(alternate)
        let appDelegate = makeAppDelegate(defaults: defaults, probe: probe)

        #expect(!appDelegate.startSummonShortcut())
        #expect(probe.attemptChords == [alternate])
        #expect(
            appDelegate.summonShortcutPresentation.status
                == .unavailable(
                    requested: alternate.settingsDisplayName,
                    retainedCurrent: nil
                )
        )
        #expect(defaults.data(forKey: SummonShortcutController.defaultsKey) == saved)

        let settings = appDelegate.summonShortcutBinding()
        #expect(settings.canRetry)
        settings.retry()
        #expect(probe.attemptChords == [alternate, alternate])
        #expect(
            appDelegate.summonShortcutPresentation.status
                == .current(alternate.settingsDisplayName)
        )

        appDelegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
    }

    @Test func resetUsesControllerAndTerminationCleansTokenExactlyOnce() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(encode(alternate), forKey: SummonShortcutController.defaultsKey)
        let probe = AppDelegateShortcutProbe()
        let appDelegate = makeAppDelegate(defaults: defaults, probe: probe)

        #expect(appDelegate.startSummonShortcut())
        appDelegate.summonShortcutBinding().reset()
        #expect(probe.attemptChords == [alternate, .defaultSummon])
        #expect(probe.cleanupChords == [alternate])
        #expect(defaults.data(forKey: SummonShortcutController.defaultsKey) == nil)
        #expect(
            appDelegate.summonShortcutPresentation.status
                == .current("⇧⌘C")
        )
        #expect(
            appDelegate.summonShortcutPresentation.warning
                == .showColorsConflict
        )

        let termination = Notification(
            name: NSApplication.willTerminateNotification
        )
        appDelegate.applicationWillTerminate(termination)
        appDelegate.applicationWillTerminate(termination)
        #expect(probe.cleanupChords == [alternate, .defaultSummon])
        #expect(appDelegate.summonShortcutPresentation.status == .stopped)
    }

    @Test func failedRecordedChangeKeepsOldBindingAndPublishesRecovery() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = AppDelegateShortcutProbe()
        let appDelegate = makeAppDelegate(defaults: defaults, probe: probe)

        #expect(appDelegate.startSummonShortcut())
        probe.failNext(alternate)
        appDelegate.changeSummonShortcut(to: alternate)

        #expect(probe.attemptChords == [.defaultSummon, alternate])
        #expect(probe.cleanupChords.isEmpty)
        #expect(defaults.data(forKey: SummonShortcutController.defaultsKey) == nil)
        #expect(
            appDelegate.summonShortcutPresentation.status
                == .unavailable(
                    requested: alternate.settingsDisplayName,
                    retainedCurrent: HotKeyChord.defaultSummon.settingsDisplayName
                )
        )

        appDelegate.summonShortcutBinding().retry()
        #expect(probe.cleanupChords == [.defaultSummon])
        #expect(
            appDelegate.summonShortcutPresentation.status
                == .current(alternate.settingsDisplayName)
        )

        appDelegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
    }

    @Test func successfulRecordedChangePublishesAndPersistsTheCandidate() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = AppDelegateShortcutProbe()
        let appDelegate = makeAppDelegate(defaults: defaults, probe: probe)

        #expect(appDelegate.startSummonShortcut())
        appDelegate.changeSummonShortcut(to: alternate)

        #expect(probe.attemptChords == [.defaultSummon, alternate])
        #expect(probe.cleanupChords == [.defaultSummon])
        #expect(
            appDelegate.summonShortcutPresentation.status
                == .current(alternate.settingsDisplayName)
        )
        #expect(
            defaults.data(forKey: SummonShortcutController.defaultsKey)
                == encode(alternate)
        )

        appDelegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
    }

    @Test func changeIntentIsOwnedByTheSettingsPresentation() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = AppDelegateShortcutProbe()
        let appDelegate = makeAppDelegate(defaults: defaults, probe: probe)
        let intentProbe = AppDelegateShortcutIntentProbe()

        #expect(appDelegate.startSummonShortcut())
        let settings = appDelegate.summonShortcutBinding {
            intentProbe.beginChangeCount += 1
        }
        #expect(settings.canChange)
        settings.beginChange()
        #expect(intentProbe.beginChangeCount == 1)
        #expect(probe.attemptChords == [.defaultSummon])

        appDelegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
    }

    @Test func activeCarbonChordCompletesTheAppOwnedRecordingOnce() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = AppDelegateShortcutProbe()
        let appDelegate = makeAppDelegate(defaults: defaults, probe: probe)
        var recorded: [HotKeyChord] = []

        #expect(appDelegate.startSummonShortcut())
        appDelegate.beginSummonShortcutRecording { recorded.append($0) }
        #expect(probe.fire(.defaultSummon))
        #expect(recorded == [.defaultSummon])
        #expect(probe.attemptChords == [.defaultSummon])
        #expect(
            appDelegate.summonShortcutPresentation.status
                == .current(HotKeyChord.defaultSummon.settingsDisplayName)
        )

        appDelegate.endSummonShortcutRecording()
        appDelegate.endSummonShortcutRecording()
        appDelegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
    }

    private func makeAppDelegate(
        defaults: UserDefaults,
        probe: AppDelegateShortcutProbe
    ) -> AppDelegate {
        AppDelegate(
            accessibilityAnnouncementOperations: .live,
            summonShortcutDefaults: defaults,
            summonShortcutRegistrationFactory: { chord, id, action in
                probe.register(chord: chord, id: id, action: action)
            }
        )
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "AppDelegateSummonShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func encode(_ chord: HotKeyChord) -> Data {
        Data([
            UInt8(truncatingIfNeeded: chord.keyCode >> 24),
            UInt8(truncatingIfNeeded: chord.keyCode >> 16),
            UInt8(truncatingIfNeeded: chord.keyCode >> 8),
            UInt8(truncatingIfNeeded: chord.keyCode),
            UInt8(truncatingIfNeeded: chord.modifiers >> 24),
            UInt8(truncatingIfNeeded: chord.modifiers >> 16),
            UInt8(truncatingIfNeeded: chord.modifiers >> 8),
            UInt8(truncatingIfNeeded: chord.modifiers),
        ])
    }

}

@MainActor
private final class AppDelegateShortcutIntentProbe {
    var beginChangeCount = 0
}

@MainActor
private final class AppDelegateShortcutProbe {
    private var failuresRemaining: [HotKeyChord: Int] = [:]
    private var registrations: [
        UInt32: (chord: HotKeyChord, action: () -> Void)
    ] = [:]

    private(set) var attemptChords: [HotKeyChord] = []
    private(set) var cleanupChords: [HotKeyChord] = []

    func failNext(_ chord: HotKeyChord) {
        failuresRemaining[chord, default: 0] += 1
    }

    func register(
        chord: HotKeyChord,
        id: UInt32,
        action: @escaping () -> Void
    ) -> SummonHotKeyRegistration? {
        attemptChords.append(chord)
        if let remaining = failuresRemaining[chord], remaining > 0 {
            failuresRemaining[chord] = remaining - 1
            return nil
        }
        registrations[id] = (chord, action)
        return SummonHotKeyRegistration { [weak self] in
            guard let self,
                  let registration = self.registrations.removeValue(forKey: id)
            else { return }
            self.cleanupChords.append(registration.chord)
        }
    }

    @discardableResult
    func fire(_ chord: HotKeyChord) -> Bool {
        guard let registration = registrations.values.first(
            where: { $0.chord == chord }
        ) else { return false }
        registration.action()
        return true
    }
}
