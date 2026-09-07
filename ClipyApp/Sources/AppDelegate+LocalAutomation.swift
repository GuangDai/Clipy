import AppKit

extension AppDelegate {
    /// Join listener shutdown before terminating. Closing the listener does
    /// not revoke the user's persistent enrollment, which resumes next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let composition else { return .terminateNow }
        Task {
            await composition.stopLocalAutomation()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
