/// PanelLifecycleHostedTests.swift — the bounded hosted Card 14C/14D leaf
/// for the actual floating window and panel-session owners. These tests use
/// the production `FloatingPanel`, `HistoryViewState`, and
/// `HistoryPanelSurfaceState`; the History double only records observation
/// registrations because storage semantics are outside this lifecycle leaf.
///
/// This same-process evidence does not claim WindowServer, Spaces, an actual
/// hardware power transition, fast-user-switching, or cross-process focus
/// behavior. Its sleep/wake leaves prove the documented NSWorkspace names,
/// object, registration center, and the product response to their delivery.
import AppKit
import Carbon.HIToolbox
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import PresentationUI
import Synchronization
import Testing
@testable import ClipyApp

@Suite("Hosted panel lifecycle", .serialized)
@MainActor
struct PanelLifecycleHostedTests {

    /// UI-7 settled-Escape contract through the actual AppDelegate-owned
    /// panel and SwiftUI list root. The first event clears the current query
    /// without retiring the session; the next closes it. Editor/Details are
    /// covered separately because their navigation destination owns Esc.
    @Test("settled list-root Escape clears search, then closes")
    func settledListRootEscapePreservesTheTwoStepIntent() async throws {
        let installed = installedOwner()
        let appDelegate = installed.appDelegate
        let composition = installed.composition
        let history = installed.history
        defer {
            appDelegate.closePanel()
            composition.stop()
        }

        appDelegate.openPanelForTesting()
        let panel = try #require(appDelegate.panelForTesting)
        await history.waitForObservationCount(1)
        _ = try #require(
            await focusedFieldEditor(in: panel),
            "The production search field never became first responder."
        )
        composition.viewState.searchText = "settled-escape-query"

