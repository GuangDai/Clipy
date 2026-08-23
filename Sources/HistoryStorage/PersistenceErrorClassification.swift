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
    /// Evidence-only metadata emitted before the platform error is translated
    /// into `HistoryFailure`. The physical APFS probe needs this owning-boundary
    /// view because the original wrapper chain is intentionally absent from the
    /// public failure. Values from `userInfo`, localized text, domains outside
    /// the closed label map, paths, and clipboard content never cross this seam.
    internal static func diagnosticLines(for error: any Error) -> [String] {
        var lines: [String] = []
        var platformError = error as NSError
        for depth in 0..<8 {
            let edge = depth == 0 ? "root" : "underlying"
            lines.append(
                "CLIPY_PERSISTENCE_ERROR depth=\(depth) edge=\(edge) "
                    + "domain=\(diagnosticDomain(for: platformError)) "
                    + "code=\(platformError.code)"
            )
            guard let underlying = platformError.userInfo[
                NSUnderlyingErrorKey
            ] as? NSError else {
                break
            }
            platformError = underlying
        }
        return lines
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

    private static func diagnosticDomain(for error: NSError) -> String {
        switch error.domain {
        case NSCocoaErrorDomain:
            return "cocoa"
        case NSPOSIXErrorDomain:
            return "posix"
        case "NSSQLiteErrorDomain":
            return "sqlite"
        default:
            return "other"
        }
    }
    #else
    private static func emitRuntimeDiagnostics(for _: any Error) {}
    #endif
}
