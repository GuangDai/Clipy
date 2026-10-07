/// App-bundle resources keep capture access, pause, and failure recovery
/// distinguishable in English and Simplified Chinese.
import Foundation
import Testing
@testable import ClipyApp

struct AppCaptureCopyHostedTests {
    private func bundle(_ language: String) throws -> Bundle {
        let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
        return try #require(Bundle(url: url))
    }

    @Test func accessMessagesKeepPermissionFailureAndTimedPauseDistinct() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        let cases: [(CaptureAccessState, String, String)] = [
            (.systemDefault, "Clipy needs permission before it can monitor clipboard changes.",
             "Clipy 需要获得权限才能监控剪贴板变化。"),
            (.ask, "Clipboard access needs your approval before monitoring can continue.",
             "需要你批准剪贴板访问，才能继续监控。"),
            (.allowed, "Clipboard monitoring is allowed.", "已允许监控剪贴板。"),
            (.denied, "Clipboard access is denied, so monitoring is stopped.",
             "剪贴板访问被拒绝，监控已停止。"),
            (.readFailure, "Clipy couldn't check clipboard access. Try again.",
             "Clipy 无法检查剪贴板访问权限，请重试。"),
            (.userPaused, "Clipboard monitoring is paused for up to 5 minutes.",
             "剪贴板监控已暂停，最长持续 5 分钟。"),
        ]
        for (state, expectedEnglish, expectedChinese) in cases {
            #expect(AppCaptureCopy.accessMessage(state, bundle: english) == expectedEnglish)
            #expect(AppCaptureCopy.accessMessage(state, bundle: chinese) == expectedChinese)
        }
    }

    @Test func localizedRecoveryAndStatusLabelsPreserveTheAvailableAction() throws {
        let chinese = try bundle("zh-Hans")
        #expect(AppCaptureCopy.recoveryTitle(.resume, bundle: chinese) == "恢复")
        #expect(AppCaptureCopy.recoveryTitle(.retry, bundle: chinese) == "重试")
        #expect(AppCaptureCopy.recoveryLabel(.resume, bundle: chinese) == "恢复剪贴板采集")
        #expect(AppCaptureCopy.recoveryLabel(.retry, bundle: chinese) == "重试剪贴板访问")
        #expect(AppCaptureCopy.statusLabel(isPaused: true, bundle: chinese) == "Clipy，剪贴板监控已暂停")
        #expect(AppCaptureCopy.statusLabel(isPaused: false, bundle: chinese) == "Clipy")
    }

    @Test func localizedOverflowNoticeFormatsCountsAndDistinguishesFailures() throws {
        let chinese = try bundle("zh-Hans")
        let english = try bundle("en")
        let locale = Locale(identifier: "zh_Hans_CN")
        let one = CaptureNoticePresentation.message(
            for: .droppedCapture(totalDropped: 1), bundle: chinese, locale: locale
        )
        let many = CaptureNoticePresentation.message(
            for: .droppedCapture(totalDropped: 27), bundle: chinese, locale: locale
        )
        let englishMany = CaptureNoticePresentation.message(
            for: .droppedCapture(totalDropped: 27), bundle: english,
            locale: Locale(identifier: "en_US")
        )
        #expect(one.contains("1"))
        #expect(many.contains("27"))
        #expect(englishMany.contains("27"))
        #expect(!many.contains("%@"))
        #expect(many != englishMany)
        let unread = CaptureNoticePresentation.message(
            for: .failed(.declaredContentUnavailable), bundle: chinese
        )
        let unsupported = CaptureNoticePresentation.message(
            for: .failed(.unsupportedClipboardShape), bundle: chinese
        )
        let unsaved = CaptureNoticePresentation.message(
            for: .failed(.unexpected), bundle: chinese
        )
        #expect(unread != unsupported)
        #expect(unread != unsaved)
        #expect(unsupported != unsaved)
        #expect([unread, unsupported, unsaved].allSatisfy { $0 != many && !$0.isEmpty })
    }
}
