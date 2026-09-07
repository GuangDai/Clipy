import Foundation
import Testing
@testable import ContentPreview

struct PreviewRTFCJKTests {
    /// Independent byte pairs from Microsoft's CP936/949/950 mappings:
    /// unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WINDOWS/CP936.TXT etc.
    /// Expected text is literal; no system encoder creates these fixtures.
    struct Fixture: Sendable {
        let codePage: Int
        let fontCharset: Int
        let bytes: [UInt8]
        let escaped: String
        let expected: String
    }

    static let fixtures = [
        Fixture(codePage: 936, fontCharset: 134, bytes: [0xD6, 0xD0, 0xCE, 0xC4],
                escaped: #"\'d6\'d0\'ce\'c4"#, expected: "中文"),
        Fixture(codePage: 950, fontCharset: 136, bytes: [0xA4, 0xA4, 0xA4, 0xE5],
                escaped: #"\'a4\'a4\'a4\'e5"#, expected: "中文"),
        Fixture(codePage: 949, fontCharset: 129, bytes: [0xC7, 0xD1, 0xB1, 0xB9],
                escaped: #"\'c7\'d1\'b1\'b9"#, expected: "한국"),
    ]

    @Test(arguments: fixtures)
    func headerCodePageDecodesLiteralAndEscapedByteRuns(_ fixture: Fixture) async throws {
        var raw = Data("{\\rtf1\\ansi\\ansicpg\(fixture.codePage) ".utf8)
        raw.append(contentsOf: fixture.bytes)
        raw.append(Data("}".utf8))
        let escaped = Data("{\\rtf1\\ansi\\ansicpg\(fixture.codePage) \(fixture.escaped)}".utf8)
        for bytes in [raw, escaped] {
            let outcome = await ContentPreview().renderHistoryPane([
                PreviewRepresentation(typeIdentifier: "public.rtf", bytes: bytes),
            ])
            let text = try artifact(outcome)
            #expect(Data(text.text.utf8) == Data(fixture.expected.utf8))
            #expect(!text.wasTruncated)
        }
    }

    @Test(arguments: fixtures)
    func fontCharsetOverridesTheHeaderAndRestoresAtTheGroupEnd(_ fixture: Fixture) throws {
        let source = "{\\rtf1\\ansi\\ansicpg1252\\deff0"
            + "{\\fonttbl{\\f0\\fcharset0 Latin;}{\\f1\\fcharset\(fixture.fontCharset) CJK;}}"
            + "\\f0 caf\\'e9 {\\f1 \(fixture.escaped)} caf\\'e9}"
        let text = try artifact(PreviewRTFRenderer.render(Data(source.utf8)))
        #expect(text.text == "café \(fixture.expected) café")
    }

    @Test(arguments: [
        (936, #"\'81\'40"#, "\u{4E02}"),
        (949, #"\'81\'41"#, "\u{AC02}"),
        (950, #"\'f9\'d6"#, "\u{7881}"),
    ])
    func windowsExtensionBytesUseTheDeclaredCodePage(page: Int, bytes: String, expected: String) throws {
        let source = "{\\rtf1\\ansi\\ansicpg\(page) \(bytes)}"
        let text = try artifact(PreviewRTFRenderer.render(Data(source.utf8)))
        #expect(Data(text.text.utf8) == Data(expected.utf8))
    }

    @Test func gb18030FourByteSequencesAreNotAcceptedAsWindows936() {
        let source = #"{\rtf1\ansi\ansicpg936\'81\'30\'81\'30}"#
        #expect(PreviewRTFRenderer.render(Data(source.utf8)) == .failed(.malformedRepresentation))
    }

    @Test func fontCodePageAndUnicodeFallbackDoNotDuplicateTheFallbackBytes() throws {
        let source = #"{\rtf1\ansi\ansicpg1252{\fonttbl{\f0\fcharset0\cpg936 CJK;}}\f0\uc2\u20013\'d6\'d0\u25991\'ce\'c4 \u-10179??\u-8704??}"#
        let text = try artifact(PreviewRTFRenderer.render(Data(source.utf8)))
        #expect(text.text == "中文 😀")
    }

    @Test(arguments: fixtures)
    func incompleteMultibyteRunsFailWithoutRepairOrPrefixSuccess(_ fixture: Fixture) {
        let lead = String(fixture.escaped.prefix(4))
        for ending in ["}", #"\b X}"#] {
            let source = "{\\rtf1\\ansi\\ansicpg\(fixture.codePage) valid prefix \(lead)\(ending)"
            #expect(PreviewRTFRenderer.render(Data(source.utf8)) == .failed(.malformedRepresentation))
        }
    }

    @Test func cjkTextKeepsTheExistingCharacterLimitAndValidatesItsSuffix() throws {
        let prefix = #"{\rtf1\ansi\ansicpg936 "# + String(repeating: #"\'d6\'d0"#, count: 50_001)
        let text = try artifact(PreviewRTFRenderer.render(Data((prefix + "}").utf8)))
        #expect(text.text == String(repeating: "中", count: 50_000))
        #expect(text.wasTruncated)
        #expect(PreviewRTFRenderer.render(Data((prefix + #"\'d6}"#).utf8)) == .failed(.malformedRepresentation))
    }

    private func artifact(_ outcome: PreviewOutcome) throws -> PreviewText {
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected decoded CJK RTF text, got \(outcome)")
            throw UnexpectedOutcome()
        }
        return text
    }

    private struct UnexpectedOutcome: Error {}
}
