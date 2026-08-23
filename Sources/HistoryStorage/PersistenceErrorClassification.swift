/// PersistenceErrorClassification.swift — platform persistence errors to the
/// closed HistoryCore failure vocabulary (docs/05-authority-kernel.md §16).
import Foundation
import HistoryCore

/// Owns the narrow semantic classification performed after a durable
/// transaction fails. It inspects platform domains/codes only: localized
/// descriptions are presentation text and never determine behavior.
internal enum PersistenceErrorClassification {
    internal static func transactionFailure(for error: any Error) -> HistoryFailure {
        emitRuntimeDiagnostics(for: error)
        let platformError = error as NSError
        if isInsufficientDiskSpace(platformError) {
            return .temporarilyUnavailable(.insufficientDiskSpace)
        }
        if let underlying = platformError.userInfo[NSUnderlyingErrorKey] as? NSError,
           isInsufficientDiskSpace(underlying) {
            return .temporarilyUnavailable(.insufficientDiskSpace)
        }

        return .persistence(.transaction)
    }

    private static func isInsufficientDiskSpace(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.Code.fileWriteOutOfSpace.rawValue {
            return true
        }
        return error.domain == NSPOSIXErrorDomain
            && error.code == POSIXErrorCode.ENOSPC.rawValue
    }

    #if DEBUG || CLIPY_RUNTIME_DIAGNOSTICS
    /// Evidence-only details emitted before the platform error is translated
    /// into `HistoryFailure`. The physical APFS probe needs the complete owning
    /// wrapper chain because that evidence is intentionally absent from the
    /// public failure. This renderer is compiled out of ordinary Release builds;
    /// its remaining bounds keep a cyclic or pathological platform error from
    /// hiding the useful runner log behind unbounded output. `Data` values are
    /// represented only by type and byte count because they can hold clipboard
    /// payload bytes (Review Card 6B physical evidence).
    internal static func diagnosticLines(for error: any Error) -> [String] {
        let maxErrorDepth = 8
        let maxUserInfoEntries = 64
        var candidates: [String] = []
        var seenErrors: Set<ObjectIdentifier> = []
        var errorChainWasTruncated = false
        var swiftError: any Error = error
        var platformError = error as NSError

        for depth in 0..<maxErrorDepth {
            let edge = depth == 0 ? "root" : "underlying"
            let errorIdentity = ObjectIdentifier(platformError)
            guard seenErrors.insert(errorIdentity).inserted else {
                candidates.append(
                    "CLIPY_PERSISTENCE_ERROR depth=\(depth) edge=\(edge) "
                        + "cycle=true swift_type=\(quoted(reflectedType(of: swiftError)))"
                )
                break
            }

            candidates.append(
                "CLIPY_PERSISTENCE_ERROR depth=\(depth) edge=\(edge) "
                    + "swift_type=\(quoted(reflectedType(of: swiftError))) "
                    + "domain=\(quoted(platformError.domain)) "
                    + "code=\(platformError.code) "
                    + "localized_description=\(quoted(platformError.localizedDescription)) "
                    + "user_info_count=\(platformError.userInfo.count)"
            )

            let keys = platformError.userInfo.keys.sorted()
            for (index, key) in keys.prefix(maxUserInfoEntries).enumerated() {
                guard let value = platformError.userInfo[key] else {
                    continue
                }
                var visitedContainers: Set<ObjectIdentifier> = []
                let renderedValue = diagnosticDescription(
                    of: value,
                    depth: 0,
                    visitedContainers: &visitedContainers
                )
                candidates.append(
                    "CLIPY_PERSISTENCE_ERROR_USER_INFO depth=\(depth) "
                        + "index=\(index) key=\(quoted(key)) "
                        + "value_type=\(quoted(reflectedType(of: value))) "
                        + "value=\(quoted(renderedValue))"
                )
            }
            if keys.count > maxUserInfoEntries {
                candidates.append(
                    "CLIPY_PERSISTENCE_ERROR_USER_INFO depth=\(depth) "
                        + "truncated_entries=\(keys.count - maxUserInfoEntries) "
                        + "entry_limit=\(maxUserInfoEntries)"
                )
            }

            guard let underlying = platformError.userInfo[
                NSUnderlyingErrorKey
            ] as? NSError else {
                break
            }
            if depth == maxErrorDepth - 1 {
                errorChainWasTruncated = true
            }
            swiftError = underlying
            platformError = underlying
        }
        if errorChainWasTruncated {
            candidates.append(
                "CLIPY_PERSISTENCE_ERROR truncated_error_chain=true "
                    + "depth_limit=\(maxErrorDepth)"
            )
        }
        return boundedDiagnosticLines(candidates)
    }

