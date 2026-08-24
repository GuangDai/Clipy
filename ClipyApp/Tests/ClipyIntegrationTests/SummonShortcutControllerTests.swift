/// SummonShortcutControllerTests — deterministic Card 14B proofs for the
/// configurable Carbon binding. The fake is one injected system-call closure,
/// not a second registrar implementation; real Carbon acceptance remains in
/// GlobalHotKeyTests.
import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import ClipyApp

@MainActor
struct SummonShortcutControllerTests {
    private let alternate = HotKeyChord(
        keyCode: UInt32(kVK_ANSI_K),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    @Test func failedSwapRetainsOldBindingAndDoesNotPersistCandidate() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = ShortcutRegistrationProbe()
        var fired = 0
        let controller = makeController(defaults: defaults, probe: probe) {
            fired += 1
        }

        #expect(controller.start())
        probe.failNext(alternate)

        #expect(!controller.change(to: alternate))
        #expect(
            controller.state == .unavailable(
                requested: alternate,
                retainedActive: .defaultSummon
            )
        )
        #expect(controller.state.warning == .knownColorsShortcut)
        #expect(persistedChord(in: defaults) == nil)
        #expect(probe.cleanupChords.isEmpty)
        #expect(probe.fire(.defaultSummon))
        #expect(fired == 1, "the previously working registration remains live")

