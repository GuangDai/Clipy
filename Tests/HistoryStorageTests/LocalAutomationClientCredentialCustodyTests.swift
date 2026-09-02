/// F1 client credential-file custody proofs (`V2-05` §0.3): owner-only
/// directory/file modes, no-follow and regular-file admission, exact 48-byte
/// readback, atomic temp-then-rename replacement, crash-orphan reclaim, and
/// the inherited-stdin supply grammar. Everything runs against real per-test
/// temp directories on the runner filesystem; no Keychain, Authority,
/// transport, or CLI process is involved, and no claim beyond the file
/// custody leaf is made.
import Foundation
import Testing
@testable import HistoryStorage

@Suite("Local Automation client credential custody (F1)")
struct LocalAutomationClientCredentialCustodyTests {
    private static let credentialBytes = Data((0..<48).map { UInt8(0x40 + $0) })
    private static let rotatedBytes = Data((0..<48).map { UInt8(0xBF - $0) })

    private struct Fixture {
        let root: URL
        let directory: URL
        let custody: LocalAutomationClientCredentialCustody

        var credentialFile: URL { custody.credentialFileURL }
    }

    /// Temp roots are created up front (repo rule for on-disk fixtures) and
    /// removed by each test's defer.
    private static func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-f1-client-custody-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        let directory = root.appendingPathComponent("custody", isDirectory: true)
        return Fixture(
            root: root,
            directory: directory,
            custody: LocalAutomationClientCredentialCustody(directoryURL: directory)
        )
    }

    private static func removeFixture(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private static func makeOwnerOnlyDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
    }

    private static func posixPermissions(at url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(
            atPath: url.path
        )[.posixPermissions] as? NSNumber)?.intValue
    }

    @Test("install writes then reads back the exact 48 bytes")
    func installThenLoadRoundTripsExactBytes() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        try fixture.custody.installCredential(Self.credentialBytes)

        #expect(try fixture.custody.loadCredential() == Self.credentialBytes)
        #expect(try Data(contentsOf: fixture.credentialFile) == Self.credentialBytes)
    }

    @Test("install enforces directory 0700 / file 0600 and tightens a loose directory")
    func installEnforcesOwnerOnlyModes() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        try fixture.custody.installCredential(Self.credentialBytes)
        #expect(try Self.posixPermissions(at: fixture.directory) == 0o700)
        #expect(try Self.posixPermissions(at: fixture.credentialFile) == 0o600)

        // A pre-existing group/other-accessible directory is tightened on the
        // next install (the save-time choice), never served loose.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: fixture.directory.path
        )
        try fixture.custody.installCredential(Self.rotatedBytes)
        #expect(try Self.posixPermissions(at: fixture.directory) == 0o700)
        #expect(try fixture.custody.loadCredential() == Self.rotatedBytes)
    }

    @Test("load refuses a group/other-accessible directory")
    func loadRejectsLoosenedDirectory() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        try fixture.custody.installCredential(Self.credentialBytes)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: fixture.directory.path
        )

        #expect(
            throws: LocalAutomationClientCredentialCustodyFailure.unsafeDirectory
        ) {
            _ = try fixture.custody.loadCredential()
        }
    }

    @Test("load refuses a group/other-readable credential file")
    func loadRejectsGroupReadableCredentialFile() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        try fixture.custody.installCredential(Self.credentialBytes)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o640)],
            ofItemAtPath: fixture.credentialFile.path
        )

        #expect(
            throws: LocalAutomationClientCredentialCustodyFailure.unsafeCredentialFile
        ) {
            _ = try fixture.custody.loadCredential()
        }
    }

    @Test("load never follows a symbolic-link directory or credential file")
    func loadRejectsSymbolicLinks() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        try fixture.custody.installCredential(Self.credentialBytes)

        // The credential file replaced by a link to an otherwise valid
        // 48-byte file is refused, never followed.
        let planted = fixture.root.appendingPathComponent("planted")
        try Self.rotatedBytes.write(to: planted)
        try FileManager.default.removeItem(at: fixture.credentialFile)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.credentialFile.path,
            withDestinationPath: planted.path
        )
        #expect(
            throws: LocalAutomationClientCredentialCustodyFailure.unsafeCredentialFile
        ) {
            _ = try fixture.custody.loadCredential()
        }

        // The custody directory itself behind a link is refused even when the
        // link target is a real directory.
        let linked = fixture.root.appendingPathComponent(
            "linked",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: linked.path,
            withDestinationPath: fixture.directory.path
        )
        let linkedCustody = LocalAutomationClientCredentialCustody(
            directoryURL: linked
        )
        #expect(
            throws: LocalAutomationClientCredentialCustodyFailure.unsafeDirectory
        ) {
            _ = try linkedCustody.loadCredential()
        }
    }

    @Test("load refuses a non-regular occupant at the credential path")
    func loadRejectsNonRegularCredentialFile() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        try fixture.custody.installCredential(Self.credentialBytes)
        try FileManager.default.removeItem(at: fixture.credentialFile)
        try FileManager.default.createDirectory(
            at: fixture.credentialFile,
            withIntermediateDirectories: false
        )

        #expect(
            throws: LocalAutomationClientCredentialCustodyFailure.unsafeCredentialFile
        ) {
            _ = try fixture.custody.loadCredential()
        }
    }

    @Test("absent directory or file loads as no credential")
    func loadReturnsNilWhenAbsent() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        #expect(try fixture.custody.loadCredential() == nil)

        try Self.makeOwnerOnlyDirectory(at: fixture.directory)
        #expect(try fixture.custody.loadCredential() == nil)
    }

    @Test("load refuses a wrong-length credential file")
    func loadRejectsWrongByteCount() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        try Self.makeOwnerOnlyDirectory(at: fixture.directory)
        try Data(repeating: 0xAB, count: 47).write(to: fixture.credentialFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fixture.credentialFile.path
        )

        #expect(
            throws: LocalAutomationClientCredentialCustodyFailure.malformedCredential
        ) {
            _ = try fixture.custody.loadCredential()
        }
    }

    @Test("install refuses a wrong-length value without creating state")
    func installRejectsWrongByteCount() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        #expect(
            throws: LocalAutomationClientCredentialCustodyFailure.malformedCredential
        ) {
            try fixture.custody.installCredential(Data(repeating: 0xCD, count: 49))
        }
        #expect(try fixture.custody.loadCredential() == nil)
    }

    @Test("replacement is atomic: a pre-seeded credential is exchanged whole, with no temp residue")
    func installReplacesPreSeededCredential() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        // Pre-seed an earlier enrollment's file directly (owner-only
        // directory + 0600 regular file), the state an earlier writer would
        // have left behind.
        try Self.makeOwnerOnlyDirectory(at: fixture.directory)
        try Data(repeating: 0x00, count: 48).write(to: fixture.credentialFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fixture.credentialFile.path
        )

        try fixture.custody.installCredential(Self.credentialBytes)

        #expect(try fixture.custody.loadCredential() == Self.credentialBytes)
        #expect(try Data(contentsOf: fixture.credentialFile) == Self.credentialBytes)
        #expect(try Self.posixPermissions(at: fixture.credentialFile) == 0o600)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.directory.path
        )
        #expect(names == [LocalAutomationClientCredentialCustody.credentialFileName])
    }

    @Test("install refuses to replace through a symbolic-link destination")
    func installRefusesSymbolicLinkDestination() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        try Self.makeOwnerOnlyDirectory(at: fixture.directory)
        let planted = fixture.root.appendingPathComponent("planted-target")
        try Self.rotatedBytes.write(to: planted)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.credentialFile.path,
            withDestinationPath: planted.path
        )

        #expect(
            throws: LocalAutomationClientCredentialCustodyFailure.unsafeCredentialFile
        ) {
            try fixture.custody.installCredential(Self.credentialBytes)
        }
        // The link target is never written through.
        #expect(try Data(contentsOf: planted) == Self.rotatedBytes)
    }

    @Test("crash-orphan temporaries are reclaimed on load and install; everything else is untouched")
    func crashOrphanReclaim() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        try fixture.custody.installCredential(Self.credentialBytes)

        let decoyBytes = Data("keep me".utf8)
        let decoyNames = [
            "notes.txt",
            ".\(LocalAutomationClientCredentialCustody.credentialFileName).bak",
        ]
        for name in decoyNames {
            try decoyBytes.write(
                to: fixture.directory.appendingPathComponent(name)
            )
        }
        let orphanNames = [
            LocalAutomationClientCredentialCustody.temporaryFileName(
                forToken: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
            ),
            LocalAutomationClientCredentialCustody.temporaryFileName(
                forToken: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
            ),
        ]
        // An interrupted write leaves a partial temp sibling behind.
        try Data(repeating: 0xEE, count: 10).write(
            to: fixture.directory.appendingPathComponent(orphanNames[0])
        )
        try Self.rotatedBytes.write(
            to: fixture.directory.appendingPathComponent(orphanNames[1])
        )

        #expect(try fixture.custody.loadCredential() == Self.credentialBytes)
        var names = Set(try FileManager.default.contentsOfDirectory(
            atPath: fixture.directory.path
        ))
        #expect(names == Set(
            [LocalAutomationClientCredentialCustody.credentialFileName] + decoyNames
        ))

        // The install path reclaims a fresh orphan the same way.
        try Data(repeating: 0xEE, count: 3).write(
            to: fixture.directory.appendingPathComponent(orphanNames[0])
        )
        try fixture.custody.installCredential(Self.rotatedBytes)
        #expect(try fixture.custody.loadCredential() == Self.rotatedBytes)
        names = Set(try FileManager.default.contentsOfDirectory(
            atPath: fixture.directory.path
        ))
        #expect(names == Set(
            [LocalAutomationClientCredentialCustody.credentialFileName] + decoyNames
        ))
        for name in decoyNames {
            #expect(try Data(
                contentsOf: fixture.directory.appendingPathComponent(name)
            ) == decoyBytes)
        }
    }

    @Test("the temporary-name predicate matches only this component's own orphans")
    func orphanNamePredicateIsExact() {
        let own = LocalAutomationClientCredentialCustody.temporaryFileName(
            forToken: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
        )
        let isOrphan = LocalAutomationClientCredentialCustody
            .isOrphanedTemporaryFileName
        #expect(isOrphan(own))
        #expect(!isOrphan(LocalAutomationClientCredentialCustody.credentialFileName))
        #expect(!isOrphan("notes.txt"))
        #expect(!isOrphan(
            ".\(LocalAutomationClientCredentialCustody.credentialFileName).tmp"
        ))
        #expect(!isOrphan("\(own).bak"))
    }

    @Test("the supply grammar accepts exactly 48 bytes")
    func supplyGrammarIsByteExact() throws {
        #expect(try LocalAutomationClientCredentialCustody
            .validatedCredentialBytes(Self.credentialBytes) == Self.credentialBytes)
        #expect(
            throws: LocalAutomationClientCredentialCustodyFailure.malformedCredential
        ) {
            _ = try LocalAutomationClientCredentialCustody.validatedCredentialBytes(
                Data(Self.credentialBytes.dropLast())
            )
        }
        #expect(
            throws: LocalAutomationClientCredentialCustodyFailure.malformedCredential
        ) {
            _ = try LocalAutomationClientCredentialCustody.validatedCredentialBytes(
                Self.credentialBytes + Data([0x00])
            )
        }
    }

    @Test("an inherited open descriptor supplies bytes identical to the installed file")
    func inheritedDescriptorSupplyMatchesFileBytes() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        try fixture.custody.installCredential(Self.credentialBytes)

        // The thin descriptor layer is proven over an already-open handle —
        // the shape the CLI's inherited stdin takes — without touching the
        // test process's own stdin.
        let handle = try FileHandle(forReadingFrom: fixture.credentialFile)
        defer { try? handle.close() }
        let supplied = try LocalAutomationClientCredentialCustody
            .readSuppliedCredential(from: handle)
        #expect(supplied == Self.credentialBytes)
        #expect(try supplied == fixture.custody.loadCredential())

        let short = fixture.root.appendingPathComponent("short")
        try Data(repeating: 0x11, count: 47).write(to: short)
        let shortHandle = try FileHandle(forReadingFrom: short)
        defer { try? shortHandle.close() }
        #expect(
            throws: LocalAutomationClientCredentialCustodyFailure.malformedCredential
        ) {
            _ = try LocalAutomationClientCredentialCustody.readSuppliedCredential(
                from: shortHandle
            )
        }
    }

    @Test("revocation-side removal is best-effort, idempotent, and never throws")
    func removalIsBestEffort() throws {
        let fixture = try Self.makeFixture()
        defer { Self.removeFixture(fixture) }

        try fixture.custody.installCredential(Self.credentialBytes)
        #expect(fixture.custody.removeCredential())
        #expect(try fixture.custody.loadCredential() == nil)
        #expect(fixture.custody.removeCredential())

        // A removal the filesystem refuses is reported as not-removed and
        // still does not throw — §0.3 authority-first revocation never waits
        // on the client file.
        try fixture.custody.installCredential(Self.credentialBytes)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o500)],
            ofItemAtPath: fixture.directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: fixture.directory.path
            )
        }
        #expect(!fixture.custody.removeCredential())
        #expect(FileManager.default.fileExists(atPath: fixture.credentialFile.path))
    }
}
