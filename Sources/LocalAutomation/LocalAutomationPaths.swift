import Darwin
import Foundation
import HistoryStorage

/// The first-party client and app use the same local locations. Requests
/// cannot select a socket, credential file, or History store (V2-05).
public enum LocalAutomationPaths {
    public static var endpointURL: URL {
        URL(fileURLWithPath: "/tmp/clipy-\(geteuid())", isDirectory: true)
            .appendingPathComponent("automation.sock")
    }

    public static var clientDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipy", isDirectory: true)
            .appendingPathComponent("LocalAutomation", isDirectory: true)
    }

    public static var credentialURL: URL {
        clientDirectory.appendingPathComponent(LocalAutomationClientCredentialCustody.credentialFileName)
    }

    /// Use the same current-file reader as enrollment, including its existing
    /// owner/mode and no-follow semantics. No second custody implementation.
    public static func readCredential() throws -> Data? {
        try LocalAutomationClientCredentialCustody(directoryURL: clientDirectory).loadCredential()
    }
}
