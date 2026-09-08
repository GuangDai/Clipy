import SwiftUI

/// TIER-5: a system pressure hint changes only reconstructible display work.
/// It never changes History retention or the user's current navigation.
enum DisplayMemoryPressure: Sendable, Equatable {
    case normal
    case warning
    case critical
}

private struct DisplayMemoryPressureKey: EnvironmentKey {
    static let defaultValue = DisplayMemoryPressure.normal
}

private struct DisplayMemoryPressureGenerationKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var displayMemoryPressure: DisplayMemoryPressure {
        get { self[DisplayMemoryPressureKey.self] }
        set { self[DisplayMemoryPressureKey.self] = newValue }
    }

    /// Repeated warnings must trim entries accumulated since the preceding
    /// warning, even when the pressure level itself has not changed.
    var displayMemoryPressureGeneration: Int {
        get { self[DisplayMemoryPressureGenerationKey.self] }
        set { self[DisplayMemoryPressureGenerationKey.self] = newValue }
    }
}
