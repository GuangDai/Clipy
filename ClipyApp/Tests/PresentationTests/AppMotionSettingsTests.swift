import Foundation
import Testing
@testable import ClipyApp

struct AppMotionSettingsTests {
    @Test(arguments: [60, 120])
    func savedLevelsDriveOrderedTransitionsAndReduceMotionRemovesThem(refreshRate: Int) throws {
        let suite = "MotionSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var previous = Double.infinity
        for speed in AppMotionSpeed.allCases {
            defaults.set(speed.rawValue, forKey: AppMotionSettings.defaultsKey)
            let reopened = try #require(UserDefaults(suiteName: suite))
            let selected = AppMotionSettings.load(from: reopened)
            let timing = AppMotionTiming(speed: selected, framesPerSecond: refreshRate, reduceMotion: false)
            #expect(selected == speed)
            #expect(timing.duration > 0 && timing.duration < previous)
            previous = timing.duration
            let reduced = AppMotionTiming(speed: selected, framesPerSecond: refreshRate, reduceMotion: true)
            #expect(reduced.animation == nil)
            #expect(reduced.duration == 0)
        }
        #expect(previous * Double(refreshRate) <= 5)
        #expect(AppMotionTiming(speed: .fastest, framesPerSecond: refreshRate, reduceMotion: false,
                                effect: .feedback).animation == nil)
        defaults.set(11, forKey: AppMotionSettings.defaultsKey)
        #expect(AppMotionSettings.load(from: defaults) == .fastest)
    }
}
