/// AccessibilityAnnouncement.swift — the AppKit boundary for content-free
/// capture-failure announcements (REVIEW Card 15D).
///
/// The app shell decides whether a capture-health snapshot represents a new
/// authoritative episode. This value owns only the framework call and the
/// same safe message rendered by the panel; clipboard bytes, types, source
/// applications, and framework errors cannot enter the operation seam.
import AppKit

enum CaptureNoticePresentation {
    static func message(
        for notice: ClipyCaptureNotice,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        switch notice {
        case .replacedCapture(let totalReplaced):
            if totalReplaced == 1 {
                return AppCaptureCopy.text("Clipy replaced 1 pending clipboard change with a newer "
                    + "one, so it wasn't saved. To try again, copy the older "
                    + "content again.", bundle: bundle)
            }
            let format = AppCaptureCopy.text("Clipy replaced %@ pending clipboard changes "
                + "with newer ones, so they weren't saved. To try again, copy "
                + "the older content again.", bundle: bundle)
            return String(format: format, locale: locale,
                          totalReplaced.formatted(.number.locale(locale)))
        case .failed(.unsupportedClipboardShape):
            return AppCaptureCopy.text("Clipy can't save multiple clipboard items yet. Copy one item at a time.", bundle: bundle)
        case .failed(.declaredContentUnavailable):
            return AppCaptureCopy.text("Clipy couldn't read the complete clipboard change. Copy the content again to make a new attempt.", bundle: bundle)
        case .failed:
            return AppCaptureCopy.text("A clipboard change wasn't saved. Clipy can't retry it "
                + "automatically; copy the content again to make a new attempt.", bundle: bundle)
        }
    }
}

/// Content-free settled-search count copy. A continuation cursor makes the
/// first-page count a lower bound, so `+` is preserved instead of presenting
/// it as an exact total (REVIEW UI-16 / Card 15D).
enum SearchResultCountAnnouncementPresentation {
    static func message(
        count: Int, hasNextPage: Bool,
        bundle: Bundle = .main, locale: Locale = .current
    ) -> String {
        AppHistoryAnnouncementsCopy.searchResults(
            count: count, hasNextPage: hasNextPage, bundle: bundle, locale: locale
        )
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

    func announceHistoryItemRemoved(bundle: Bundle = .main) {
        operations.post(
            AppHistoryAnnouncementsCopy.text("Item removed from history.", bundle: bundle),
            priority: .medium
        )
    }

    func announceSettledSearchResultCount(
        _ count: Int,
        hasNextPage: Bool,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) {
        operations.post(
            SearchResultCountAnnouncementPresentation.message(
                count: count,
                hasNextPage: hasNextPage,
                bundle: bundle,
                locale: locale
            ),
            priority: .medium
        )
    }
}
