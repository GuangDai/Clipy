import Foundation
import Testing
@testable import ContentPreview

struct PreviewRTFDRendererTests {
    @Test func serializedPackageUsesInertRTFTextAndIgnoresAttachmentContents() async throws {
        let payload = try package(
            #"{\rtf1\ansi Before {{\NeXTGraphic attachment.png}\'ac} after \u20013?\u25991?}"#,
            attachments: [
                "attachment.png": FileWrapper(regularFileWithContents: Data("not an image".utf8)),
                "external": FileWrapper(symbolicLinkWithDestinationURL: URL(fileURLWithPath: "/does-not-exist/secret")),
                "nested": FileWrapper(directoryWithFileWrappers: [
                    "TXT.rtf": FileWrapper(regularFileWithContents: Data(#"{\rtf1 decoy}"#.utf8)),
                ]),
            ]
        )
        #expect(await render(payload) == .content(.text(PreviewText(
            text: "Before [Attachment] after 中文", wasTruncated: false
        ))))
    }

    @Test func plainTextThenRTFThenRTFDThenHTMLPriorityIsIndependentOfOrder() async throws {
        let rtfd = representation(try package(#"{\rtf1 RTFD}"#))
        let html = PreviewRepresentation(typeIdentifier: "public.html", bytes: Data("<p>HTML</p>".utf8))
        let rtf = PreviewRepresentation(typeIdentifier: "public.rtf", bytes: Data(#"{\rtf1 RTF}"#.utf8))
        let plain = PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("plain".utf8))
        let renderer = ContentPreview()
        #expect(await renderer.renderHistoryPane([html, rtfd]) == text("RTFD"))
        #expect(await renderer.renderHistoryPane([rtfd, html, rtf]) == text("RTF"))
        #expect(await renderer.renderHistoryPane([rtfd, html, rtf, plain]) == text("plain"))
    }

    @Test func nativeAttachmentMarkersAreRemovedWithoutRemovingBodyNegationSigns() async throws {
        let rtf = #"{\rtf1\ansi Before \'ac {{\NeXTGraphic image.png}\'ac} \'ac after}"#
        #expect(await render(try package(rtf)) == text("Before ¬ [Attachment] ¬ after"))
        // The ungrouped form does not own a trailing attachment marker.
        let ungrouped = #"{\rtf1\ansi {\NeXTGraphic image.png}\'ac}"#
        #expect(await render(try package(ungrouped)) == text("[Attachment]¬"))
        var rawRTF = Data(#"{\rtf1\ansi {{\NeXTGraphic image.png}"#.utf8)
        rawRTF.append(0xAC)
        rawRTF.append(contentsOf: "} body}".utf8)
        let rawPackage = try #require(FileWrapper(directoryWithFileWrappers: [
            "TXT.rtf": FileWrapper(regularFileWithContents: rawRTF),
        ]).serializedRepresentation)
        #expect(await render(rawPackage) == text("[Attachment] body"))
    }

    @Test func malformedRTFDDoesNotFallThroughToHTML() async {
        #expect(await ContentPreview().renderHistoryPane([
            representation(Data("not a serialized wrapper".utf8)),
            PreviewRepresentation(typeIdentifier: "public.html", bytes: Data("<p>fallback</p>".utf8)),
        ]) == .failed(.malformedRepresentation))
    }

    @Test func malformedDocumentAndUnsupportedDocumentWrapperAreDistinct() async throws {
        #expect(await render(try package("not RTF")) == .failed(.malformedRepresentation))
        let missing = try #require(FileWrapper(directoryWithFileWrappers: [:]).serializedRepresentation)
        #expect(await render(missing) == .failed(.malformedRepresentation))
        let plainWrapper = try #require(FileWrapper(regularFileWithContents: Data(#"{\rtf1 text}"#.utf8)).serializedRepresentation)
        #expect(await render(plainWrapper) == .failed(.malformedRepresentation))
        for document in [
            FileWrapper(symbolicLinkWithDestinationURL: URL(fileURLWithPath: "/does-not-exist/TXT.rtf")),
            FileWrapper(directoryWithFileWrappers: [:]),
        ] {
            let bytes = try #require(FileWrapper(directoryWithFileWrappers: ["TXT.rtf": document]).serializedRepresentation)
            #expect(await render(bytes) == .unavailable(.unsupported))
        }
    }

    @Test func resourceLimitsCoverInputEntriesAndVisibleText() async throws {
        #expect(await render(Data(repeating: 0, count: 1_048_577)) == .failed(.resourceLimit))
        var attachments: [String: FileWrapper] = [:]
        for index in 0..<129 {
            attachments["attachment-\(index)"] = FileWrapper(regularFileWithContents: Data())
        }
        #expect(await render(try package(#"{\rtf1 text}"#, attachments: attachments)) == .failed(.resourceLimit))
        let source = #"{\rtf1 "# + String(repeating: "a", count: 50_001) + "}"
        #expect(await render(try package(source)) == .content(.text(PreviewText(
            text: String(repeating: "a", count: 50_000), wasTruncated: true
        ))))
    }

    @Test func directoryAndLookalikeIdentifiersRemainOpaque() async throws {
        let payload = try package(#"{\rtf1 opaque}"#)
        for type in ["com.apple.rtfd", "com.apple.flat-rtfd.private"] {
            #expect(await ContentPreview().renderHistoryPane([
                PreviewRepresentation(typeIdentifier: type, bytes: payload),
            ]) == .unavailable(.unsupported))
        }
    }

    @Test func cancellationPrecedesDeserialization() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return PreviewRTFDRenderer.render(Data())
        }
        #expect(await task.value == .failed(.cancelled))
    }

    private func package(_ rtf: String, attachments: [String: FileWrapper] = [:]) throws -> Data {
        var children = attachments
        children["TXT.rtf"] = FileWrapper(regularFileWithContents: Data(rtf.utf8))
        return try #require(FileWrapper(directoryWithFileWrappers: children).serializedRepresentation)
    }

    private func representation(_ bytes: Data) -> PreviewRepresentation {
        PreviewRepresentation(typeIdentifier: "com.apple.flat-rtfd", bytes: bytes)
    }

    private func render(_ bytes: Data) async -> PreviewOutcome {
        await ContentPreview().renderHistoryPane([representation(bytes)])
    }

    private func text(_ value: String) -> PreviewOutcome {
        .content(.text(PreviewText(text: value, wasTruncated: false)))
    }
}
