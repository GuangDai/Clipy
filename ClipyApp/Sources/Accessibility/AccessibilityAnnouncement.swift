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
        case .replacedCapture(let totalReplaced):
            if totalReplaced == 1 {
                return "Clipy replaced 1 pending clipboard change with a newer "
                    + "one, so it wasn't saved. To try again, copy the older "
                    + "content again."
            }
            return "Clipy replaced \(totalReplaced) pending clipboard changes "
                + "with newer ones, so they weren't saved. To try again, copy "
                + "the older content again."
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

/// Content-free settled-search count copy. A continuation cursor makes the
/// first-page count a lower bound, so `+` is preserved instead of presenting
/// it as an exact total (REVIEW UI-16 / Card 15D).
enum SearchResultCountAnnouncementPresentation {
    static func message(count: Int, hasNextPage: Bool) -> String {
        if hasNextPage { return "\(count)+ results" }
        return count == 1 ? "1 result" : "\(count) results"
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

    func post(
        _ message: String,
        priority: NSAccessibilityPriorityLevel
    ) {
        postNotification(
            NSApp as Any,
            .announcementRequested,
            [
                .announcement: message,
                .priority: priority.rawValue,
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
            CaptureNoticePresentation.message(for: .failed(failure)),
            priority: .high
        )
    }

    func announceHistoryItemRemoved() {
        operations.post(
            "Item removed from history.",
            priority: .medium
        )
    }

    func announceSettledSearchResultCount(
        _ count: Int,
        hasNextPage: Bool
    ) {
        operations.post(
            SearchResultCountAnnouncementPresentation.message(
                count: count,
                hasNextPage: hasNextPage
            ),
            priority: .medium
        )
    }
}