        NSApp.sendEvent(try #require(escapeKeyDown(for: panel)))
        #expect(composition.viewState.searchText.isEmpty)
        #expect(panel.isPresented)

        NSApp.sendEvent(try #require(escapeKeyDown(for: panel)))
        #expect(!panel.isPresented)
        #expect(!(appDelegate.panelSurfaceState?.isSessionActive ?? true))
    }

    /// UI-7 destination ownership through the same hosted panel. This is a
    /// synthetic AppKit key-equivalent proof, not a physical keyboard/IME
    /// claim: the application dispatches an exact settled Escape to its key
    /// window, Details pops, and the list-root session remains alive.
    @Test("settled Details Escape returns to the live list session")
    func settledDetailsEscapeDismissesOnlyDetails() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        _ = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "details-escape-owner",
                observedAt: Date(timeIntervalSinceReferenceDate: 800_043_005)
            )
        ))
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(
                pasteboard: ComposedSupport.makePasteboard()
            )
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        defer {
            appDelegate.closePanel()
            composition.stop()
        }

        appDelegate.openPanelForTesting()
        let panel = try #require(appDelegate.panelForTesting)
        let surface = try #require(appDelegate.panelSurfaceState)
        let selected = await waitForHostedUI {
            surface.selectedReference(in: composition.viewState.rows) != nil
        }
        try #require(
            selected,
            "The real observed row never became the list selection."
        )

        let selectedReference = try #require(
            surface.selectedReference(in: composition.viewState.rows)
        )
        let rowIdentifier = "clipy.history.row.\(selectedReference.id.description)"
        let rowRendered = await waitForHostedUI {
            panel.contentView?.layoutSubtreeIfNeeded()
            return accessibilityElement(
                identifiedBy: rowIdentifier,
                in: panel.contentView
            ) != nil
        }
        try #require(
            rowRendered,
            "The selected production row never reached the public AX tree."
        )
        let rowElement = try #require(
            accessibilityElement(
                identifiedBy: rowIdentifier,
                in: panel.contentView
            )
        )
        let showDetails = try #require(
            (rowElement.accessibilityCustomActions() ?? []).first {
                $0.name == "Show Details"
            },
            "The production row did not expose its Show Details action."
        )
        let showDetailsHandler = try #require(
            showDetails.handler,
            "The production Show Details action had no callable handler."
        )
        try #require(showDetailsHandler())
        let detailsRendered = await waitForHostedUI {
            panel.contentView?.layoutSubtreeIfNeeded()
            return containsAccessibilityIdentifier(
                "clipy.details.root",
                in: panel.contentView
            )
        }
        try #require(
            detailsRendered,
            "The real rendered Details destination never became ready."
        )

        NSApp.sendEvent(try #require(escapeKeyDown(for: panel)))
        let detailsDismissed = await waitForHostedUI {
            panel.contentView?.layoutSubtreeIfNeeded()
            return !containsAccessibilityIdentifier(
                "clipy.details.root",
                in: panel.contentView
            )
        }

        #expect(detailsDismissed)
        #expect(surface.isAtListRoot)
        #expect(!containsAccessibilityIdentifier(
            "clipy.details.root",
            in: panel.contentView
        ))
        #expect(panel.isPresented)
        #expect(surface.isSessionActive)
    }

    /// Card 8G-2: the actual focused SwiftUI search field must override an
    /// inherited AppKit field-editor posture when a new panel session starts.
    /// This uses only the public NSWindow/NSTextView responder contract: it
    /// neither traverses NSHostingView internals nor relies on the runner's
    /// global spelling preferences.
    @Test("search refocus disables inherited automatic spelling correction")
    func searchRefocusDisablesInheritedAutomaticSpellingCorrection() async throws {
        let installed = installedOwner()
        let appDelegate = installed.appDelegate
        let composition = installed.composition
        let history = installed.history
        defer {
            appDelegate.closePanel()
            composition.stop()
        }

        appDelegate.openPanelForTesting()
        let panel = try #require(appDelegate.panelForTesting)
        await history.waitForObservationCount(1)
        let firstEditor = try #require(
            await focusedFieldEditor(in: panel),
            "The production search field never became the panel's public field editor."
        )
        #expect(firstEditor.isFieldEditor)
        #expect(!firstEditor.isAutomaticSpellingCorrectionEnabled)

        // Seed the opposite inherited posture after the first session ends.
        // Reopening must make the real TextField authoritative again; without
        // its autocorrection-disabled configuration this remains true and the
        // test fails even on a CI account whose global default is already off.
        appDelegate.closePanel()
        await history.waitForTerminationCount(1)
        firstEditor.isAutomaticSpellingCorrectionEnabled = true
        #expect(firstEditor.isAutomaticSpellingCorrectionEnabled)

        appDelegate.openPanelForTesting()
        await history.waitForObservationCount(2)
        let reopenedEditor = try #require(
            await focusedFieldEditor(in: panel),
            "The reopened production search field never regained focus."
        )
        #expect(reopenedEditor === firstEditor)
        #expect(!reopenedEditor.isAutomaticSpellingCorrectionEnabled)
    }

    @Test("focus loss ends one session; reopen starts one replacement observation")
    func focusLossClosesExactlyOnceAndReopenStartsFreshSession() async throws {
        let installed = installedOwner()
        let appDelegate = installed.appDelegate
        let composition = installed.composition
        let history = installed.history
        defer {
            appDelegate.closePanel()
            composition.stop()
        }

        appDelegate.openPanelForTesting()
        let panel = try #require(appDelegate.panelForTesting)
        let surface = try #require(appDelegate.panelSurfaceState)
        await history.waitForObservationCount(1)

        #expect(panel.isPresented)
        #expect(surface.isSessionActive)
        #expect(surface.sessionGeneration == 1)

        // `resignKey` is the production outside-click/focus-loss path. The
        // close callback owns both session retirement and view observation
        // cancellation; a duplicate AppKit notification must be a no-op.
        panel.resignKey()
        panel.resignKey()
        await panel.waitForDeferredFocusLossCloseForTesting()
        try #require(!panel.isPresented)
        await history.waitForTerminationCount(1)

        #expect(!panel.isPresented)
        #expect(!surface.isSessionActive)
        #expect(await history.observationCount == 1)
        #expect(await history.terminationCount == 1)

        appDelegate.openPanelForTesting()

        #expect(surface.isSessionActive)
        #expect(surface.sessionGeneration == 2)

        // A second activation signal in the same open episode must reuse the
        // active observation. Only close -> reopen creates a new generation.
        composition.viewState.activate()
        await history.waitForObservationCount(2)
        #expect(await history.observationCount == 2)
    }

    /// Card 14C app-activation leaf. `NSApplication.didResignActiveNotification`
    /// is not an `NSWorkspace` login-session resignation: it retires only the
    /// visible panel/browsing session. Capture remains owned by the always-live
    /// composition, and becoming active never fabricates a panel session.
    @Test("app resign closes; active then explicit summon starts a fresh session")
    func appActivationLifecycleRequiresAnExplicitFreshSummon() async throws {
        let installed = installedOwner()
        let appDelegate = installed.appDelegate
        let composition = installed.composition
        let history = installed.history
        defer {
            appDelegate.closePanel()
            composition.stop()
        }

        appDelegate.openPanelForTesting()
        let panel = try #require(appDelegate.panelForTesting)
        let surface = try #require(appDelegate.panelSurfaceState)
        await history.waitForObservationCount(1)
        #expect(panel.isPresented)
        #expect(surface.isSessionActive)
        #expect(surface.sessionGeneration == 1)
        #expect(composition.isCaptureObservationActiveForTesting)

        appDelegate.applicationDidResignActive(
            Notification(
                name: NSApplication.didResignActiveNotification,
                object: NSApp
            )
        )
        await history.waitForTerminationCount(1)
        #expect(!panel.isPresented)
        #expect(!surface.isSessionActive)
        #expect(await history.observationCount == 1)
        #expect(await history.terminationCount == 1)
        #expect(composition.isCaptureObservationActiveForTesting)

        appDelegate.applicationDidBecomeActive(
            Notification(
                name: NSApplication.didBecomeActiveNotification,
                object: NSApp
            )
        )
        await Task.yield()

        // Activation alone is not a summon and must not create an invisible
        // browsing owner. The next explicit summon starts one fresh session.
        #expect(!panel.isPresented)
        #expect(!surface.isSessionActive)
        #expect(surface.sessionGeneration == 1)
        #expect(await history.observationCount == 1)
        #expect(composition.isCaptureObservationActiveForTesting)

        appDelegate.openPanelForTesting()
        await history.waitForObservationCount(2)
        #expect(panel.isPresented)
        #expect(surface.isSessionActive)
        #expect(surface.sessionGeneration == 2)
        #expect(await history.observationCount == 2)
        #expect(await history.terminationCount == 1)
        #expect(composition.isCaptureObservationActiveForTesting)
    }

    /// Card 14C sleep leaf: production registers on the NSWorkspace-owned
    /// notification center with the documented shared-workspace object. The
    /// callback retires both visible browsing and capture observation without
    /// turning system sleep into the user's visible Pause state.
    @Test("workspace sleep closes panel and suspends capture observation")
    func workspaceSleepRetiresPanelAndCaptureOwners() async throws {
        let installed = installedOwner()
        let appDelegate = installed.appDelegate
        let composition = installed.composition
        let history = installed.history
        appDelegate.installWorkspaceLifecycleObservationForTesting()
        defer {
            appDelegate.removeWorkspaceLifecycleObservationForTesting()
            appDelegate.closePanel()
            composition.stop()
        }

        appDelegate.openPanelForTesting()
        let panel = try #require(appDelegate.panelForTesting)
        let surface = try #require(appDelegate.panelSurfaceState)
        await history.waitForObservationCount(1)
        #expect(panel.isPresented)
        #expect(surface.isSessionActive)
        #expect(composition.isCaptureObservationActiveForTesting)

        // Apple explicitly says the default center does not deliver these
        // messages. This negative discriminator prevents a superficially
        // equivalent but incorrect NotificationCenter.default registration.
        NotificationCenter.default.post(
            name: NSWorkspace.willSleepNotification,
            object: NSWorkspace.shared
        )
        await Task.yield()
        #expect(panel.isPresented)
        #expect(surface.isSessionActive)
        #expect(composition.isCaptureObservationActiveForTesting)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: NSObject()
        )
        await Task.yield()
        #expect(panel.isPresented)
        #expect(surface.isSessionActive)
        #expect(composition.isCaptureObservationActiveForTesting)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: NSWorkspace.shared
        )
        await history.waitForTerminationCount(1)

        #expect(!panel.isPresented)
        #expect(!surface.isSessionActive)
        #expect(!composition.workspaceActivityForTesting.isSystemAwake)
        #expect(!composition.isCaptureObservationActiveForTesting)
        #expect(composition.captureAccessState == .allowed)

        appDelegate.openPanelForTesting()
        #expect(!panel.isPresented)
        #expect(!surface.isSessionActive)
        #expect(surface.sessionGeneration == 1)

        composition.submitCaptureForTesting(
            ComposedSupport.textCapture(
                "must-not-enter-while-sleeping",
                observedAt: Date(timeIntervalSinceReferenceDate: 1)
            )
        )
        await Task.yield()
        #expect(await history.captureAttemptCount == 0)
    }

    /// Stopping observation is not permission to erase values already frozen
    /// and admitted before willSleep. The existing active+latest owner drains
    /// both slots while refusing any new sleep-period admission.
    @Test("workspace sleep drains an already admitted active and pending pair")
    func workspaceSleepPreservesThePreSleepCaptureBacklog() async throws {
        let base = try await ComposedSupport.openMemoryHistory()
        let history = FirstCaptureSuspendingHistory(base: base)
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let accessBehavior = Mutex(PasteboardAccessBehavior.allowed)
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            observerPollInterval: 60,
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: {
                accessBehavior.withLock { $0 }
            }
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        appDelegate.installWorkspaceLifecycleObservationForTesting()
        defer {
            appDelegate.removeWorkspaceLifecycleObservationForTesting()
            composition.stop()
        }

        composition.submitCaptureForTesting(
            ComposedSupport.textCapture(
                "active-before-sleep",
                observedAt: Date(timeIntervalSinceReferenceDate: 2)
            )
        )
        await history.waitUntilFirstCaptureIsSuspended()
        composition.submitCaptureForTesting(
            ComposedSupport.textCapture(
                "pending-before-sleep",
                observedAt: Date(timeIntervalSinceReferenceDate: 3)
            )
        )
        #expect(composition.captureHealth.activeCommitCount == 1)
        #expect(composition.captureHealth.pendingCaptureCount == 1)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: NSWorkspace.shared
        )
        #expect(!composition.isCaptureObservationActiveForTesting)
        #expect(composition.captureHealth.pendingCaptureCount == 1)

        accessBehavior.withLock { $0 = .denied }
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )
        #expect(composition.captureAccessState == .denied)
        #expect(!composition.isCaptureObservationActiveForTesting)
        #expect(composition.captureHealth.pendingCaptureCount == 1)

        await history.resumeFirstCapture()
        let drained = await ComposedSupport.waitFor {
            composition.captureHealth.activeCommitCount == 0
                && composition.captureHealth.pendingCaptureCount == 0
        }
        #expect(drained)
        let page = try await base.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.map(\.title) == [
            "pending-before-sleep",
            "active-before-sleep",
        ])
    }

    /// Card 14C wake leaf: wake restarts the one existing composition but
    /// baselines the current generation, so sleep-period content is excluded.
    /// Wake itself does not reopen UI; a later copy and explicit summon both
    /// work through their normal production paths.
    @Test("workspace wake baselines clipboard and allows a fresh summon")
    func workspaceWakeBaselinesThenCapturesTheNextChange() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("before-sleep", forType: .string)
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            observerPollInterval: 0.02,
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: { .allowed }
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        appDelegate.installWorkspaceLifecycleObservationForTesting()
        defer {
            appDelegate.removeWorkspaceLifecycleObservationForTesting()
            appDelegate.closePanel()
            composition.stop()
        }

        #expect(await Self.waitForRows(1, in: history))
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: NSWorkspace.shared
        )
        pasteboard.clearContents()
        pasteboard.setString("copied-while-sleeping", forType: .string)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )
        #expect(composition.workspaceActivityForTesting.isSystemAwake)
        #expect(composition.isCaptureObservationActiveForTesting)
        #expect(composition.captureHealth.activeCommitCount == 0)
        var page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.map(\.title) == ["before-sleep"])

        pasteboard.clearContents()
        pasteboard.setString("copied-after-wake", forType: .string)
        #expect(await Self.waitForRows(2, in: history))
        page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.map(\.title).contains("copied-after-wake"))
        #expect(!page.rows.map(\.title).contains("copied-while-sleeping"))

        #expect(appDelegate.panelForTesting == nil)
        appDelegate.openPanelForTesting()
        let panel = try #require(appDelegate.panelForTesting)
        let surface = try #require(appDelegate.panelSurfaceState)
        #expect(panel.isPresented)
        #expect(surface.isSessionActive)
        #expect(surface.sessionGeneration == 1)

        // A user Pause remains authoritative across a later sleep/wake pair;
        // didWake must not bypass the existing access reducer.
        composition.pauseCapture()
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: NSWorkspace.shared
        )
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )
        #expect(composition.captureAccessState == .userPaused)
        #expect(!composition.isCaptureObservationActiveForTesting)
    }

    /// Apple distinguishes login-session switching from ordinary app focus.
    /// The exact NSWorkspace pair stops capture and closes sensitive UI while
    /// switched out, then baselines on switch-in without reopening the panel.
    @Test("workspace session switch baselines and requires a fresh summon")
    func workspaceSessionSwitchUsesTheSharedLifecycleOwner() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("before-session-switch", forType: .string)
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            observerPollInterval: 0.02,
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: { .allowed }
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        appDelegate.installWorkspaceLifecycleObservationForTesting()
        defer {
            appDelegate.removeWorkspaceLifecycleObservationForTesting()
            appDelegate.closePanel()
            composition.stop()
        }

        #expect(await Self.waitForRows(1, in: history))
        appDelegate.openPanelForTesting()
        let panel = try #require(appDelegate.panelForTesting)
        let surface = try #require(appDelegate.panelSurfaceState)
        #expect(panel.isPresented)
        #expect(surface.sessionGeneration == 1)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: NSWorkspace.shared
        )
        #expect(!panel.isPresented)
        #expect(!surface.isSessionActive)
        #expect(
            !composition.workspaceActivityForTesting.isLoginSessionActive
        )
        #expect(!composition.isCaptureObservationActiveForTesting)

        pasteboard.clearContents()
        pasteboard.setString("copied-in-inactive-session", forType: .string)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: NSWorkspace.shared
        )
        #expect(
            composition.workspaceActivityForTesting.isLoginSessionActive
        )
        #expect(composition.isCaptureObservationActiveForTesting)
        #expect(!panel.isPresented)
        #expect(composition.captureHealth.activeCommitCount == 0)
        var page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.map(\.title) == ["before-session-switch"])

        pasteboard.clearContents()
        pasteboard.setString("copied-after-session-active", forType: .string)
        #expect(await Self.waitForRows(2, in: history))
        page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.map(\.title).contains("copied-after-session-active"))
        #expect(
            !page.rows.map(\.title).contains("copied-in-inactive-session")
        )

        appDelegate.openPanelForTesting()
        #expect(panel.isPresented)
        #expect(surface.isSessionActive)
        #expect(surface.sessionGeneration == 2)
    }

    @Test("an attached NSAlert preserves the panel until the alert ends")
    func modalAlertSuppressesFocusLossClose() async throws {
        let installed = installedOwner()
        let appDelegate = installed.appDelegate
        let composition = installed.composition
        let history = installed.history
        appDelegate.openPanelForTesting()
        let panel = try #require(appDelegate.panelForTesting)
        let surface = try #require(appDelegate.panelSurfaceState)
        await history.waitForObservationCount(1)
        let sessionGeneration = surface.sessionGeneration
        let alert = NSAlert()
        alert.messageText = "Hosted lifecycle alert"
        alert.addButton(withTitle: "OK")
        let alertWindow = alert.window
        defer {
            if panel.attachedSheet === alertWindow {
                panel.endSheet(alertWindow)
            }
            appDelegate.closePanel()
            composition.stop()
        }

        alert.beginSheetModal(for: panel) { _ in }
        // AppKit may synchronously deliver the parent resign callback before
        // publishing `attachedSheet`. Join the production deferred decision so
        // this assertion covers that exact ordering, not merely the later
        // already-attached state.
        await panel.waitForDeferredFocusLossCloseForTesting()
        #expect(panel.attachedSheet === alertWindow)
        #expect(panel.isPresented)
        #expect(surface.isSessionActive)
        #expect(surface.sessionGeneration == sessionGeneration)

        // AppKit transfers key status to a sheet. The production public-API
        // modal predicate must retain the panel while that sheet is attached.
        panel.resignKey()
        await panel.waitForDeferredFocusLossCloseForTesting()
        #expect(panel.isPresented)
        #expect(surface.isSessionActive)
        #expect(surface.sessionGeneration == sessionGeneration)

        panel.endSheet(alertWindow)
        #expect(panel.attachedSheet == nil)
        panel.resignKey()
        await panel.waitForDeferredFocusLossCloseForTesting()
        try #require(!panel.isPresented)
        #expect(!panel.isPresented)
        #expect(!surface.isSessionActive)
        #expect(surface.sessionGeneration == sessionGeneration)
    }

    private func installedOwner() -> (
        appDelegate: AppDelegate,
        composition: AppComposition,
        history: LifecycleObservationHistory
    ) {
        let history = LifecycleObservationHistory()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "com.clipy.panel-lifecycle.\(UUID().uuidString)"
            )
        )
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            observerPollInterval: 60,
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: { .allowed }
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        return (appDelegate, composition, history)
    }

    private static func waitForRows(
        _ expectedCount: Int,
        in history: any ClipboardHistory,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let page = try? await history.browse(
                HistoryBrowseRequest(kind: .recent, limit: 10)
            ), page.rows.count == expectedCount {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// SwiftUI applies FocusState after the hosted body is scheduled. A fixed
    /// scheduler-turn budget detects a missing focus transition without a
    /// wall-clock sleep or an unbounded hung test.
    private func focusedFieldEditor(
        in panel: FloatingPanel,
        attemptLimit: Int = 2_000
    ) async -> NSTextView? {
        for _ in 0..<attemptLimit {
            if let editor = panel.firstResponder as? NSTextView,
               editor.isFieldEditor {
                return editor
            }
            await Task.yield()
        }
        return nil
    }

    private func escapeKeyDown(for panel: FloatingPanel) -> NSEvent? {
        keyDown(
            for: panel,
            keyCode: UInt16(kVK_Escape),
            characters: "\u{1B}",
            modifierFlags: []
        )
    }

    private func keyDown(
        for panel: FloatingPanel,
        keyCode: UInt16,
        characters: String,
        modifierFlags: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    /// Reads only the app's own public accessibility hierarchy. This is the
    /// hosted render-boundary join for the SwiftUI destination; it requires no
    /// Accessibility authorization and does not inspect NSHostingView's
    /// private implementation tree.
    private func containsAccessibilityIdentifier(
        _ expected: String,
        in element: (any NSAccessibilityProtocol)?,
        depth: Int = 0
    ) -> Bool {
        accessibilityElement(
            identifiedBy: expected,
            in: element,
            depth: depth
        ) != nil
    }

    private func accessibilityElement(
        identifiedBy expected: String,
        in element: (any NSAccessibilityProtocol)?,
        depth: Int = 0
    ) -> (any NSAccessibilityProtocol)? {
        guard let element, depth < 64 else { return nil }
        if element.accessibilityIdentifier() == expected { return element }
        for child in element.accessibilityChildren() ?? [] {
            if let match = accessibilityElement(
                identifiedBy: expected,
                in: child as? any NSAccessibilityProtocol,
                depth: depth + 1
            ) {
                return match
            }
        }
        return nil
    }

    /// A monotonic hosted-render deadline. Sleeping briefly releases the main
    /// actor so AppKit/SwiftUI can publish responder and accessibility state;
    /// unlike a fixed yield count, the budget remains meaningful on a busy
    /// runner (REVIEW UI-7 / Card 14A).
    private func waitForHostedUI(
        timeout: Duration = .seconds(3),
        condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

/// Records only lifecycle-facing observation registrations. Its streams stay
/// open until the view-state cancels them, so each count is one live panel
/// observation rather than a loop that immediately completes and restarts.
actor LifecycleObservationHistory: ClipboardHistory {
    private(set) var observationCount = 0
    private(set) var terminationCount = 0
    private(set) var captureAttemptCount = 0
    private var observationContinuations: [
        AsyncThrowingStream<HistoryPage, Error>.Continuation
    ] = []
    private var countWaiters: [
        (target: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var terminationWaiters: [
        (target: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func waitForObservationCount(_ target: Int) async {
        guard observationCount < target else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((target, continuation))
        }
    }

    func waitForTerminationCount(_ target: Int) async {
        guard terminationCount < target else { return }
        await withCheckedContinuation { continuation in
            terminationWaiters.append((target, continuation))
        }
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        if case .capture = action {
            captureAttemptCount += 1
        }
        return .unchanged
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        throw CancellationError()
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        observationCount += 1
        let (stream, continuation) =
            AsyncThrowingStream<HistoryPage, Error>.makeStream()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.recordObservationTermination() }
        }
        observationContinuations.append(continuation)

        var remaining: [
            (target: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in countWaiters {
            if waiter.target <= observationCount {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        countWaiters = remaining
        return stream
    }

    private func recordObservationTermination() {
        terminationCount += 1
        var remaining: [
            (target: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in terminationWaiters {
            if waiter.target <= terminationCount {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        terminationWaiters = remaining
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        throw HistoryFailure.notFound(id)
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        throw HistoryFailure.notFound(id)
    }

    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        nil
    }

    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        throw CancellationError()
    }
}
