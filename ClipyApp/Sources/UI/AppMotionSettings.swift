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
        // Levels 1–9 have an even proportional spread, from 900 to 80 ms;
        // the full-width preview reveal makes that tempo visible. Level 10
        // requests three refresh intervals, leaving room within five frames
        // for the UI handoff. Slower displays never extend it beyond 50 ms.
        let presentation = speed == .fastest
            ? min(0.05, 3 / Double(refreshRate))
            : 0.9 * pow(0.08 / 0.9, Double(speed.rawValue - 1) / 8)
        switch effect {
        case .presentation: duration = reduceMotion ? 0 : presentation
        case .feedback:
            // Keep frequent button feedback brief even at the slowest level,
            // while retaining the same curve and an ordered ten-level tempo.
            duration = reduceMotion ? 0 : min(0.12 * sqrt(presentation / 0.9), presentation * 0.6)
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

struct AppMotionSurface: ViewModifier {
    let presentation: AppMotionPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playbackTrigger: UInt = 0

    private struct Values: Sendable {
        var scale = 1.0
        var opacity = 1.0
    }

    func body(content: Content) -> some View {
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

/// A drawer emerging from the physical edge beside the history list. The
/// hosting/window size and content layout stay fixed; only a built-in display
/// offset changes per frame, within the fixed viewport's clip.
struct PreviewMotionSurface: ViewModifier {
    let presentation: AppMotionPresentation
    let isOnLeadingSide: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playbackTrigger: UInt = 0

    func body(content: Content) -> some View {
        let request = presentation.requestGeneration
        let active = presentation.isActive && !reduceMotion
        let duration = active ? presentation.duration : 0
        let awaitingStart = request != playbackTrigger
        let direction = isOnLeadingSide ? 1.0 : -1.0
        content
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .keyframeAnimator(initialValue: 1.0, trigger: playbackTrigger) { content, progress in
                let visibleProgress = active ? (awaitingStart ? 0 : progress) : 1
                content.visualEffect { effect, geometry in
                    effect.offset(x: geometry.size.width * CGFloat(direction * (1 - visibleProgress)))
                }
            } keyframes: { _ in
                MoveKeyframe(active ? 0.0 : 1.0)
                LinearKeyframe(1.0, duration: duration, timingCurve: AppMotionTiming.unitCurve)
            }
            .clipped()
            .onChange(of: request, initial: true) { _, request in
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
