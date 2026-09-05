import Foundation
import Testing
@testable import PresentationUI

struct PreviewCopyTests {
    private func bundle(_ language: String) throws -> Bundle {
        let localization = try #require(PreviewCopy.bundle.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(PreviewCopy.bundle.resourceURL)
        return try #require(Bundle(url: root.appendingPathComponent(
            "\(localization).lproj", isDirectory: true
        )))
    }

    @Test func statesAndQuickLookActionsHaveBothNativeLocalizations() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        for (key, translation) in [
            ("Loading preview", "正在加载预览"),
            ("No Preview", "无可用预览"),
            ("Preview Unavailable", "预览暂不可用"),
            ("Retry", "重试"),
            ("Close", "关闭"),
            ("Quick Look preview", "快速查看预览"),
        ] {
            #expect(PreviewCopy.text(key, bundle: english) == key)
            #expect(PreviewCopy.text(key, bundle: chinese) == translation)
        }
    }

    @Test func copyCountsKeepTheirFullUnsignedValueAndLocalizedGrouping() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        #expect(PreviewCopy.copyCount(1, bundle: english, locale: Locale(identifier: "en_US")) == "Copied 1×")
        #expect(PreviewCopy.copyCount(1_234, bundle: chinese, locale: Locale(identifier: "zh_Hans_CN")) == "已复制 1,234 次")
        #expect(PreviewCopy.copyCount(1_234, bundle: english, locale: Locale(identifier: "de_DE")) == "Copied 1.234×")
        #expect(PreviewCopy.copyCount(UInt64.max, bundle: english, locale: Locale(identifier: "en_US")) == "Copied 18,446,744,073,709,551,615×")
    }

    @Test func imageAccessibilityMetadataKeepsWidthAndHeightInTheirTranslatedPositions() throws {
        #expect(PreviewCopy.imageDimensions(
            width: 1, height: 1, bundle: try bundle("en"), locale: Locale(identifier: "en_US")
        ) == "Image preview, 1 by 1 pixels")
        #expect(PreviewCopy.imageDimensions(
            width: 1_920, height: 1_080, bundle: try bundle("zh-Hans"), locale: Locale(identifier: "zh_Hans_CN")
        ) == "图像预览，宽 1,920 像素，高 1,080 像素")
    }
}
