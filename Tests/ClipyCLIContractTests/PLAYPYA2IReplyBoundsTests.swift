/// PLAY-PY-A2I reply-side boundary literals for the closed protocol-v1 result.
import ClipyCLIContract
import Testing

struct PLAYPYA2IReplyBoundsTests {
    private func item(
        locator: String = "locator",
        title: String = "title",
        typeIdentifiers: [String] = [],
        lastCopiedAt: String = "2026-08-23T12:34:56.007Z",
        snippet: String? = nil
    ) throws -> ClipyCLIBrowsePreviewItem {
        try .init(
            locator: locator,
            title: title,
            typeIdentifiers: typeIdentifiers,
            lastCopiedAt: lastCopiedAt,
            pinned: false,
            snippet: snippet
        )
    }

    @Test func locatorUTF8BoundIsExactAndEmptyIsRejected() throws {
        _ = try item(locator: String(repeating: "x", count: 1_024))

        for locator in ["", String(repeating: "x", count: 1_025)] {
            #expect(throws: ClipyCLIValueFailure.invalidValue) {
                try item(locator: locator)
            }
        }
    }

    @Test func titleUsesOwningProjectionUTF8Bound() throws {
        let exact = String(repeating: "é", count: 512)
        _ = try item(title: exact)

        #expect(throws: ClipyCLIValueFailure.invalidValue) {
            try item(title: exact + "x")
        }
    }

    @Test func snippetUsesOwningCharacterBound() throws {
        let exact = String(repeating: "🧩", count: 322)
        _ = try item(snippet: exact)

        #expect(throws: ClipyCLIValueFailure.invalidValue) {
            try item(snippet: exact + "🧩")
        }
    }

    @Test func typeIdentifierCountAndUTF8BoundsAreExact() throws {
        _ = try item(typeIdentifiers: Array(repeating: "x", count: 32))
        _ = try item(
            typeIdentifiers: [String(repeating: "x", count: 512)]
        )

        #expect(throws: ClipyCLIValueFailure.invalidValue) {
            try item(typeIdentifiers: Array(repeating: "x", count: 33))
        }
        #expect(throws: ClipyCLIValueFailure.invalidValue) {
            try item(
                typeIdentifiers: [String(repeating: "x", count: 513)]
            )
        }
    }

    @Test func timestampRequiresExactMillisecondsAndAValidCalendarDate() throws {
        _ = try item(lastCopiedAt: "2026-08-23T12:34:56.007Z")

        for timestamp in [
            "2026-08-23T12:34:56.07Z",
            "2026-02-30T12:34:56.007Z",
        ] {
            #expect(throws: ClipyCLIValueFailure.invalidValue) {
                try item(lastCopiedAt: timestamp)
            }
        }
    }

    @Test func nextCursorUTF8BoundIsExact() throws {
        _ = try ClipyCLIBrowsePreviewResult(
            items: [],
            nextCursor: String(repeating: "x", count: 4_096)
        )

        #expect(throws: ClipyCLIValueFailure.invalidValue) {
            try ClipyCLIBrowsePreviewResult(
                items: [],
                nextCursor: String(repeating: "x", count: 4_097)
            )
        }
        #expect(throws: ClipyCLIValueFailure.invalidValue) {
            try ClipyCLIBrowsePreviewResult(items: [], nextCursor: "")
        }
    }

    @Test func globalResultCountBoundIsExact() throws {
        let value = try item()
        _ = try ClipyCLIBrowsePreviewResult(
            items: Array(repeating: value, count: 500),
            nextCursor: nil
        )

        #expect(throws: ClipyCLIValueFailure.invalidValue) {
            try ClipyCLIBrowsePreviewResult(
                items: Array(repeating: value, count: 501),
                nextCursor: nil
            )
        }
    }
}
