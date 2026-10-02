import Foundation
@testable import HistoryCore
import Testing
@testable import ClipyApp

@MainActor
struct LocalAutomationSettingsTests {
    @Test(arguments: [ExternalCapability.deleteItem, .reviseContent])
    func cancellingHighRiskConfirmationDoesNotSubmitAnyGrant(capability: ExternalCapability) async {
        let actions = SettingsActions(grants: [.browsePreview])
        let model = LocalAutomationSettingsModel(settings: actions.settings)
        await model.load()
        await model.requestCapability(capability, enabled: true)
        #expect(actions.grantCalls == 0)
        #expect(model.state?.grants == [.browsePreview])
        #expect(model.confirmsDeletionGrant == (capability == .deleteItem))
        #expect(model.confirmsRevisionGrant == (capability == .reviseContent))
        if capability == .deleteItem {
            model.cancelDeletionGrant()
        } else {
            model.cancelRevisionGrant()
        }
        #expect(!model.confirmsDeletionGrant)
        #expect(!model.confirmsRevisionGrant)
        #expect(actions.grantCalls == 0)
        #expect(model.state?.grants == [.browsePreview])
    }

    @Test func revisionConfirmationAndRevocationOnlyChangeTheirOwnPermission() async {
        let actions = SettingsActions(grants: [.browsePreview, .deleteItem])
        let model = LocalAutomationSettingsModel(settings: actions.settings)
        await model.load()
        await model.requestCapability(.reviseContent, enabled: true)
        #expect(actions.grantCalls == 0)
        await model.confirmRevisionGrant()
        #expect(actions.grantCalls == 1)
        #expect(model.state?.grants == [.browsePreview, .deleteItem, .reviseContent])
        #expect(!model.confirmsRevisionGrant)
        await model.requestCapability(.reviseContent, enabled: false)
        #expect(actions.grantCalls == 2)
        #expect(model.state?.grants == [.browsePreview, .deleteItem])
        #expect(!model.confirmsRevisionGrant)
        #expect(!model.confirmsDeletionGrant)
    }

    @Test func revisionAloneDoesNotRequestReadingDeletionOrBrowsing() async {
        let actions = SettingsActions(grants: [])
        let model = LocalAutomationSettingsModel(settings: actions.settings)
        await model.load()
        await model.requestCapability(.reviseContent, enabled: true)
        await model.confirmRevisionGrant()
        #expect(actions.grantCalls == 1)
        #expect(model.state?.grants == [.reviseContent])
    }

    @Test func unchangedPermissionsDoNotSubmitOrAskForConfirmation() async {
        let actions = SettingsActions(grants: [.browsePreview, .deleteItem, .reviseContent])
        let model = LocalAutomationSettingsModel(settings: actions.settings)
        await model.load()
        await model.requestCapability(.browsePreview, enabled: true)
        await model.requestCapability(.organize, enabled: false)
        await model.requestCapability(.deleteItem, enabled: true)
        await model.requestCapability(.reviseContent, enabled: true)
        #expect(actions.grantCalls == 0)
        #expect(!model.confirmsDeletionGrant)
        #expect(!model.confirmsRevisionGrant)
    }

    @Test func confirmationStaysExclusiveAndSurvivesSwiftUIClosingTheAlert() async {
        let actions = SettingsActions(grants: [])
        let model = LocalAutomationSettingsModel(settings: actions.settings)
        await model.load()
        await model.requestCapability(.reviseContent, enabled: true)
        await model.requestCapability(.deleteItem, enabled: true)
        await model.requestCapability(.browsePreview, enabled: true)
        #expect(model.confirmsRevisionGrant)
        #expect(!model.confirmsDeletionGrant)
        #expect(actions.grantCalls == 0)

        // SwiftUI dismisses the alert before its button's Task gets to run.
        model.confirmsRevisionGrant = false
        await model.confirmRevisionGrant()
        await model.confirmRevisionGrant()
        #expect(actions.grantCalls == 1)
        #expect(model.state?.grants == [.reviseContent])
    }

