import AppKit
import QuartzCore
import SwiftUI

enum AppMotionSpeed: Int, CaseIterable, Sendable {
    case level1 = 1, level2, level3, level4, level5
    case level6, level7, level8, level9, level10

    static let fastest = Self.level10

    var title: String {
        let format = switch self {
        case .level1: NativeAppearanceCopy.text("%d — Slowest")
        case .level10: NativeAppearanceCopy.text("%d — Fastest")
        default: NativeAppearanceCopy.text("Level %d")
        }
        return String(format: format, rawValue)
    }
}

enum AppMotionEffect: Sendable {
    case presentation, feedback
}

/// Short transitions share a display-relative duration. This bounds the
/// requested animation, not disk I/O or WindowServer presentation latency.
struct AppMotionTiming: Sendable {
    let duration: TimeInterval
    private static let curve = (0.2, 0.8, 0.2, 1.0)

    init(speed: AppMotionSpeed, framesPerSecond: Int, reduceMotion: Bool,
         effect: AppMotionEffect = .presentation) {
        let refreshRate = framesPerSecond > 0 ? framesPerSecond : 60
        // Levels 1–9 use the same progression on every display; level 10
        // requests three refresh intervals, leaving room within five frames
        // for the UI handoff. Slower displays never extend it beyond 50 ms.
        let presentation = speed == .fastest
            ? min(0.05, 3 / Double(refreshRate))
            : 0.075 + Double(9 - speed.rawValue) * 0.045
        switch effect {
        case .presentation: duration = reduceMotion ? 0 : presentation
        case .feedback:
            duration = reduceMotion || speed == .fastest ? 0 : presentation * 0.5
        }
    }

    var animation: Animation? {
        duration > 0 ? .timingCurve(Self.curve.0, Self.curve.1, Self.curve.2, Self.curve.3,
                                  duration: duration) : nil
    }

    static var nativeTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(curve.0), Float(curve.1),
                              Float(curve.2), Float(curve.3))
    }
}

enum AppMotionSettings {
    static let defaultsKey = "clipy.appearance.motionSpeed"

    static func load(from defaults: UserDefaults) -> AppMotionSpeed {
        AppMotionSpeed(rawValue: defaults.integer(forKey: defaultsKey)) ?? .fastest
    }

    @MainActor
    static func duration(for screen: NSScreen?, defaults: UserDefaults = .standard) -> TimeInterval {
        AppMotionTiming(
            speed: load(from: defaults),
            framesPerSecond: screen?.maximumFramesPerSecond ?? 60,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ).duration
    }

    @MainActor
    static func animation(speed: AppMotionSpeed, reduceMotion: Bool,
                          effect: AppMotionEffect = .feedback) -> Animation? {
        AppMotionTiming(
            speed: speed,
            framesPerSecond: (NSApp.keyWindow?.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60,
            reduceMotion: reduceMotion,
            effect: effect
        ).animation
    }
}

/// Insertion only: disappearing or invalid content leaves immediately. The
/// small scale settles on the same curve as native window alpha, while the
/// fastest level omits this decorative movement.
struct AppMotionArrival: ViewModifier {
    let opacity: Double
    let scale: CGFloat

    func body(content: Content) -> some View {
        content.opacity(opacity).scaleEffect(scale)
    }

    static func transition(speed: AppMotionSpeed, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(insertion: .modifier(
            active: AppMotionArrival(opacity: 0.92, scale: speed == .fastest ? 1 : 0.985),
            identity: AppMotionArrival(opacity: 1, scale: 1)
        ), removal: .identity)
    }
}
