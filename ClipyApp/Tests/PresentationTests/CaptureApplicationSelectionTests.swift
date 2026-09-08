import Foundation
import Testing
@testable import ClipyApp

@MainActor
struct CaptureApplicationSelectionTests {
    @Test func selectedApplicationsPersistThroughTheExistingCapturePreference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try application(at: root.appendingPathComponent("First.app"), identifier: "org.example.First")
        let second = try application(at: root.appendingPathComponent("Second.app"), identifier: "org.example.Second")
        var list = CaptureIgnoreList(bundleIDs: ["org.example.existing"])
        #expect(CapturePrivacySettingsView.addApplications([first, second, first], to: &list) == 0)
        let suite = "clipy-selection-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        list.store(to: defaults)
        let loaded = CaptureIgnoreList.load(from: defaults)
        #expect(loaded.ignores("org.example.First"))
        #expect(loaded.ignores("org.example.Second"))
        #expect(loaded.ignores("org.example.existing"))
        #expect(loaded.bundleIDs.count == 3)
        #expect(!loaded.ignores("org.example.other"))
        #expect(!loaded.ignores(nil))
    }

    @Test func unidentifiableSelectionDoesNotDiscardOtherApplications() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try application(at: root.appendingPathComponent("Valid.app"), identifier: "org.example.valid")
        let unidentified = try application(at: root.appendingPathComponent("MissingID.app"), identifier: nil)
        var list = CaptureIgnoreList(bundleIDs: ["org.example.existing"])
        #expect(CapturePrivacySettingsView.addApplications([unidentified, valid], to: &list) == 1)
        #expect(list.bundleIDs == ["org.example.existing", "org.example.valid"])
        #expect(CapturePrivacySettingsView.addApplications([], to: &list) == 0)
        #expect(list.bundleIDs == ["org.example.existing", "org.example.valid"])
    }

    private func application(at url: URL, identifier: String?) throws -> URL {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = ["CFBundlePackageType": "APPL", "CFBundleName": "Selection Fixture"]
        if let identifier { info["CFBundleIdentifier"] = identifier }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }
}
