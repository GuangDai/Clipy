/// RetentionCountJourneyUITests.swift — running-app proof that the unified
/// Retention surface sends the real v1 count action only after destructive
/// confirmation, clears accepted success on a newer edit, reads the
/// committed value back after a same-store process restart, and refreshes
/// the retained-usage row when the accepted count Apply lands (037178f's
/// display trigger, previously untested). The DEBUG launch seam changes
/// only the store path and privacy posture; captures, retention mutation,
/// persistence, observation, and panel purge remain production paths.
import AppKit
import HistoryCore
import HistoryStorage
import XCTest

final class RetentionCountJourneyUITests: XCTestCase {
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

    @MainActor
    func testCountTighteningCancelCommitDirtyResetAndRestartReadback() throws {
        let oldest = "clipy-retention-count-oldest"
        let newest = "clipy-retention-count-newest"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(oldest, forType: .string))

        let storeURL = try makeStoreURL()
        let app = launchApp(storeURL: storeURL)
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        assertExists(panel, timeout: 20, in: app, context: "initial panel")

        let rows = historyRows(in: app)
        assertRowCount(1, in: rows, app: app, context: "first capture")
        XCTAssertTrue(
            rows.firstMatch.label.contains(oldest),
            diagnostic(app, context: "oldest row label")
        )

