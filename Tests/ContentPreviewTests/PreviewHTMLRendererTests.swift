import Foundation
import Testing
@testable import ContentPreview

struct PreviewHTMLRendererTests {
    @Test func documentAndClipboardFragmentBecomeReadableParagraphs() throws {
        let html = """
        <!DOCTYPE html><HTML><head><title>Hidden title</title>
        <style>body { color: red }</style></head><body>
        <!--StartFragment--><h1>Clipy &amp; friends</h1>
        <p>Hello <strong>world</strong>.<br>Another line.</p>
        <ul><li>One</li><li>Two</li></ul>
        <table><tr><th>Name</th><th>Value</th></tr><tr><td>A</td><td>42</td></tr></table>
        <!--EndFragment--></body></HTML>
        """
        let text = try rendered(html)
        #expect(text.text == "Clipy & friends\nHello world.\nAnother line.\nOne\nTwo\nName\tValue\nA\t42")
        #expect(!text.wasTruncated)
    }

    @Test func linksImagesAndActiveContentNeverSupplyExternalContent() throws {
        let html = """
        <p><a href="https://example.invalid/private" onclick="danger()">Read me</a>
        <img src="file:///private/secret" onerror="danger()"></p>
        <script>if (2 < 3) document.write('secret')</script>
        <STYLE>/* invisible */</STYLE>
        <template>hidden <template>nested</template> remainder</template>
        <p title="a > b &quot;quoted&quot;">Visible</p>
        """
        #expect(try rendered(html).text == "Read me\nVisible")
    }

    @Test func entitiesDecodeOnceAndUnknownNamesRemainVisible() throws {
        let html = "<p>&lt;b&gt;&amp;lt; &quot;hi&quot; &apos;x&apos; &nbsp; &copy; &eacute; &mdash; &#128; &#x1F600; &#65 &#0; &#xD800; &unknown;</p>"
        #expect(try rendered(html).text == "<b>&lt; \"hi\" 'x' \u{A0} © é — € 😀 A � � &unknown;")
    }

