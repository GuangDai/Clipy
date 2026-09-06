import Foundation
import Testing
@testable import ContentPreview

struct PreviewRTFRendererTests {
    @Test(arguments: [
        (#"{\rtf1\ansi Hello {\b bold} and {\i italic}.\par Next\tab cell\line end}"#,
         "Hello bold and italic.\nNext\tcell\nend"),
        (#"{\rtf1 Escaped \{braces\} and \\slash\~space\_hyphen}"#,
         "Escaped {braces} and \\slash\u{00A0}space\u{2011}hyphen"),
        (#"{\rtf1\ansi\ansicpg1252 caf\'e9 \ldblquote quoted\rdblquote\emdash\bullet}"#,
         "café “quoted”—•"),
        (#"{\rtf1\ansi\uc1 \u20320?\u22909? \u-10179?\u-8704?}"#,
         "你好 😀"),
        (#"{\rtf1\uc1 A{\uc0\u937}B\u233?C}"#, "AΩBéC"),
        (#"{\rtf1\uc2\u233\'65\'3fX}"#, "éX"),
        (#"{\rtf1\uc1\u233\~X}"#, "éX"),
        (#"{\rtf1\uc1\u233{X}}"#, "éX"),
        (#"{\rtf1 A{\v secret}B{\deleted removed}C}"#, "ABC"),
        (#"{\rtf1 A{\deleted removed\v0 still removed}B}"#, "AB"),
        (#"{\rtf1\ansicpg65001 caf\'c3\'a9}"#, "café"),
        (#"{\rtf1\ansicpg65001\'ef\'bb\'bfA}"#, "\u{FEFF}A"),
        (#"{\rtf1\ansi{\fonttbl{\f0\fcharset0 Arial;}{\f1\fcharset204 Arial;}}\f1\'cf\'f0\'e8\'e2\'e5\'f2}"#,
         "Привет"),
        (#"{\rtf1\ansi{\fonttbl{\f0\fcharset134 Chinese;}}\f0\u20320?\u22909?}"#, "你好"),
        (#"{\rtf1 Before{\upr{ANSI fallback}{\*\ud Unicode \u937?}}After}"#, "BeforeUnicode ΩAfter"),
    ])
    func extractsVisibleBodyWithScopedControls(source: String, expected: String) throws {
        let text = try artifact(PreviewRTFRenderer.render(Data(source.utf8)))
        #expect(Data(text.text.utf8) == Data(expected.utf8))
        #expect(!text.wasTruncated)
    }

    @Test func formattingTablesAndUnknownDestinationsNeverLeakIntoBody() throws {
        let source = #"{\rtf1\ansi{\fonttbl{\f0 Arial;}}{\colortbl;\red255\green0\blue0;}{\stylesheet{\s0 Normal;}}{\info{\author Secret Author}}Visible{\*\unknown hidden {nested \{text\}}} body}"#
        let text = try artifact(PreviewRTFRenderer.render(Data(source.utf8)))
        #expect(text.text == "Visible body")
    }

    @Test func linksRemainTextAndEmbeddedOrExternalObjectsBecomePlaceholders() throws {
        // File/network addresses exist only in skipped instructions and
        // attachment destinations. The parser never constructs a URL, file
        // wrapper, attributed document, image source, or resource loader.
        let source = #"{\rtf1{\field{\*\fldinst HYPERLINK "https://example.invalid/private"}{\fldrslt Read more}} {\object\objlink{\*\objclass Package}{\*\objdata file:///private/secret}{\result ignored}} {\pict\pngblip 89504e470d0a} {\NeXTGraphic /private/secret}}"#
        let text = try artifact(PreviewRTFRenderer.render(Data(source.utf8)))
        #expect(text.text == "Read more [Attachment] [Attachment] [Attachment]")
    }

    @Test func binaryAttachmentBytesDoNotParticipateInGroupParsing() throws {
        var source = Data(#"{\rtf1 Before{\pict\bin5 "#.utf8)
        source.append(contentsOf: [123, 125, 92, 0, 255])
        source.append(Data("}After}".utf8))
        let text = try artifact(PreviewRTFRenderer.render(source))
        #expect(text.text == "Before[Attachment]After")
    }

    @Test func physicalLineWrappingIsNotAParagraphBreak() throws {
        let source = "{\\rtf1 A\r\nB\\par\r\nC} \n"
        let text = try artifact(PreviewRTFRenderer.render(Data(source.utf8)))
        #expect(text.text == "AB\nC")
    }

    @Test func displayLimitPreservesCompleteComposedCharacters() throws {
        let prefix = String(repeating: "a", count: 49_999)
        let source = #"{\rtf1\uc0 "# + prefix + #"e\u769 omitted}"#
        let text = try artifact(PreviewRTFRenderer.render(Data(source.utf8)))
        #expect(Data(text.text.utf8) == Data((prefix + "e\u{301}").utf8))
        #expect(text.wasTruncated)
    }

    @Test(arguments: [
        "", "plain text", #"{\rtf2 text}"#, #"{\rtf1 missing}"# + "trailing",
        #"{\rtf1 unclosed"#, #"{\rtf1 extra}}"#, #"{\rtf1\'xz}"#,
        #"{\rtf1\bin10 short}"#, #"{\rtf1\bin-1 bad}"#, #"{\rtf1\u40000?}"#,
        #"{\rtf1\uc-1 bad}"#, #"{\rtf1\u-10179?}"#, #"{\rtf1\u-8704?}"#,
        #"{\rtf1\u-?}"#, #"{\rtf1\fs999999999999999999999999 text}"#,
        #"{\rtf1\upr{missing second branch}}"#, #"{\rtf1\upr{ANSI}{invalid second branch}}"#,
    ])
    func malformedSyntaxAndUnicodeFailWithoutDisplayingMarkup(source: String) {
        #expect(PreviewRTFRenderer.render(Data(source.utf8)) == .failed(.malformedRepresentation))
    }

    @Test func malformedUndisplayedSuffixIsStillRejected() {
        let source = #"{\rtf1 "# + String(repeating: "a", count: 50_001) + #"\'zz}"#
        #expect(PreviewRTFRenderer.render(Data(source.utf8)) == .failed(.malformedRepresentation))
    }

    @Test func inputNestingAndAttachmentBudgetsAreIndependent() {
        #expect(PreviewRTFRenderer.render(Data(repeating: 32, count: 1_048_577)) == .failed(.resourceLimit))
        let nested = #"{\rtf1 "# + String(repeating: "{", count: 128)
            + "text" + String(repeating: "}", count: 129)
        #expect(PreviewRTFRenderer.render(Data(nested.utf8)) == .failed(.resourceLimit))
        let attachments = #"{\rtf1 "# + String(repeating: #"{\pict 00}"#, count: 129) + "}"
        #expect(PreviewRTFRenderer.render(Data(attachments.utf8)) == .failed(.resourceLimit))
    }

    @Test(arguments: [
        #"{\rtf1\ansicpg99999\'ff}"#,
        #"{\rtf1{\fonttbl{\f0\fcharset2 Symbol;}}\f0 a}"#,
    ])
    func unimplementedEncodingsAreExplicitlyUnsupported(source: String) {
        #expect(PreviewRTFRenderer.render(Data(source.utf8)) == .unavailable(.unsupported))
    }

    @Test func cancelledWorkReturnsTheExistingCancellationOutcome() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return PreviewRTFRenderer.render(Data(#"{\rtf1 text}"#.utf8))
        }
        #expect(await task.value == .failed(.cancelled))
    }

    private func artifact(_ outcome: PreviewOutcome) throws -> PreviewText {
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected inert RTF body text, got \(outcome)")
            throw UnexpectedOutcome()
        }
        return text
    }

    private struct UnexpectedOutcome: Error {}
}
