/// ClipyCLIReplyRenderer — controlled typed reply values, stable exit classes,
/// and deterministic pure output bytes (V2-05 §0.1.2; PLAY-PY-A2G–A2H).
import Foundation

package extension ClipyCLIContract {
    static func render(_ reply: ClipyCLIReply) -> ClipyCLIProcessOutput {
        guard let rendered = renderUnchecked(reply) else {
            let code = ClipyCLIErrorCode.responseTooLarge
            guard let failure = renderUnchecked(
                .failure(requestID: reply.requestID, code: code)
            ) else {
                preconditionFailure("the fixed error envelope fits its response bound")
            }
            return processOutput(stdout: failure, errorCode: code)
        }
        return processOutput(stdout: rendered, errorCode: reply.errorCode)
    }

    static func render(_ failure: ClipyCLIRequestFailure) -> ClipyCLIProcessOutput {
        render(.failure(requestID: failure.requestID, code: failure.code))
    }

    private static func renderUnchecked(_ reply: ClipyCLIReply) -> Data? {
        var output = BoundedJSONWriter(maximumBytes: maximumResponseBytes)
        switch reply.payload {
        case let .success(requestID, result):
            output.appendASCII("{\"ok\":true,\"protocolVersion\":1,\"requestID\":")
            output.appendJSON(requestID.rawValue)
            output.appendASCII(",\"result\":{\"items\":[")
            for (index, item) in result.items.enumerated() {
                if index != 0 { output.appendASCII(",") }
                output.appendASCII("{\"lastCopiedAt\":")
                output.appendJSON(item.lastCopiedAt)
                output.appendASCII(",\"locator\":")
                output.appendJSON(item.locator)
                output.appendASCII(",\"pinned\":")
                output.appendASCII(item.pinned ? "true" : "false")
                output.appendASCII(",\"snippet\":")
                if let snippet = item.snippet {
                    output.appendJSON(snippet)
                } else {
                    output.appendASCII("null")
                }
                output.appendASCII(",\"title\":")
                output.appendJSON(item.title)
                output.appendASCII(",\"typeIdentifiers\":[")
                for (typeIndex, identifier) in item.typeIdentifiers.enumerated() {
                    if typeIndex != 0 { output.appendASCII(",") }
                    output.appendJSON(identifier)
                }
                output.appendASCII("]}")
            }
            output.appendASCII("],\"nextCursor\":")
            if let cursor = result.nextCursor {
                output.appendJSON(cursor)
            } else {
                output.appendASCII("null")
            }
            output.appendASCII("}}")
        case let .failure(requestID, code):
            output.appendASCII("{\"error\":{\"code\":")
            output.appendJSON(code.rawValue)
            output.appendASCII("},\"ok\":false,\"protocolVersion\":1,\"requestID\":")
            if let requestID {
                output.appendJSON(requestID.rawValue)
            } else {
                output.appendASCII("null")
            }
            output.appendASCII("}")
        }
        output.appendByte(0x0A)
        return output.exceeded ? nil : output.data
    }

    private static func processOutput(
        stdout: Data,
        errorCode: ClipyCLIErrorCode?
    ) -> ClipyCLIProcessOutput {
        guard let errorCode else {
            return .init(exitCode: 0, stdout: stdout, stderr: Data())
        }
        var stderr = Data("clipyctl: ".utf8)
        stderr.append(contentsOf: errorCode.rawValue.utf8)
        stderr.append(0x0A)
        return .init(exitCode: errorCode.exitCode, stdout: stdout, stderr: stderr)
    }
}

package enum ClipyCLIValueFailure: Error, Equatable, Sendable {
    case invalidValue
}

