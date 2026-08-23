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
    @Test func directErrorDiagnosticIncludesOwningNSErrorEvidence() {
        let error = NSError(
            domain: NSPOSIXErrorDomain,
            code: 28,
            userInfo: [
                NSLocalizedDescriptionKey: "write failed at /Volumes/Clipy ENOSPC/history.store",
                NSFilePathErrorKey: "/Volumes/Clipy ENOSPC/history.store",
                "probe-data": Data("SECRET-PAYLOAD".utf8),
            ]
        )

        let diagnostics = PersistenceErrorClassification.diagnosticLines(for: error)
            .joined(separator: "\n")
        #expect(diagnostics.contains("depth=0 edge=root"))
        #expect(diagnostics.contains("swift_type=\"Foundation.NSError\""))
        #expect(diagnostics.contains("domain=\"NSPOSIXErrorDomain\" code=28"))
        #expect(diagnostics.contains(
            "localized_description=\"write failed at /Volumes/Clipy ENOSPC/history.store\""
        ))
        #expect(diagnostics.contains("key=\"NSFilePath\""))
        #expect(diagnostics.contains(
            "value=\"/Volumes/Clipy ENOSPC/history.store\""
        ))
        #expect(diagnostics.contains("key=\"probe-data\""))
        #expect(diagnostics.contains("value=\"Data(byte_count=14)\""))
        #expect(!diagnostics.contains("SECRET-PAYLOAD"))
    }

    @Test func oneWrapperDiagnosticPreservesDescriptionsPathsAndUserInfo() {
        let underlying = NSError(
            domain: NSPOSIXErrorDomain,
            code: 28,
            userInfo: [NSLocalizedDescriptionKey: "device has no space"]
        )
        let wrapper = NSError(
            domain: NSCocoaErrorDomain,
            code: 512,
            userInfo: [
                NSUnderlyingErrorKey: underlying,
                NSFilePathErrorKey: "/private/fixture.store",
            ]
        )

        let lines = PersistenceErrorClassification.diagnosticLines(for: wrapper)
        let diagnostics = lines.joined(separator: "\n")
        #expect(lines.count >= 5)
        #expect(diagnostics.contains(
            "depth=0 edge=root swift_type=\"Foundation.NSError\" "
                + "domain=\"NSCocoaErrorDomain\" code=512"
        ))
        #expect(diagnostics.contains("key=\"NSFilePath\""))
        #expect(diagnostics.contains("value=\"/private/fixture.store\""))
        #expect(diagnostics.contains(
            "depth=1 edge=underlying swift_type=\"Foundation.NSError\" "
                + "domain=\"NSPOSIXErrorDomain\" code=28"
        ))
        #expect(diagnostics.contains("localized_description=\"device has no space\""))
    }

    @Test func unknownDomainIsSerializedVerbatimForEvidence() {
        let error = NSError(
            domain: "private.fixture.domain",
            code: -7,
            userInfo: [NSLocalizedDescriptionKey: "/private/fixture.store"]
        )

        let diagnostics = PersistenceErrorClassification.diagnosticLines(for: error)
            .joined(separator: "\n")
        #expect(diagnostics.contains("domain=\"private.fixture.domain\" code=-7"))
        #expect(diagnostics.contains(
            "localized_description=\"/private/fixture.store\""
        ))
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
        let diagnostics = PersistenceErrorClassification.diagnosticLines(for: cocoa)
            .joined(separator: "\n")
        #expect(diagnostics.contains("depth=0 edge=root"))
        #expect(diagnostics.contains("domain=\"NSCocoaErrorDomain\" code=512"))
        #expect(diagnostics.contains("depth=1 edge=underlying"))
        #expect(diagnostics.contains("domain=\"NSSQLiteErrorDomain\" code=13"))
        #expect(diagnostics.contains("depth=2 edge=underlying"))
        #expect(diagnostics.contains("domain=\"NSPOSIXErrorDomain\" code=28"))
    }

    @Test func diagnosticRenderingBoundsCyclesCollectionsLinesAndTotalOutput() {
        let cycle = NSMutableDictionary()
        cycle["path"] = "/Volumes/Clipy ENOSPC/cyclic.store"
        cycle["self"] = cycle

        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: String(repeating: "localized-", count: 2_000),
            "cycle": cycle,
            "payload": Data(repeating: 0x41, count: 16_384),
            "large": String(repeating: "value-", count: 20_000),
        ]
        for index in 0..<60 {
            userInfo["entry-\(index)"] = "value-\(index)"
        }
        let error = NSError(domain: "fixture.large", code: 99, userInfo: userInfo)

        let lines = PersistenceErrorClassification.diagnosticLines(for: error)
        let diagnostics = lines.joined(separator: "\n")
        #expect(lines.count <= 128)
        #expect(lines.allSatisfy { $0.utf8.count <= 4_096 })
        #expect(diagnostics.utf8.count <= 65_536)
        #expect(diagnostics.contains("<cycle"))
        #expect(diagnostics.contains("Data(byte_count=16384)"))
        #expect(!diagnostics.contains(String(repeating: "A", count: 32)))
        #expect(diagnostics.contains("truncated"))
    }

    @Test func diagnosticRenderingMarksErrorChainDepthLimit() {
        var error = NSError(domain: "fixture.layer.11", code: 11)
        for depth in stride(from: 10, through: 0, by: -1) {
            error = NSError(
                domain: "fixture.layer.\(depth)",
                code: depth,
                userInfo: [NSUnderlyingErrorKey: error]
            )
        }

        let diagnostics = PersistenceErrorClassification.diagnosticLines(for: error)
            .joined(separator: "\n")
        #expect(diagnostics.contains("depth=0 edge=root"))
        #expect(diagnostics.contains("depth=7 edge=underlying"))
        #expect(!diagnostics.contains("depth=8 edge=underlying"))
        #expect(diagnostics.contains(
            "CLIPY_PERSISTENCE_ERROR truncated_error_chain=true depth_limit=8"
        ))
    }

    @Test func diagnosticRenderingMarksTotalOutputLimit() {
        var userInfo: [String: Any] = [:]
        for index in 0..<64 {
            userInfo["entry-\(index)"] = String(repeating: "wide-value-", count: 1_000)
        }
        let error = NSError(domain: "fixture.total", code: 1, userInfo: userInfo)

        let lines = PersistenceErrorClassification.diagnosticLines(for: error)
        let diagnostics = lines.joined(separator: "\n")
        #expect(lines.count <= 128)
        #expect(diagnostics.utf8.count <= 65_536)
        #expect(diagnostics.contains(
            "CLIPY_PERSISTENCE_ERROR diagnostics_truncated=true"
        ))
    }
    #endif
}
