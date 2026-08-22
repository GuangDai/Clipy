/// PersistenceErrorClassificationTests — platform write-failure translation
/// at the HistoryStorage boundary (docs/05-authority-kernel.md §16).
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct PersistenceErrorClassificationTests {
    @Test func cocoaOutOfSpaceIsTemporarilyUnavailable() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileWriteOutOfSpace.rawValue
        )

        #expect(
            PersistenceErrorClassification.transactionFailure(for: error)
                == .temporarilyUnavailable(.insufficientDiskSpace)
        )
    }

    @Test func directPosixENOSPCIsTemporarilyUnavailable() {
        let error = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.ENOSPC.rawValue)
        )

        #expect(
            PersistenceErrorClassification.transactionFailure(for: error)
                == .temporarilyUnavailable(.insufficientDiskSpace)
        )
    }

    @Test func oneUnderlyingPosixENOSPCWrapperIsTemporarilyUnavailable() {
        let underlying = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.ENOSPC.rawValue)
        )
        let wrapper = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileWriteUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        #expect(
            PersistenceErrorClassification.transactionFailure(for: wrapper)
                == .temporarilyUnavailable(.insufficientDiskSpace)
        )
    }

    @Test func unrelatedErrorRemainsTransactionFailure() {
        let unrelated = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadNoSuchFile.rawValue
        )
        #expect(
            PersistenceErrorClassification.transactionFailure(for: unrelated)
                == .persistence(.transaction)
        )
    }
}
