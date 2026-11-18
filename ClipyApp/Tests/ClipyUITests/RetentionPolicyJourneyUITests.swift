/// RetentionPolicyJourneyUITests.swift — running-app proofs for the V2-02
/// Settings action. The R2 journey crosses a real General-pasteboard capture,
/// configured-policy read, destructive confirmation, receipt-derived feedback,
/// synchronous surface purge, and authoritative empty replacement. The age
/// journey verifies persistent history after cancelling and confirming the
/// same relaxation when an item is already expired.
/// The DEBUG launch seam changes only the store path and capture-access posture.
import AppKit
import HistoryCore
import HistoryStorage
import XCTest

final class RetentionPolicyJourneyUITests: XCTestCase {
    private var temporaryDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    /// One ASCII representation contributes its UTF-8 length to R2. The
    /// short first line keeps the durable/AX title bounded while the second
    /// line makes the canonical representation unambiguously exceed 1 MiB.
    @MainActor
    func testStorageTighteningReportsRetirementAndPurgesThePanel() throws {
        let title = "clipy-retention-storage-large"
        let captured = title + "\n" + String(repeating: "x", count: 1_100_000)
        let app = try launchApp(capturing: captured)
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        let rows = historyRows(in: app)
        assertRowCount(1, in: rows, app: app, context: "large initial capture")
        XCTAssertTrue(
            rows.firstMatch.label.contains(title),
            diagnostic(app, context: "bounded large-capture row title")
        )

        openRetentionSettings(in: app)

        let storageEnabled = app.checkBoxes[
            "clipy.settings.retention.storage-enabled"
        ]
        assertExists(
            storageEnabled,
            timeout: 5,
            in: app,
            context: "storage policy toggle"
        )
        let owningWindow = settingsWindow(
            in: app,
            owningToggle: "clipy.settings.retention.storage-enabled"
        )
        let retentionScrollView = owningWindow.scrollViews.containing(
            .checkBox, identifier: "clipy.settings.retention.age-enabled"
        ).firstMatch
        assertExists(
            retentionScrollView,
            timeout: 5,
            in: app,
            context: "retention policy scroll view"
        )
        // This real UTF-8 capture is a little over 1.1 MB in the .file
        // display's decimal units. Exact content-byte accounting is proved
        // by the storage owner tests; the running UI must show the actual
        // nonempty store, including zero pinned items, before retirement.
        assertUsage(itemCount: "1", contentSize: "1.1 MB", in: app)
        guard scrollUntilFullyVisible(
            storageEnabled,
            in: retentionScrollView,
            app: app,
            context: "storage policy toggle"
        ) else { return }
        storageEnabled.click()

        let storageMiB = app.textFields[
            "clipy.settings.retention.storage-mib"
        ]
        assertExists(
            storageMiB,
            timeout: 5,
            in: app,
            context: "storage budget field"
        )
        guard scrollUntilFullyVisible(
            storageMiB,
            in: retentionScrollView,
            app: app,
            context: "storage budget field"
        ) else { return }
        replaceText(in: storageMiB, with: "1")

        let apply = app.buttons["clipy.settings.retention.apply"]
        assertExists(apply, timeout: 5, in: app, context: "policy Apply")
        XCTAssertTrue(
            waitUntil(timeout: 5) { apply.isEnabled },
            diagnostic(app, context: "loaded changed storage policy")
        )
        guard scrollUntilFullyVisible(
            apply,
            in: retentionScrollView,
            app: app,
            context: "storage policy Apply"
        ) else { return }
        apply.click()

        confirmPolicy(
            in: owningWindow,
            app: app,
            context: "storage tightening"
        )

        let policyStatus = app.descendants(matching: .any)[
            "clipy.settings.retention.policy-status"
        ]
        assertExists(
            policyStatus,
            timeout: 15,
            in: app,
            context: "storage receipt status"
        )
        XCTAssertTrue(
            app.staticTexts[
                "Done. 1 item retired, 0 revisions pruned."
            ].exists,
            diagnostic(app, context: "exact storage retirement receipt")
        )

        let refreshUsage = app.buttons["clipy.settings.usage.refresh"]
        assertExists(refreshUsage, timeout: 10, in: app, context: "retained usage Refresh")
        guard scrollUntilFullyVisible(
            refreshUsage,
            in: retentionScrollView,
            app: app,
            context: "retained usage Refresh after R2"
        ) else { return }
        refreshUsage.click()
        assertUsage(itemCount: "0", contentSize: "0 bytes", in: app)

        closeSettingsAndSummonPanel(
            field: storageMiB,
            panel: panel,
            app: app
        )
        assertRowCount(0, in: rows, app: app, context: "post-R2 panel purge")
        XCTAssertTrue(
            app.staticTexts["No Clipboard History"].waitForExistence(timeout: 5),
            diagnostic(app, context: "authoritative empty panel after R2")
        )
    }

