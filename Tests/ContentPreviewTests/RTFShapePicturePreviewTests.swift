import Foundation
import Testing
@testable import ContentPreview

struct RTFShapePicturePreviewTests {
    // Microsoft RTF 1.7 §Pictures: the shppict destination contains the
    // primary image and nonshppict contains the alternate for older readers.
    private let picture = #"{\*\shppict{\pict\pngblip 89504e47}}{\nonshppict{\pict\wmetafile8 0100}}"#

    @Test func primaryAndCompatibilityPicturesSupplyOneInertAttachment() async throws {
        let source = Data((#"{\rtf1 Before "# + picture + " after}").utf8)
        let package = try #require(FileWrapper(directoryWithFileWrappers: [
            "TXT.rtf": FileWrapper(regularFileWithContents: source),
        ]).serializedRepresentation)
        for representation in [
            PreviewRepresentation(typeIdentifier: "public.rtf", bytes: source),
            PreviewRepresentation(typeIdentifier: "com.apple.flat-rtfd", bytes: package),
        ] {
            #expect(await ContentPreview().renderHistoryPane([representation]) == text("Before [Attachment] after"))
        }
    }

    @Test func hiddenAndUnknownDestinationsCannotExposeTheirPictures() {
        let source = #"{\rtf1 A{\v "# + picture + #"}{\deleted "# + picture
            + #"}{\*\unknown "# + picture + "}B}"
        #expect(PreviewRTFRenderer.render(Data(source.utf8)) == text("AB"))
    }

    @Test func onlyTheUnicodeAlternativeContributesItsPicture() {
        let source = #"{\rtf1{\upr{ANSI "# + picture + #"}{\*\ud Unicode \u937? "# + picture + "}}}"
        #expect(PreviewRTFRenderer.render(Data(source.utf8)) == text("Unicode Ω [Attachment]"))
    }

    @Test func nestedBinaryDataRemainsOpaqueWhileSyntaxStillValidates() {
        var source = Data(#"{\rtf1 A{\*\shppict{\pict\bin5 "#.utf8)
        source.append(contentsOf: [123, 125, 92, 0, 255])
        source.append(Data("}}B}".utf8))
        #expect(PreviewRTFRenderer.render(source) == text("A[Attachment]B"))
        #expect(PreviewRTFRenderer.render(Data(#"{\rtf1{\*\shppict{\pict\bin99 short}}}"#.utf8))
            == .failed(.malformedRepresentation))
    }

    @Test func primaryPicturesShareTheExistingAttachmentBudgetWithoutChargingFallbacks() {
        let atLimit = #"{\rtf1 "# + String(repeating: picture, count: 128) + "}"
        #expect(PreviewRTFRenderer.render(Data(atLimit.utf8)) == text(String(repeating: "[Attachment]", count: 128)))
        let overLimit = #"{\rtf1 "# + String(repeating: picture, count: 129) + "}"
        #expect(PreviewRTFRenderer.render(Data(overLimit.utf8)) == .failed(.resourceLimit))
    }

    private func text(_ value: String) -> PreviewOutcome {
        .content(.text(PreviewText(text: value, wasTruncated: false)))
    }
}