    private static func emitRuntimeDiagnostics(for error: any Error) {
        guard ProcessInfo.processInfo.environment[
            "CLIPY_RUNTIME_DIAGNOSTICS"
        ] == "1" else {
            return
        }
        let lines = diagnosticLines(for: error)
        guard !lines.isEmpty else {
            return
        }
        FileHandle.standardError.write(
            Data((lines.joined(separator: "\n") + "\n").utf8)
        )
    }

    private static func reflectedType(of value: Any) -> String {
        String(reflecting: Swift.type(of: value))
    }

    private static func quoted(_ value: String) -> String {
        "\"\(boundedText(escaped(value), utf8Limit: 1_024))\""
    }

    private static func escaped(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x09:
                result += "\\t"
            case 0x0A:
                result += "\\n"
            case 0x0D:
                result += "\\r"
            case 0x22:
                result += "\\\""
            case 0x5C:
                result += "\\\\"
            case 0x00...0x1F, 0x7F:
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func diagnosticDescription(
        of value: Any,
        depth: Int,
        visitedContainers: inout Set<ObjectIdentifier>
    ) -> String {
        let maxValueDepth = 6
        let maxCollectionEntries = 16
        guard depth < maxValueDepth else {
            return "<value-depth-limit type=\(reflectedType(of: value))>"
        }

        if let data = value as? Data {
            return "Data(byte_count=\(data.count))"
        }
        if let string = value as? String {
            return string
        }
        if let url = value as? URL {
            return url.absoluteString
        }
        if let error = value as? NSError {
            return "NSError(type=\(reflectedType(of: error)), "
                + "domain=\(error.domain), code=\(error.code), "
                + "localized_description=\(error.localizedDescription))"
        }
        if value is NSNull {
            return "null"
        }
        if let dictionary = value as? NSDictionary {
            let identity = ObjectIdentifier(dictionary)
            guard visitedContainers.insert(identity).inserted else {
                return "<cycle type=\(reflectedType(of: value))>"
            }
            defer { visitedContainers.remove(identity) }

            var entries: [(key: String, value: Any)] = []
            for key in dictionary.allKeys {
                entries.append((
                    key: String(describing: key),
                    value: dictionary.object(forKey: key) ?? NSNull()
                ))
            }
            entries.sort { $0.key < $1.key }
            let rendered = entries.prefix(maxCollectionEntries).map { entry in
                "\(entry.key): " + diagnosticDescription(
                    of: entry.value,
                    depth: depth + 1,
                    visitedContainers: &visitedContainers
                )
            }
            let omitted = entries.count - rendered.count
            let suffix = omitted > 0 ? ", <truncated_entries=\(omitted)>" : ""
            return "Dictionary(count=\(entries.count)){\(rendered.joined(separator: ", "))\(suffix)}"
        }
        if let array = value as? NSArray {
            let identity = ObjectIdentifier(array)
            guard visitedContainers.insert(identity).inserted else {
                return "<cycle type=\(reflectedType(of: value))>"
            }
            defer { visitedContainers.remove(identity) }

            let retainedCount = min(array.count, maxCollectionEntries)
            var rendered: [String] = []
            for index in 0..<retainedCount {
                rendered.append(diagnosticDescription(
                    of: array[index],
                    depth: depth + 1,
                    visitedContainers: &visitedContainers
                ))
            }
            let omitted = array.count - rendered.count
            let suffix = omitted > 0 ? ", <truncated_entries=\(omitted)>" : ""
            return "Array(count=\(array.count))[\(rendered.joined(separator: ", "))\(suffix)]"
        }
        if let set = value as? NSSet {
            let identity = ObjectIdentifier(set)
            guard visitedContainers.insert(identity).inserted else {
                return "<cycle type=\(reflectedType(of: value))>"
            }
            defer { visitedContainers.remove(identity) }

            let rendered = set.allObjects.map { element in
                diagnosticDescription(
                    of: element,
                    depth: depth + 1,
                    visitedContainers: &visitedContainers
                )
            }.sorted()
            let retained = Array(rendered.prefix(maxCollectionEntries))
            let omitted = rendered.count - retained.count
            let suffix = omitted > 0 ? ", <truncated_entries=\(omitted)>" : ""
            return "Set(count=\(rendered.count)){\(retained.joined(separator: ", "))\(suffix)}"
        }
        return String(describing: value)
    }

    private static func boundedText(_ value: String, utf8Limit: Int) -> String {
        guard value.utf8.count > utf8Limit else {
            return value
        }
        let suffix = "…<truncated utf8_bytes=\(value.utf8.count)>"
        let prefixLimit = max(0, utf8Limit - suffix.utf8.count)
        var prefix = ""
        var prefixByteCount = 0
        for scalar in value.unicodeScalars {
            let scalarText = String(scalar)
            let scalarByteCount = scalarText.utf8.count
            guard prefixByteCount + scalarByteCount <= prefixLimit else {
                break
            }
            prefix.unicodeScalars.append(scalar)
            prefixByteCount += scalarByteCount
        }
        return prefix + suffix
    }

    private static func boundedDiagnosticLines(_ candidates: [String]) -> [String] {
        let maxLines = 128
        let maxLineUTF8Bytes = 4_096
        let maxTotalUTF8Bytes = 65_536
        let truncationLine = "CLIPY_PERSISTENCE_ERROR diagnostics_truncated=true"
        var lines: [String] = []
        var totalByteCount = 0

        for candidate in candidates {
            guard lines.count < maxLines else {
                let removed = lines.removeLast()
                totalByteCount -= removed.utf8.count
                if !lines.isEmpty {
                    totalByteCount -= 1
                }
                appendTruncationLine(
                    truncationLine,
                    to: &lines,
                    totalByteCount: &totalByteCount,
                    totalLimit: maxTotalUTF8Bytes
                )
                break
            }
            let line = boundedText(candidate, utf8Limit: maxLineUTF8Bytes)
            let separatorByteCount = lines.isEmpty ? 0 : 1
            guard totalByteCount + separatorByteCount + line.utf8.count
                <= maxTotalUTF8Bytes else {
                appendTruncationLine(
                    truncationLine,
                    to: &lines,
                    totalByteCount: &totalByteCount,
                    totalLimit: maxTotalUTF8Bytes
                )
                break
            }
            lines.append(line)
            totalByteCount += separatorByteCount + line.utf8.count
        }
        return lines
    }

    private static func appendTruncationLine(
        _ truncationLine: String,
        to lines: inout [String],
        totalByteCount: inout Int,
        totalLimit: Int
    ) {
        while !lines.isEmpty {
            let separatorByteCount = lines.isEmpty ? 0 : 1
            if totalByteCount + separatorByteCount + truncationLine.utf8.count
                <= totalLimit {
                break
            }
            let removed = lines.removeLast()
            totalByteCount -= removed.utf8.count
            if !lines.isEmpty {
                totalByteCount -= 1
            }
        }
        let separatorByteCount = lines.isEmpty ? 0 : 1
        if totalByteCount + separatorByteCount + truncationLine.utf8.count
            <= totalLimit {
            lines.append(truncationLine)
            totalByteCount += separatorByteCount + truncationLine.utf8.count
        }
    }
    #else
    private static func emitRuntimeDiagnostics(for _: any Error) {}
    #endif
}
