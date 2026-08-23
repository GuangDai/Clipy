/// PLAY-PY-A2G — X.8 proves immutable emission bytes, not real stdio.
@testable import ClipyCLIContract
import Foundation
import Testing

struct PLAYPYA2GEmissionGoldenTests {
    @Test func emptySuccessIsCompactSortedAndEndsInExactlyOneLF() throws {
        let request = try #require(
            decodedRequest(ClipyCLIContract.decodeRequest(requestBytes()))
        )
        let result = try ClipyCLIBrowsePreviewResult(items: [], nextCursor: nil)
        let output = ClipyCLIContract.render(
            try .success(for: request, result: result)
        )

        #expect(output.exitCode == 0)
        #expect(output.stderr.isEmpty)
        #expect(
            utf8(output.stdout)
                == #"{"ok":true,"protocolVersion":1,"requestID":"9bd92054-bd3f-4d20-8f8a-5d77aa63b726","result":{"items":[],"nextCursor":null}}"# + "\n"
        )
        #expect(output.stdout.last == 0x0A)
        #expect(output.stdout.dropLast().last != 0x0A)
    }

    @Test func itemFieldsAreSortedWhileSemanticArraysKeepInputOrder() throws {
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

        #expect(
            utf8(output.stdout)
                == #"{"ok":true,"protocolVersion":1,"requestID":"9bd92054-bd3f-4d20-8f8a-5d77aa63b726","result":{"items":[{"lastCopiedAt":"2026-08-23T12:34:56.007Z","locator":"opaque-1","pinned":true,"snippet":null,"title":"a \"title\"","typeIdentifiers":["public.png","public.text"]}],"nextCursor":"next"}}"# + "\n"
        )
    }

    @Test func errorGoldenHasClosedContentFreeStderr() {
        let output = ClipyCLIContract.render(
            .failure(requestID: nil, code: .invalidRequest)
        )

        #expect(output.exitCode == 2)
        #expect(
            utf8(output.stdout)
                == #"{"error":{"code":"invalid_request"},"ok":false,"protocolVersion":1,"requestID":null}"# + "\n"
        )
        #expect(utf8(output.stderr) == "clipyctl: invalid_request\n")
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

    @Test func boundedWriterCountsTerminalLFAtExactMaximum() {
        do {
            var exact = BoundedJSONWriter(
                maximumBytes: ClipyCLIContract.maximumResponseBytes
            )
            exact.appendJSON(
                String(
                    repeating: "x",
                    count: ClipyCLIContract.maximumResponseBytes - 3
                )
            )
            exact.appendByte(0x0A)

            #expect(!exact.exceeded)
            #expect(exact.data.count == ClipyCLIContract.maximumResponseBytes)
            #expect(exact.data.last == 0x0A)
        }

        var over = BoundedJSONWriter(
            maximumBytes: ClipyCLIContract.maximumResponseBytes
        )
        over.appendJSON(
            String(
                repeating: "x",
                count: ClipyCLIContract.maximumResponseBytes - 2
            )
        )
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
        #expect(
            utf8(output.stdout)
                == #"{"error":{"code":"response_too_large"},"ok":false,"protocolVersion":1,"requestID":"9bd92054-bd3f-4d20-8f8a-5d77aa63b726"}"# + "\n"
        )
        #expect(utf8(output.stderr) == "clipyctl: response_too_large\n")
    }

    @Test func replyConstructorsRejectOutOfContractValues() {
        #expect(throws: ClipyCLIValueFailure.invalidValue) {
            try ClipyCLIBrowsePreviewItem(
                locator: "",
                title: "title",
                typeIdentifiers: [],
                lastCopiedAt: "2026-08-23T12:34:56.007Z",
                pinned: false,
                snippet: nil
            )
        }
        #expect(throws: ClipyCLIValueFailure.invalidValue) {
            try ClipyCLIBrowsePreviewItem(
                locator: "locator",
                title: "title",
                typeIdentifiers: [],
                lastCopiedAt: "2026-02-30T12:34:56.007Z",
                pinned: false,
                snippet: nil
            )
        }
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
