import Foundation
import Testing
@testable import ClipyApp

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

    @Test func copyCountKeepsItsFullUnsignedValueInTheSelectedRegion() throws {
        let locale = Locale(identifier: "de_DE")
        let label = PreviewCopy.copyCount(UInt64.max, bundle: try bundle("zh-Hans"), locale: locale)
        #expect(label.contains(UInt64.max.formatted(.number.locale(locale))))
    }

    @Test func imageAccessibilityMetadataKeepsWidthAndHeightInTheirTranslatedPositions() throws {
        let label = PreviewCopy.imageDimensions(
            width: 640, height: 480, bundle: try bundle("zh-Hans"), locale: Locale(identifier: "zh_Hans_CN")
        )
        let width = try #require(label.range(of: "640"))
        let height = try #require(label.range(of: "480"))
        #expect(width.upperBound <= height.lowerBound)
    }
}