    @Test func preformattedWhitespaceAndOrdinaryComparisonsRemainText() throws {
        #expect(try rendered("<p>2 < 3 &amp; 5 > 4</p><pre> a\n  b\t c</pre><p>tail</p>").text
            == "2 < 3 & 5 > 4\n a\n  b\t c\ntail")
    }

    @Test func angleEntitiesUseCurrentHTMLCodePoints() throws {
        // WHATWG named-characters.html assigns U+27E8/U+27E9, not the
        // legacy HTML4 U+2329/U+232A spellings.
        let text = try rendered("&lang;x&rang;")
        #expect(text.text.unicodeScalars.map(\.value) == [0x27E8, 0x78, 0x27E9])
    }

    @Test func commentsAndIncompleteMarkupHaveDeterministicText() throws {
        #expect(try rendered("before<!-- <script>fake</script> --> after").text == "before after")
        #expect(try rendered("<p>visible</p><!-- unfinished secret").text == "visible")
        #expect(try rendered("<p>visible</p><script>unfinished secret").text == "visible")
        #expect(try rendered("trailing <").text == "trailing <")
        #expect(try rendered("<head><title>title</title><body>visible").text == "visible")
        #expect(try rendered("<script>const source = '<div title=\"';</ScRiPt><p>visible</p>").text == "visible")
        #expect(try rendered("<style><!-- ignored </style><p>visible</p>").text == "visible")
    }

    @Test func outputCharacterLimitPreservesGraphemesAndReportsTruncation() throws {
        let grapheme = "👩‍💻"
        let exact = String(repeating: grapheme, count: 50_000)
        let atLimit = try rendered("<p>" + exact + "</p>")
        #expect(atLimit.text == exact)
        #expect(!atLimit.wasTruncated)
        let overLimit = try rendered("<p>" + exact + "e\u{301}</p>")
        #expect(overLimit.text == exact)
        #expect(overLimit.wasTruncated)
    }

    @Test func outputByteLimitDoesNotReturnAPartialGrapheme() throws {
        let ascii = try rendered("<p>abcdefghi</p>", maximumOutputBytes: 7)
        #expect(ascii.text == "abcdefg")
        #expect(ascii.wasTruncated)
        let combining = try rendered("<p>abcde\u{301}tail</p>", maximumOutputBytes: 5)
        #expect(combining.text == "abcd")
        #expect(combining.wasTruncated)
        let joined = try rendered("<p>a👩‍💻tail</p>", maximumOutputBytes: 5)
        #expect(joined.text == "a")
        #expect(joined.wasTruncated)
    }

    @Test func sourceBudgetAndInvalidEncodingsFailTyped() {
        #expect(PreviewHTMLRenderer.render(Data("<p>x</p>".utf8), maximumInputBytes: 3,
                                          maximumOutputBytes: 100) == .failed(.resourceLimit))
        for bytes in [
            Data([0xFF]), Data([0xFF, 0xFE, 0x41]),
            Data([0xFF, 0xFE, 0x00, 0xD8]),             // LE unpaired high surrogate
            Data([0xFF, 0xFE, 0x00, 0xDC]),             // LE unpaired low surrogate
            Data([0xFE, 0xFF, 0xD8, 0x00, 0x00, 0x41]), // BE high surrogate followed by A
            Data([0xFE, 0xFF, 0xDC, 0x00]),             // BE unpaired low surrogate
        ] {
            #expect(PreviewHTMLRenderer.render(bytes, maximumInputBytes: 100,
                                              maximumOutputBytes: 100) == .failed(.malformedRepresentation))
        }
    }

    @Test func utf16ContentMarkersNeverReinterpretTheEncodingBOM() {
        let cases: [(Data, [UInt32])] = [
            (Data([0xFF, 0xFE, 0xFF, 0xFE, 0x41, 0x00]), [0xFEFF, 0x41]),
            (Data([0xFE, 0xFF, 0xFE, 0xFF, 0x00, 0x41]), [0xFEFF, 0x41]),
            (Data([0xFF, 0xFE, 0xFE, 0xFF, 0x41, 0x00]), [0xFFFE, 0x41]),
            (Data([0xFE, 0xFF, 0xFF, 0xFE, 0x00, 0x41]), [0xFFFE, 0x41]),
        ]
        for (bytes, expected) in cases {
            let outcome = PreviewHTMLRenderer.render(bytes, maximumInputBytes: 100, maximumOutputBytes: 100)
            guard case .content(.text(let text)) = outcome else {
                Issue.record("Expected literal UTF-16 content scalars, got \(outcome)")
                continue
            }
            #expect(text.text.unicodeScalars.map(\.value) == expected)
            #expect(!text.wasTruncated)
        }
    }

    @Test func utf8AndBOMDeclaredUTF16DocumentsDecode() throws {
        let html = "<p>你好 &amp; 😀</p>"
        let little = Data([0xFF, 0xFE]) + (try #require(html.data(using: .utf16LittleEndian)))
        let big = Data([0xFE, 0xFF]) + (try #require(html.data(using: .utf16BigEndian)))
        for bytes in [Data([0xEF, 0xBB, 0xBF]) + Data(html.utf8), little, big] {
            let outcome = PreviewHTMLRenderer.render(bytes, maximumInputBytes: 1_024, maximumOutputBytes: 1_024)
            guard case .content(.text(let text)) = outcome else {
                Issue.record("Expected a decoded HTML document, got \(outcome)")
                continue
            }
            #expect(text.text == "你好 & 😀")
        }
    }

    @Test func cancellationReturnsNoPartialArtifact() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return PreviewHTMLRenderer.render(Data("<p>visible</p>".utf8), maximumInputBytes: 100,
                                              maximumOutputBytes: 100)
        }
        #expect(await task.value == .failed(.cancelled))
    }

    private func rendered(_ html: String, maximumOutputBytes: Int = 1_048_576) throws -> PreviewText {
        let outcome = PreviewHTMLRenderer.render(Data(html.utf8), maximumInputBytes: 1_048_576,
                                                maximumOutputBytes: maximumOutputBytes)
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected inert HTML text, got \(outcome)")
            throw CancellationError()
        }
        return text
    }
}
