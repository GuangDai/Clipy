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

    #if DEBUG
    @Test func directErrorDiagnosticContainsOnlySanitizedMetadata() {
        let error = NSError(
            domain: NSPOSIXErrorDomain,
            code: 28,
            userInfo: [NSLocalizedDescriptionKey: "sensitive path and content"]
        )

        #expect(PersistenceErrorClassification.diagnosticLines(for: error) == [
            "CLIPY_PERSISTENCE_ERROR depth=0 edge=root domain=posix code=28",
        ])
    }

    @Test func oneWrapperDiagnosticPreservesTheApprovedObservedShape() {
        let underlying = NSError(
            domain: NSPOSIXErrorDomain,
            code: 28,
            userInfo: ["private": "must never be serialized"]
        )
        let wrapper = NSError(
            domain: NSCocoaErrorDomain,
            code: 512,
            userInfo: [
                NSUnderlyingErrorKey: underlying,
                NSFilePathErrorKey: "/private/fixture.store",
            ]
        )

        #expect(PersistenceErrorClassification.diagnosticLines(for: wrapper) == [
            "CLIPY_PERSISTENCE_ERROR depth=0 edge=root domain=cocoa code=512",
            "CLIPY_PERSISTENCE_ERROR depth=1 edge=underlying domain=posix code=28",
        ])
    }

    @Test func unknownDomainIsCollapsedInsteadOfSerialized() {
        let error = NSError(
            domain: "private.fixture.domain",
            code: -7,
            userInfo: [NSLocalizedDescriptionKey: "/private/fixture.store"]
        )

        #expect(PersistenceErrorClassification.diagnosticLines(for: error) == [
            "CLIPY_PERSISTENCE_ERROR depth=0 edge=root domain=other code=-7",
        ])
    }

    @Test func deeperWrapperIsVisibleWithoutBroadeningClassification() {
        let posix = NSError(
            domain: NSPOSIXErrorDomain,
            code: 28
        )
        let sqlite = NSError(
            domain: "NSSQLiteErrorDomain",
            code: 13,
            userInfo: [NSUnderlyingErrorKey: posix]
        )
        let cocoa = NSError(
            domain: NSCocoaErrorDomain,
            code: 512,
            userInfo: [NSUnderlyingErrorKey: sqlite]
        )

        #expect(
            PersistenceErrorClassification.transactionFailure(for: cocoa)
                == .persistence(.transaction)
        )
        #expect(PersistenceErrorClassification.diagnosticLines(for: cocoa) == [
            "CLIPY_PERSISTENCE_ERROR depth=0 edge=root domain=cocoa code=512",
            "CLIPY_PERSISTENCE_ERROR depth=1 edge=underlying domain=sqlite code=13",
            "CLIPY_PERSISTENCE_ERROR depth=2 edge=underlying domain=posix code=28",
        ])
    }
    #endif
}
