import Foundation
import HistoryCore
import Testing
@testable import ClipyApp

@MainActor
struct SourceApplicationSearchResolverTests {
    @Test func humanNamesResolveWithoutChangingBooleanGrouping() throws {
        let resolver = SourceApplicationSearchResolver(applications: [
            .init(bundleID: "ph.telegra.Telegraph", displayName: "Telegram"),
            .init(bundleID: "com.brave.Browser", displayName: "Brave Browser"),
            .init(bundleID: "com.apple.Notes", displayName: "Notes")
        ])
        let expression = try HistorySearchExpression.parse("source:Telegram or (source:Brave AND NOT source:Notes)")
        let result = resolver.resolve(expression)

        #expect(result.unresolvedNames.isEmpty)
        #expect(result.expression == (try HistorySearchExpression.parse(
            "source-id:ph.telegra.Telegraph OR (source-id:com.brave.Browser AND NOT source-id:com.apple.Notes)"
        )))
        #expect(try HistorySearchExpression.parse(result.expression.serialized) == result.expression)
    }

    @Test func identicallyNamedAppsRemainDistinctAndAreAllIncludedUnderNot() throws {
        let resolver = SourceApplicationSearchResolver(applications: [
            .init(bundleID: "org.example.notes-one", displayName: "Notes"),
            .init(bundleID: "org.example.notes-two", displayName: "Notes")
        ])
        let result = resolver.resolve(try HistorySearchExpression.parse("NOT source:notes"))

        #expect(resolver.applications.count == 2)
        #expect(result.unresolvedNames.isEmpty)
        #expect(result.expression == (try HistorySearchExpression.parse(
            "NOT (source-id:org.example.notes-one OR source-id:org.example.notes-two)"
        )))
    }

    @Test func namesAreRealMetadataAndNotGuessedFromBundleIdentifiers() {
        let resolver = SourceApplicationSearchResolver(applications: [
            .init(bundleID: "org.example.Telegram", displayName: "Unrelated Application"),
            .init(bundleID: "org.example.browser", displayName: "浏览器", names: ["Brave Browser"])
        ])

        #expect(resolver.identifiers(matching: "Telegram").isEmpty)
        #expect(resolver.identifiers(matching: "brave") == ["org.example.browser"])
        #expect(resolver.identifiers(matching: "浏览器") == ["org.example.browser"])
        #expect(resolver.identifiers(matching: "  BRAVE  ") == ["org.example.browser"])
        #expect(resolver.identifiers(matching: "org.example.browser") == ["org.example.browser"])
        #expect(resolver.identifiers(matching: "org.example").isEmpty)
    }

    @Test func unavailableNamesAreReportedAndExplicitIDsNeedNoInstalledApplication() throws {
        let resolver = SourceApplicationSearchResolver(applications: [])
        let unresolved = resolver.resolve(try HistorySearchExpression.parse(
            "source:Missing OR NOT source:Missing"
        ))
        let explicit = try HistorySearchExpression.parse("source-id:org.example.removed-app")

        #expect(unresolved.unresolvedNames == ["Missing"])
        #expect(resolver.resolve(explicit).unresolvedNames.isEmpty)
        #expect(resolver.resolve(explicit).expression == explicit)
    }

    @Test func duplicateInstallationsMergeTheirRealNamesWithoutDuplicateChoices() async {
        let resolver = SourceApplicationSearchResolver(applications: [
            .init(bundleID: "org.example.app", displayName: "Localized Name"),
            .init(bundleID: "org.example.app", displayName: "Original Name")
        ])
        await resolver.prepare()

        #expect(resolver.applications.count == 1)
        #expect(resolver.identifiers(matching: "Localized Name") == ["org.example.app"])
        #expect(resolver.identifiers(matching: "Original Name") == ["org.example.app"])
    }

    @Test func differentlySpelledMetadataIDsArePreservedForExactHistoryMatching() {
        let resolver = SourceApplicationSearchResolver(applications: [
            .init(bundleID: "org.example.App", displayName: "Same Application"),
            .init(bundleID: "org.example.app", displayName: "Same Application")
        ])

        #expect(resolver.identifiers(matching: "Same Application") == ["org.example.App", "org.example.app"])
    }

    @Test func bundleMetadataSuppliesDisplayNameOriginalNameAndActualFileName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try application(at: root.appendingPathComponent("Chosen File Name.app"),
                                  identifier: "org.example.real-id", name: "Original Name", displayName: "显示名称")
        let metadata = try #require(SourceApplicationSearchResolver.application(at: url))
        let resolver = SourceApplicationSearchResolver(applications: [metadata])

        #expect(metadata.displayName == "显示名称")
        #expect(metadata.bundleID == "org.example.real-id")
        for name in ["显示名称", "Original Name", "Chosen File Name"] {
            #expect(resolver.identifiers(matching: name) == ["org.example.real-id"])
        }
        let unidentified = try application(at: root.appendingPathComponent("No ID.app"), identifier: nil)
        #expect(SourceApplicationSearchResolver.application(at: unidentified) == nil)
    }

    @Test func discoveryIncludesAppFoldersButDoesNotInspectApplicationInternalsOrOtherRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Applications", isDirectory: true)
        let outer = try application(at: directory.appendingPathComponent("Vendor/Outer.app"), identifier: "org.example.outer")
        _ = try application(at: outer.appendingPathComponent("Contents/Helpers/Inner.app"), identifier: "org.example.helper")
        _ = try application(at: root.appendingPathComponent("Other/Unrelated.app"), identifier: "org.example.unrelated")

        let discovered = SourceApplicationSearchResolver.applications(in: [directory])
        #expect(discovered.map(\.bundleID) == ["org.example.outer"])
    }

    private func application(at url: URL, identifier: String?, name: String = "Fixture", displayName: String? = nil) throws -> URL {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = ["CFBundlePackageType": "APPL", "CFBundleName": name]
        if let identifier { info["CFBundleIdentifier"] = identifier }
        if let displayName { info["CFBundleDisplayName"] = displayName }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }
}
