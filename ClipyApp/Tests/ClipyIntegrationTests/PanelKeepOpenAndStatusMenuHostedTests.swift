/// PanelKeepOpenAndStatusMenuHostedTests.swift — hosted evidence for the
/// AppKit-side wiring owned by the composition root:
///
/// - the status item's secondary-click menu: the four product items, the
///   Pause/Resume title flipping with the composition-owned capture-pause
///   state, and the primary-click summon path staying byte-identical;
/// - the keep-open pin: a pinned panel survives the production `resignKey`
///   focus-loss path, an unpinned panel still closes through it, and every
///   actual close resets the pin;
/// - the capture ignore gate: a complete capture whose source application
///   is on the Settings ▸ Privacy ignore list never occupies a lane slot
///   and never reaches History, while non-ignored and unknown sources
///   capture normally.
///
/// The menu pop-up itself (AppKit's modal tracking) is not a same-process
/// assertable surface; the evidence reads the lazily built menu's content
/// and drives the same action entry point the button dispatches to.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import PresentationUI
import Testing
@testable import ClipyApp

@Suite("Hosted keep-open pin, status menu, and capture ignore gate", .serialized)
@MainActor
struct PanelKeepOpenAndStatusMenuHostedTests {

    // MARK: - Click routing

    @Test("only a right-mouse-up diverts to the menu")
    func clickRoutingOnlyDivertsRightMouseUp() {
        #expect(
            StatusItemClickDecision.disposition(eventType: .rightMouseUp)
                == .showMenu
        )
        // Everything else — including the nil event of a programmatic
        // action invocation — is the pre-menu primary-click behavior.
        #expect(
            StatusItemClickDecision.disposition(eventType: .leftMouseUp)
                == .togglePanel
        )
        #expect(
            StatusItemClickDecision.disposition(eventType: .leftMouseDown)
                == .togglePanel
        )
        #expect(
            StatusItemClickDecision.disposition(eventType: .keyDown)
                == .togglePanel
        )
        #expect(
            StatusItemClickDecision.disposition(eventType: nil)
                == .togglePanel
        )
    }

    // MARK: - Status-item menu content

    @Test("status menu exposes the four product items")
    func statusMenuExposesTheFourProductItems() {
        let appDelegate = AppDelegate()
        let menu = appDelegate.statusItemMenuForTesting

        let items = menu.items.filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == [
            "Show Clipboard History",
            "Pause Clipboard Monitoring for 5 Minutes",
            "Settings…",
            "Quit Clipy",
        ])
        // The layout contract: Show, Pause/Resume, separator, Settings…,
        // separator, Quit.
        #expect(menu.items.count == 6)
        #expect(menu.items[2].isSeparatorItem)
        #expect(menu.items[4].isSeparatorItem)
    }

    @Test("pause item title flips with the capture-pause state")
    func pauseItemTitleFlipsWithCapturePauseState() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: { .allowed }
        )
        defer { composition.stop() }
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        #expect(appDelegate.captureAccessState == .allowed)

        let menu = appDelegate.statusItemMenuForTesting
        let pauseItem = menu.items.filter { !$0.isSeparatorItem }[1]

        // `NSMenu.update()` only runs NSMenuValidation enable/disable — it
        // never invokes the delegate's `menuNeedsUpdate`. The production
        // display-time refresh entry is the delegate callback AppKit fires
        // before each presentation, so drive that seam directly.
        func refreshThroughDelegate() {
            menu.delegate?.menuNeedsUpdate?(menu)
        }

        refreshThroughDelegate()
        #expect(pauseItem.title == "Pause Clipboard Monitoring for 5 Minutes")
        #expect(pauseItem.isEnabled)

        appDelegate.pauseCapture()
        #expect(appDelegate.captureAccessState == .userPaused)
        refreshThroughDelegate()
        #expect(pauseItem.title == "Resume Clipboard Monitoring")
        #expect(pauseItem.isEnabled)

        appDelegate.recoverCaptureAccess()
        #expect(appDelegate.captureAccessState == .allowed)
        refreshThroughDelegate()
        #expect(pauseItem.title == "Pause Clipboard Monitoring for 5 Minutes")
        #expect(pauseItem.isEnabled)
    }

    @Test("primary status-item click still summons and dismisses the panel")
    func primaryStatusItemClickStillTogglesThePanel() throws {
        let appDelegate = AppDelegate()
        appDelegate.installStatusItemForTesting()
        defer {
            appDelegate.closePanel()
            appDelegate.removeStatusItemForTesting()
        }
        #expect(appDelegate.panelForTesting == nil)

        // Outside event dispatch `NSApp.currentEvent` is nil, so this is
        // the primary-click routing — the pre-menu summon behavior.
        appDelegate.performStatusItemClickForTesting()
        let panel = try #require(appDelegate.panelForTesting)
        #expect(panel.isPresented)

        appDelegate.performStatusItemClickForTesting()
        #expect(!panel.isPresented)
    }

    // MARK: - Keep-open pin

    @Test("pinned panel survives focus loss; the close still resets the pin")
    func pinnedPanelSurvivesResignKeyAndCloseResetsThePin() async throws {
        let appDelegate = AppDelegate()
        defer { appDelegate.closePanel() }
        appDelegate.openPanelForTesting()
        let panel = try #require(appDelegate.panelForTesting)
        #expect(panel.isPresented)

        #expect(!appDelegate.isPanelKeepOpenActive)
        appDelegate.togglePanelKeepOpen()
        #expect(appDelegate.isPanelKeepOpenActive)

        // The production outside-click path: with the pin active the
        // deferred focus-loss decision must skip its close.
        panel.resignKey()
        await panel.waitForDeferredFocusLossCloseForTesting()
        #expect(panel.isPresented)
        #expect(appDelegate.isPanelKeepOpenActive)

        // An explicit close is unaffected by the pin and resets it for the
        // next summon.
        appDelegate.closePanel()
        #expect(!panel.isPresented)
        #expect(!appDelegate.isPanelKeepOpenActive)
    }

    @Test("unpinned panel still closes on focus loss")
    func unpinnedPanelStillClosesOnResignKey() async throws {
        let appDelegate = AppDelegate()
        defer { appDelegate.closePanel() }
        appDelegate.openPanelForTesting()
        let panel = try #require(appDelegate.panelForTesting)
        #expect(panel.isPresented)

        panel.resignKey()
        await panel.waitForDeferredFocusLossCloseForTesting()
        #expect(!panel.isPresented)
        #expect(!appDelegate.isPanelKeepOpenActive)
    }

    // MARK: - Capture ignore gate

    @Test("an ignored source application never enters history")
    func ignoredSourceBundleIDIsDroppedBeforeHistory() async throws {
        let ignoredBundleID = "com.example.ignored-\(UUID().uuidString)"
        let keptBundleID = "com.example.kept-\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(
            forKey: CaptureIgnoreList.defaultsKey
        )
        defaults.set([ignoredBundleID], forKey: CaptureIgnoreList.defaultsKey)
        defer {
            if let previousValue {
                defaults.set(
                    previousValue,
                    forKey: CaptureIgnoreList.defaultsKey
                )
            } else {
                defaults.removeObject(
                    forKey: CaptureIgnoreList.defaultsKey
                )
            }
        }

        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: { .allowed }
        )
        defer { composition.stop() }

        composition.submitCaptureForTesting(ComposedSupport.textCapture(
            "ignored-source-value",
            observedAt: Date(timeIntervalSinceReferenceDate: 1),
            source: ignoredBundleID
        ))
        // Admission is synchronous: a gated value never occupies either
        // lane slot and — like a concealed capture — is not a health
        // failure.
        #expect(composition.captureHealth.activeCommitCount == 0)
        #expect(composition.captureHealth.pendingCaptureCount == 0)
        #expect(composition.captureHealth.failedCaptureCount == 0)
        await Task.yield()
        var page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(!page.rows.map(\.title).contains("ignored-source-value"))

        composition.submitCaptureForTesting(ComposedSupport.textCapture(
            "kept-source-value",
            observedAt: Date(timeIntervalSinceReferenceDate: 2),
            source: keptBundleID
        ))
        #expect(await Self.waitForRows(1, in: history))

        // A capture with no observed source application is not ignored.
        composition.submitCaptureForTesting(ComposedSupport.textCapture(
            "unknown-source-value",
            observedAt: Date(timeIntervalSinceReferenceDate: 3)
        ))
        #expect(await Self.waitForRows(2, in: history))

        page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.map(\.title).contains("kept-source-value"))
        #expect(page.rows.map(\.title).contains("unknown-source-value"))
        #expect(!page.rows.map(\.title).contains("ignored-source-value"))
    }

    private static func waitForRows(
        _ count: Int,
        in history: SwiftDataHistory
    ) async -> Bool {
        for _ in 0..<200 {
            if let page = try? await history.browse(
                HistoryBrowseRequest(kind: .recent, limit: 10)
            ), page.rows.count == count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
