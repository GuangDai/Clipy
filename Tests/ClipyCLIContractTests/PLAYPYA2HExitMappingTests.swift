import ClipyCLIContract
import Foundation
import Testing

struct PLAYPYA2HExitMappingTests {
    @Test func errorCodesHaveScriptReadableNamesAndExitClasses() throws {
        let rows: [(ClipyCLIErrorCode, String, Int32)] = [
            (.invalidJSON, "invalid_json", 2),
            (.invalidRequest, "invalid_request", 2),
            (.unsupportedProtocolVersion, "unsupported_protocol_version", 2),
            (.unknownOperation, "unknown_operation", 2),
            (.requestTooLarge, "request_too_large", 2),
            (.responseTooLarge, "response_too_large", 2),
            (.notEnrolled, "not_enrolled", 3),
            (.notGranted, "not_granted", 3),
            (.connectionRevoked, "connection_revoked", 3),
            (.authenticationFailed, "authentication_failed", 3),
            (.peerRejected, "peer_rejected", 3),
            (.notFound, "not_found", 4),
            (.cursorExpired, "cursor_expired", 4),
            (.contentStale, "content_stale", 4),
            (.locatorInvalidated, "locator_invalidated", 4),
            (.notReady, "not_ready", 5),
            (.rateLimited, "rate_limited", 5),
            (.busy, "busy", 5),
            (.timeout, "timeout", 5),
            (.cancelled, "cancelled", 5),
            (.outcomeUnknown, "outcome_unknown", 5),
            (.storeOpenFailed, "store_open_failed", 6),
            (.corruptData, "corrupt_data", 6),
            (.invariantViolation, "invariant_violation", 6),
            (.transactionFailed, "transaction_failed", 6),
            (.auditFailed, "audit_failed", 6),
        ]

        for (code, expectedRaw, expectedExit) in rows {
            let output = ClipyCLIContract.render(
                .failure(requestID: nil, code: code)
            )
            #expect(output.exitCode == expectedExit)
            let reply = try #require(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
            #expect(reply["ok"] as? Bool == false)
            #expect(reply["requestID"] is NSNull)
            #expect((reply["error"] as? [String: String])?["code"] == expectedRaw)
            #expect(utf8(output.stderr) == "clipyctl: \(expectedRaw)\n")
        }
    }
}
