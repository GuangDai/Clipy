import Foundation
import Testing
@testable import ContentPreview

struct HTMLRawTextBoundaryTests {
    // WHATWG script data escaped/double-escaped states. No JavaScript is
    // evaluated; these are HTML token boundaries in copied script data.
    @Test(arguments: [
        "<script><!--<script>hidden</script>still hidden</script><p>visible</p>",
        "<script><!--<ScRiPt\t>hidden</sCrIpT/>still hidden</SCRIPT><p>visible</p>",
        "<script><!--<scriptx>hidden</script><p>visible</p>",
        "<script><!--><script>hidden</script><p>visible</p>",
        "<script><!---><script>hidden</script><p>visible</p>",
        "<script><!--<script>hidden--></script><p>visible</p>",
        "<script><!--<script>hidden</scriptx>hidden</script>hidden</script><p>visible</p>",
        "<style><!--<script>hidden</style><p>visible</p>",
        "<style>hidden</stylex>still hidden</STYLE><p>visible</p>",
    ])
    func rawTextCannotLeakThroughAnEmbeddedOrLookalikeClosingTag(source: String) async throws {
        let text = try await rendered(source)
        #expect(text.text == "visible")
        #expect(!text.wasTruncated)
    }

    @Test func unclosedDoubleEscapedScriptDoesNotReleaseItsRemainingMarkup() async throws {
        let text = try await rendered("<p>before</p><script><!--<script>x</script><p>still script</p>")
        #expect(text.text == "before")
        #expect(!text.wasTruncated)
    }

    @Test func scriptEndTagsAreHTMLBoundariesEvenInsideJavaScriptQuotes() async throws {
        let text = try await rendered("<script>const x = '</script>literal<p>visible</p>")
        #expect(text.text == "literal\nvisible")
        #expect(!text.wasTruncated)
    }

    @Test(arguments: ["<!-->", "<!--->", "<!-- hidden --!>", "<!-- hidden ---->"])
    func htmlCommentRecoveryRetainsFollowingContent(comment: String) async throws {
        let text = try await rendered("before" + comment + "<p>after &amp; more</p>")
        #expect(text.text == "before\nafter & more")
        #expect(!text.wasTruncated)
    }

    @Test func largeRawTextWithRepeatedLookalikesKeepsTheVisibleBudgetAvailable() async throws {
        let hidden = String(repeating: "</scriptx>", count: 70_000)
        let text = try await rendered(
            "<p>before</p><script><!--<script>" + hidden
                + "</script>still hidden</script><p>after</p>"
        )
        #expect(text.text == "before\nafter")
        #expect(!text.wasTruncated)
    }

    @Test func longCombiningTextSurvivesGeometricCharacterCounting() async throws {
        let source = "e" + String(repeating: "\u{301}", count: 150_000)
        let text = try await rendered("<p>" + source + "</p>")
        #expect(Data(text.text.utf8) == Data(source.utf8))
        #expect(text.text.count == 1)
        #expect(!text.wasTruncated)
    }

    @Test func htmlNestingUsesNoRecursiveDocumentTree() async throws {
        let text = try await rendered(
            String(repeating: "<div>", count: 20_000) + "visible"
                + String(repeating: "</div>", count: 20_000)
        )
        #expect(text.text == "visible")
        #expect(!text.wasTruncated)
    }

    private func rendered(_ source: String) async throws -> PreviewText {
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.html", bytes: Data(source.utf8)),
        ])
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected inert HTML body text, got \(outcome)")
            throw UnexpectedOutcome()
        }
        return text
    }

    private struct UnexpectedOutcome: Error {}
}
