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
        bundle: Bundle = AppLocalization.bundle,
        locale: Locale = .current
    ) -> String {
        switch notice {
        case .droppedCapture(let totalDropped):
            if totalDropped == 1 {
                return AppCaptureCopy.text("The clipboard capture queue was full, so 1 change "
                    + "wasn't saved. Copy that content again to save it.", bundle: bundle)
            }
            let format = AppCaptureCopy.text("The clipboard capture queue was full, so %@ changes "
                + "weren't saved. Copy that content again to save it.", bundle: bundle)
            return String(format: format, locale: locale,
                          totalDropped.formatted(.number.locale(locale)))
        case .failed(.unsupportedClipboardShape):
            return AppCaptureCopy.text("Clipy couldn't save this clipboard change because its size or structure isn't supported.", bundle: bundle)
        case .failed(.declaredContentUnavailable):
            return AppCaptureCopy.text("The clipboard data is not fully available yet. Clipy will retry automatically.", bundle: bundle)
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
        bundle: Bundle = AppLocalization.bundle, locale: Locale = .current
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

    func announceHistoryItemRemoved(bundle: Bundle = AppLocalization.bundle) {
        operations.post(
            AppHistoryAnnouncementsCopy.text("Item removed from history.", bundle: bundle),
            priority: .medium
        )
    }

    func announceSettledSearchResultCount(
        _ count: Int,
        hasNextPage: Bool,
        bundle: Bundle = AppLocalization.bundle,
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