package struct ClipyCLIBrowsePreviewItem: Equatable, Sendable {
    package let locator: String
    package let title: String
    package let typeIdentifiers: [String]
    package let lastCopiedAt: String
    package let pinned: Bool
    package let snippet: String?

    package init(
        locator: String,
        title: String,
        typeIdentifiers: [String],
        lastCopiedAt: String,
        pinned: Bool,
        snippet: String?
    ) throws {
        guard !locator.isEmpty, locator.utf8.count <= 1_024,
              title.utf8.count <= 1_024,
              typeIdentifiers.count <= 32,
              typeIdentifiers.allSatisfy({ $0.utf8.count <= 512 }),
              snippet.map({ $0.count <= 322 }) ?? true,
              Self.isExactUTCDate(lastCopiedAt) else {
            throw ClipyCLIValueFailure.invalidValue
        }
        self.locator = locator
        self.title = title
        self.typeIdentifiers = typeIdentifiers
        self.lastCopiedAt = lastCopiedAt
        self.pinned = pinned
        self.snippet = snippet
    }

    private static func isExactUTCDate(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 24,
              bytes[4] == 0x2D, bytes[7] == 0x2D,
              bytes[10] == 0x54, bytes[13] == 0x3A,
              bytes[16] == 0x3A, bytes[19] == 0x2E,
              bytes[23] == 0x5A else {
            return false
        }
        let digitPositions = [
            0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18, 20, 21, 22,
        ]
        guard digitPositions.allSatisfy({ (0x30...0x39).contains(bytes[$0]) }) else {
            return false
        }
        func number(_ range: Range<Int>) -> Int {
            range.reduce(0) { $0 * 10 + Int(bytes[$1] - 0x30) }
        }
        let year = number(0..<4)
        let month = number(5..<7)
        let day = number(8..<10)
        let hour = number(11..<13)
        let minute = number(14..<16)
        let second = number(17..<19)
        guard year > 0, (1...12).contains(month),
              (0...23).contains(hour), (0...59).contains(minute),
              (0...59).contains(second) else {
            return false
        }
        let leap = year.isMultiple(of: 400)
            || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...days[month - 1]).contains(day)
    }
}

package struct ClipyCLIBrowsePreviewResult: Equatable, Sendable {
    package let items: [ClipyCLIBrowsePreviewItem]
    package let nextCursor: String?

    package init(items: [ClipyCLIBrowsePreviewItem], nextCursor: String?) throws {
        guard items.count <= 500,
              nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 4_096 }) ?? true else {
            throw ClipyCLIValueFailure.invalidValue
        }
        self.items = items
        self.nextCursor = nextCursor
    }
}

package struct ClipyCLIReply: Sendable {
    fileprivate enum Payload: Sendable {
        case success(ClipyCLIRequestID, ClipyCLIBrowsePreviewResult)
        case failure(ClipyCLIRequestID?, ClipyCLIErrorCode)
    }

    fileprivate let payload: Payload
    fileprivate let requestID: ClipyCLIRequestID?
    fileprivate let errorCode: ClipyCLIErrorCode?

    package static func success(
        for request: ClipyCLIRequest,
        result: ClipyCLIBrowsePreviewResult
    ) throws -> Self {
        guard result.items.count <= request.arguments.limit else {
            throw ClipyCLIValueFailure.invalidValue
        }
        return .init(
            payload: .success(request.requestID, result),
            requestID: request.requestID,
            errorCode: nil
        )
    }

    package static func failure(
        requestID: ClipyCLIRequestID?,
        code: ClipyCLIErrorCode
    ) -> Self {
        .init(
            payload: .failure(requestID, code),
            requestID: requestID,
            errorCode: code
        )
    }
}

package enum ClipyCLIErrorCode: String, CaseIterable, Equatable, Sendable {
    case invalidJSON = "invalid_json"
    case invalidRequest = "invalid_request"
    case unsupportedProtocolVersion = "unsupported_protocol_version"
    case unknownOperation = "unknown_operation"
    case requestTooLarge = "request_too_large"
    case responseTooLarge = "response_too_large"
    case notEnrolled = "not_enrolled"
    case notGranted = "not_granted"
    case connectionRevoked = "connection_revoked"
    case authenticationFailed = "authentication_failed"
    case peerRejected = "peer_rejected"
    case notFound = "not_found"
    case cursorExpired = "cursor_expired"
    case contentStale = "content_stale"
    case locatorInvalidated = "locator_invalidated"
    case notReady = "not_ready"
    case rateLimited = "rate_limited"
    case busy
    case timeout
    case cancelled
    case outcomeUnknown = "outcome_unknown"
    case storeOpenFailed = "store_open_failed"
    case corruptData = "corrupt_data"
    case invariantViolation = "invariant_violation"
    case transactionFailed = "transaction_failed"
    case auditFailed = "audit_failed"

    package var exitCode: Int32 {
        switch self {
        case .invalidJSON, .invalidRequest, .unsupportedProtocolVersion,
             .unknownOperation, .requestTooLarge, .responseTooLarge:
            2
        case .notEnrolled, .notGranted, .connectionRevoked,
             .authenticationFailed, .peerRejected:
            3
        case .notFound, .cursorExpired, .contentStale, .locatorInvalidated:
            4
        case .notReady, .rateLimited, .busy, .timeout, .cancelled,
             .outcomeUnknown:
            5
        case .storeOpenFailed, .corruptData, .invariantViolation,
             .transactionFailed, .auditFailed:
            6
        }
    }
}

package struct ClipyCLIProcessOutput: Equatable, Sendable {
    package let exitCode: Int32
    package let stdout: Data
    package let stderr: Data

    fileprivate init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}
