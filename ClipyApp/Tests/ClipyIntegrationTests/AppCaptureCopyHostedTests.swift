import Foundation
import Testing
@testable import ClipyApp

struct AppCaptureCopyHostedTests {
    @Test func localizedOverflowNoticeInterpolatesTheDroppedCount() throws {
        let url = try #require(Bundle.main.url(forResource: "zh-Hans", withExtension: "lproj"))
        let bundle = try #require(Bundle(url: url))
        let locale = Locale(identifier: "zh_Hans_CN")
        let message = CaptureNoticePresentation.message(
            for: .droppedCapture(totalDropped: 27), bundle: bundle, locale: locale
        )
        #expect(message.contains("27"))
        #expect(message.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
    }
}