    @Test(arguments: [true, false])
    func refreshingOrRevokingInvalidatesAnOldConfirmation(refresh: Bool) async {
        let actions = SettingsActions(grants: [])
        let model = LocalAutomationSettingsModel(settings: actions.settings)
        await model.load()
        await model.requestCapability(.deleteItem, enabled: true)
        #expect(model.confirmsDeletionGrant)
        if refresh { await model.load() } else { await model.revoke() }
        #expect(!model.confirmsDeletionGrant)
        await model.confirmDeletionGrant()
        #expect(actions.grantCalls == 0)
    }

    @Test func disabledAccessDoesNotOpenAConfirmationOrChangePermissions() async {
        let actions = SettingsActions(grants: [])
        let model = LocalAutomationSettingsModel(settings: actions.settings)
        await model.load()
        await model.revoke()
        await model.requestCapability(.deleteItem, enabled: true)
        await model.requestCapability(.browsePreview, enabled: true)
        #expect(!model.canEditCapabilities)
        #expect(!model.confirmsDeletionGrant)
        #expect(actions.grantCalls == 0)
        #expect(model.notice == "Access revoked. Programs can no longer use Local Automation.")
    }

    @Test func accessFeedbackAndPermissionCountsAreLocalized() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        #expect(LocalAutomationSettingsCopy.permissionSummary(granted: 2, total: 5, bundle: english)
            == "2 of 5 permissions enabled")
        #expect(LocalAutomationSettingsCopy.permissionSummary(granted: 2, total: 5, bundle: chinese)
            == "已启用 2 项权限，共 5 项")
        #expect(LocalAutomationSettingsCopy.text("Refresh Needed", bundle: chinese) == "状态待确认")
        #expect(LocalAutomationSettingsCopy.text("Saving Permission…", bundle: chinese) == "正在保存权限…")
        #expect(LocalAutomationSettingsCopy.text("Refresh Status", bundle: chinese) == "刷新状态")
    }

    @Test func revisionPermissionDisclosureIsLocalizedAndExplainsRetainedHistory() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        #expect(LocalAutomationSettingsCopy.text("Revise Current Content", bundle: english) == "Revise Current Content")
        #expect(LocalAutomationSettingsCopy.text("Revise Current Content", bundle: chinese) == "修订当前内容")
        #expect(LocalAutomationSettingsCopy.text("Allow Programs to Revise Current Content?", bundle: chinese) == "允许程序修订当前内容？")
        #expect(LocalAutomationSettingsCopy.text("Allow Revisions", bundle: chinese) == "允许修订")
        #expect(LocalAutomationSettingsCopy.revisionDisclosure(bundle: english)
            == "Programs using your account will be able to change an item's current content without asking again. Each change appends an immutable revision. Original content and older revisions remain retained until removed by retention or item deletion; revision is not erasure. This permission does not grant content reading or deletion.")
        #expect(LocalAutomationSettingsCopy.revisionDisclosure(bundle: chinese)
            == "使用你账户的程序将能够更改条目的当前内容，不再逐次询问。每次更改都会追加一个不可变的修订版本。原始内容和旧修订仍会保留，直到保留策略移除旧修订或条目被删除；修订并不等于擦除。此权限不会授予读取内容或删除条目的权限。")
    }

    private func bundle(_ language: String) throws -> Bundle {
        let resources = LocalAutomationSettingsCopy.bundle
        let localization = try #require(resources.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(resources.resourceURL)
        return try #require(Bundle(url: root.appendingPathComponent("\(localization).lproj")))
    }
}

/// Records only Settings commands, not History behavior. Enrollment's real
/// Authority tests separately exercise persistence and capability isolation.
@MainActor
private final class SettingsActions {
    var grants: Set<ExternalCapability>
    private(set) var grantCalls = 0

    init(grants: Set<ExternalCapability>) { self.grants = grants }

    var settings: LocalAutomationSettings {
        LocalAutomationSettings(
            load: { [self] in LocalAutomationSettingsState(enabled: true, grants: grants) },
            enable: { LocalAutomationSettingsState(enabled: true, grants: []) },
            revoke: { LocalAutomationSettingsState(enabled: false, grants: []) },
            setCapability: { [self] capability, enabled in
                grantCalls += 1
                if enabled { grants.insert(capability) } else { grants.remove(capability) }
                return LocalAutomationSettingsState(enabled: true, grants: grants)
            }
        )
    }
}
