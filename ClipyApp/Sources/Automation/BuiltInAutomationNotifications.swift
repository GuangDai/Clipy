import Foundation
import UserNotifications

/// No clipboard text is included in a notification. Authorization is requested
/// only by an explicit Run containing an enabled notification step, after every
/// transformation succeeds. Preview and Save never enter this effect.
enum BuiltInAutomationNotifications {
    static func send() async throws {
        try Task.checkCancellation()
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                throw BuiltInAutomationFailure.notificationDenied
            }
            try Task.checkCancellation()
            let content = UNMutableNotificationContent()
            content.title = "Clipy"
            content.body = BuiltInAutomationCopy.text("Workflow conditions matched.")
            content.sound = .default
            try await center.add(UNNotificationRequest(
                identifier: "clipy.workflow.\(UUID().uuidString)", content: content, trigger: nil
            ))
        } catch is CancellationError { throw CancellationError() }
        catch let failure as BuiltInAutomationFailure { throw failure }
        catch { throw BuiltInAutomationFailure.notificationFailed }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix("clipy.workflow.") ? [.banner, .sound] : []
    }
}
