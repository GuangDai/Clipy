/// AccessibilityAnnouncement.swift — the AppKit boundary for content-free
/// capture-failure announcements (REVIEW Card 15D).
///
/// The app shell decides whether a capture-health snapshot represents a new
/// authoritative episode. This value owns only the framework call and the
/// same safe message rendered by the panel; clipboard bytes, types, source
/// applications, and framework errors cannot enter the operation seam.
import AppKit

enum CaptureNoticePresentation {
    static func message(for notice: ClipyCaptureNotice) -> String {
        switch notice {
        case .replacedCapture:
            return "A pending clipboard change was replaced by a newer one "
                + "and wasn't saved. To try again, copy the older content again."
        case .failed(.unsupportedClipboardShape):
            return "Clipy can't save multiple clipboard items yet. Copy one item at a time."
        case .failed(.declaredContentUnavailable):
            return "Clipy couldn't read the complete clipboard change. Copy the content again to make a new attempt."
        case .failed:
            return "A clipboard change wasn't saved. Clipy can't retry it "
                + "automatically; copy the content again to make a new attempt."
        }
    }
}

@MainActor
struct AccessibilityAnnouncementOperations {
    private let postNotification: @MainActor (
        Any,
        NSAccessibility.Notification,
        [NSAccessibility.NotificationUserInfoKey: Any]?
    ) -> Void

    init(
        postNotification: @escaping @MainActor (
            Any,
            NSAccessibility.Notification,
            [NSAccessibility.NotificationUserInfoKey: Any]?
        ) -> Void
    ) {
        self.postNotification = postNotification
    }

    func post(_ message: String) {
        postNotification(
            NSApp as Any,
            .announcementRequested,
            [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    static let live = AccessibilityAnnouncementOperations {
        element,
        notification,
        userInfo in
        NSAccessibility.post(
            element: element,
            notification: notification,
            userInfo: userInfo
        )
    }
}

@MainActor
struct AccessibilityAnnouncement {
    private let operations: AccessibilityAnnouncementOperations

    init(operations: AccessibilityAnnouncementOperations) {
        self.operations = operations
    }

    func announceCaptureFailure(_ failure: ClipyCaptureFailure) {
        operations.post(
            CaptureNoticePresentation.message(for: .failed(failure))
        )
    }
}
