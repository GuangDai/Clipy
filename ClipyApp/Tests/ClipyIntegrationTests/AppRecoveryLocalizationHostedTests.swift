import Foundation
import HistoryCore
import PasteboardAdapter
import PresentationUI
import Testing
@testable import ClipyApp

@MainActor
struct AppRecoveryLocalizationHostedTests {
    private func appBundle(_ language: String) throws -> Bundle {
        let localization = try #require(Bundle.main.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(Bundle.main.resourceURL)
        return try #require(Bundle(url: root.appendingPathComponent(
            "\(localization).lproj", isDirectory: true
        )))
    }

    @Test(arguments: ["en", "zh-Hans"])
    func localizedRecoveryKeepsDistinctStoreOwners(_ language: String) throws {
        let bundle = try appBundle(language)
        let english = language == "en"
        #expect(PanelRootView.failureCategory(
            for: HistoryFailure.persistence(.openStore), bundle: bundle
        ) == (english ? "History Store Open Failed" : "无法打开历史记录存储"))
        #expect(PanelRootView.failureMessage(
            for: HistoryFailure.persistence(.storeAlreadyOpen), bundle: bundle
        ) == (english
            ? "Clipy's history store is already open in another instance. Quit that instance and try again."
            : "Clipy 的历史记录存储已在另一个实例中打开。请退出该实例后重试。"))
        #expect(PanelRootView.failureMessage(
            for: ClipyCompositionError.storeAlreadyOpen(
                URL(fileURLWithPath: "/private/clipboard-store")
            ), bundle: bundle
        ) == (english
            ? "Clipy's history store is already open in this app. Quit Clipy and try again."
            : "Clipy 的历史记录存储已在此应用中打开。请退出 Clipy 后重试。"))
        #expect(AppRecoveryCopy.text("Reveal Store Location", bundle: bundle) ==
            (english ? "Reveal Store Location" : "显示存储位置"))
    }

    @Test(arguments: ["en", "zh-Hans"])
    func pasteAndUnexpectedOpenErrorsStayContentFree(_ language: String) throws {
        let bundle = try appBundle(language)
        let english = language == "en"
        #expect(PanelRootView.pasteFailureMessage(.busy, bundle: bundle) == (english
            ? "A copy is already in progress. Try again when it finishes."
            : "正在进行复制，请完成后重试。"))
        #expect(PanelRootView.pasteFailureMessage(
            .write(.representationsRejected(typeIdentifiers: ["com.private.clipboard-format"])),
            bundle: bundle
        ) == (english
            ? "The pasteboard refused this copy. Try again."
            : "剪贴板拒绝了此次复制，请重试。"))
        let rawError = NSError(
            domain: "/private/clipboard-store", code: 17,
            userInfo: [NSLocalizedDescriptionKey: "private clipboard contents"]
        )
        #expect(PanelRootView.failureMessage(for: rawError, bundle: bundle) == (english
            ? "Clipy couldn't open its history store."
            : "Clipy 无法打开历史记录存储。"))
    }

    @Test func typedHistoryFailuresKeepTheSharedPresentationVocabulary() {
        let itemID = HistoryItemID(rawValue: UUID())
        let removed = HistoryFailure.notFound(itemID)
        #expect(PanelRootView.pasteFailureMessage(.history(removed)) ==
            FailurePresentation.message(for: removed))
        #expect(PanelRootView.failureMessage(for: HistoryFailure.persistence(.transaction)) ==
            FailurePresentation.message(for: .persistence(.transaction)))
    }
}
