import Foundation
import LocalAutomation

/// Process presentation only: raw output uses the existing content-read JSON
/// request and its permission. It never sends a mutation or selects a transport.
struct CLIArguments {
    let rawType: String?

    init?(_ arguments: [String]) {
        if arguments.isEmpty {
            rawType = nil
        } else if arguments.count == 3, arguments[0] == "--raw", arguments[1] == "--type",
                  !arguments[2].isEmpty, arguments[2].utf8.count <= 512 {
            rawType = arguments[2]
        } else {
            return nil
        }
    }

    /// Called after the authoritative wire decoder has accepted the request.
    func accepts(_ request: Data) -> Bool {
        guard rawType != nil else { return true }
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let operation = object["operation"] as? String else { return false }
        return operation == "detailsEffective" || operation == "pasteEffective"
    }

    func output(_ reply: LocalAutomationOutput) -> CLIOutput {
        guard let rawType else { return CLIOutput(reply) }
        guard reply.exitCode == 0 else {
            return .init(exitCode: reply.exitCode, stdout: Data(), stderr: reply.stderr)
        }
        guard let object = try? JSONSerialization.jsonObject(with: reply.stdout) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let representations = result["representations"] as? [[String: Any]] else {
            return .failure(.notReady, raw: true)
        }
        // Swift String equality folds canonical Unicode spellings. Clipboard
        // type identifiers are exact UTF-8 identifiers (ClipboardFormats).
        let matches = representations.filter {
            ($0["typeIdentifier"] as? String)?.utf8.elementsEqual(rawType.utf8) == true
        }
        guard !matches.isEmpty else {
            return .init(exitCode: 4, stdout: Data(), stderr: Data("clipyctl: not_found\n".utf8))
        }
        guard matches.count == 1,
              let encoded = matches[0]["bytesBase64"] as? String,
              let bytes = Data(base64Encoded: encoded) else {
            return .failure(.notReady, raw: true)
        }
        return .init(exitCode: 0, stdout: bytes, stderr: Data())
    }

    static func help(executablePath: String) -> String {
        let executable = "'" + executablePath.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        return """
        Usage: clipyctl [--raw --type TYPE]
               clipyctl --help | -h
               clipyctl --version

        Send one UTF-8 JSON request on stdin; receive one JSON reply on stdout.
        Enable Local Automation in Clipy Settings > Automation and grant permissions.

        Operations: browsePreview, detailsEffective, pasteEffective, pin, unpin,
                    delete, reviseContent.
        Example command (recent history; executable bundled inside Clipy.app):
        printf '%s\\n' '{"protocolVersion":1,"requestID":"12345678-1234-1234-1234-123456789abc","operation":"browsePreview","arguments":{"limit":20}}' | \(executable)

        --raw --type TYPE  For detailsEffective or pasteEffective only: write exactly
                           one representation's bytes, with no newline or JSON.
                           TYPE matches the exact returned typeIdentifier.
                           Failures leave stdout empty and report a code on stderr.
        --help, --version  Do not read stdin, credentials, or history, or launch Clipy.

        Exit: 0 success; 2 invalid input; 3 denied; 4 missing/stale; 5 unavailable;
              6 persistence failure. Mutations are never automatically retried.

        """
    }
}

struct CLIOutput {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data

    init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    init(_ output: LocalAutomationOutput) {
        self.init(exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr)
    }

    static func failure(_ code: LocalAutomationClientFailure, raw: Bool) -> Self {
        let output = LocalAutomationClient.failure(code)
        return .init(exitCode: output.exitCode, stdout: raw ? Data() : output.stdout, stderr: output.stderr)
    }
}
