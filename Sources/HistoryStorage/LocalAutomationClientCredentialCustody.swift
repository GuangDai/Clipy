/// F1 client-side credential-file custody (`V2-05` §0.3/§3.4/§6.7;
/// `07-python-local-automation.md` §5.1).
///
/// This is the client half of the §0.3 custody decision for the future
/// first-party `clipyctl`: the exact 48-byte credential (preassigned
/// connection UUID16 + `SecRandomCopyBytes` secret32, minted app-side by
/// `LocalAutomationCredential.generate`) is kept in ONE owner-only no-follow
/// regular file beneath a validated owner-only directory — directory mode
/// `0700`, file mode `0600`, byte-exact length and readback.
///
/// Deliberate scope boundaries:
///
/// - No executable/product placement and no fixed production path are chosen
///   here: the §6.7 client leaf is still BLOCKED-SPEC on both, so the custody
///   directory is an injected `URL` and only custody at that URL is enforced.
/// - The §0.3 publication order is honored from the client side only.
///   `installCredential` returns solely after an exact post-replace readback,
///   the client-file precondition the app-side enrollment coordinator must
///   hold BEFORE it asks the Authority to publish the preassigned
///   `.localAutomation` row last. `removeCredential` is the revocation-side
///   best-effort deletion: the Authority revokes first, and client-file
///   deletion can never make revocation succeed or fail.
/// - §0.3 startup reconciliation of client-file/Keychain orphans against
///   durable rows is app-side and is NOT implemented here. The only cleanup
///   this component owns is reclaim of its OWN interrupted atomic-write
///   temporaries, on the next load or install.
/// - Per §0.3/§5.2 these checks exclude other UIDs and accidental path
///   substitution; they claim no confidentiality against a malicious
///   same-EUID process.
import Foundation

/// Content-free custody failures: no path, byte fragment, or underlying
/// `NSError` is carried, mirroring `CredentialStoreFailure` (`V2-05` §6.7).
package enum LocalAutomationClientCredentialCustodyFailure: Error, Sendable, Equatable {
    /// The custody directory is a symbolic link, is not a directory, or is
    /// group/other-accessible at load time.
    case unsafeDirectory
    /// The credential file is a symbolic link, is not a regular file, is
    /// group/other-accessible, or belongs to a different account than the
    /// custody directory.
    case unsafeCredentialFile
    /// The value is not exactly the §0.3 48-byte credential grammar.
    case malformedCredential
    /// The post-install readback did not return the installed bytes.
    case readbackMismatch
    /// The underlying filesystem operation failed.
    case unavailable
}

