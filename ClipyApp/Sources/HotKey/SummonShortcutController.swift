/// SummonShortcutController.swift — one app-owned lifecycle for the selected
/// summon chord. Candidate registration precedes persistence and teardown, so
/// a conflict never strands the person without the previously working binding
/// (REVIEW Card 14B).
import Foundation

@MainActor
final class SummonHotKeyRegistration {
    private var unregisterAction: (() -> Void)?

    init(unregister: @escaping () -> Void) {
        unregisterAction = unregister
    }

    /// A registration token has one cleanup. Idempotence makes explicit app
    /// termination and a repeated stop safe without relying on deinit timing.
    func unregister() {
        let action = unregisterAction
        unregisterAction = nil
        action?()
    }
}

enum SummonShortcutState: Equatable {
    case stopped
    case active(HotKeyChord)
    case unavailable(requested: HotKeyChord, retainedActive: HotKeyChord?)

    var warning: HotKeyChordWarning? {
        switch self {
        case .stopped:
            nil
        case .active(let chord), .unavailable(let chord, _):
            chord.warning
        }
    }
}

/// Owns the active Carbon token and the single UserDefaults value that records
/// the chosen chord. The injectable closure is a narrow system-call seam for
/// deterministic conflict tests; no protocol, service locator, or registry is
/// introduced.
@MainActor
final class SummonShortcutController {
    typealias RegistrationFactory = (
        _ chord: HotKeyChord,
        _ id: UInt32,
        _ action: @escaping () -> Void
    ) -> SummonHotKeyRegistration?

    nonisolated static let defaultsKey = "summonShortcutChord"

    private enum PersistenceAfterRegistration {
        case keep
        case set
        case remove
    }

    private struct PendingAttempt {
        let chord: HotKeyChord
        let persistence: PersistenceAfterRegistration
    }

    private let defaults: UserDefaults
    private let key: String
    private let defaultChord: HotKeyChord
    private let action: () -> Void
    private let registrationFactory: RegistrationFactory

    private var activeRegistration: SummonHotKeyRegistration?
    private var activeChord: HotKeyChord?
    private var pendingAttempt: PendingAttempt?
    private var nextRegistrationID: UInt32 = 1

    private(set) var state: SummonShortcutState = .stopped

    init(
        defaults: UserDefaults = .standard,
        key: String = SummonShortcutController.defaultsKey,
        defaultChord: HotKeyChord = .defaultSummon,
        action: @escaping () -> Void,
        registrationFactory: RegistrationFactory? = nil
    ) {
        self.defaults = defaults
        self.key = key
        self.defaultChord = defaultChord
        self.action = action
        self.registrationFactory = registrationFactory ?? Self.registerCarbonHotKey
    }

    /// Starts from the persisted chord when it decodes, otherwise the product
    /// default. A registration conflict is visible and retryable; startup does
    /// not silently replace or erase the person's saved choice.
    @discardableResult
    func start() -> Bool {
        guard case .stopped = state else {
            if case .active = state { return true }
            return false
        }
        let savedChord = loadSavedChord()
        return attempt(
            PendingAttempt(
                chord: savedChord ?? defaultChord,
                persistence: .keep
            )
        )
    }

    /// Safely changes the binding. The old registration remains live and the
    /// defaults value remains untouched until the candidate registers.
    @discardableResult
    func change(to chord: HotKeyChord) -> Bool {
        attempt(PendingAttempt(chord: chord, persistence: .set))
    }

    /// Re-attempts precisely the last unavailable candidate, including a saved
    /// startup chord or a failed reset.
    @discardableResult
    func retry() -> Bool {
        guard let pendingAttempt else { return false }
        return attempt(pendingAttempt)
    }

    /// Restores the product default. Success removes the override instead of
    /// writing a duplicate default value; failure retains both the active token
    /// and the previous preference until Retry can finish the same operation.
    @discardableResult
    func reset() -> Bool {
        attempt(PendingAttempt(chord: defaultChord, persistence: .remove))
    }

    /// Ends the owned registration exactly once. A later start re-reads the
    /// authoritative preference instead of reviving an unpersisted candidate.
    func stop() {
        activeRegistration?.unregister()
        activeRegistration = nil
        activeChord = nil
        pendingAttempt = nil
        state = .stopped
    }

    private func attempt(_ pending: PendingAttempt) -> Bool {
        if pending.chord == activeChord, activeRegistration != nil {
            persist(pending.persistence, chord: pending.chord)
            pendingAttempt = nil
            state = .active(pending.chord)
            return true
        }

        let id = takeRegistrationID()
        guard let candidate = registrationFactory(pending.chord, id, action) else {
            pendingAttempt = pending
            state = .unavailable(
                requested: pending.chord,
                retainedActive: activeChord
            )
            return false
        }

        let previous = activeRegistration
        activeRegistration = candidate
        activeChord = pending.chord
        persist(pending.persistence, chord: pending.chord)
        pendingAttempt = nil
        state = .active(pending.chord)
        previous?.unregister()
        return true
    }

    private func persist(
        _ persistence: PersistenceAfterRegistration,
        chord: HotKeyChord
    ) {
        switch persistence {
        case .keep:
            break
        case .set:
            defaults.set(Self.encode(chord), forKey: key)
        case .remove:
            defaults.removeObject(forKey: key)
        }
    }

    private func loadSavedChord() -> HotKeyChord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return Self.decode(data)
    }

    /// One fixed-width UserDefaults value: big-endian key code followed by
    /// big-endian Carbon modifiers. Every HotKeyChord is representable, so a
    /// successful candidate can never outrun a fallible encoding step.
    private static func encode(_ chord: HotKeyChord) -> Data {
        Data([
            UInt8(truncatingIfNeeded: chord.keyCode >> 24),
            UInt8(truncatingIfNeeded: chord.keyCode >> 16),
            UInt8(truncatingIfNeeded: chord.keyCode >> 8),
            UInt8(truncatingIfNeeded: chord.keyCode),
            UInt8(truncatingIfNeeded: chord.modifiers >> 24),
            UInt8(truncatingIfNeeded: chord.modifiers >> 16),
            UInt8(truncatingIfNeeded: chord.modifiers >> 8),
            UInt8(truncatingIfNeeded: chord.modifiers)
        ])
    }

    private static func decode(_ data: Data) -> HotKeyChord? {
        guard data.count == 8 else { return nil }
        let bytes = Array(data)
        let keyCode = (
            UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        )
        let modifiers = (
            UInt32(bytes[4]) << 24
            | UInt32(bytes[5]) << 16
            | UInt32(bytes[6]) << 8
            | UInt32(bytes[7])
        )
        return HotKeyChord(keyCode: keyCode, modifiers: modifiers)
    }

    private func takeRegistrationID() -> UInt32 {
        let id = nextRegistrationID
        nextRegistrationID &+= 1
        if nextRegistrationID == 0 { nextRegistrationID = 1 }
        return id
    }

    private static func registerCarbonHotKey(
        chord: HotKeyChord,
        id: UInt32,
        action: @escaping () -> Void
    ) -> SummonHotKeyRegistration? {
        let hotKey = GlobalHotKey(
            keyCode: chord.keyCode,
            modifiers: chord.modifiers,
            id: id,
            action: action
        )
        guard hotKey.register() else { return nil }
        return SummonHotKeyRegistration { hotKey.unregister() }
    }
}
