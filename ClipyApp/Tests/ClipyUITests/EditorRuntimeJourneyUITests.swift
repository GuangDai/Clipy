/// EditorRuntimeJourneyUITests — Cards 3B/3C/3D public-control evidence. The
/// app captures one real General-pasteboard value into a real persistent
/// store, navigates through the production panel and Details surface, and
/// drives the actual revision editor. The optional DEBUG launch seam changes
/// only first-revise ordering and one typed details result; it never supplies
/// a fake editor, draft, receipt, or store.
import AppKit
import XCTest

final class EditorRuntimeJourneyUITests: XCTestCase {
    private let textType = "public.utf8-plain-text"
    private let competingRevision = "clipy-editor-competing-revision"
    private var temporaryDirectory: URL?
    private var capturedItemID: UUID?

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        capturedItemID = nil
        try super.tearDownWithError()
    }

    /// Exact external UTF-16 editing through the running app: the original
    /// representation has a big-endian BOM. macOS also supplies a UTF-8
    /// sibling; explicitly Hide that captured sibling before editing UTF-16,
    /// so Save/Copy cannot retain its old "Before" bytes as another flavor.
    /// The UTF-16 type, byte order, and BOM must survive the actual edit.
    /// Canonical/revision lineage preservation is covered by storage tests.
    @MainActor
    func testExternalUTF16ReplaceSaveAndCopyPreservesItsWireEncoding() throws {
        let typeIdentifier = "public.utf16-external-plain-text"
        let type = NSPasteboard.PasteboardType(typeIdentifier)
        // Literal UTF-16BE+BOM vectors, independent of the product encoder.
        let originalBytes = Data([
            0xFE, 0xFF, 0x00, 0x42, 0x00, 0x65, 0x00, 0x66,
            0x00, 0x6F, 0x00, 0x72, 0x00, 0x65,
        ]) // "Before"
        let expectedBytes = Data([
            0xFE, 0xFF, 0x00, 0x41, 0x00, 0x66, 0x00, 0x74,
            0x00, 0x65, 0x00, 0x72,
        ]) // "After"
        let app = try launchEditor(
            capturing: "Before",
            typeIdentifier: typeIdentifier,
            bytes: originalBytes
        )
        defer { app.terminate() }
        let expectedItemID = try XCTUnwrap(capturedItemID)
        let pasteboard = NSPasteboard.general
        let source = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertEqual(Set(source.types.map(\.rawValue)), Set([typeIdentifier, textType]))
        XCTAssertEqual(source.data(forType: type), originalBytes)
        XCTAssertEqual(source.data(forType: .string), Data("Before".utf8))

        // Each captured representation has its own revision decision. Editing
        // UTF-16 does not implicitly rewrite a different captured flavor.
        let utf8Decision = app.descendants(matching: .any)[
            "clipy.editor.decision.\(textType)"
        ]
        guard assertEventually(
            { utf8Decision.exists && utf8Decision.isHittable },
            in: app,
            message: "The captured UTF-8 sibling did not expose its editor decision."
        ) else { return }
        utf8Decision.click()
        let hideUTF8 = app.menuItems["Hide"]
        guard assertEventually(
            { hideUTF8.exists && hideUTF8.isHittable },
            in: app,
            message: "The real decision menu did not offer Hide for the UTF-8 sibling."
        ) else { return }
        hideUTF8.click()

        _ = try authorReplacement("After", in: app, typeIdentifier: typeIdentifier)
        let save = app.buttons["clipy.editor.save"]
        guard assertEventually(
            { save.exists && save.isEnabled && save.isHittable },
            in: app,
            message: "The valid UTF-16 replacement did not enable Save."
        ) else { return }
        save.click()

        let editorDecision = app.descendants(matching: .any)[
            "clipy.editor.decision.\(typeIdentifier)"
        ]
        let detailsTitle = app.descendants(matching: .any)["clipy.details.title"]
        let copy = editorDetailsDialog(in: app).buttons["Copy to Clipboard"]
        guard assertEventually(
            {
                !editorDecision.exists && detailsTitle.exists
                    && self.accessibilityText(of: detailsTitle) == "After"
                    && copy.exists && copy.isHittable
            },
            in: app,
            timeout: 10,
            message: "Saved UTF-16 content did not return to copyable current Details."
        ) else { return }
        copy.click()
        guard assertEventually(
            { pasteboard.pasteboardItems?.first?.data(forType: type) == expectedBytes },
            in: app,
            timeout: 10,
            message: "Copy did not write the edited UTF-16BE bytes and BOM."
        ) else { return }

        let pastedItems = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(pastedItems.count, 1)
        let pasted = try XCTUnwrap(pastedItems.first)
        let writtenTypes = Set(pasted.types.map(\.rawValue))
        let requiredTypes = Set([typeIdentifier, "com.clipy.lineageHint"])
        XCTAssertTrue(requiredTypes.isSubset(of: writtenTypes))
        XCTAssertTrue(writtenTypes.isSubset(of: requiredTypes.union([textType])))
        XCTAssertEqual(pasted.data(forType: type), expectedBytes)
        // General pasteboard may synthesize UTF-8 again from the newly written
        // UTF-16. Such a sibling must describe After, never the hidden Before.
        if writtenTypes.contains(textType) {
            XCTAssertEqual(pasted.data(forType: .string), Data("After".utf8))
        }
        XCTAssertEqual(
            pasted.data(forType: NSPasteboard.PasteboardType("com.clipy.lineageHint")),
            Data(expectedItemID.uuidString.utf8)
        )
    }

    /// Card 3B: one real competing revision makes Save fail OCC-stale. The
    /// alert and footer preserve literal draft bytes. Explicit Reload then
    /// observes one typed transient failure, and Retry recovers through a
    /// fresh read of the same real store without submitting the draft. Card
    /// 3D also requires the approved disclosure through its stable public AX
    /// identifier before this journey clicks the actual Save control.
    @MainActor
    func testStaleSavePreservesDraftAndReloadFailureRecovers() throws {
        let draft = "clipy-editor-stale-draft"
        let revisionDisclosureIdentifier =
            "clipy.editor.revision-disclosure"
        let approvedRevisionDisclosure =
            "Save appends an immutable revision. Previous and original "
            + "content may remain in this item's revision history."
        let app = try launchEditor(
            capturing: "clipy-editor-stale-original",
            editorJourney: "stale-reload-failure-once"
        )
        defer { app.terminate() }

        let replacement = try authorReplacement(draft, in: app)
        let revisionDisclosure = app.descendants(matching: .any)[
            revisionDisclosureIdentifier
        ]
        guard assertEventually(
            {
                revisionDisclosure.exists
                    && revisionDisclosure.identifier
                        == revisionDisclosureIdentifier
                    && self.accessibilityText(of: revisionDisclosure)
                        == approvedRevisionDisclosure
                    && app.buttons["clipy.editor.save"].isEnabled
            },
            in: app,
            message: "The approved immutable-revision disclosure was not visible before Save."
        ) else { return }
        app.buttons["clipy.editor.save"].click()

        let detailsDialog = editorDetailsDialog(in: app)
        let alert = detailsDialog.sheets.firstMatch
        guard assertEventually(
            {
                alert.exists
                    && alert.staticTexts["Revision Not Saved"].exists
                    && alert.buttons["clipy.editor.stale-reload"].exists
            },
            in: app,
            message: "The stale OCC result did not present its real Reload alert."
        ) else { return }
        XCTAssertEqual(replacement.value as? String, draft)

        alert.buttons["clipy.editor.stale-reload"].click()
        guard assertEventually(
            {
                alert.exists
                    && alert.staticTexts["Couldn't Reload Latest"].exists
                    && alert.staticTexts[
                        "History is busy. Try again shortly."
                    ].exists
                    && alert.buttons["clipy.editor.retry-reload"].exists
            },
            in: app,
            message: "The typed first Reload failure did not remain retryable."
        ) else { return }
        XCTAssertEqual(replacement.value as? String, draft)

        alert.buttons["clipy.editor.retry-reload"].click()
        let notice = app.descendants(matching: .any)[
            "clipy.editor.reload-notice"
        ]
        guard assertEventually(
            {
                notice.exists
                    && self.accessibilityText(of: notice).contains(
                        "Latest content loaded"
                    )
                    && replacement.exists
                    && replacement.value as? String == draft
                    && app.buttons["clipy.editor.save"].isEnabled
            },
            in: app,
            message: "Retry did not rebase onto the real latest details while preserving the draft."
        ) else { return }

        // Save being enabled is not itself a dirty-state proof because an
        // unchanged revision remains submit-able. The real dismissal intent
        // must still guard the authored bytes after the successful rebase.
        app.buttons["clipy.editor.cancel"].click()
        guard assertEventually(
            {
                alert.exists
                    && alert.staticTexts["Discard Changes?"].exists
                    && alert.buttons["clipy.editor.confirm-discard"].exists
                    && replacement.value as? String == draft
            },
            in: app,
            message: "The recovered reload no longer treated the preserved draft as dirty."
        ) else { return }
        alert.buttons["clipy.editor.confirm-discard"].click()

        let editorDecision = app.descendants(matching: .any)[
            "clipy.editor.decision.\(textType)"
        ]
        let detailsTitle = app.descendants(matching: .any)[
            "clipy.details.title"
        ]
        guard assertEventually(
            {
                !editorDecision.exists
                    && detailsTitle.exists
                    && self.accessibilityText(of: detailsTitle)
                        == self.competingRevision
                    && !app.staticTexts["Item Removed"].exists
            },
            in: app,
            message: "Discard did not return to current competitor Details after Reload."
        ) else { return }

        // Reopen against the retargeted v2 Details reference. A fresh v3 Save
        // must advance both the child fence and Navigation path before its
        // receipt purge, then reload authored Effective content in place.
        let edit = app.buttons["Edit Content"]
        guard assertEventually(
            { edit.exists && edit.isHittable },
            in: app,
            message: "Retargeted Details did not remain editable."
        ) else { return }
        edit.click()
        _ = try authorReplacement(draft, in: app)
        app.buttons["clipy.editor.save"].click()

        guard assertEventually(
            {
                !editorDecision.exists
                    && detailsTitle.exists
                    && self.accessibilityText(of: detailsTitle) == draft
                    && !app.staticTexts["Item Removed"].exists
            },
            in: app,
            timeout: 10,
            message: "Committed v3 Save did not keep current authored Details open."
        ) else { return }
    }

    /// Card 3C: Esc and Cancel enter the same dirty-dismiss alert. Keeping
    /// editing preserves the actual TextEditor value; explicit destructive
    /// confirmation is the only path that leaves a dirty editor. Reopening
    /// the same real editor and cancelling without a change closes directly,
    /// fixing the playbook's independent no-dirty control in the same launch.
    @MainActor
    func testDirtyDismissalConfirmsAndCleanCancelClosesDirectly() throws {
        let original = "clipy-editor-dirty-original"
        let draft = "clipy-editor-dirty-draft"
        let app = try launchEditor(capturing: original)
        defer { app.terminate() }

        let replacement = try authorReplacement(draft, in: app)
        replacement.typeKey(.escape, modifierFlags: [])

        let detailsDialog = editorDetailsDialog(in: app)
        let alert = detailsDialog.sheets.firstMatch
        guard assertEventually(
            {
                alert.exists
                    && alert.staticTexts["Discard Changes?"].exists
                    && alert.buttons["Keep Editing"].exists
                    && alert.buttons["clipy.editor.confirm-discard"].exists
            },
            in: app,
            message: "Esc did not enter the editor's dirty-dismiss intent."
        ) else { return }
        XCTAssertEqual(replacement.value as? String, draft)

        alert.buttons["Keep Editing"].click()
        guard assertEventually(
            {
                replacement.exists && replacement.value as? String == draft
            },
            in: app,
            message: "Keep Editing did not restore the intact authored draft."
        ) else { return }

        app.buttons["clipy.editor.cancel"].click()
        guard assertEventually(
            {
                alert.exists
                    && alert.staticTexts["Discard Changes?"].exists
                    && alert.buttons["clipy.editor.confirm-discard"].exists
            },
            in: app,
            message: "Cancel bypassed the shared dirty-dismiss confirmation."
        ) else { return }
        alert.buttons["clipy.editor.confirm-discard"].click()

        let editorDecision = app.descendants(matching: .any)[
            "clipy.editor.decision.\(textType)"
        ]
        let detailsTitle = app.descendants(matching: .any)[
            "clipy.details.title"
        ]
        guard assertEventually(
            {
                !editorDecision.exists
                    && detailsTitle.exists
                    && self.accessibilityText(of: detailsTitle) == original
            },
            in: app,
            message: "Confirmed Discard changed content or did not return to Details."
        ) else { return }

        let edit = app.buttons["Edit Content"]
        guard assertEventually(
            { edit.exists && edit.isHittable },
            in: app,
            message: "Details did not remain editable after confirmed Discard."
        ) else { return }
        edit.click()

        let cancel = app.buttons["clipy.editor.cancel"]
        guard assertEventually(
            {
                editorDecision.exists
                    && cancel.exists
                    && cancel.isHittable
                    && !alert.exists
            },
            in: app,
            message: "The clean editor did not reopen without a discard alert."
        ) else { return }
        cancel.click()

        guard assertEventually(
            {
                !editorDecision.exists
                    && !alert.exists
                    && detailsTitle.exists
                    && self.accessibilityText(of: detailsTitle) == original
            },
            in: app,
            message: "A clean Cancel did not return directly to Details."
        ) else { return }
    }

    // MARK: - Product navigation

    @MainActor
    private func launchEditor(
        capturing value: String,
        typeIdentifier: String = "public.utf8-plain-text",
        bytes: Data? = nil,
        editorJourney: String? = nil
    ) throws -> XCUIApplication {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(
            bytes ?? Data(value.utf8),
            forType: NSPasteboard.PasteboardType(typeIdentifier)
        ))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectory = directory

        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store")
            .path
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        if let editorJourney {
            app.launchEnvironment["CLIPY_UI_TEST_EDITOR_JOURNEY"] =
                editorJourney
        }
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        guard assertEventually(
            { panel.exists },
            in: app,
            timeout: 20,
            message: "The production panel did not appear."
        ) else { return app }

        let row = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "clipy.history.row."
            )
        ).firstMatch
        guard assertEventually(
            { row.exists && row.label.contains(value) && row.isHittable },
            in: app,
            timeout: 10,
            message: "The real clipboard capture did not produce its history row."
        ) else { return app }
        capturedItemID = try XCTUnwrap(UUID(uuidString: String(
            row.identifier.dropFirst("clipy.history.row.".count)
        )))
        row.rightClick()

        let showDetails = app.menuItems["Show Details"]
        guard assertEventually(
            { showDetails.exists && showDetails.isHittable },
            in: app,
            message: "The row context menu did not expose Show Details."
        ) else { return app }
        showDetails.click()

        let details = app.descendants(matching: .any)["clipy.details.root"]
        let edit = app.buttons["Edit Content"]
        guard assertEventually(
            { details.exists && edit.exists && edit.isHittable },
            in: app,
            timeout: 10,
            message: "Details did not expose its real Edit Content control."
        ) else { return app }
        edit.click()

        let editorDecision = app.descendants(matching: .any)[
            "clipy.editor.decision.\(typeIdentifier)"
        ]
        _ = assertEventually(
            {
                editorDecision.exists
                    && app.buttons["clipy.editor.cancel"].exists
                    && app.buttons["clipy.editor.save"].exists
            },
            in: app,
            message: "The Details-owned editor controls were absent from public AX."
        )
        return app
    }

    @MainActor
    private func authorReplacement(
        _ draft: String,
        in app: XCUIApplication,
        typeIdentifier: String = "public.utf8-plain-text"
    ) throws -> XCUIElement {
        let decision = app.descendants(matching: .any)[
            "clipy.editor.decision.\(typeIdentifier)"
        ]
        guard assertEventually(
            { decision.exists && decision.isHittable },
            in: app,
            message: "The \(typeIdentifier) editor decision control was not publicly usable."
        ) else { throw JourneyFailure.precondition }
        decision.click()

        let replace = app.menuItems["Replace"]
        guard assertEventually(
            { replace.exists && replace.isHittable },
            in: app,
            message: "The real decision menu did not expose Replace."
        ) else { throw JourneyFailure.precondition }
        replace.click()

        let replacement = app.descendants(matching: .any)[
            "clipy.editor.replacement.\(typeIdentifier)"
        ]
        guard assertEventually(
            { replacement.exists && replacement.isHittable },
            in: app,
            message: "Replace did not materialize the actual TextEditor."
        ) else { throw JourneyFailure.precondition }
        replacement.click()
        replacement.typeKey("a", modifierFlags: .command)
        replacement.typeText(draft)
        XCTAssertEqual(replacement.value as? String, draft)
        return replacement
    }

    @MainActor
    private func editorDetailsDialog(in app: XCUIApplication) -> XCUIElement {
        app.dialogs.containing(
            .any,
            identifier: "clipy.details.root"
        ).firstMatch
    }

    // MARK: - Evidence helpers

    private enum JourneyFailure: Error {
        case precondition
    }

    @MainActor
    private func accessibilityText(of element: XCUIElement) -> String {
        if !element.label.isEmpty {
            return element.label
        }
        return element.value as? String ?? ""
    }

    @MainActor
    @discardableResult
    private func assertEventually(
        _ condition: @escaping () -> Bool,
        in app: XCUIApplication,
        timeout: TimeInterval = 5,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        let result = XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
        if !result {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = message
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(
            result,
            "\(message)\n\(app.debugDescription)",
            file: file,
            line: line
        )
        return result
    }
}
