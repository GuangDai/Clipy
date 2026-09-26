import CoreFoundation
import Foundation

/// V2-07 §6: interaction preferences remain independent of retained content.
/// One defaults value publishes a complete edit; malformed fields fall back
/// individually so one damaged preference cannot disable its neighbors.
struct AdvancedInteractionSettings: Equatable, Sendable {
    static let defaultsKey = "clipy.interaction.settings"
    static let previewDelayRange = 0...1_500
    static let pointerGraceRange = 0...1_000

    var remembersSearch = true
    var selectsOnHover = true
    var previewDelayMilliseconds = 200
    var pointerGraceMilliseconds = 150

    var previewDelay: Duration {
        .milliseconds(Self.validated(previewDelayMilliseconds, in: Self.previewDelayRange, fallback: 200))
    }

    var pointerGrace: Duration {
        .milliseconds(Self.validated(pointerGraceMilliseconds, in: Self.pointerGraceRange, fallback: 150))
    }

    static func load(from defaults: UserDefaults) -> Self {
        guard let values = defaults.dictionary(forKey: defaultsKey) else { return Self() }
        var settings = Self()
        settings.remembersSearch = boolean(values["remembersSearch"], fallback: true)
        settings.selectsOnHover = boolean(values["selectsOnHover"], fallback: true)
        settings.previewDelayMilliseconds = integer(
            values["previewDelayMilliseconds"], in: previewDelayRange, fallback: 200
        )
        settings.pointerGraceMilliseconds = integer(
            values["pointerGraceMilliseconds"], in: pointerGraceRange, fallback: 150
        )
        return settings
    }

    func store(to defaults: UserDefaults) {
        let values: [String: Any] = [
            "remembersSearch": remembersSearch,
            "selectsOnHover": selectsOnHover,
            "previewDelayMilliseconds": Self.validated(
                previewDelayMilliseconds, in: Self.previewDelayRange, fallback: 200
            ),
            "pointerGraceMilliseconds": Self.validated(
                pointerGraceMilliseconds, in: Self.pointerGraceRange, fallback: 150
            )
        ]
        defaults.set(values, forKey: Self.defaultsKey)
    }

    /// Settings controls merge only their field into the latest value on the
    /// main actor. Two open views therefore cannot overwrite each other's
    /// unrelated edits with stale whole-form snapshots.
    @MainActor
    @discardableResult
    static func update(
        in defaults: UserDefaults,
        _ edit: (inout Self) -> Void
    ) -> Self {
        var latest = load(from: defaults)
        edit(&latest)
        latest.store(to: defaults)
        return load(from: defaults)
    }

    private static func validated(_ value: Int, in range: ClosedRange<Int>, fallback: Int) -> Int {
        range.contains(value) ? value : fallback
    }

    private static func boolean(_ raw: Any?, fallback: Bool) -> Bool {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return fallback }
        return number.boolValue
    }

    private static func integer(_ raw: Any?, in range: ClosedRange<Int>, fallback: Int) -> Int {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return fallback }
        let value = number.doubleValue
        guard value.isFinite, value.rounded(.towardZero) == value,
              value >= Double(range.lowerBound), value <= Double(range.upperBound)
        else { return fallback }
        return Int(value)
    }
}

enum AdvancedInteractionSettingsCopy {
    static func text(_ english: String, bundle: Bundle = AppLocalization.bundle) -> String {
        bundle.localizedString(forKey: english, value: english, table: "AdvancedInteractionSettings")
    }
}