    @MainActor
    func testRelaxingAgeConfirmsBeforeDeletingExpiredHistory() async throws {
        let storeURL = try makeStoreURL()
        let before = try await seedExpiredHistory(at: storeURL)
        let app = launchApp(storeURL: storeURL, captureAccess: "denied")
        defer { app.terminate() }

        let firstWindow = try XCTUnwrap(requestAgeChange(in: app))
        let firstSheet = firstWindow.sheets.firstMatch
        assertExists(firstSheet, timeout: 5, in: app, context: "relaxed age confirmation")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitUntil(timeout: 5) { !firstSheet.exists },
            diagnostic(app, context: "cancelled cleanup confirmation")
        )
        app.terminate()

        let cancelled = try await readAgeHistory(at: storeURL)
        XCTAssertEqual(cancelled.age, before.age)
        XCTAssertEqual(cancelled.usage, before.usage)
        XCTAssertEqual(cancelled.items, before.items)

        app.launch()
        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        assertExists(panel, timeout: 20, in: app, context: "reopened after cancelling cleanup")
        let secondWindow = try XCTUnwrap(requestAgeChange(in: app))
        confirmPolicy(in: secondWindow, app: app, context: "relaxed age cleanup", checksAge: true)
        assertExists(
            app.staticTexts["Done. 1 item retired, 0 revisions pruned."],
            timeout: 15,
            in: app,
            context: "confirmed age retirement receipt"
        )
        let apply = app.buttons["clipy.settings.retention.apply"]
        XCTAssertTrue(
            waitUntil(timeout: 5) { apply.exists && !apply.isEnabled },
            diagnostic(app, context: "saved age limit has no pending change")
        )
        app.terminate()

