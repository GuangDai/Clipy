/// CaptureIgnoreListTests — the capture-exclusion vocabulary proofs: the
/// ignore list fails open to the empty list, `add` validates and
/// normalizes reverse-domain identifiers (rejecting invalid shapes and
/// duplicates without mutating), the list round-trips through UserDefaults
/// under its pinned key, `ignores` matches case-insensitively and never
/// ignores `nil`, and `remove` tolerates unknown entries.
import Foundation
import PresentationUI
import Testing

@Suite("Capture ignore list")
struct CaptureIgnoreListTests {
    @Test("an absent UserDefaults key loads the empty list")
    func absentKeyLoadsEmptyList() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let loaded = CaptureIgnoreList.load(from: defaults)

        #expect(loaded == CaptureIgnoreList())
        #expect(loaded.bundleIDs.isEmpty)
    }

    @Test("add accepts reverse-domain identifiers and normalizes them")
    func addAcceptsAndNormalizes() {
        var list = CaptureIgnoreList()

        let addedLower = list.add("com.1password.1password")
        let addedMixedCase = list.add("  COM.Example.App  ")

        #expect(addedLower)
        #expect(addedMixedCase)
        // Sorted ("1" precedes "e") and lowercase-normalized.
        #expect(list.bundleIDs == ["com.1password.1password", "com.example.app"])
    }

    @Test("add rejects invalid shapes and duplicates without mutating")
    func addRejectsInvalidAndDuplicates() {
        var list = CaptureIgnoreList()
        let added = list.add("com.example.app")
        #expect(added)

        for invalid in [
            "",
            "   ",
            "nodots",
            "com example.app",
            "com.example_app",
            "com.example.app!",
            "com.exämple.app",
        ] {
            let accepted = list.add(invalid)
            #expect(!accepted)
        }
        let duplicateExact = list.add("com.example.app")
        let duplicateAfterNormalization = list.add(" COM.EXAMPLE.APP")

        #expect(!duplicateExact)
        #expect(!duplicateAfterNormalization)
        #expect(list.bundleIDs == ["com.example.app"])
    }

    @Test("store→load round-trips the normalized sorted list")
    func storeLoadRoundTrips() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var list = CaptureIgnoreList()
        let addedB = list.add("com.b.app")
        let addedA = list.add("com.a.app")
        #expect(addedB)
        #expect(addedA)
        list.store(to: defaults)

        #expect(CaptureIgnoreList.load(from: defaults) == list)
        #expect(list.bundleIDs == ["com.a.app", "com.b.app"])
    }

    @Test("load sanitizes a hand-edited persisted value")
    func loadSanitizesPersistedEntries() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            ["COM.Valid.App", "not valid", "com.valid.app", "nodots"],
            forKey: CaptureIgnoreList.defaultsKey
        )

        #expect(
            CaptureIgnoreList.load(from: defaults).bundleIDs
                == ["com.valid.app"]
        )
    }

    @Test("ignores matches case-insensitively and never ignores nil")
    func ignoresMatchesCaseInsensitively() {
        var list = CaptureIgnoreList()
        let added = list.add("com.1password.1password")
        #expect(added)

        #expect(list.ignores("com.1password.1password"))
        #expect(list.ignores("COM.1Password.1Password"))
        #expect(list.ignores("  com.1password.1password  "))
        #expect(!list.ignores("com.other.app"))
        #expect(!list.ignores(""))
        #expect(!list.ignores(nil))
        #expect(!CaptureIgnoreList().ignores("com.1password.1password"))
    }

    @Test("remove deletes case-insensitively and tolerates unknown entries")
    func removeDeletesCaseInsensitively() {
        var list = CaptureIgnoreList()
        let addedA = list.add("com.a.app")
        let addedB = list.add("com.b.app")
        #expect(addedA)
        #expect(addedB)

        list.remove("COM.A.APP")
        #expect(list.bundleIDs == ["com.b.app"])
        list.remove("com.unknown.app")
        #expect(list.bundleIDs == ["com.b.app"])
    }

    @Test("the UserDefaults key stays pinned")
    func defaultsKeyStaysPinned() {
        #expect(
            CaptureIgnoreList.defaultsKey == "clipy.capture.ignoredBundleIDs"
        )
    }

    /// One fresh, empty UserDefaults suite per test — the same isolation
    /// pattern as `PanelAppearanceSettingsTests`.
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "CaptureIgnoreListTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