        controller.stop()
    }

    @Test func retryCompletesTheSameSwapThenPersistsAndCleansOldToken() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = ShortcutRegistrationProbe()
        var fired = 0
        let controller = makeController(defaults: defaults, probe: probe) {
            fired += 1
        }

        #expect(controller.start())
        probe.failNext(alternate)
        #expect(!controller.change(to: alternate))

        #expect(controller.retry())
        #expect(controller.state == .active(alternate))
        #expect(persistedChord(in: defaults) == alternate)
        #expect(probe.cleanupChords == [.defaultSummon])
        #expect(!probe.fire(.defaultSummon))
        #expect(probe.fire(alternate))
        #expect(fired == 1)

        controller.stop()
    }

    @Test func failedResetKeepsOverrideUntilRetryCanRemoveIt() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = ShortcutRegistrationProbe()
        let controller = makeController(defaults: defaults, probe: probe)

        #expect(controller.start())
        #expect(controller.change(to: alternate))
        #expect(persistedChord(in: defaults) == alternate)

        probe.failNext(.defaultSummon)
        #expect(!controller.reset())
        #expect(
            controller.state == .unavailable(
                requested: .defaultSummon,
                retainedActive: alternate
            )
        )
        #expect(persistedChord(in: defaults) == alternate)
        #expect(probe.fire(alternate))

        #expect(controller.retry())
        #expect(controller.state == .active(.defaultSummon))
        #expect(persistedChord(in: defaults) == nil)
        #expect(!probe.fire(alternate))

        controller.stop()
    }

    @Test func savedStartupConflictIsVisibleAndRetryableWithoutRewritingChoice() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let writerProbe = ShortcutRegistrationProbe()
        let writer = makeController(defaults: defaults, probe: writerProbe)
        #expect(writer.start())
        #expect(writer.change(to: alternate))
        writer.stop()

        let probe = ShortcutRegistrationProbe()
        probe.failNext(alternate)
        let controller = makeController(defaults: defaults, probe: probe)

        #expect(!controller.start())
        #expect(
            controller.state == .unavailable(
                requested: alternate,
                retainedActive: nil
            )
        )
        #expect(persistedChord(in: defaults) == alternate)

        #expect(controller.retry())
        #expect(controller.state == .active(alternate))
        #expect(persistedChord(in: defaults) == alternate)

        controller.stop()
    }

    @Test func stopCleansEachOwnedTokenExactlyOnce() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = ShortcutRegistrationProbe()
        let controller = makeController(defaults: defaults, probe: probe)

        #expect(controller.start())
        controller.stop()
        controller.stop()
        #expect(controller.state == .stopped)
        #expect(probe.cleanupChords == [.defaultSummon])

        #expect(controller.start())
        controller.stop()
        #expect(probe.cleanupChords == [.defaultSummon, .defaultSummon])
    }

    @Test func changingToActiveChordPersistsWithoutDuplicateRegistration() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = ShortcutRegistrationProbe()
        let controller = makeController(defaults: defaults, probe: probe)

        #expect(controller.start())
        #expect(controller.change(to: .defaultSummon))
        #expect(probe.attemptChords == [.defaultSummon])
        #expect(persistedChord(in: defaults) == .defaultSummon)

        controller.stop()
    }

    @Test func documentedDefaultColorsShortcutWarnsButIsNotRejected() {
        #expect(HotKeyChord.defaultSummon.warning == .knownColorsShortcut)
        #expect(alternate.warning == nil)
    }

    @Test func recorderCancelsEscapeAndRejectsBareOrModifierOnlyKeys() {
        #expect(
            SummonShortcutRecordingDecision.decide(
                keyCode: UInt16(kVK_Escape),
                modifierFlags: [.command]
            ) == .cancel
        )
        #expect(
            SummonShortcutRecordingDecision.decide(
                keyCode: UInt16(kVK_ANSI_K),
                modifierFlags: []
            ) == .reject
        )
        #expect(
            SummonShortcutRecordingDecision.decide(
                keyCode: UInt16(kVK_Command),
                modifierFlags: [.command]
            ) == .reject
        )
    }

    @Test func recorderProducesTheExactCarbonCandidateFromAdmittedFlags() {
        let decision = SummonShortcutRecordingDecision.decide(
            keyCode: UInt16(kVK_ANSI_K),
            modifierFlags: [.capsLock, .command, .option, .numericPad]
        )
        #expect(decision == .candidate(HotKeyChord(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey | optionKey)
        )))
    }

    @Test func recorderInputViewDispatchesKeyDownAndIgnoresRepeat() throws {
        var decisions: [SummonShortcutRecordingDecision] = []
        let input = SummonShortcutRecorderInputView { decisions.append($0) }
        let first = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "k",
            charactersIgnoringModifiers: "k",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_K)
        ))
        let repeated = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "k",
            charactersIgnoringModifiers: "k",
            isARepeat: true,
            keyCode: UInt16(kVK_ANSI_K)
        ))

        input.keyDown(with: first)
        input.keyDown(with: repeated)

        #expect(decisions == [.candidate(HotKeyChord(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | shiftKey)
        ))])
    }

    private func makeController(
        defaults: UserDefaults,
        probe: ShortcutRegistrationProbe,
        action: @escaping () -> Void = {}
    ) -> SummonShortcutController {
        SummonShortcutController(
            defaults: defaults,
            action: action,
            registrationFactory: { chord, id, action in
                probe.register(chord: chord, id: id, action: action)
            }
        )
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "SummonShortcutControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func persistedChord(in defaults: UserDefaults) -> HotKeyChord? {
        guard let data = defaults.data(forKey: SummonShortcutController.defaultsKey) else {
            return nil
        }
        guard data.count == 8 else { return nil }
        let bytes = Array(data)
        return HotKeyChord(
            keyCode: UInt32(bytes[0]) << 24
                | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8
                | UInt32(bytes[3]),
            modifiers: UInt32(bytes[4]) << 24
                | UInt32(bytes[5]) << 16
                | UInt32(bytes[6]) << 8
                | UInt32(bytes[7])
        )
    }
}

@MainActor
private final class ShortcutRegistrationProbe {
    private var failuresRemaining: [HotKeyChord: Int] = [:]
    private var registrations: [UInt32: (chord: HotKeyChord, action: () -> Void)] = [:]

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
            guard let self, let registration = self.registrations.removeValue(forKey: id) else {
                return
            }
            self.cleanupChords.append(registration.chord)
        }
    }

    @discardableResult
    func fire(_ chord: HotKeyChord) -> Bool {
        guard let registration = registrations.values.first(where: { $0.chord == chord }) else {
            return false
        }
        registration.action()
        return true
    }
}
