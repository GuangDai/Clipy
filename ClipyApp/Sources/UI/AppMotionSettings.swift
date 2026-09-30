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
    static let arrivalAnimationKey = "clipy.presentation.arrival"

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

    /// Keep AppKit's hosting-view geometry untouched. The transparent parent
    /// carries the arrival effect on its sublayers; normal view autoresizing
    /// still owns the child's size, with no per-frame layout work.
    @MainActor
    static func surface(containing view: NSView) -> NSView {
        let surface = NSView(frame: view.frame)
        surface.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        surface.addSubview(view)
        return surface
    }

    /// Animate the prepared child surface without changing the backing layer's
    /// AppKit-owned transform or anchorPoint (Core Animation Guide, OS X rules).
    @MainActor
    static func animateArrival(in view: NSView?, duration: TimeInterval) {
        cancelArrival(in: view)
        guard duration > 0, let view, let layer = view.layer else { return }
        let scale = CGFloat(AppMotionTiming.arrivalScale)
        var start = CATransform3DMakeScale(scale, scale, 1)
        // AppKit chooses its backing-layer anchor. Read it rather than changing
        // it, and compensate so the visible content scales around its center.
        start.m41 = (1 - scale) * view.bounds.width * (0.5 - layer.anchorPoint.x)
        start.m42 = (1 - scale) * view.bounds.height * (0.5 - layer.anchorPoint.y)
        let animation = CABasicAnimation(keyPath: "sublayerTransform")
        animation.fromValue = NSValue(caTransform3D: start)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = duration
        animation.timingFunction = AppMotionTiming.nativeTimingFunction
        layer.add(animation, forKey: arrivalAnimationKey)
    }

    @MainActor
    static func cancelArrival(in view: NSView?) {
        view?.layer?.removeAnimation(forKey: arrivalAnimationKey)
    }
}

/// Insertion only: disappearing or invalid content leaves immediately. The
/// small scale settles on the same curve as native window alpha, while the
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
