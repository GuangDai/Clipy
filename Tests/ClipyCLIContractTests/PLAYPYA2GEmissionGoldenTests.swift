@testable import ClipyCLIContract
import Foundation
import Testing

struct PLAYPYA2GEmissionGoldenTests {
    @Test func browseReplyPreservesTheTitleTypeOrderAndCursor() throws {
        let request = try #require(
            decodedRequest(ClipyCLIContract.decodeRequest(requestBytes()))
        )
        let item = try ClipyCLIBrowsePreviewItem(
            locator: "opaque-1",
            title: "a \"title\"",
            typeIdentifiers: ["public.png", "public.text"],
            lastCopiedAt: "2026-08-23T12:34:56.007Z",
            pinned: true,
            snippet: nil
        )
        let result = try ClipyCLIBrowsePreviewResult(
            items: [item],
            nextCursor: "next"
        )

        let output = ClipyCLIContract.render(try .success(for: request, result: result))
        #expect(output.exitCode == 0)
        #expect(output.stderr.isEmpty)
        let reply = try #require(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
        #expect(reply["ok"] as? Bool == true)
        #expect(reply["protocolVersion"] as? Int == 1)
        #expect(reply["requestID"] as? String == request.requestID.rawValue)
        let body = try #require(reply["result"] as? [String: Any])
        let rows = try #require(body["items"] as? [[String: Any]])
        try #require(rows.count == 1)
        #expect(rows[0]["locator"] as? String == item.locator)
        #expect(rows[0]["title"] as? String == item.title)
        #expect(rows[0]["typeIdentifiers"] as? [String] == item.typeIdentifiers)
        #expect(rows[0]["lastCopiedAt"] as? String == item.lastCopiedAt)
        #expect(rows[0]["pinned"] as? Bool == item.pinned)
        #expect(rows[0]["snippet"] is NSNull)
        #expect(body["nextCursor"] as? String == result.nextCursor)
    }

    @Test func typedDecodeFailureEchoesOnlyTheValidatedCorrelationID() throws {
        let rejected = failure(
            ClipyCLIContract.decodeRequest(
                requestBytes(
                    operation: "secret-query-must-not-leak",
                    arguments: "{\"limit\":20}"
                )
            )
        )
        let output = ClipyCLIContract.render(try #require(rejected))

        #expect(utf8(output.stdout)?.contains(validRequestID) == true)
        #expect(utf8(output.stdout)?.contains("secret-query-must-not-leak") == false)
        #expect(utf8(output.stderr) == "clipyctl: unknown_operation\n")
    }

    @Test func boundedWriterCountsTheNewlineInTheResponseBudget() {
        let payload = "value"
        let stringByteCount = payload.utf8.count + 2
        var exact = BoundedJSONWriter(maximumBytes: stringByteCount + 1)
        exact.appendJSON(payload)
        exact.appendByte(0x0A)
        #expect(!exact.exceeded)
        #expect(exact.data.count == stringByteCount + 1)
        #expect(exact.data.last == 0x0A)

        var over = BoundedJSONWriter(maximumBytes: stringByteCount)
        over.appendJSON(payload)
        over.appendByte(0x0A)
        #expect(over.exceeded)
    }

    @Test func rendererRejectsOversizedResponseMadeOnlyFromValidItems() throws {
        let request = try #require(
            decodedRequest(
                ClipyCLIContract.decodeRequest(
                    requestBytes(arguments: "{\"limit\":500}")
                )
            )
        )
        let escapedIdentifier = String(repeating: "\u{0001}", count: 512)
        let item = try ClipyCLIBrowsePreviewItem(
            locator: "locator",
            title: "title",
            typeIdentifiers: Array(repeating: escapedIdentifier, count: 32),
            lastCopiedAt: "2026-08-23T12:34:56.007Z",
            pinned: false,
            snippet: nil
        )
        let result = try ClipyCLIBrowsePreviewResult(
            items: Array(repeating: item, count: 500),
            nextCursor: nil
        )
        let output = ClipyCLIContract.render(
            try .success(for: request, result: result)
        )

        #expect(output.exitCode == 2)
        let reply = try #require(JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["requestID"] as? String == request.requestID.rawValue)
        #expect(reply["result"] == nil)
        #expect((reply["error"] as? [String: String])?["code"] == "response_too_large")
    }

    @Test func successCannotReturnMoreItemsThanTheRequestLimit() throws {
        let request = try #require(
            decodedRequest(
                ClipyCLIContract.decodeRequest(
                    requestBytes(arguments: "{\"limit\":1}")
                )
            )
        )
        let item = try ClipyCLIBrowsePreviewItem(
            locator: "locator",
            title: "title",
            typeIdentifiers: [],
            lastCopiedAt: "2026-08-23T12:34:56.007Z",
            pinned: false,
            snippet: nil
        )
        let result = try ClipyCLIBrowsePreviewResult(
            items: [item, item],
            nextCursor: nil
        )

        #expect(throws: ClipyCLIValueFailure.invalidValue) {
            try ClipyCLIReply.success(for: request, result: result)
        }
    }
}
