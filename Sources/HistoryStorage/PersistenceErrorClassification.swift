/// PersistenceErrorClassification.swift — platform persistence errors to the
/// closed HistoryCore failure vocabulary (docs/05-authority-kernel.md §16).
import Foundation
import HistoryCore

/// Owns the narrow semantic classification performed after a durable
/// transaction fails. It inspects platform domains/codes only: localized
/// descriptions are presentation text and never determine behavior.
internal enum PersistenceErrorClassification {
    internal static func transactionFailure(for error: any Error) -> HistoryFailure {
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
}
