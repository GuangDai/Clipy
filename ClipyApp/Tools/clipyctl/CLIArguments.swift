import Foundation
import LocalAutomation

/// Shell commands build the existing JSON request; no arguments retains the
/// one-request stdin interface. Both use the same validation and single send.
struct CLIArguments {
    let rawType: String?
    let requestJSON: Data?

    init?(_ arguments: [String]) {
        guard let command = arguments.first else {
            rawType = nil
            requestJSON = nil
            return
        }
        switch command {
        case "--raw":
            guard arguments.count == 3, arguments[1] == "--type",
                  !arguments[2].isEmpty, arguments[2].utf8.count <= 512 else { return nil }
            rawType = arguments[2]
            requestJSON = nil
        case "read":
            guard arguments.count == 2 || arguments.count == 5 else { return nil }
            if arguments.count == 5 {
                guard arguments[2] == "--raw", arguments[3] == "--type",
                      !arguments[4].isEmpty, arguments[4].utf8.count <= 512 else { return nil }
                rawType = arguments[4]
            } else { rawType = nil }
            guard let json = Self.json(operation: "detailsEffective", arguments: ["locator": arguments[1]]) else {
                return nil
            }
            requestJSON = json
        case "pin", "unpin", "delete":
            guard arguments.count == 2,
                  let json = Self.json(operation: command, arguments: ["locator": arguments[1]]) else { return nil }
            rawType = nil
            requestJSON = json
        case "recent", "search":
            var fields: [String: Any] = ["limit": 20]
            var offset = 1
            if command == "search" {
                guard arguments.count >= 2 else { return nil }
                fields["query"] = arguments[1]
                fields["mode"] = "exact"
                offset = 2
            }
            var supplied: Set<String> = []
            while offset < arguments.count {
                let option = arguments[offset]
                guard offset + 1 < arguments.count, supplied.insert(option).inserted else { return nil }
                let value = arguments[offset + 1]
                switch option {
                case "--limit":
                    guard let limit = Int(value) else { return nil }
                    fields["limit"] = limit
                case "--cursor": fields["cursor"] = value
                case "--mode" where command == "search": fields["mode"] = value
                default: return nil
                }
                offset += 2
            }
            guard let json = Self.json(operation: "browsePreview", arguments: fields) else { return nil }
            rawType = nil
            requestJSON = json
        default: return nil
        }
    }

    private static func json(operation: String, arguments: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: [
            "protocolVersion": 1, "requestID": UUID().uuidString.lowercased(),
            "operation": operation, "arguments": arguments,
        ])
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
        Usage: clipyctl recent [--limit N] [--cursor CURSOR]
               clipyctl search QUERY [--mode exact|fuzzy|regexp] [--limit N] [--cursor CURSOR]
               clipyctl read LOCATOR [--raw --type TYPE]
               clipyctl pin|unpin|delete LOCATOR
               clipyctl [--raw --type TYPE] < request.json
               clipyctl --help | -h | --version

        Enable Local Automation in Clipy Settings > Automation and grant permissions.
        Commands return one JSON reply on stdout and do not read stdin.
        recent/search default to 20 items; N is 1...500. Search defaults to exact.
        Quote QUERY as one shell argument, including spaces or regexp characters.
        Pass nextCursor with the same command, query, mode and limit to continue.
        read/pin/unpin/delete use an item's opaque locator from recent/search.
        read returns current representations and contentVersion, without pasting.

        Examples (executable bundled inside Clipy.app):
        \(executable) recent --limit 20
        \(executable) search 'meeting notes' --mode exact
        \(executable) read '<locator>' --raw --type public.utf8-plain-text > clipboard.txt
        \(executable) pin '<locator>'

        Without a command, send one UTF-8 JSON request on stdin.
        JSON operations: browsePreview, detailsEffective, pasteEffective, pin, unpin,
                         delete, reviseContent. Revisions use complete JSON input.
        Example JSON request:
        {"protocolVersion":1,"requestID":"12345678-1234-1234-1234-123456789abc","operation":"browsePreview","arguments":{"limit":20}}

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
