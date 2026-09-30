import AppKit
import Observation
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
    static let arrivalScale = 0.975
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
            duration = reduceMotion ? 0 : presentation * 0.5
        }
    }

    var animation: Animation? {
        duration > 0 ? .timingCurve(Self.unitCurve, duration: duration) : nil
    }

    static var unitCurve: UnitCurve {
        .bezier(startControlPoint: UnitPoint(x: curve.0, y: curve.1),
                endControlPoint: UnitPoint(x: curve.2, y: curve.3))
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

/// Presentation values only. Window/session/content lifetime stays with the
/// existing native owners; SwiftUI replaces the keyframes for each request.
@MainActor
@Observable
final class AppMotionPresentation {
    private(set) var requestGeneration: UInt = 0
    private(set) var isActive = false
    private(set) var duration: TimeInterval = 0

    func play(duration: TimeInterval) {
        self.duration = duration
        isActive = duration > 0
        requestGeneration &+= 1
    }

    func cancel() {
        guard isActive else { return }
        isActive = false
        requestGeneration &+= 1
    }
}

struct AppMotionSurface<Content: View>: View {
    let presentation: AppMotionPresentation
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playbackTrigger: UInt = 0

    private struct Values: Sendable {
        var scale = 1.0
        var opacity = 1.0
    }

    var body: some View {
        // The @Sendable frame closure captures immutable values, never the
        // MainActor state or History. Only these two visual modifiers update.
        let request = presentation.requestGeneration
        let isActive = presentation.isActive && !reduceMotion
        let duration = isActive ? presentation.duration : 0
        let awaitingStart = request != playbackTrigger
        content
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .keyframeAnimator(initialValue: Values(), trigger: playbackTrigger) { content, values in
                content
                    .scaleEffect(CGFloat(isActive ? (awaitingStart ? AppMotionTiming.arrivalScale : values.scale) : 1))
                    .opacity(isActive ? (awaitingStart ? 0.92 : values.opacity) : 1)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    MoveKeyframe(isActive ? AppMotionTiming.arrivalScale : 1)
                    LinearKeyframe(1, duration: duration, timingCurve: AppMotionTiming.unitCurve)
                }
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(isActive ? 0.92 : 1)
                    LinearKeyframe(1, duration: duration, timingCurve: AppMotionTiming.unitCurve)
                }
            }
            .onChange(of: request, initial: true) { _, request in
                // The native owner can request before the hosting view first
                // mounts. Forward after mounting so the trigger truly changes.
                playbackTrigger = request
            }
    }
}

/// Insertion only: disappearing or invalid content leaves immediately. The
/// small scale settles on the same curve as the window content, while the
/// ten levels retain the same movement, including the short fastest level.
struct AppMotionArrival: ViewModifier {
    let opacity: Double
    let scale: CGFloat

    func body(content: Content) -> some View {
        content.opacity(opacity).scaleEffect(scale)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(insertion: .modifier(
            active: AppMotionArrival(opacity: 0.92, scale: CGFloat(AppMotionTiming.arrivalScale)),
            identity: AppMotionArrival(opacity: 1, scale: 1)
        ), removal: .identity)
    }
}

/// Immediate action, short visual acknowledgement. Layout and hit targets
/// keep their normal size while the label responds to the real button press.
struct AppMotionPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppMotionSettings.defaultsKey) private var motionLevel = AppMotionSpeed.fastest.rawValue

    func makeBody(configuration: Configuration) -> some View {
        let speed = AppMotionSpeed(rawValue: motionLevel) ?? .fastest
        return configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(AppMotionSettings.animation(speed: speed, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
    }
}