        // Publish fully prepared bytes, as the product paste writer does.
        // clearContents/setString can expose an empty generation to polling.
        let newestItem = NSPasteboardItem()
        XCTAssertTrue(newestItem.setString(newest, forType: .string))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([newestItem]))
        assertRowCount(2, in: rows, app: app, context: "second capture")
        let capturedLabels = rows.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(
            capturedLabels.contains(where: { $0.contains(oldest) })
                && capturedLabels.contains(where: { $0.contains(newest) }),
            diagnostic(app, context: "distinguishable captured rows")
        )

        app.typeKey(",", modifierFlags: .command)
        let retentionTab = app.buttons["clipy.settings.category.retention"]
        assertExists(
            retentionTab,
            timeout: 10,
            in: app,
            context: "Settings Retention tab"
        )
        retentionTab.click()

        let maximumUnpinned = app.textFields[
            "clipy.settings.retention.maximum-unpinned"
        ]
        assertExists(
            maximumUnpinned,
            timeout: 5,
            in: app,
            context: "maximum unpinned field"
        )
        maximumUnpinned.click()
        maximumUnpinned.typeKey("a", modifierFlags: .command)
        maximumUnpinned.typeText("1")

        let applyItemLimit = app.buttons[
            "clipy.settings.retention.apply-item-limit"
        ]
        assertExists(
            applyItemLimit,
            timeout: 5,
            in: app,
            context: "Apply Item Limit"
        )
        XCTAssertTrue(
            waitUntil(timeout: 5) { applyItemLimit.isEnabled },
            diagnostic(app, context: "loaded count configuration")
        )
        applyItemLimit.click()

        // Anchor to the Settings window that owns the edited field, then its
        // attached confirmation sheet. A global title query also sees the
        // Touch Bar mirror on CI and is therefore ambiguous.
        let settingsWindow = app.windows.containing(
            .textField,
            identifier: "clipy.settings.retention.maximum-unpinned"
        ).firstMatch
        assertExists(
            settingsWindow,
            timeout: 5,
            in: app,
            context: "Settings window owning count confirmation"
        )
        let confirmationSheet = settingsWindow.sheets.firstMatch
        assertExists(
            confirmationSheet,
            timeout: 5,
            in: app,
            context: "attached count confirmation sheet"
        )
        let confirm = confirmationSheet.buttons["action-button-1"]
        assertExists(
            confirm,
            timeout: 5,
            in: app,
            context: "destructive count confirmation"
        )
        let itemLimitStatus = app.descendants(matching: .any)[
            "clipy.settings.retention.item-limit-status"
        ]

        // Card 10D: dismissing the destructive confirmation must send no
        // History action. The real panel therefore still exposes both rows,
        // and no receipt-derived success can appear.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitUntil(timeout: 5) { !confirmationSheet.exists },
            diagnostic(app, context: "cancel count confirmation")
        )
        XCTAssertFalse(
            itemLimitStatus.exists,
            diagnostic(app, context: "cancel must not publish a receipt")
        )
        XCTAssertTrue(
            applyItemLimit.isEnabled,
            diagnostic(app, context: "canceled count draft remains applicable")
        )

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil(timeout: 5) { !maximumUnpinned.exists },
            diagnostic(app, context: "Settings close after canceled count")
        )
        app.typeKey("c", modifierFlags: [.command, .shift])
        assertExists(
            panel,
            timeout: 10,
            in: app,
            context: "panel after canceled count confirmation"
        )
        assertRowCount(
            2,
            in: rows,
            app: app,
            context: "cancel before count mutation"
        )

        // Re-enter through the real Settings scene without rewriting the
        // field: its unsaved draft must survive both window closure and the
        // next configured-policy read. Enabled Apply also joins that read;
        // the control stays disabled while configuration is still loading.
        app.typeKey(",", modifierFlags: .command)
        assertExists(
            retentionTab,
            timeout: 10,
            in: app,
            context: "reopened Settings Retention tab"
        )
        retentionTab.click()
        assertExists(
            maximumUnpinned,
            timeout: 5,
            in: app,
            context: "reopened maximum unpinned field"
        )
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                maximumUnpinned.value as? String == "1" && applyItemLimit.isEnabled
            },
            diagnostic(app, context: "unsubmitted count draft survives Settings reopen and readback")
        )
        XCTAssertFalse(itemLimitStatus.exists,
                       diagnostic(app, context: "reopened draft has no submitted receipt"))

        // No confirmation was accepted. Returning the draft to this new
        // store's original 200-item limit must be an exact no-change value,
        // proving the durable comparison baseline did not become 1 on close.
        replaceText(in: maximumUnpinned, with: "200")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                maximumUnpinned.value as? String == "200" && !applyItemLimit.isEnabled
            },
            diagnostic(app, context: "unsubmitted draft leaves the durable 200-item limit unchanged")
        )
        replaceText(in: maximumUnpinned, with: "1")
        XCTAssertTrue(
            waitUntil(timeout: 5) { applyItemLimit.isEnabled },
            diagnostic(app, context: "edited count is applicable before its explicit confirmation")
        )
        // Record the retained-usage row before the accepted Apply: both
        // captures are live, so the store measures 2 items / 56 logical
        // bytes. The post-receipt assertion below then proves the count
        // path refreshed usage without a manual Refresh click.
        assertUsage(itemCount: "2", contentSize: "56 bytes", in: app)
        applyItemLimit.click()
        assertExists(
            confirmationSheet,
            timeout: 5,
            in: app,
            context: "reopened count confirmation sheet"
        )
        let reopenedConfirm = confirmationSheet.buttons["action-button-1"]
        assertExists(
            reopenedConfirm,
            timeout: 5,
            in: app,
            context: "reopened destructive count confirmation"
        )
        reopenedConfirm.click()

        assertExists(
            itemLimitStatus,
            timeout: 10,
            in: app,
            context: "receipt-derived item-limit status"
        )
        XCTAssertTrue(
            app.staticTexts["Done. 1 item removed."].exists,
            diagnostic(app, context: "exact count receipt feedback")
        )

        // The count Apply path bumps the Retention tab's usage-refresh
        // generation alongside its receipt, so the row must show the
        // post-retention store (the newest capture's 28 bytes alone)
        // without clicking Refresh.
        assertUsage(itemCount: "1", contentSize: "28 bytes", in: app)

        // Card 10E: an accepted success belongs to exactly one edit
        // generation. A newer edit clears it immediately; restoring the exact
        // configured baseline disables Apply without resurrecting old success.
        replaceText(in: maximumUnpinned, with: "2")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                !itemLimitStatus.exists && applyItemLimit.isEnabled
            },
            diagnostic(app, context: "new count edit clears accepted success")
        )
        replaceText(in: maximumUnpinned, with: "1")
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                !itemLimitStatus.exists && !applyItemLimit.isEnabled
            },
            diagnostic(app, context: "restored count baseline has no pending save")
        )

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            waitUntil(timeout: 5) { !maximumUnpinned.exists },
            diagnostic(app, context: "Settings window close")
        )
        app.typeKey("c", modifierFlags: [.command, .shift])
        assertExists(
            panel,
            timeout: 10,
            in: app,
            context: "panel after retention commit"
        )

        assertRowCount(1, in: rows, app: app, context: "post-retention panel")
        let remainingLabel = rows.firstMatch.label
        XCTAssertTrue(
            remainingLabel.contains(newest),
            diagnostic(app, context: "newest row retained")
        )
        XCTAssertFalse(
            remainingLabel.contains(oldest),
            diagnostic(app, context: "oldest row retired")
        )

        // Card 10A: discard every process-local Settings value and reopen the
        // same physical store. The new process must render the persisted count
        // through the public configured-policy read, with no dirty Apply, and
        // must observe the same retained survivor.
        app.terminate()
        let reopenedApp = launchApp(storeURL: storeURL)
        defer { reopenedApp.terminate() }

        let reopenedPanel = reopenedApp.descendants(matching: .any)[
            "clipy.panel.root"
        ]
        assertExists(
            reopenedPanel,
            timeout: 20,
            in: reopenedApp,
            context: "same-store restarted panel"
        )
        let reopenedRows = historyRows(in: reopenedApp)
        assertRowCount(
            1,
            in: reopenedRows,
            app: reopenedApp,
            context: "same-store restarted survivor"
        )
        let restartedLabel = reopenedRows.firstMatch.label
        XCTAssertTrue(
            restartedLabel.contains(newest),
            diagnostic(reopenedApp, context: "same-store newest survivor")
        )
        XCTAssertFalse(
            restartedLabel.contains(oldest),
            diagnostic(reopenedApp, context: "same-store retired row absent")
        )

        reopenedApp.typeKey(",", modifierFlags: .command)
        let reopenedRetentionTab = reopenedApp.buttons["clipy.settings.category.retention"]
        assertExists(
            reopenedRetentionTab,
            timeout: 10,
            in: reopenedApp,
            context: "same-store Settings Retention tab"
        )
        reopenedRetentionTab.click()
        let readbackField = reopenedApp.textFields[
            "clipy.settings.retention.maximum-unpinned"
        ]
        assertExists(
            readbackField,
            timeout: 5,
            in: reopenedApp,
            context: "same-store maximum unpinned readback field"
        )
        let readbackApply = reopenedApp.buttons[
            "clipy.settings.retention.apply-item-limit"
        ]
        assertExists(
            readbackApply,
            timeout: 5,
            in: reopenedApp,
            context: "same-store Apply Item Limit"
        )
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                readbackField.value as? String == "1"
                    && !readbackApply.isEnabled
            },
            diagnostic(
                reopenedApp,
                context: "same-store authoritative count readback"
            )
        )
        XCTAssertFalse(
            reopenedApp.descendants(matching: .any)[
                "clipy.settings.retention.item-limit-status"
            ].exists,
            diagnostic(reopenedApp, context: "restart carries no stale success")
        )
    }

    @MainActor
    func testRaisingCountConfirmsBeforeRemovingAnExcessItem() async throws {
        let storeURL = try makeStoreURL()
        let (oldest, before) = try await seedHistoryAboveCountLimit(at: storeURL)
        XCTAssertEqual(before.limit, 1)
        XCTAssertEqual(before.usage.itemCount - before.usage.pinnedItemCount, 3)
        XCTAssertEqual(before.usage.pinnedItemCount, 1)
        XCTAssertEqual(before.payloads.count, before.usage.itemCount)

        let app = launchApp(storeURL: storeURL, captureAccess: "denied")
        defer { app.terminate() }
        let cancelledSheet = requestCountIncrease(in: app)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitUntil(timeout: 5) { !cancelledSheet.exists },
            diagnostic(app, context: "cancel raising the item limit")
        )
        app.terminate()
        let cancelled = try await readCountHistory(at: storeURL)
        XCTAssertEqual(cancelled, before)

        app.launch()
        let acceptedSheet = requestCountIncrease(in: app)
        let confirm = acceptedSheet.buttons["action-button-1"]
        assertExists(confirm, timeout: 5, in: app, context: "confirm raising the item limit")
        confirm.click()
        let status = app.descendants(matching: .any)["clipy.settings.retention.item-limit-status"]
        assertExists(status, timeout: 10, in: app, context: "receipt after confirmed increase")
        app.terminate()

        let applied = try await readCountHistory(at: storeURL)
        XCTAssertEqual(applied.limit, 2)
        XCTAssertEqual(applied.usage.position.rawValue, before.usage.position.rawValue + 1)
        XCTAssertEqual(applied.usage.pinnedItemCount, 1)
        XCTAssertEqual(applied.payloads, before.payloads.filter { $0.key != oldest })
    }

    @MainActor
    private func requestCountIncrease(in app: XCUIApplication) -> XCUIElement {
        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        assertExists(panel, timeout: 20, in: app, context: "panel before opening Retention Settings")
        app.typeKey(",", modifierFlags: .command)
        let retentionTab = app.buttons["clipy.settings.category.retention"]
        assertExists(retentionTab, timeout: 10, in: app, context: "Retention Settings")
        retentionTab.click()
        let fieldID = "clipy.settings.retention.maximum-unpinned"
        let field = app.textFields[fieldID]
        XCTAssertTrue(
            waitUntil(timeout: 5) { field.exists && field.isEnabled && field.value as? String == "1" },
            diagnostic(app, context: "current count limit loads before editing")
        )
        replaceText(in: field, with: "2")
        let apply = app.buttons["clipy.settings.retention.apply-item-limit"]
        XCTAssertTrue(
            waitUntil(timeout: 5) { apply.exists && apply.isEnabled },
            diagnostic(app, context: "apply the higher limit")
        )
        apply.click()
        let sheet = app.windows.containing(.textField, identifier: fieldID).firstMatch.sheets.firstMatch
        assertExists(sheet, timeout: 5, in: app, context: "higher count limit requests confirmation")
        return sheet
    }

    private struct CountHistorySnapshot: Equatable {
        let limit: Int?
        let usage: HistoryUsage
        let payloads: [HistoryItemReference: Data]
    }

    @MainActor
    private func seedHistoryAboveCountLimit(
        at url: URL
    ) async throws -> (HistoryItemReference, CountHistorySnapshot) {
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .persistent(storeURL: url), initialMaximumUnpinnedItems: 1
        ))
        let values = ["oldest unpinned", "next unpinned", "keep pinned", "newest unpinned"]
        var items: [HistoryItemReference] = []
        for (index, value) in values.enumerated() {
            let receipt = try await history.perform(.capture(ClipboardCapture(
                representations: [CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(value.utf8))],
                origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
                observedAt: Date(timeIntervalSinceReferenceDate: Double(index + 1))
            )))
            let inserted: HistoryItemReference?
            if case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome { inserted = item }
            else { inserted = nil }
            let item = try XCTUnwrap(inserted)
            items.append(item)
            if index < values.count - 1 {
                _ = try await history.perform(.placePinned(item.id, at: .last))
            }
        }
        for item in items.prefix(2) {
            _ = try await history.perform(.unpin(item.id))
        }
        let oldest = try XCTUnwrap(items.first)
        return (oldest, try await countHistory(in: history))
    }

    @MainActor
    private func readCountHistory(at url: URL) async throws -> CountHistorySnapshot {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .persistent(storeURL: url)))
        return try await countHistory(in: history)
    }

    @MainActor
    private func countHistory(in history: SQLiteHistory) async throws -> CountHistorySnapshot {
        let configuration = try await history.retentionConfiguration()
        let usage = try await history.usage()
        let page = try await history.browse(.init(kind: .recent, limit: 5))
        var payloads: [HistoryItemReference: Data] = [:]
        for row in page.rows {
            let payload = try await history.pastePayload(for: row.item.id)
            payloads[row.item] = try XCTUnwrap(payload.representations.first?.bytes)
        }
        return CountHistorySnapshot(limit: configuration.maximumUnpinnedItems, usage: usage, payloads: payloads)
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
        return app
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with value: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
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
            waitUntil(timeout: 10) { rows.count == expected },
            diagnostic(
                app,
                context: "\(context); expected \(expected) rows, observed \(rows.count)"
            )
        )
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