/// A stateless owner for the one client credential file. Every operation is
/// a function over the injected directory; the only state is the filesystem.
package struct LocalAutomationClientCredentialCustody: Sendable {
    /// Fixed leaf name of the single credential file inside the custody
    /// directory (§0.3 keeps exactly one client credential).
    package static let credentialFileName = "local-automation.credential"

    package let directoryURL: URL

    package init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    package var credentialFileURL: URL {
        directoryURL.appendingPathComponent(Self.credentialFileName)
    }

    // MARK: - Supply grammar (§0.3 dedicated inherited stdin descriptor)

    /// The complete §0.3 grammar for a supplied or stored credential:
    /// exactly 48 bytes. The provisioning helper receives the minted value
    /// through a dedicated inherited stdin descriptor — never argv,
    /// environment, a cwd-derived input, or a caller-selected path — so the
    /// descriptor is drained to EOF and the byte count is the whole
    /// admission rule.
    package static func validatedCredentialBytes(_ supplied: Data) throws -> Data {
        guard supplied.count == LocalAutomationCredential.byteCount else {
            throw LocalAutomationClientCredentialCustodyFailure.malformedCredential
        }
        return supplied
    }

    /// Reads the credential from an already-open descriptor supplied by the
    /// caller (the future CLI passes its inherited `FileHandle.standardInput`).
    package static func readSuppliedCredential(
        from handle: FileHandle
    ) throws -> Data {
        let supplied: Data
        do {
            supplied = try handle.readToEnd() ?? Data()
        } catch {
            throw LocalAutomationClientCredentialCustodyFailure.unavailable
        }
        return try validatedCredentialBytes(supplied)
    }

    // MARK: - Atomic-write temporary naming (pure)

    /// The temp-name scheme, owned here so interrupted writes leave
    /// recognizable siblings of the credential file — and only those.
    package static func temporaryFileName(forToken token: UUID) -> String {
        ".\(credentialFileName).\(token.uuidString).tmp"
    }

    package static func isOrphanedTemporaryFileName(_ name: String) -> Bool {
        let prefix = ".\(credentialFileName)."
        let suffix = ".tmp"
        return name.hasPrefix(prefix)
            && name.hasSuffix(suffix)
            && name.count > prefix.count + suffix.count
    }

    // MARK: - Custody operations

    /// Loads the credential, or `nil` when the directory or file does not
    /// exist. The §0.3 load-time rule is fail-closed: a symbolic-link or
    /// group/other-accessible directory or file is refused, never followed
    /// or repaired; the file must be regular, must belong to the same
    /// account that owns the custody directory (the FileManager-only form
    /// of the §0.3 owner check), and must read back at byte-exact length.
    /// Own interrupted-write temporaries are reclaimed first.
    package func loadCredential() throws -> Data? {
        let fileManager = FileManager.default
        if Self.isSymbolicLink(atPath: directoryURL.path) {
            throw LocalAutomationClientCredentialCustodyFailure.unsafeDirectory
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ) else { return nil }
        guard isDirectory.boolValue else {
            throw LocalAutomationClientCredentialCustodyFailure.unsafeDirectory
        }
        let directoryAttributes = try Self.attributes(atPath: directoryURL.path)
        guard let directoryMode = directoryAttributes[.posixPermissions] as? NSNumber else {
            throw LocalAutomationClientCredentialCustodyFailure.unavailable
        }
        guard directoryMode.intValue & 0o077 == 0 else {
            throw LocalAutomationClientCredentialCustodyFailure.unsafeDirectory
        }

        try cleanOrphanedTemporaryFiles()

        if Self.isSymbolicLink(atPath: credentialFileURL.path) {
            throw LocalAutomationClientCredentialCustodyFailure.unsafeCredentialFile
        }
        guard fileManager.fileExists(atPath: credentialFileURL.path) else {
            return nil
        }
        let fileAttributes = try Self.attributes(atPath: credentialFileURL.path)
        guard let fileType = fileAttributes[.type] as? FileAttributeType,
              fileType == .typeRegular else {
            throw LocalAutomationClientCredentialCustodyFailure.unsafeCredentialFile
        }
        guard let fileMode = fileAttributes[.posixPermissions] as? NSNumber,
              fileMode.intValue & 0o077 == 0 else {
            throw LocalAutomationClientCredentialCustodyFailure.unsafeCredentialFile
        }
        guard let fileOwner = fileAttributes[.ownerAccountID] as? NSNumber,
              let directoryOwner = directoryAttributes[.ownerAccountID] as? NSNumber,
              fileOwner == directoryOwner else {
            throw LocalAutomationClientCredentialCustodyFailure.unsafeCredentialFile
        }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: credentialFileURL)
        } catch {
            throw LocalAutomationClientCredentialCustodyFailure.unavailable
        }
        return try Self.validatedCredentialBytes(bytes)
    }

    /// Installs the credential with a write-temp-then-rename replace so a
    /// concurrent reader never observes a partial file: the temp sibling is
    /// created at mode `0600`, then atomically renamed over the destination
    /// (`moveItem` on first install, `replaceItemAt` with the new item's
    /// metadata afterwards). A symbolic-link or non-regular destination is
    /// refused rather than followed. Returns only after the installed file
    /// passes full load validation AND reads back byte-exact — the client
    /// half of the §0.3 authority-last publication order.
    package func installCredential(_ exactBytes: Data) throws {
        _ = try Self.validatedCredentialBytes(exactBytes)
        try prepareDirectory()
        try cleanOrphanedTemporaryFiles()

        let fileManager = FileManager.default
        let credentialPath = credentialFileURL.path
        if Self.isSymbolicLink(atPath: credentialPath) {
            throw LocalAutomationClientCredentialCustodyFailure.unsafeCredentialFile
        }
        if fileManager.fileExists(atPath: credentialPath) {
            let existing = try Self.attributes(atPath: credentialPath)
            guard (existing[.type] as? FileAttributeType) == .typeRegular else {
                throw LocalAutomationClientCredentialCustodyFailure.unsafeCredentialFile
            }
        }

        let temporaryURL = directoryURL.appendingPathComponent(
            Self.temporaryFileName(forToken: UUID())
        )
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: exactBytes,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw LocalAutomationClientCredentialCustodyFailure.unavailable
        }
        do {
            // Normalize so the invariant never depends on creation-attribute
            // semantics; the parent directory is already owner-only.
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: temporaryURL.path
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw LocalAutomationClientCredentialCustodyFailure.unavailable
        }
        do {
            if fileManager.fileExists(atPath: credentialPath) {
                _ = try fileManager.replaceItemAt(
                    credentialFileURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly, .withoutCreatingBackup]
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: credentialFileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw LocalAutomationClientCredentialCustodyFailure.unavailable
        }

        guard try loadCredential() == exactBytes else {
            try? fileManager.removeItem(at: credentialFileURL)
            throw LocalAutomationClientCredentialCustodyFailure.readbackMismatch
        }
    }

    /// §0.3 revocation is authority-first: the client stops presenting the
    /// credential, and the file deletion itself is best effort — it can
    /// never make revocation succeed or fail, so this operation never throws
    /// and only reports whether the path is absent afterwards. Only the
    /// credential regular file (or a symbolic link AT its path) is removed;
    /// a non-regular occupant is left in place and reported as not removed.
    @discardableResult
    package func removeCredential() -> Bool {
        let fileManager = FileManager.default
        let credentialPath = credentialFileURL.path
        if Self.isSymbolicLink(atPath: credentialPath) {
            return (try? fileManager.removeItem(atPath: credentialPath)) != nil
        }
        guard fileManager.fileExists(atPath: credentialPath) else { return true }
        let attributes = try? Self.attributes(atPath: credentialPath)
        guard (attributes?[.type] as? FileAttributeType) == .typeRegular else {
            return false
        }
        return (try? fileManager.removeItem(atPath: credentialPath)) != nil
    }

    /// Reclaims THIS component's own interrupted atomic-write temporaries —
    /// sibling names matching `isOrphanedTemporaryFileName` that are regular
    /// files or symbolic links — and nothing else: the credential file,
    /// unrelated names, and non-regular occupants are all left untouched.
    /// Removal failure is fail-closed, matching the §0.3 rule that custody
    /// cleanup failure blocks publication.
    package func cleanOrphanedTemporaryFiles() throws {
        let fileManager = FileManager.default
        if Self.isSymbolicLink(atPath: directoryURL.path) {
            throw LocalAutomationClientCredentialCustodyFailure.unsafeDirectory
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
        } catch {
            throw LocalAutomationClientCredentialCustodyFailure.unavailable
        }
        for name in names where Self.isOrphanedTemporaryFileName(name) {
            let path = directoryURL.appendingPathComponent(name).path
            let isLink = Self.isSymbolicLink(atPath: path)
            let attributes = try? Self.attributes(atPath: path)
            let fileType = attributes?[.type] as? FileAttributeType
            guard isLink || fileType == .typeRegular else { continue }
            do {
                try fileManager.removeItem(atPath: path)
            } catch {
                throw LocalAutomationClientCredentialCustodyFailure.unavailable
            }
        }
    }

    // MARK: - Filesystem primitives (FileManager-only)

    /// Creates the custody directory at mode `0700` when absent; when it
    /// already exists group/other-accessible, installation tightens it to
    /// owner-only rather than serving a loose container. A symbolic-link or
    /// non-directory occupant is refused.
    private func prepareDirectory() throws {
        let fileManager = FileManager.default
        if Self.isSymbolicLink(atPath: directoryURL.path) {
            throw LocalAutomationClientCredentialCustodyFailure.unsafeDirectory
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ) else {
            do {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)],
                    ofItemAtPath: directoryURL.path
                )
            } catch {
                throw LocalAutomationClientCredentialCustodyFailure.unavailable
            }
            return
        }
        guard isDirectory.boolValue else {
            throw LocalAutomationClientCredentialCustodyFailure.unsafeDirectory
        }
        let attributes = try Self.attributes(atPath: directoryURL.path)
        guard let mode = attributes[.posixPermissions] as? NSNumber else {
            throw LocalAutomationClientCredentialCustodyFailure.unavailable
        }
        guard mode.intValue & 0o077 != 0 else { return }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            throw LocalAutomationClientCredentialCustodyFailure.unavailable
        }
    }

    private static func attributes(
        atPath path: String
    ) throws -> [FileAttributeKey: Any] {
        do {
            return try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw LocalAutomationClientCredentialCustodyFailure.unavailable
        }
    }

    /// FileManager-only no-follow probe: destination resolution succeeds
    /// exactly when the path itself is a symbolic link (broken links count;
    /// the link destination is never touched).
    private static func isSymbolicLink(atPath path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