        let applied = try await readAgeHistory(at: storeURL)
        XCTAssertEqual(applied.age?.maxAge, Double(31 * 86_400))
        XCTAssertEqual(applied.usage.position.rawValue, before.usage.position.rawValue + 1)
        XCTAssertEqual(applied.items, before.items.filter { $0 == before.pinned })
    }

    @MainActor
    private func requestAgeChange(in app: XCUIApplication) -> XCUIElement? {
        openRetentionSettings(in: app)
        let ageToggle = "clipy.settings.retention.age-enabled"
        let ageDays = app.textFields["clipy.settings.retention.age-days"]
        let window = settingsWindow(in: app, owningToggle: ageToggle)
        let scrollView = window.scrollViews.containing(.checkBox, identifier: ageToggle).firstMatch
        assertExists(ageDays, timeout: 10, in: app, context: "configured age limit")
        XCTAssertTrue(
            waitUntil(timeout: 5) { (ageDays.value as? String) == "30" && ageDays.isEnabled },
            diagnostic(app, context: "persisted age limit before editing")
        )
        guard scrollUntilFullyVisible(ageDays, in: scrollView, app: app, context: "age limit") else {
            return nil
        }
        replaceText(in: ageDays, with: "31")

        let apply = app.buttons["clipy.settings.retention.apply"]
        XCTAssertTrue(
            waitUntil(timeout: 5) { apply.exists && apply.isEnabled },
            diagnostic(app, context: "apply relaxed age limit")
        )
        guard scrollUntilFullyVisible(apply, in: scrollView, app: app, context: "apply after age edit") else {
            return nil
        }
        apply.click()
        return window
    }

    @MainActor
    private func seedExpiredHistory(
        at url: URL
    ) async throws -> (age: AgeRetention?, usage: HistoryUsage, items: [HistoryItemReference], pinned: HistoryItemReference) {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .persistent(storeURL: url)))
        _ = try await history.perform(.setRetentionPolicies(.init(
            age: AgeRetention(maxAge: 30 * 86_400), storage: nil, revisions: nil
        )))
        let now = Date()
        func capture(_ text: String, ageDays: Double) async throws -> HistoryItemReference {
            let receipt = try await history.perform(.capture(ClipboardCapture(
                representations: [CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8))],
                origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
                observedAt: now.addingTimeInterval(-ageDays * 86_400)
            )))
            let reference: HistoryItemReference?
            if case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome { reference = item }
            else { reference = nil }
            return try XCTUnwrap(reference)
        }

        let pinned = try await capture("clipy-retention-expired-pinned", ageDays: 40)
        _ = try await history.perform(.placePinned(pinned.id, at: .first))
        // Capture uses the observation's time to check age. The old item
        // survives capture and becomes eligible when Settings applies again.
        let expired = try await capture("clipy-retention-expired-unpinned", ageDays: 50)
        let configuration = try await history.retentionConfiguration()
        let usage = try await history.usage()
        let page = try await history.browse(.init(kind: .recent, limit: 5))
        XCTAssertEqual(page.rows.map(\.item), [pinned, expired])
        return (configuration.policies.age, usage, page.rows.map(\.item), pinned)
    }

    @MainActor
    private func readAgeHistory(
        at url: URL
    ) async throws -> (age: AgeRetention?, usage: HistoryUsage, items: [HistoryItemReference]) {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .persistent(storeURL: url)))
        let configuration = try await history.retentionConfiguration()
        let usage = try await history.usage()
        let page = try await history.browse(.init(kind: .recent, limit: 5))
        return (configuration.policies.age, usage, page.rows.map(\.item))
    }

    /// The Batch 38 ceiling's last strictness dimension at running-app
    /// level: enabling the revision-count threshold is strict, prunes the
    /// oldest inactive revision through the destructive confirmation, and
    /// shrinks the retained-usage content size in the same receipt.
    @MainActor
    func testRevisionTighteningPrunesInactiveRevisionsAndShrinksUsage() throws {
        let original = "clipy-r3-revision-original"
        let firstRevision = "clipy-r3-revision-first"
        let secondRevision = "clipy-r3-revision-second"
        let app = try launchApp(capturing: original)
        defer { app.terminate() }

        let rows = historyRows(in: app)
        assertRowCount(
            1,
            in: rows,
            app: app,
            context: "revision journey initial capture"
        )

        // Two real revisions through the running Details editor: the
        // canonical capture stays, each replace appends one stored
        // revision, and the newest revision is the effective value. The
        // list only carries the entry point once — after Save the panel
        // stays on the Details surface, so the second revision enters
        // through its Edit Content control directly.
        let row = historyRows(in: app).firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 10) { row.exists && row.isHittable },
            diagnostic(app, context: "revision journey captured row")
        )
        row.rightClick()
        let showDetails = app.menuItems["Show Details"]
        XCTAssertTrue(
            waitUntil(timeout: 5) { showDetails.exists && showDetails.isHittable },
            diagnostic(app, context: "row context menu Show Details")
        )
        showDetails.click()
        try appendRevision(firstRevision, in: app)
        try appendRevision(secondRevision, in: app)

        openRetentionSettings(in: app)
        // Usage before: the canonical capture plus both stored revisions.
        let bytesBefore = original.utf8.count
            + firstRevision.utf8.count
            + secondRevision.utf8.count
        assertUsage(
            itemCount: "1",
            contentSize: "\(bytesBefore) bytes",
            in: app
        )

        // Enabling the revision-count threshold at 1 is strict (the draft
        // matrix pins the semantics; this journey runs the control). The
        // toggle is queried by identifier like the age/storage toggles —
        // its text renders as an unbound StaticText in the AX tree.
        let revisionCountToggle = app.checkBoxes[
            "clipy.settings.retention.revision-count-enabled"
        ]
        let revisionCountField = app.textFields[
            "clipy.settings.retention.revision-count"
        ]
        let owningWindow = settingsWindow(
            in: app,
            owningToggle: "clipy.settings.retention.revision-count-enabled"
        )
        let retentionScrollView = owningWindow.scrollViews.containing(
            .checkBox, identifier: "clipy.settings.retention.age-enabled"
        ).firstMatch
        assertExists(
            revisionCountToggle,
            timeout: 5,
            in: app,
            context: "revision-count toggle"
        )
        assertExists(
            retentionScrollView,
            timeout: 5,
            in: app,
            context: "revision policy scroll view"
        )
        guard scrollUntilFullyVisible(
            revisionCountToggle,
            in: retentionScrollView,
            app: app,
            context: "revision-count toggle below retained usage"
        ) else { return }
        XCTAssertFalse(revisionCountField.exists, diagnostic(app, context: "disabled revision policy hides its field"))
        revisionCountToggle.click()
        assertExists(
            revisionCountField,
            timeout: 5,
            in: app,
            context: "revision-count field"
        )
        guard scrollUntilFullyVisible(
            revisionCountField,
            in: retentionScrollView,
            app: app,
            context: "revision-count field below its toggle"
        ) else { return }
        replaceText(in: revisionCountField, with: "1")

        let apply = app.buttons["clipy.settings.retention.apply"]
        assertExists(apply, timeout: 5, in: app, context: "policy Apply")
        XCTAssertTrue(
            waitUntil(timeout: 5) { apply.isEnabled },
            diagnostic(app, context: "enabled strict revision policy")
        )
        guard scrollUntilFullyVisible(
            apply,
            in: retentionScrollView,
            app: app,
            context: "strict revision policy Apply"
        ) else { return }
        apply.click()

        confirmPolicy(
            in: owningWindow,
            app: app,
            context: "revision-count enable tightening"
        )

        // R3 keeps the newest inactive revision and prunes the oldest:
        // one revision pruned, no items retired (HistoryUsageTests pins
        // the same sweep semantics through the storage seam).
        XCTAssertTrue(
            app.staticTexts["Done. 0 items retired, 1 revision pruned."]
                .waitForExistence(timeout: 10),
            diagnostic(app, context: "exact revision prune receipt")
        )

        // The policy Apply refreshes usage in the same receipt: the pruned
        // oldest revision's bytes leave the content size.
        let bytesAfter = original.utf8.count + secondRevision.utf8.count
        assertUsage(
            itemCount: "1",
            contentSize: "\(bytesAfter) bytes",
            in: app
        )
    }

    /// Appends one revision through the real Details editor, starting from
    /// the open Details surface (EditorRuntimeJourneyUITests' flow after
    /// its entry steps): enter the editor with Edit Content, open the
    /// replace editor for the UTF-8 representation, type the replacement,
    /// Save, and stay on the Details surface it returns to.
    @MainActor
    private func appendRevision(_ text: String, in app: XCUIApplication) throws {
        let details = app.descendants(matching: .any)["clipy.details.root"]
        let edit = app.buttons["Edit Content"]
        XCTAssertTrue(
            waitUntil(timeout: 10) { details.exists && edit.exists && edit.isHittable },
            diagnostic(app, context: "Details Edit Content control")
        )
        edit.click()

        let typeIdentifier = "public.utf8-plain-text"
        let decision = app.descendants(matching: .any)[
            "clipy.editor.decision.\(typeIdentifier)"
        ]
        XCTAssertTrue(
            waitUntil(timeout: 10) { decision.exists && decision.isHittable },
            diagnostic(app, context: "editor decision control")
        )
        decision.click()
        let replace = app.menuItems["Replace"]
        XCTAssertTrue(
            waitUntil(timeout: 5) { replace.exists && replace.isHittable },
            diagnostic(app, context: "decision menu Replace")
        )
        replace.click()
        let replacement = app.descendants(matching: .any)[
            "clipy.editor.replacement.\(typeIdentifier)"
        ]
        XCTAssertTrue(
            waitUntil(timeout: 5) { replacement.exists && replacement.isHittable },
            diagnostic(app, context: "replacement editor field")
        )
        replacement.click()
        replacement.typeKey("a", modifierFlags: .command)
        replacement.typeText(text)
        let save = app.buttons["clipy.editor.save"]
        XCTAssertTrue(
            waitUntil(timeout: 5) { save.exists && save.isEnabled && save.isHittable },
            diagnostic(app, context: "enabled Save for the valid replacement")
        )
        save.click()
        XCTAssertTrue(
            waitUntil(timeout: 10) { !app.buttons["clipy.editor.save"].exists },
            diagnostic(app, context: "saved revision closes the editor")
        )
    }

    @MainActor
    private func launchApp(capturing value: String) throws -> XCUIApplication {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(value, forType: .string))

        return launchApp(storeURL: try makeStoreURL())
    }

    private func makeStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        return directory.appendingPathComponent("history.store")
    }

    @MainActor
    private func launchApp(storeURL: URL, captureAccess: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-clipy.language", "system"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = storeURL.path
        if let captureAccess {
            app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = captureAccess
        }
        app.launch()

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        assertExists(panel, timeout: 20, in: app, context: "initial panel")
        return app
    }

    @MainActor
    private func openRetentionSettings(in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        openRetentionTab(in: app)
    }

    @MainActor
    private func openRetentionTab(in app: XCUIApplication) {
        let retentionTab = app.buttons["clipy.settings.category.retention"]
        assertExists(
            retentionTab,
            timeout: 10,
            in: app,
            context: "Settings Retention tab"
        )
        retentionTab.click()
    }

    @MainActor
    private func assertUsage(itemCount: String, contentSize: String, in app: XCUIApplication) {
        let items = app.staticTexts["clipy.settings.usage.item-count"]
        let pinned = app.staticTexts["clipy.settings.usage.pinned-count"]
        let bytes = app.staticTexts["clipy.settings.usage.content-bytes"]
        // Foundation can use a nonbreaking space between quantity and unit;
        // compare the user-visible words without pinning that typography.
        func text(of element: XCUIElement) -> String {
            (element.value as? String ?? element.label)
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                items.exists && pinned.exists && bytes.exists
                    && text(of: items) == itemCount
                    && text(of: pinned) == "0"
                    && text(of: bytes) == contentSize
            },
            diagnostic(app, context: "retained usage: \(itemCount) items, 0 pinned, \(contentSize)")
        )
    }

    @MainActor
    private func settingsWindow(
        in app: XCUIApplication,
        owningToggle identifier: String
    ) -> XCUIElement {
        let window = app.windows.containing(
            .checkBox,
            identifier: identifier
        ).firstMatch
        assertExists(
            window,
            timeout: 5,
            in: app,
            context: "Settings window owning \(identifier)"
        )
        return window
    }

    @MainActor
    private func confirmPolicy(
        in settingsWindow: XCUIElement,
        app: XCUIApplication,
        context: String,
        checksAge: Bool = false
    ) {
        // A global button-label query also sees the Touch Bar mirror on CI.
        let sheet = settingsWindow.sheets.firstMatch
        assertExists(sheet, timeout: 5, in: app, context: "\(context) sheet")
        let confirm = sheet.buttons["action-button-1"]
        assertExists(
            confirm,
            timeout: 5,
            in: app,
            context: "\(context) destructive action"
        )
        XCTAssertEqual(
            confirm.label,
            "Apply Changes",
            diagnostic(app, context: "\(context) action copy")
        )
        let disclosure = checksAge
            ? "Clipy will check for expired items now. Applying these limits may immediately and permanently remove items or revisions."
            : "Applying these limits may immediately and permanently remove items or revisions."
        XCTAssertTrue(sheet.staticTexts[disclosure].exists, diagnostic(app, context: "\(context) disclosure"))
        confirm.click()
    }

    @MainActor
    private func closeSettingsAndSummonPanel(
        field: XCUIElement,
        panel: XCUIElement,
        app: XCUIApplication
    ) {
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil(timeout: 5) { !field.exists },
            diagnostic(app, context: "Settings window close")
        )
        app.typeKey("c", modifierFlags: [.command, .shift])
        assertExists(panel, timeout: 10, in: app, context: "resummoned panel")
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    /// SwiftUI's grouped Form exposes offscreen descendants as existing even
    /// though macOS cannot compute a hit point for them. Move the real owning
    /// scroll view in bounded wheel increments until the requested control is
    /// actually visible; no coordinate outside that public view is guessed.
    @MainActor
    @discardableResult
    private func scrollUntilFullyVisible(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        app: XCUIApplication,
        context: String
    ) -> Bool {
        let scrollCoordinate = scrollView.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        func isFullyVisible() -> Bool {
            element.exists
                && scrollView.frame.contains(element.frame)
                && element.isHittable
        }
        for _ in 0..<8 {
            if isFullyVisible() {
                return true
            }
            // Follow the control's actual distance, bounded to less than a
            // viewport per wheel action. A fixed 8 × 50-point travel budget
            // stopped above Apply after the count-retention section grew.
            let distance = element.frame.midY - scrollView.frame.midY
            let step = min(abs(distance), scrollView.frame.height * 0.75)
            let deltaY: CGFloat = distance < 0 ? step : -step
            scrollCoordinate.scroll(byDeltaX: 0, deltaY: deltaY)
        }
        let result = isFullyVisible()
        XCTAssertTrue(
            result,
            diagnostic(app, context: "\(context) did not scroll into view")
        )
        return result
    }

    @MainActor
    private func historyRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "clipy.history.row."
            )
        )
    }

    @MainActor
    private func assertRowCount(
        _ expected: Int,
        in rows: XCUIElementQuery,
        app: XCUIApplication,
        context: String
    ) {
        XCTAssertTrue(
            waitUntil(timeout: 30) { rows.count == expected },
            diagnostic(
                app,
                context: "\(context); expected \(expected) rows, observed \(rows.count)"
            )
        )
    }

    @MainActor
    private func assertExists(
        _ element: XCUIElement,
        timeout: TimeInterval,
        in app: XCUIApplication,
        context: String
    ) {
        XCTAssertTrue(
            element.exists || element.waitForExistence(timeout: timeout),
            diagnostic(app, context: context)
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) -> Bool {
        // XCTest polls after an initial interval even when the preceding UI
        // action already settled. Keep the full wait for unfinished work.
        if condition() { return true }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    @MainActor
    private func diagnostic(
        _ app: XCUIApplication,
        context: String
    ) -> String {
        "\(context)\n\(app.debugDescription)"
    }
}
